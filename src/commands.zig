const std = @import("std");
const r = @import("root.zig");
const App = r.app.App;
const ChatEntry = r.app.ChatEntry;

// thread safe command queue
pub const CommandQueue = struct {
    arena: std.heap.ArenaAllocator,
    _data: std.ArrayList(Command) = .empty,
    _m: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator) !CommandQueue {
        return CommandQueue{
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
        defer self._m.unlock(io);
        for (self._data.items) |*cmd| try cmd.execute(app);
        self._data = .empty;
        _ = self.arena.reset(.retain_capacity);
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
    set_mode: u8,
    spawn_agent: SpawnArgs,
    queue_agent_message: QueuedMessageArgs,
    scroll_to: usize,
    scroll_up: usize,
    scroll_down: usize,
    compact,
    reload_mcp,
    custom: CustomCmd,
    load_session: []const u8,
    save_session: []const u8,
    attach_screenshot: ScreenshotArgs,
    add_tool: AddToolArgs,
    // -------------------------------------------

    pub const AddToolArgs = struct {
        agent_type: r.reg.AgentType,
        tool_name: []const u8,
    };

    pub const PlanArgs = struct {
        plan_prompt: []const u8,
    };

    pub const SpawnArgs = struct {
        parent_id: ?r.prv.Swarm.AgentId = null,
        agent_id: r.prv.Swarm.AgentId,
        prompt: []const r.prv.adapter.ContentPart,
        agent_type: u8 = @intFromEnum(r.reg.AgentType.main),
        tool_budget: u32 = 64,
        effort: r.prv.config.EffortLevel = .min,
        fork: bool = false,
        level: r.prv.agent.AgentPermissionLevel = .read,
        chat_entry: ?ChatEntry = null,
    };

    pub const CustomCmd = struct {
        ptr: *anyopaque,
        func: *const fn (*anyopaque, *App) anyerror!void,
    };

    pub const QueuedMessageArgs = struct {
        agent_id: r.prv.Swarm.AgentId,
        parts: []const r.prv.adapter.ContentPart,
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
                if (app.main_agent_id) |id| {
                    app.event_bus.emit(app, .{ .agent_cancelled = .{ .id = id } }) catch {};
                }
                app.swarm.cancelAll();
                app.dropStreamingPreview();
                app.cleanupCancelledTurn();
                app.running = false;
                app.auto_scroll = true;
            },
            .set_mode => |m| {
                app.mode = @enumFromInt(m);
                if (app.main_agent_id) |id| {
                    const agent = app.swarm.getAgent(id).?;
                    agent.mode_idx = m;
                    agent.flags.force_full_reminder = true;
                }
            },
            .retry => {
                if (app.main_agent_id) |id| {
                    app.swarm.retryAgent(id);
                    app.running = true;
                    app.auto_scroll = true;
                    app.scroll_offset = 0;
                }
            },
            .scroll_up => |delta| {
                app.auto_scroll = false;
                app.scroll_offset = @min(app.scroll_offset +| delta, std.math.maxInt(u16));
            },
            .scroll_to => |val| {
                app.scroll_offset = @min(val, std.math.maxInt(u16));
                app.auto_scroll = false;
            },
            .scroll_down => |delta| {
                app.scroll_offset -|= delta;
                if (app.scroll_offset == 0) app.auto_scroll = true;
            },
            .queue_agent_message => |arg| {
                const parts = try r.util.deepClone(@TypeOf(arg.parts), arg.parts, alloc);
                const chat_entry = if (arg.chat_entry) |en| try r.util.deepClone(ChatEntry, en, alloc) else null;
                try app.queued.push(alloc, arg.agent_id, chat_entry, parts);

                app.running = true;
                app.auto_scroll = true;
                app.scroll_offset = 0;

                const state = app.swarm.getSlotState(arg.agent_id);
                if (state != .active) {
                    try app.swarm.runAgent(arg.agent_id);
                }
            },
            .compact => {
                if (app.main_agent_id) |id| {
                    const ag = app.swarm.getAgent(id).?;
                    try app.event_bus.emit(app, .{ .agent_complete = id });
                    ag.requestCompaction();
                    app.running = true;
                    app.auto_scroll = true;
                }
            },
            .reload_mcp => {
                try app.reloadMcpTools();
            },
            .spawn_agent => |arg| {
                if (arg.fork) {
                    try app.swarm.forkAgentInSlot(arg.parent_id.?, arg.agent_id);
                } else {
                    try app.swarm.newAgentInSlot(
                        arg.agent_id,
                        .max,
                        arg.parent_id,
                        arg.agent_type,
                        @intFromEnum(app.mode),
                    );
                }
                const agent = app.swarm.getAgent(arg.agent_id).?;
                try app.configureAgent(agent);

                agent.permission_level = arg.level;
                agent.max_allowed_tool_calls = arg.tool_budget;

                try app.event_bus.emit(app, .{
                    .agent_created = .{ .id = arg.agent_id, .type_idx = agent.type_idx, .depth = agent.depth },
                });

                if (arg.parent_id == null) {
                    if (app.main_agent_id) |ag_id| {
                        std.log.warn("Dropping active agent without reset!", .{});
                        if (app.swarm.getAgent(ag_id)) |ag| ag.deinit();
                        app.chat_entries.clearRetainingCapacity();
                    }
                    app.main_agent_id = arg.agent_id;
                }

                if (arg.chat_entry) |en| {
                    const entry = try r.util.deepClone(ChatEntry, en, alloc);
                    try app.chat_entries.append(alloc, entry);
                }

                const prompt = try r.util.deepClone(@TypeOf(arg.prompt), arg.prompt, alloc);
                try app.swarm.runAgentWithMsg(arg.agent_id, prompt);
                try app.event_bus.emit(app, .{ .agent_started = arg.agent_id });
                app.running = true;
            },
            .push_notification => |msg| {
                try app.notifications.append(app.arena_app.allocator(), "{s}", .{msg});
                // app.pushSystemMessage("{s}", .{msg});
            },
            .push_chat_entry => |en| {
                const entry = try r.util.deepClone(ChatEntry, en, alloc);
                try app.chat_entries.append(alloc, entry);
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
                app.context_factory.addAgentTool(arg.agent_type, arg.tool_name) catch return;
                if (app.main_agent_id) |id| {
                    if (app.swarm.getAgent(id)) |agent| {
                        var set = r.reg.ToolSet{};
                        app.context_factory.build_toolset(@enumFromInt(agent.type_idx), &set) catch return;
                        try agent.setTools(set.slice());
                    }
                }
            },
        }
    }
};
