const std = @import("std");
const r = @import("root.zig");
const App = r.app.App;
const ChatEntry = r.app.ChatEntry;

// thread safe command queue
pub const CommandQueue = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    _data: std.ArrayList(Command) = .empty,
    _m: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator) !CommandQueue {
        return CommandQueue{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    /// push a command into queue. Referenced data is deep-cloned into the
    /// queue's arena, so callers do not need to pre-clone. `custom.ptr`
    /// (`*anyopaque`) is passed through — caller owns its lifetime.
    pub fn append(self: *CommandQueue, io: std.Io, cmd: Command) !void {
        try self._m.lock(io);
        defer self._m.unlock(io);
        const alloc = self.arena.allocator();
        const owned = try r.util.deepClone(Command, cmd, alloc);
        try self._data.append(alloc, owned);
    }

    pub fn apply(self: *CommandQueue, io: std.Io, app: *App) !void {
        try self._m.lock(io);
        var arena = self.arena;
        var data = self._data;
        self.arena = std.heap.ArenaAllocator.init(self.alloc);
        self._data = .empty;
        self._m.unlock(io);
        defer arena.deinit();

        var i: u32 = 0;
        while (i < data.items.len) : (i += 1) {
            try data.items[i].execute(app);
        }

        if (self._data.items.len > 0) try self.apply(io, app);
    }

    pub fn deinit(self: *CommandQueue) void {
        self.arena.deinit();
    }
};

// defered mutation of the app state
// exposed to lua
pub const Command = union(enum) {
    const Self = @This();
    // -------------------------------------------
    reset_session,
    cancel,
    retry,
    push_notification: []const u8,
    push_chat_entry: ChatEntry,
    spawn_agent: SpawnArgs,
    queue_agent_message: QueuedMessageArgs,
    scroll_to: usize,
    scroll_up: usize,
    scroll_down: usize,
    cd: []const u8,
    compact,
    reload_mcp,
    start_mcp: StartArgs,
    custom: CustomCmd,
    load_session: []const u8,
    save_session: []const u8,
    attach_screenshot: ScreenshotArgs,
    add_tool: AddToolArgs,
    // -------------------------------------------

    pub const AddToolArgs = struct {
        agent_type: r.ContextFactory.AgentType,
        tool_name: []const u8,
    };

    pub const StartArgs = struct {
        name: []const u8,
    };

    pub const PlanArgs = struct {
        plan_prompt: []const u8,
    };

    pub const SpawnArgs = struct {
        parent_id: ?r.AgentId = null,
        agent_id: r.AgentId,
        prompt: []const r.sdk.Part,
        agent_type: u8 = @intFromEnum(r.ContextFactory.AgentType.general),
        fork: bool = false,
        chat_entry: ?ChatEntry = null,
        cwd: []const u8 = "",
        background: bool = false,
    };

    pub const CustomCmd = struct {
        ptr: *anyopaque,
        func: *const fn (*anyopaque, *App) anyerror!void,
    };

    pub const QueuedMessageArgs = struct {
        agent_id: r.AgentId,
        parts: []const r.sdk.Part,
        /// optional display message for render
        chat_entry: ?ChatEntry = null,
    };

    pub const ScreenshotArgs = struct {
        media_type: []const u8 = "image/png",
        data: []const u8,
    };

    pub fn execute(self: *Self, app: *App) !void {
        const alloc = app.sessionAlloc();
        switch (self.*) {
            .reset_session => app.reset(),
            .cancel => {
                const checkpoint_start = if (app.main_agent_id) |id|
                    if (app.registry.get(id)) |agent| agent.history().len else null
                else
                    null;
                if (app.main_agent_id) |id| {
                    app.event_bus.emit(app, .{ .agent_cancelled = .{ .id = id } }) catch {};
                }
                app.cancelPermissions();
                app.registry.cancelAll();
                app.exec_pool.cancelAll();
                app.dropStreamingPreview();
                if (app.main_agent_id) |id| {
                    if (checkpoint_start) |start| try app.appendAgentHistory(id, start, app.sdk_run_rendered_steps);
                }
                app.sdk_run_rendered_steps = 0;

                app.running = false;
                app.auto_scroll = true;
            },
            .retry => {
                if (app.main_agent_id) |id| {
                    app.sdk_run_rendered_steps = 0;
                    try app.registry.retry(id, .{ .max_steps = std.math.maxInt(usize) });
                    app.running = true;
                    app.auto_scroll = true;
                    app.scroll_offset = 0;
                }
            },
            .scroll_up => |delta| {
                app.auto_scroll = false;
                app.scroll_offset +|= delta;
            },
            .scroll_to => |val| {
                app.scroll_offset = val;
                app.auto_scroll = false;
            },
            .scroll_down => |delta| {
                app.scroll_offset -|= delta;
                if (app.scroll_offset == 0) app.auto_scroll = true;
            },
            .queue_agent_message => |arg| {
                const parts = try r.util.deepClone(@TypeOf(arg.parts), arg.parts, alloc);
                const chat_entry = if (arg.chat_entry) |en| try r.util.deepClone(ChatEntry, en, alloc) else null;
                if (app.streaming_entry != null) try app.flushSdkPreview();
                if (chat_entry) |entry| try app.appendChatEntry(alloc, entry);
                const agent = app.registry.get(arg.agent_id) orelse return;
                try agent.queueMessages(&.{.{ .role = .user, .content = parts }});

                app.running = true;
                app.auto_scroll = true;
                app.scroll_offset = 0;

                const state = app.registry.state(arg.agent_id);
                if (state != .active) {
                    if (app.main_agent_id == arg.agent_id) app.sdk_run_rendered_steps = 0;
                    try app.registry.run(arg.agent_id, .{ .max_steps = std.math.maxInt(usize) });
                }
            },
            .cd => |path| {
                if (path.len == 0) return;
                const base = app.exec_pool.effectiveCwd(app.cwd);
                if (std.fs.path.resolve(app.appAlloc(), &.{ base, path })) |resolved| {
                    if (app.exec_pool.ssh_active) {
                        if (app.exec_pool.ssh_target) |*tar| {
                            const new_remote = app.exec_pool.alloc.dupe(u8, resolved) catch return;
                            app.exec_pool.alloc.free(tar.cwd);
                            tar.cwd = new_remote;
                        }
                    }
                    app.cwd = resolved;
                    app.context_factory.rescanSkills(resolved);
                    if (app.main_agent_id) |id| {
                        if (app.registry.get(id)) |ag| ag.setCwd(resolved) catch {};
                    }
                } else |_| {}
            },
            .compact => {
                if (app.main_agent_id) |id| {
                    const result = try app.registry.compact(id);
                    if (app.streaming_entry != null) try app.flushSdkPreview();
                    switch (result) {
                        .started => app.pushSystemMessage("compaction started", .{}),
                        .queued => app.pushSystemMessage("compaction queued for the next turn", .{}),
                        .running => app.pushSystemMessage("compaction already running", .{}),
                        .empty => app.pushSystemMessage("nothing to compact", .{}),
                    }
                    app.running = true;
                    app.auto_scroll = true;
                    app.dirty = true;
                } else {
                    app.pushSystemMessage("no agent to compact", .{});
                    app.dirty = true;
                }
            },
            .reload_mcp => {
                try app.reloadMcpTools();
            },
            .start_mcp => |arg| {
                if (!app.lua_vm.enableMcp(arg.name)) return;
                try app.reloadMcpTools();
            },
            .spawn_agent => |arg| {
                var model_config: ?r.models.Config = null;
                if (!arg.fork) {
                    if (app.registry.state(arg.agent_id) != .reserved) return;
                    switch (app.context_factory.buildAgentApiConfig(
                        @enumFromInt(arg.agent_type),
                        &app.config,
                        app.exec_pool.env,
                    )) {
                        .config => |config| model_config = config,
                        .diagnostic => |diagnostic| {
                            app.registry.releaseReservation(arg.agent_id);
                            if (arg.chat_entry) |en| {
                                const entry = try r.util.deepClone(ChatEntry, en, alloc);
                                try app.appendChatEntry(alloc, entry);
                            }
                            showProviderOnboarding(app, diagnostic);
                            app.running = app.registry.countActive() > 0;
                            app.auto_scroll = true;
                            app.scroll_offset = 0;
                            app.dirty = true;
                            return;
                        },
                    }
                }

                var constructed = false;
                errdefer if (constructed)
                    app.registry.release(arg.agent_id)
                else
                    app.registry.releaseReservation(arg.agent_id);

                const cwd = if (arg.cwd.len > 0)
                    arg.cwd
                else if (arg.parent_id) |parent_id|
                    if (app.registry.get(parent_id)) |parent| parent.cwd else app.cwd
                else
                    app.cwd;
                const agent = if (arg.fork)
                    try app.registry.activateFork(arg.agent_id, arg.parent_id.?)
                else
                    try app.registry.activate(arg.agent_id, model_config.?, .{ .identity = .{
                        .type_idx = arg.agent_type,
                        .name = app.context_factory.agentName(@enumFromInt(arg.agent_type)),
                        .parent = if (arg.parent_id) |id| id.pack() else null,
                        .depth = if (arg.parent_id) |id| app.registry.get(id).?.depth + 1 else 0,
                        .cwd = cwd,
                    }, .context_limit = app.default_context_limit });
                constructed = true;
                agent.background = arg.background;
                try app.configureAgent(arg.agent_id, agent);

                try app.event_bus.emit(app, .{
                    .agent_created = .{ .id = arg.agent_id, .type_idx = agent.type_idx, .depth = agent.depth },
                });

                if (arg.parent_id == null) {
                    if (app.main_agent_id) |ag_id| {
                        std.log.warn("Dropping active agent without reset!", .{});
                        app.chat_entries.clearRetainingCapacity();
                        app.registry.release(ag_id);
                    }
                    app.main_agent_id = arg.agent_id;
                }

                if (arg.chat_entry) |en| {
                    const entry = try r.util.deepClone(ChatEntry, en, alloc);
                    try app.appendChatEntry(alloc, entry);
                }

                try agent.setMessages(&.{.{ .role = .user, .content = arg.prompt }});
                if (arg.parent_id == null) app.sdk_run_rendered_steps = 0;
                try app.registry.run(arg.agent_id, .{ .max_steps = std.math.maxInt(usize) });
                try app.event_bus.emit(app, .{ .agent_started = arg.agent_id });
                app.running = true;
            },
            .push_notification => |msg| {
                try app.notifications.append(app.gpa, "{s}", .{msg});
            },
            .push_chat_entry => |en| {
                const entry = try r.util.deepClone(ChatEntry, en, alloc);
                try app.appendChatEntry(alloc, entry);
            },
            .custom => |arg| {
                try arg.func(arg.ptr, app);
            },
            .load_session => |path| {
                const file = try std.Io.Dir.cwd().openFile(app.context_factory.io, path, .{ .mode = .read_only });
                var buf: [64]u8 = undefined;
                var reader = file.reader(app.context_factory.io, &buf);

                r.session.loadSession(app, &reader.interface) catch {
                    // --
                };
            },
            .save_session => |path| {
                // Ensure parent directory exists
                const parent = std.fs.path.dirname(path) orelse ".";
                std.Io.Dir.cwd().createDirPath(app.context_factory.io, parent) catch {};
                const file = try std.Io.Dir.cwd().createFile(app.context_factory.io, path, .{});
                var buf: [64]u8 = undefined;
                var writer = file.writer(app.context_factory.io, &buf);

                r.session.saveSession(app, &writer.interface) catch {
                    // ---
                };
            },
            .attach_screenshot => |arg| {
                _ = arg.media_type;
                if (arg.data.len == 0) return;

                const encoded_len = std.base64.standard.Encoder.calcSize(arg.data.len);
                const encoded = try alloc.alloc(u8, encoded_len);
                _ = std.base64.standard.Encoder.encode(encoded, arg.data);
                app.screenshot_buf = encoded;
                app.dirty = true;
            },
            .add_tool => |arg| {
                app.lua_vm.vm_mu.lockUncancelable(app.io);
                defer app.lua_vm.vm_mu.unlock(app.io);
                app.context_factory.addAgentTool(arg.agent_type, arg.tool_name) catch return;
                if (app.main_agent_id) |id| {
                    if (app.registry.get(id)) |agent| {
                        if (agent.task != null) {
                            agent.markToolsDirty();
                        } else {
                            try app.context_factory.refreshAgentTools(&app.config, agent, app.toolBase(id));
                        }
                    }
                }
            },
        }
    }
};

fn showProviderOnboarding(app: *App, diagnostic: r.ContextFactory.AgentConfigDiagnostic) void {
    const config_path = "~/.config/blitzdenk/blitz.lua";
    const example =
        \\local provider = blitz.add_provider({
        \\    type = "openai",
        \\    url = "https://api.openai.com/v1",
        \\    key_envar = "OPENAI_API_KEY",
        \\})
        \\local model = blitz.add_model({
        \\    name = "gpt-5.4-mini",
        \\    provider = provider,
        \\})
        \\blitz.set_model_agent(blitz.AGENT_GENERAL, model, "max")
        \\
        \\Then set the key before launching Blitzdenk:
        \\export OPENAI_API_KEY=...
        \\Restart Blitzdenk after changing its launch environment, then resend your message from history.
    ;

    switch (diagnostic) {
        .no_agent_model => |name| {
            app.pushSystemMessage(
                "Agent `{s}` has no model bound. Bind a model per agent with `blitz.set_model_agent(AGENT_TYPE, model, effort?)` or `model =` in `blitz.add_agent`. Edit {s}.\n\n{s}",
                .{ name, config_path, example },
            );
            app.notifications.append(app.gpa, "Agent `{s}` has no model bound", .{name}) catch {};
        },
        .invalid_provider => {
            app.pushSystemMessage(
                "The configured provider is invalid or inactive. Check its handle and model binding in {s}.\n\n{s}",
                .{ config_path, example },
            );
            app.notifications.append(app.gpa, "Configured provider is invalid or inactive", .{}) catch {};
        },
        .missing_api_key => |name| {
            app.pushSystemMessage(
                "Provider configuration is missing the required environment variable `{s}`. Set it in the environment that launches Blitzdenk. Configuration lives at {s}.\n\n{s}",
                .{ name, config_path, example },
            );
            app.notifications.append(app.gpa, "Missing required environment variable: {s}", .{name}) catch {};
        },
    }
}
