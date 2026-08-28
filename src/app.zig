const std = @import("std");
const r = @import("root.zig");
const text_utils = r.tui.text_utils;
const log = std.log.scoped(.app);

pub const PROMPT_HISTORY_FILENAME = "prompt_history.json";
pub const MAX_HISTORY = 100;
pub const CONTEXT_LIMIT = 124 * 1024;
const COMMAND_COMPLETION_ROWS = 64;

pub const ChatRole = enum { system, user, agent };

pub const CommandCompletion = struct {
    text: []const u8,
    description: ?[]const u8 = null,
};

const builtin_command_completions: []const CommandCompletion = &.{
    .{ .text = "/ssh", .description = "connect user@host:cwd" },
};

pub const UiState = union(enum) {
    chat,
    password,
};

pub const AppFlags = packed struct {
    show_thinking: bool = false,
    debug_log: bool = true,
    skip_permissions: bool = true,
    skip_ssh_permissions: bool = false,
};

pub const Theme = struct {
    bg: r.tui.Color,
    overlay_dark: r.tui.Color,
    overlay: r.tui.Color,
    muted: r.tui.Color,
    text: r.tui.Color,
    text_hl: r.tui.Color,
    ok: r.tui.Color,
    info: r.tui.Color,
    warn: r.tui.Color,
    err: r.tui.Color,
    on_err: r.tui.Color,
    diff_surface: r.tui.Color,
    diff_add: r.tui.Color,
    diff_remove: r.tui.Color,
    role_user: r.tui.Color,
    role_agent: r.tui.Color,
    role_system: r.tui.Color,

    pub const default: Theme = .{
        .bg = .{ .rgb = .{ .r = 26, .g = 27, .b = 38 } },
        .overlay_dark = .{ .rgb = .{ .r = 22, .g = 22, .b = 30 } },
        .overlay = .reset,
        .muted = .{ .rgb = .{ .r = 86, .g = 95, .b = 137 } },
        .text = .{ .rgb = .{ .r = 192, .g = 202, .b = 245 } },
        .text_hl = .white,
        .ok = .{ .rgb = .{ .r = 158, .g = 206, .b = 106 } },
        .info = .{ .rgb = .{ .r = 122, .g = 162, .b = 247 } },
        .warn = .{ .rgb = .{ .r = 224, .g = 175, .b = 104 } },
        .err = .{ .rgb = .{ .r = 247, .g = 118, .b = 142 } },
        .on_err = .{ .rgb = .{ .r = 26, .g = 27, .b = 38 } },
        .diff_surface = .{ .rgb = .{ .r = 41, .g = 46, .b = 66 } },
        .diff_add = .{ .rgb = .{ .r = 158, .g = 206, .b = 106 } },
        .diff_remove = .{ .rgb = .{ .r = 247, .g = 118, .b = 142 } },
        .role_user = .{ .rgb = .{ .r = 122, .g = 162, .b = 247 } },
        .role_agent = .{ .rgb = .{ .r = 187, .g = 154, .b = 247 } },
        .role_system = .{ .rgb = .{ .r = 247, .g = 118, .b = 142 } },
    };
};

pub const InputMode = union(enum) {
    text: Text,
    perm_select: PermSelect,
    perm_message: PermMessage,
    passphrase: Passphrase,
    wizard: Wizard,
    session_picker: r.session_picker.Picker,

    pub const Text = struct {
        completion_open: bool = false,
        completion_selected: usize = 0,
        completion_query_len: usize = 0,
    };
    pub const PermSelect = struct { selected: u8 = 0 };
    pub const PermMessage = struct {
        buf: [512]u8 = undefined,
        len: usize = 0,
    };
    pub const Passphrase = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        // Buffers backing user/host/cwd are owned by App.passphrase_args_buf.
        user: []const u8,
        host: []const u8,
        cwd: []const u8,
    };
    pub const Wizard = r.wizard.Wizard;
};

pub const QueuedMessage = struct {
    agent_id: r.AgentId,
    entry: ?ChatEntry = null,
    parts: []const r.sdk.Part,
};

pub const MessageQueue = struct {
    items: std.ArrayList(QueuedMessage) = .empty,

    fn sameAgent(a: r.AgentId, b: r.AgentId) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn push(
        self: *MessageQueue,
        alloc: std.mem.Allocator,
        agent_id: r.AgentId,
        entry: ?ChatEntry,
        parts: []const r.sdk.Part,
    ) !void {
        try self.items.append(alloc, .{
            .agent_id = agent_id,
            .entry = entry,
            .parts = parts,
        });
    }

    pub fn popFor(self: *MessageQueue, agent_id: r.AgentId) ?QueuedMessage {
        for (self.items.items, 0..) |item, i| {
            if (sameAgent(item.agent_id, agent_id)) {
                return self.items.orderedRemove(i);
            }
        }
        return null;
    }

    pub fn count(self: *const MessageQueue) usize {
        return self.items.items.len;
    }

    pub fn clear(self: *MessageQueue) void {
        self.items.items.len = 0;
    }
};

pub const Notifications = struct {
    list: [MAX_ENTRIES]Entry = @splat(.empty),

    pub const Entry = union(enum) { empty, used: struct { msg: []const u8, alive: f32 } };
    const MAX_ENTRIES = 16;
    pub const DISPLAY_SECONDS: f32 = 8.0;
    pub const MAX_VISIBLE: usize = 4;

    pub fn append(self: *Notifications, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        switch (self.list[MAX_ENTRIES - 1]) {
            .used => |en| {
                alloc.free(en.msg);
            },
            else => {},
        }

        std.mem.copyBackwards(Entry, self.list[1..], self.list[0 .. MAX_ENTRIES - 1]);
        const text = try std.fmt.allocPrint(alloc, fmt, args);
        self.list[0] = .{ .used = .{ .msg = text, .alive = 0 } };
    }

    pub fn deinit(self: *Notifications, alloc: std.mem.Allocator) void {
        for (&self.list) |en| switch (en) {
            .used => |e| alloc.free(e.msg),
            else => {},
        };
    }

    pub fn tick(self: *Notifications, dt: f32) void {
        for (&self.list) |*en| {
            switch (en.*) {
                .used => |*slot| slot.alive += dt,
                else => {},
            }
        }
    }

    pub fn hasVisible(self: *const Notifications) bool {
        var it = self.iter();
        return it.next() != null;
    }

    pub fn iter(self: *const Notifications) Iterator {
        return .{
            .list = &self.list,
        };
    }

    const Iterator = struct {
        list: *const [MAX_ENTRIES]Entry,
        i: u8 = 0,
        pub fn next(self: *Iterator) ?*const Entry {
            while (self.i < MAX_ENTRIES) {
                const n = &self.list[self.i];
                self.i += 1;

                switch (n.*) {
                    .used => |en| {
                        if (en.alive < DISPLAY_SECONDS) return n;
                    },
                    else => {},
                }
            }
            return null;
        }
    };
};

const Locked = r.agent_state.Locked;

const ToolStatusEntry = struct {
    lines: std.ArrayList(r.tui.Line) = .empty,
    child_id: ?r.AgentId = null,
    is_error: ?bool = null,
};

const ToolStatusAgent = struct {
    generation: u16 = 0,
    entries: std.array_hash_map.String(ToolStatusEntry) = .empty,
};

const ToolStatusStore = struct {
    agents: [r.agent_registry.max_agents]ToolStatusAgent = [_]ToolStatusAgent{.{}} ** r.agent_registry.max_agents,

    fn setResult(self: *ToolStatusStore, alloc: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, is_error: bool) !void {
        const agent = &self.agents[agent_id.index];
        if (agent.generation != agent_id.generation) agent.* = .{ .generation = agent_id.generation };

        const entry = try agent.entries.getOrPut(alloc, call_id);
        if (!entry.found_existing) {
            entry.key_ptr.* = try alloc.dupe(u8, call_id);
            entry.value_ptr.* = .{};
        }
        entry.value_ptr.is_error = is_error;
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    /// app arena,
    arena_app: std.heap.ArenaAllocator,
    /// session arena,
    arena_session: std.heap.ArenaAllocator,
    /// streaming arena
    arena_streaming_preview: std.heap.ArenaAllocator,
    arena_streaming_snapshot: std.heap.ArenaAllocator,
    /// frame render arena
    arena_frame: std.heap.ArenaAllocator,
    mu: std.Io.Mutex = .init,
    io: std.Io,
    input_buffer: std.ArrayList(u8) = .empty,
    input_cursor: u32 = 0,
    input_scroll_offset: u16 = 0,
    // ---------------
    // async interface
    permission_queue: Locked(std.ArrayList(*r.permissions.Request)),
    tool_status_entries: Locked(ToolStatusStore) = .{},
    //-----------------
    active_permission: ?*r.permissions.Request = null,
    registry: *r.agent_registry.Registry = undefined,
    exec_pool: *r.exec.CmdPool = undefined,
    update_check: ?r.update.CheckTask = null,
    config: r.config.BlitzdenkCfg = .{},
    main_agent_id: ?r.AgentId = null,
    running: bool = false,
    frame_count: usize = 0,
    session_run_ns: i128 = 0,
    session_run_started_ns: i128 = 0,
    scroll_offset: usize = 0,
    auto_scroll: bool = true,
    input_mode: InputMode = .{ .text = .{} },
    context_factory: *r.ContextFactory,
    theme: Theme = .default,
    cwd: []const u8,
    lua_config_dir: ?[]const u8 = null,
    lua_config_abs: ?[]const u8 = null,
    lua_reload_requested: std.atomic.Value(bool) = .init(false),
    lua_reload_failed: std.atomic.Value(bool) = .init(false),
    remote_cwd: []const u8 = "/",
    flags: AppFlags = .{},
    default_context_limit: u32 = CONTEXT_LIMIT,
    last_unbound_warn: ?[]const u8 = null,
    screenshot_buf: ?[]const u8 = null,
    dirty: bool = true,
    history: std.ArrayList(PromptEntry) = .empty,
    history_cursor: usize = 0,
    chat_entries: std.ArrayList(ChatEntry) = .empty,
    streaming_entry: ?ChatEntry = null,
    sdk_preview_parts: std.ArrayList(SdkPreviewPart) = .empty,
    sdk_preview_flushed: bool = false,
    sdk_run_rendered_steps: usize = 0,
    sdk_usage: r.sdk.Usage = .{},
    /// model round-trips of the main agent, incremented on .step events
    step_count: u32 = 0,
    compaction_indicator_active: bool = false,
    compaction_completion_seen_count: usize = 0,
    current_plan_file: ?[]const u8 = null,
    passphrase_args_buf: [512]u8 = undefined,
    queued: MessageQueue = .{},
    ui_state: UiState = .chat,
    keymap: r.keys.KeyMap = .{},
    cmd_queue: r.cmd.CommandQueue,
    lua_vm: *r.lua.LuaVm,
    lua_state: r.lua_state.Store = .{},
    lua_status_bar_enabled: bool = false,
    lua_status_bar_cache: [512]u8 = undefined,
    lua_status_bar_cache_len: usize = 0,
    lua_inject_hooks_enabled: std.atomic.Value(bool) = .init(false),
    mcp_manager: r.mcp.Manager,
    mcp_load: ?r.mcp.LoadTask = null,
    notifications: Notifications = .{},
    event_bus: r.events.EventBus = .{},
    injection_hooks: r.inject.InjectionsHooks = .{},

    // TODO: cleanup io
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        agent_factory: *r.ContextFactory,
        cwd: []const u8,
    ) !App {
        const lua_vm = try r.lua.LuaVm.init(gpa);
        errdefer lua_vm.deinit();

        return App{
            .gpa = gpa,
            .arena_app = .init(gpa),
            .arena_session = .init(gpa),
            .arena_streaming_preview = .init(gpa),
            .arena_streaming_snapshot = .init(gpa),
            .arena_frame = .init(gpa),
            .context_factory = agent_factory,
            .io = io,
            .cwd = cwd,
            .cmd_queue = try r.cmd.CommandQueue.init(gpa),
            .lua_vm = lua_vm,
            .mcp_manager = r.mcp.Manager.init(gpa, agent_factory.io),
            .injection_hooks = try r.inject.InjectionsHooks.init(gpa),
            .permission_queue = .{
                .value = try .initCapacity(gpa, 16),
            },
        };
    }

    pub fn deinit(self: *App) void {
        if (self.update_check) |*task| task.deinit();
        if (self.mcp_load) |*task| task.deinit();
        self.mcp_manager.deinit();
        self.lua_vm.deinit();
        self.lua_state.deinit(self.gpa);
        self.cmd_queue.deinit();
        self.injection_hooks.deinit(self.gpa);
        self.permission_queue.value.deinit(self.gpa);
        self.notifications.deinit(self.gpa);
        self.event_bus.clear(self.gpa, self.io);
        if (self.last_unbound_warn) |s| self.gpa.free(s);
        for (self.history.items) |e| self.gpa.free(e.text);
        self.history.deinit(self.gpa);
        self.context_factory.deinit();
        self.arena_streaming_preview.deinit();
        self.arena_streaming_snapshot.deinit();
        self.arena_frame.deinit();
        self.arena_session.deinit();
        self.arena_app.deinit();
    }

    pub fn cancelPermissions(self: *App) void {
        if (self.active_permission) |req| {
            req.state = .denied;
            req.event.set(self.io);
            self.active_permission = null;
        }

        const g = self.permission_queue.lock(self.io);
        defer g.unlock();

        for (g.ptr.items) |req| {
            req.state = .denied;
            req.event.set(self.io);
        }
        g.ptr.clearRetainingCapacity();

        self.returnToText();
    }

    /// Session-scoped allocator. Wiped on reset.
    pub fn sessionAlloc(self: *App) std.mem.Allocator {
        return self.arena_session.allocator();
    }

    pub fn setToolStatus(
        self: *App,
        agent_id: r.AgentId,
        call_id: []const u8,
        text: []const u8,
    ) !void {
        if (agent_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();

        const alloc = self.sessionAlloc();
        const agent = &g.ptr.agents[agent_id.index];
        if (agent.generation != agent_id.generation) {
            agent.* = .{ .generation = agent_id.generation };
        }

        const res = try agent.entries.getOrPut(alloc, call_id);
        if (!res.found_existing) {
            res.key_ptr.* = try alloc.dupe(u8, call_id);
            res.value_ptr.* = .{};
        } else {
            for (res.value_ptr.lines.items) |*line| line.deinit(alloc);
            res.value_ptr.lines.clearRetainingCapacity();
        }

        var parsed = try r.tui.Text.fromAnsi(alloc, text);
        defer parsed.deinit(alloc);
        for (parsed.lines.items) |*line| {
            try res.value_ptr.lines.append(alloc, line.*);
            line.* = .{};
        }
    }

    pub fn setToolChild(self: *App, agent_id: r.AgentId, call_id: []const u8, child_id: r.AgentId) !void {
        if (agent_id.index >= r.agent_registry.max_agents or child_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();

        const alloc = self.sessionAlloc();
        const agent = &g.ptr.agents[agent_id.index];
        if (agent.generation != agent_id.generation) {
            agent.* = .{ .generation = agent_id.generation };
        }

        const res = try agent.entries.getOrPut(alloc, call_id);
        if (!res.found_existing) {
            res.key_ptr.* = try alloc.dupe(u8, call_id);
            res.value_ptr.* = .{};
        }
        res.value_ptr.child_id = child_id;
    }

    pub fn setToolResult(self: *App, agent_id: r.AgentId, call_id: []const u8, is_error: bool) !void {
        if (agent_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();
        try g.ptr.setResult(self.sessionAlloc(), agent_id, call_id, is_error);
    }

    /// App-scoped allocator. Survives session resets.
    pub fn appAlloc(self: *App) std.mem.Allocator {
        return self.arena_app.allocator();
    }

    pub fn startUpdateCheck(self: *App) void {
        self.update_check = .init(self.exec_pool, self.gpa, self.io);
        self.update_check.?.start();
    }

    pub fn availableUpdateVersion(self: *const App) ?[]const u8 {
        const task = if (self.update_check) |*task| task else return null;
        return task.availableVersion();
    }

    pub fn reset(self: *App) void {
        if (self.mcp_load) |*task| task.deinit();
        self.mcp_load = null;
        self.dropStreamingPreview();
        self.cancelPermissions();
        self.exec_pool.cancelAll();
        self.registry.cancelAll();
        r.artifact.cleanup(self.exec_pool);

        self.main_agent_id = null;
        self.running = false;
        self.frame_count = 0;
        self.session_run_ns = 0;
        self.session_run_started_ns = 0;
        self.scroll_offset = 0;
        self.input_mode = .{ .text = .{} };
        self.input_cursor = 0;
        self.streaming_entry = null;
        self.sdk_preview_parts = .empty;
        self.sdk_preview_flushed = false;
        self.sdk_run_rendered_steps = 0;
        self.sdk_usage = .{};
        self.step_count = 0;
        self.compaction_indicator_active = false;
        self.compaction_completion_seen_count = 0;
        self.registry.reset();
        self.screenshot_buf = null;
        self.dirty = true;
        _ = self.arena_session.reset(.free_all);
        // Backing storage just got freed — reset list headers to .empty so
        // stale ptr/capacity don't cause UB on next append.
        self.input_buffer = .empty;
        self.chat_entries = .empty;
        self.queued = .{};
        self.context_factory.resetLoadedTools() catch {};
        self.lua_vm.disableAllMcp();
        self.lua_state.reset(self.io, self.gpa);
        self.event_bus.emit(self, .session_reset) catch {};
        self.reloadMcpTools() catch {};
        self.reloadLuaTools() catch {};

        // cleanup
        self.tool_status_entries = .{};
        self.permission_queue.value.clearRetainingCapacity();
    }

    pub fn tick(self: *App) !void {
        try self.finishMcpLoad(false);
        for (&self.registry.slots, 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;
            const id = r.AgentId{ .index = @intCast(index), .generation = slot.generation };
            var drain_context = RegistryDrainContext{ .app = self, .id = id };
            _ = self.registry.drain(id, 64, &drain_context, applyRegistryEvent);
            if (self.registry.reap(id)) try self.handleReapedAgent(id);
        }
        self.registry.retryDue();
        self.running = self.registry.countActive() > 0;
        self.updateSessionTime();

        // --------------------------------------------------
        // pop permission
        {}

        self.syncCompactionIndicator();
    }

    fn updateSessionTime(self: *App) void {
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds);
        if (self.running) {
            if (self.session_run_started_ns == 0) self.session_run_started_ns = now;
        } else if (self.session_run_started_ns != 0) {
            self.session_run_ns += now - self.session_run_started_ns;
            self.session_run_started_ns = 0;
        }
    }

    fn sessionRunSecs(self: *const App) u32 {
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds);
        const live: i128 = if (self.session_run_started_ns != 0) @max(0, now - self.session_run_started_ns) else 0;
        return @intCast(@divTrunc(self.session_run_ns + live, std.time.ns_per_s));
    }

    fn handleReapedAgent(self: *App, agent_id: r.AgentId) !void {
        const agent = self.registry.get(agent_id) orelse return;
        const state = self.registry.state(agent_id) orelse return;
        if (agent.background and state != .active and agent.queued_messages.items.len == 0) {
            try self.finishBackgroundAgent(agent_id, agent);
            return;
        }
        if (state == .active or agent.queued_messages.items.len == 0) return;
        try self.registry.run(agent_id, .{ .max_steps = std.math.maxInt(usize) });
        try self.event_bus.emit(self, .{ .agent_started = agent_id });
    }

    fn finishBackgroundAgent(self: *App, agent_id: r.AgentId, agent: *r.agent.Agent) !void {
        defer self.registry.release(agent_id);
        var notice_buf: [160]u8 = undefined;
        const notice = if (self.writeBackgroundResult(agent_id, agent)) |path| blk: {
            defer self.gpa.free(path);
            break :blk try std.fmt.bufPrint(&notice_buf, "Agent result done: {s}", .{path});
        } else |err| try std.fmt.bufPrint(&notice_buf, "Agent result failed to save: {s}", .{@errorName(err)});

        if (agent.parent) |packed_id| {
            const parent_id = r.AgentId.unpack(packed_id);
            if (self.registry.get(parent_id)) |parent| {
                try parent.queueReminder(notice);
                if (parent.task == null and parent.compact_task == null and parent.status != .retrying and parent.status != .compacting) {
                    try self.registry.run(parent_id, .{ .max_steps = std.math.maxInt(usize) });
                    try self.event_bus.emit(self, .{ .agent_started = parent_id });
                }
            }
        }
    }

    fn writeBackgroundResult(self: *App, agent_id: r.AgentId, agent: *const r.agent.Agent) ![]const u8 {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.gpa);
        var wrote_text = false;
        var index = agent.history().len;
        while (index > 0) {
            index -= 1;
            const message = agent.history()[index];
            if (message.role != .assistant) continue;
            for (message.parts()) |part| switch (part) {
                .text => |text| {
                    if (text.len == 0) continue;
                    try content.appendSlice(self.gpa, text);
                    wrote_text = true;
                },
                else => {},
            };
            if (wrote_text) break;
        }
        if (!wrote_text) {
            if (agent.last_error) |err|
                try content.print(self.gpa, "Agent failed: {s}\n", .{@errorName(err)})
            else
                try content.appendSlice(self.gpa, "Agent produced no text output.\n");
        }
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "agent-{d}.md", .{agent_id.pack()});
        return r.artifact.write(self.exec_pool, self.gpa, name, content.items);
    }

    pub fn enterPermSelect(self: *App) void {
        self.input_mode = .{ .perm_select = .{} };
    }

    pub fn enterPermMessage(self: *App) void {
        self.input_mode = .{ .perm_message = .{} };
    }

    pub fn enterPassphrase(self: *App, user: []const u8, host: []const u8, cwd: []const u8) void {
        if (user.len + host.len + cwd.len > self.passphrase_args_buf.len) {
            std.log.warn("ssh args too long for passphrase buffer ({d} bytes)", .{user.len + host.len + cwd.len});
            return;
        }
        const u = self.passphrase_args_buf[0..user.len];
        @memcpy(u, user);
        const h = self.passphrase_args_buf[user.len..][0..host.len];
        @memcpy(h, host);
        const c = self.passphrase_args_buf[user.len + host.len ..][0..cwd.len];
        @memcpy(c, cwd);
        self.input_mode = .{ .passphrase = .{ .user = u, .host = h, .cwd = c } };
    }

    pub fn enterWizard(self: *App) void {
        self.input_mode = .{ .wizard = .{} };
    }

    pub fn enterSessionPicker(self: *App, rows: []const r.session_picker.Row) void {
        self.input_mode = .{ .session_picker = .{ .rows = rows } };
    }

    pub fn wizardState(self: *App) ?*InputMode.Wizard {
        return switch (self.input_mode) {
            .wizard => |*w| w,
            else => null,
        };
    }

    fn wizardSelection(self: *App, w: *const InputMode.Wizard) ?r.wizard.Selection {
        _ = self;
        return w.selection();
    }

    pub fn wizardConfirm(self: *App, config_dir: std.Io.Dir) void {
        const w = self.wizardState() orelse return;
        const selection = self.wizardSelection(w) orelse {
            w.error_msg = "invalid wizard state";
            self.dirty = true;
            return;
        };
        r.wizard.writeProviderLua(self.io, config_dir, self.gpa, selection) catch |err| switch (err) {
            error.OutOfMemory => {
                w.error_msg = "write failed: out of memory";
                self.dirty = true;
                return;
            },
            error.WizardTextUnsafe => {
                w.error_msg = "text contains characters not allowed in lua strings";
                self.dirty = true;
                return;
            },
            error.ProviderLuaExists => {
                r.wizard.writeDoneMarker(self.io, config_dir);
                self.finishWizard();
                return;
            },
            else => {
                w.error_msg = "write failed: filesystem error";
                self.dirty = true;
                return;
            },
        };
        r.wizard.writeDoneMarker(self.io, config_dir);
        self.finishWizard();
    }

    pub fn wizardSkip(self: *App, config_dir: std.Io.Dir) void {
        r.wizard.writeSkipDefaults(self.io, config_dir, self.gpa) catch |err| switch (err) {
            error.ProviderLuaExists => {},
            else => {
                const w = self.wizardState() orelse return;
                w.error_msg = "writing defaults failed — check that the config dir is writable";
                self.dirty = true;
                return;
            },
        };
        r.wizard.writeDoneMarker(self.io, config_dir);
        self.finishWizard();
    }

    pub fn wizardAbortClearSecrets(self: *App) void {
        if (self.input_mode != .wizard) return;
        self.input_mode.wizard.abortClearSecrets();
    }

    fn finishWizard(self: *App) void {
        self.returnToText();
    }

    pub fn returnToText(self: *App) void {
        // Zero passphrase buffer when leaving the modal so it doesn't linger.
        if (self.input_mode == .passphrase) {
            const pp = &self.input_mode.passphrase;
            @memset(pp.buf[0..pp.len], 0);
        }
        if (self.input_mode == .wizard) {
            self.input_mode.wizard.abortClearSecrets();
        }
        self.input_mode = .{ .text = .{} };
    }

    fn textState(self: *App) ?*InputMode.Text {
        return switch (self.input_mode) {
            .text => |*t| t,
            else => null,
        };
    }

    pub fn completionIsOpen(self: *const App) bool {
        return switch (self.input_mode) {
            .text => |t| t.completion_open,
            else => false,
        };
    }

    pub fn syncCompletion(self: *App) void {
        const t = self.textState() orelse return;
        t.completion_selected = 0;
        t.completion_query_len = commandCompletionPrefix(self.input_buffer.items, self.input_cursor).len;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const rows = commandCompletions(self, arena.allocator(), self.input_buffer.items, self.input_cursor);
        t.completion_open = completionVisible(self.input_buffer.items, self.input_cursor, rows.len);
    }

    pub fn closeCompletion(self: *App) bool {
        const t = self.textState() orelse return false;
        if (!t.completion_open) return false;
        t.completion_open = false;
        t.completion_selected = 0;
        t.completion_query_len = 0;
        return true;
    }

    pub const CompletionMove = enum { next, prev, accept };

    pub fn handleCompletion(self: *App, move: CompletionMove) void {
        const t = self.textState() orelse return;
        if (!t.completion_open) return;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const rows = commandCompletions(self, alloc, self.input_buffer.items, self.input_cursor);
        if (rows.len == 0) {
            t.completion_open = false;
            t.completion_selected = 0;
            t.completion_query_len = 0;
            return;
        }
        if (t.completion_selected >= rows.len) t.completion_selected = 0;

        const cur_end = @min(@as(usize, self.input_cursor), self.input_buffer.items.len);
        const already = std.ascii.eqlIgnoreCase(self.input_buffer.items[0..cur_end], rows.items[t.completion_selected].text);

        switch (move) {
            .accept => {},
            .next => {
                if (already) {
                    if (t.completion_selected + 1 < rows.len) t.completion_selected += 1;
                }
            },
            .prev => {
                if (already and t.completion_selected > 0) t.completion_selected -= 1;
            },
        }

        insertCompletionToken(self, rows.items[t.completion_selected].text);

        if (move == .accept) {
            t.completion_open = false;
            t.completion_selected = 0;
            t.completion_query_len = 0;
        }
    }

    pub fn reloadMcpTools(self: *App) !void {
        const alloc = self.sessionAlloc();

        self.lua_vm.vm_mu.lockUncancelable(self.io);
        defer self.lua_vm.vm_mu.unlock(self.io);

        const servers = try self.lua_vm.getEnabledMcpServers(alloc);
        self.loadMcpTools(servers);
    }

    pub fn loadMcpTools(self: *App, servers: []const r.mcp.ServerConfig) void {
        if (self.mcp_load != null) return;
        for (self.mcp_manager.registeredTools()) |entry| self.context_factory.remove(entry.tool.def.name);

        self.mcp_load = .init(self.io, &self.mcp_manager, servers);
        self.mcp_load.?.start();
    }

    pub fn waitForMcpTools(self: *App) !void {
        try self.finishMcpLoad(true);
    }

    fn finishMcpLoad(self: *App, wait: bool) !void {
        const task = if (self.mcp_load) |*task| task else return;
        if (!wait and !task.isFinished()) return;
        task.wait();
        defer {
            task.deinit();
            self.mcp_load = null;
        }

        for (self.mcp_manager.registeredTools()) |entry| try self.context_factory.add(entry.tool, entry.flags);

        try self.refreshLiveAgentTools();
        self.event_bus.emit(self, .mcp_tools_reloaded) catch {};
        self.dirty = true;
    }
    pub fn reloadLuaTools(self: *App) !void {
        const alloc = self.sessionAlloc();

        self.lua_vm.vm_mu.lockUncancelable(self.io);
        defer self.lua_vm.vm_mu.unlock(self.io);

        const tools = try self.lua_vm.getRegisteredTools(alloc);
        for (tools) |tool| try self.context_factory.add(tool, .all);

        try self.refreshLiveAgentTools();
        self.dirty = true;
    }

    pub fn refreshLiveAgentTools(self: *App) !void {
        for (&self.registry.slots, 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;
            const agent = &slot.agent.?;
            if (agent.task != null) {
                agent.markToolsDirty();
            } else {
                try self.context_factory.refreshAgentTools(&self.config, agent, self.toolBase(.{ .index = @intCast(index), .generation = slot.generation }));
            }
        }
    }

    pub fn requestLuaReload(self: *App) void {
        self.lua_reload_requested.store(true, .release);
    }

    pub fn markLuaReloadDone(self: *App) void {
        self.lua_reload_requested.store(false, .release);
    }

    fn refreshRunningAgentTools(ctx: ?*anyopaque, agent: *r.agent.Agent) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        while (self.lua_reload_requested.load(.acquire)) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
        }
        if (self.lua_reload_failed.load(.acquire)) return;
        self.lua_vm.vm_mu.lockUncancelable(self.io);
        defer self.lua_vm.vm_mu.unlock(self.io);
        const id = self.registry.idForAgent(agent) orelse return error.AgentNotFound;
        try self.context_factory.refreshAgentToolsLive(&self.config, agent, self.toolBase(id));
    }

    pub fn pushSystemMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.sessionAlloc();
        const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
        const parts = alloc.alloc(ChatPart, 1) catch return;
        parts[0] = .{ .message = text };

        self.appendChatEntry(alloc, .{
            .role = .system,
            .parts = parts,
        }) catch return;
    }

    pub fn warnUnboundAgentModels(self: *App) void {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.gpa);
        self.context_factory.collectUnboundAgents(self.gpa, &names) catch return;
        if (names.items.len == 0) {
            if (self.last_unbound_warn) |s| self.gpa.free(s);
            self.last_unbound_warn = null;
            return;
        }
        const joined = std.mem.join(self.gpa, ", ", names.items) catch return;
        if (self.last_unbound_warn) |s| {
            if (std.mem.eql(u8, s, joined)) {
                self.gpa.free(joined);
                return;
            }
            self.gpa.free(s);
        }
        self.last_unbound_warn = joined;
        self.pushSystemMessage(
            "Agent(s) without a bound model: {s}. Bind `model` per agent with `blitz.set_model_agent(AGENT_TYPE, model, effort?)` or `model =` in `blitz.add_agent`.",
            .{joined},
        );
        self.notifications.append(self.gpa, "Agent(s) without a bound model: {s}", .{joined}) catch {};
    }

    pub fn mainAgent(self: *const App) ?*r.agent.Agent {
        const id = self.main_agent_id orelse return null;
        return self.registry.get(id);
    }

    pub fn configureAgent(self: *const App, id: r.AgentId, agent: *r.agent.Agent) !void {
        try self.context_factory.configureAgent(&self.config, agent, self.toolBase(id));
        agent.context_limit = self.default_context_limit;
        agent.lifetime.reminder = buildReminderOpaque;
        agent.lifetime.reminder_ctx = @ptrCast(@constCast(self));
        agent.lifetime.refresh_tools = refreshRunningAgentTools;
        agent.lifetime.refresh_tools_ctx = @ptrCast(@constCast(self));
    }

    pub fn toolBase(self: *const App, id: r.AgentId) r.tools.context.BaseContext {
        const agent = self.registry.get(id).?;
        return .{
            .registry = self.registry,
            .exec_pool = self.exec_pool,
            .self_id = id,
            .cwd = agent.cwd,
            .permissions = .{ .ctx = @ptrCast(@constCast(self)), .request = requestPermissionOpaque },
            .display = .{ .ctx = @ptrCast(@constCast(self)) },
            .app = @ptrCast(@constCast(self)),
        };
    }

    fn requestPermissionOpaque(ctx: ?*anyopaque, request: *r.permissions.Request) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const queue = self.permission_queue.lock(self.io);
        defer queue.unlock();
        queue.ptr.append(self.gpa, request) catch {
            request.state = .denied;
            request.event.set(self.io);
        };
    }

    pub fn contextPercent(self: *const App) f32 {
        const id = self.main_agent_id orelse return 0;
        const slot = &self.registry.slots[id.index];
        if (slot.generation != id.generation) return 0;
        return slot.agent.?.contextPercent();
    }

    pub fn isMainAgentCompacting(self: *const App) bool {
        const agent = self.mainAgent() orelse return false;
        return agent.status == .compacting;
    }

    pub fn syncCompactionIndicator(self: *App) void {
        const agent_id = self.main_agent_id orelse {
            self.compaction_indicator_active = false;
            return;
        };
        const agent = self.registry.get(agent_id) orelse {
            self.compaction_indicator_active = false;
            return;
        };

        if (agent.status == .compacting) {
            if (!self.compaction_indicator_active) {
                self.compaction_indicator_active = true;
                self.event_bus.emit(self, .{ .compaction_started = .{ .id = agent_id } }) catch {};
            }
            return;
        }

        if (self.compaction_indicator_active) self.compaction_indicator_active = false;

        const compacted_count = agent.compaction.completion_count.load(.acquire);
        if (compacted_count == 0 or compacted_count == self.compaction_completion_seen_count) return;

        self.compaction_completion_seen_count = compacted_count;
        self.event_bus.emit(self, .{ .compaction_complete = .{ .id = agent_id } }) catch {};
        self.pushSystemMessage("compact complete", .{});
        self.dirty = true;
    }

    fn buildReminderOpaque(ptr: ?*anyopaque, agent: *r.agent.Agent) anyerror!?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        return try self.injection_hooks.build(self, agent);
    }

    pub fn render(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
        refreshLuaStatusBar(app);
        app.mu.lockUncancelable(app.io);
        defer app.mu.unlock(app.io);
        _ = app.arena_frame.reset(.free_all);
        const frame_alloc = app.arena_frame.allocator();

        const input_height: u16 = blk: {
            switch (app.input_mode) {
                .text, .passphrase => {
                    const inner_w = area.width -| 5; // 2 left + 2 right padding + ❯ prompt
                    const rows = inputWrappedRows(app, frame_alloc, inner_w);
                    break :blk @min(rows +| 3, 9); // input rows + status + 2 padding
                },
                .perm_message => break :blk 8, // 5-row input box + status + 2 padding
                .wizard => break :blk 18,
                .session_picker => |*picker| break :blk @intCast(@min(6 + @max(picker.rows.len, 1), area.height -| 1)),
                .perm_select => {
                    const entry = app.active_permission orelse break :blk 9;
                    if (entry.payload == .ask) {
                        break :blk askPermissionInputHeight(entry.payload.ask.options, entry.payload.ask.header, entry.payload.ask.question, area.width, area.height);
                    }
                    if (entry.payload == .call) {
                        const rows = text_utils.wrappedRowCount(entry.payload.call.description, area.width -| 7);
                        break :blk @min(8 +| rows, area.height -| 1);
                    }
                    break :blk 9;
                },
            }
        };

        // Chat fills the screen; input + status stick right after the chat
        // content (or to the viewport bottom once it overflows). Each status
        // line lives inside the input footer: the main-agent status on the top
        // row, the statusbar on the row above the bottom padding.
        const _combined_area, _ =
            r.tui.Col(area, .{
                r.tui.Constr.fill, // chat + status
                r.tui.Constr{ .fixed = input_height }, // input + status footer
            });

        const lua_error_height = luaErrorHeight(app, frame_alloc, _combined_area.width, _combined_area.height) catch 0;
        const _lua_error_area, const _chat_status_area =
            r.tui.Col(_combined_area, .{
                r.tui.Constr{ .fixed = lua_error_height },
                r.tui.Constr.fill,
            });

        // Build the content first so the viewport only renders as much as needed.
        const is_welcome = app.chat_entries.items.len == 0 and !app.isMainAgentCompacting();
        var welcome_p: ?r.tui.Paragraph = null;
        var chat_stack: ?ChatStack = null;
        var content_end_h: usize = 0;

        const progress_line: ?r.tui.Line = mainProgressLine(app, frame_alloc);
        const progress_h: u16 = if (progress_line != null) 1 else 0;
        const footer_h: u16 = input_height +| progress_h;
        const chat_h: u16 = _chat_status_area.height -| progress_h;

        if (is_welcome) {
            var wp = r.tui.Paragraph{
                .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            };
            r.dash.build_info(app, &wp.lines) catch {};
            content_end_h = wp.totalHeightLong(_chat_status_area.width);
            welcome_p = wp;
        } else {
            chat_stack = buildChatStack(app, frame_alloc, _chat_status_area.width, chat_h) catch |err| blk: {
                log.err("chat build failed with {any}", .{err});
                break :blk null;
            };
            if (chat_stack) |cs| content_end_h = cs.total -| cs.scroll_offset;
        }

        // Input sits right after the chat content; once content fills the
        // viewport it pins to the bottom and stays sticky. The footer includes
        // the main-agent status row on top of the input widget.
        const max_footer_y: u16 = (area.y +| area.height) -| footer_h;
        const content_cap: u16 = @intCast(@min(content_end_h, @as(usize, chat_h)));
        const footer_y: u16 = @min(
            _chat_status_area.y +| content_cap,
            max_footer_y,
        );
        const _input_area: r.tui.Rect = .{
            .x = area.x,
            .y = footer_y,
            .width = area.width,
            .height = footer_h,
        };

        // Paint the background only over the used region; the rest stays
        // terminal default so unused viewport space is not rendered.
        const used_bottom: u16 = @min(footer_y +| footer_h, area.y +| area.height);
        buf.fill(.{
            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = used_bottom -| area.y,
        }, .{ .style = .{ .bg = app.theme.overlay } });

        renderLuaError(app, frame_alloc, _lua_error_area, buf) catch |err| {
            log.err("lua error render failed with {any}", .{err});
        };

        const _chat_area: r.tui.Rect = .{
            .x = _chat_status_area.x,
            .y = _chat_status_area.y,
            .width = _chat_status_area.width,
            .height = chat_h,
        };

        if (welcome_p) |wp| {
            const welcome_area: r.tui.Rect = .{
                .x = _chat_area.x,
                .y = _chat_area.y,
                .width = _chat_area.width,
                .height = content_cap,
            };
            wp.renderSimple(frame_alloc, welcome_area, buf);
        } else if (chat_stack) |cs| {
            renderChatStack(app, cs, _chat_area, buf);
        }

        // Input/Permission: a single overlay_dark block hosting the main-agent
        // progress, the input content, and the statusbar.
        renderInputWidget(app, frame_alloc, _input_area, progress_h, progress_line, buf);

        // Notifications
        renderNotifications(app, frame_alloc, area, buf);

        if (app.input_mode == .text and app.input_mode.text.completion_open) {
            const completions = commandCompletions(app, frame_alloc, app.input_buffer.items, app.input_cursor);
            if (completions.len > 0) {
                var max_width: usize = 0;
                for (completions.items[0..completions.len]) |cmp| {
                    const width = textWidthCols(cmp.text) + 1 + descriptionWidth(cmp.description);
                    if (width > max_width) max_width = width;
                }

                var p = r.tui.Paragraph{};
                p.border = .single;
                p.style.bg = app.theme.overlay_dark;

                const visible = 8;
                const selected = @min(app.input_mode.text.completion_selected, completions.len - 1);
                const start = if (selected >= visible) selected + 1 - visible else 0;
                const end = @min(completions.len, start + visible);
                for (completions.items[start..end], 0..) |cmp, i| {
                    const sel = start + i == selected;
                    const cmd_style: r.tui.Style = .{ .modifier = .{ .bold = true, .reverse = sel } };
                    const desc_style: r.tui.Style = if (sel) cmd_style else .{ .fg = app.theme.muted };
                    var line = r.tui.Line{};
                    line.pushText(frame_alloc, cmp.text, cmd_style) catch {};
                    if (cmp.description) |desc| {
                        line.pushText(frame_alloc, " ", desc_style) catch {};
                        line.pushText(frame_alloc, desc, desc_style) catch {};
                    }
                    p.lines.append(frame_alloc, line) catch {};
                }

                if (p.lines.items.len > 0) {
                    const height: u16 = @intCast(p.lines.items.len + 2);
                    const completion_area = r.tui.Rect{
                        .x = _input_area.x + 1,
                        .y = _input_area.y -| height + 1,
                        .width = @intCast(@min(max_width + 2, std.math.maxInt(u16))),
                        .height = height,
                    };
                    p.renderSimple(frame_alloc, completion_area, buf);
                }
            }
        }
    }

    pub fn resolveActivePermission(self: *App, state: r.permissions.State) void {
        if (self.active_permission) |perm| {
            if (self.registry.state(perm.agent_id) == .active) {
                perm.state = state;
                perm.event.set(self.io);
            }
            self.active_permission = null;
        }
    }

    pub fn appendBytes(self: *App, bytes: []const u8) void {
        if (self.input_cursor > self.input_buffer.items.len) {
            self.input_cursor = @intCast(self.input_buffer.items.len);
        }
        const idx = self.input_cursor;
        self.input_buffer.replaceRange(self.sessionAlloc(), idx, 0, bytes) catch return;
        self.input_cursor += @intCast(bytes.len);
        self.syncCompletion();
    }

    pub fn deleteChar(self: *App) void {
        if (self.input_cursor > self.input_buffer.items.len) {
            self.input_cursor = @intCast(self.input_buffer.items.len);
        }
        if (self.input_cursor == 0) return;

        // Pasted image: deleting anywhere inside (or right after) the masked
        // `[Image]` token removes the whole link.
        if (r.clipboard.findPasteAt(self.input_buffer.items, self.input_cursor)) |rg| {
            self.input_buffer.replaceRange(self.sessionAlloc(), rg.start, rg.end - rg.start, &.{}) catch return;
            self.input_cursor = @intCast(rg.start);
            self.syncCompletion();
            return;
        }

        var start: usize = self.input_cursor;
        while (start > 0) {
            start -= 1;
            if ((self.input_buffer.items[start] & 0xC0) != 0x80) break;
        }
        const len = self.input_cursor - start;
        self.input_buffer.replaceRange(self.sessionAlloc(), start, len, &.{}) catch return;
        self.input_cursor = @intCast(start);
        self.syncCompletion();
    }

    /// The input as rendered: pasted-image URLs are masked with `[Image]` and
    /// `cursor` is remapped to the display position.
    pub fn displayInput(self: *const App, arena: std.mem.Allocator) r.clipboard.Display {
        return r.clipboard.toDisplay(arena, self.input_buffer.items, self.input_cursor) catch {
            return .{ .text = self.input_buffer.items, .cursor = self.input_cursor };
        };
    }

    /// Ctrl+V handler. When the system clipboard holds an image, saves it to a
    /// temp file and embeds its `file://` URL (masked as `[Image]`) instead of
    /// inserting the raw paste text. Reports the outcome with a notification.
    pub fn pasteImage(self: *App) void {
        if (!self.context_factory.agentVision(&self.config, .general)) {
            self.notifications.append(self.gpa, "Current model does not support images", .{}) catch {};
            return;
        }
        const img = r.clipboard.readImage(self.sessionAlloc(), self.exec_pool) catch null;
        if (img) |image| {
            defer self.sessionAlloc().free(image.data);
            const url = r.clipboard.saveImage(self.io, self.sessionAlloc(), image.data, image.ext) catch null;
            if (url) |u| {
                self.appendBytes(u);
                self.dirty = true;
                self.notifications.append(self.gpa, "Image pasted", .{}) catch {};
                return;
            }
            self.notifications.append(self.gpa, "Failed to save clipboard image", .{}) catch {};
            return;
        }
        self.notifications.append(self.gpa, "Clipboard holds no image", .{}) catch {};
    }

    /// Terminal paste event handler. Pastes the clipboard image if one is
    /// present, otherwise appends the raw paste `text`.
    pub fn pasteImageOrText(self: *App, text: []const u8) void {
        if (!self.context_factory.agentVision(&self.config, .general)) {
            self.appendPathRef(text);
            return;
        }
        const img = r.clipboard.readImage(self.sessionAlloc(), self.exec_pool) catch null;
        if (img) |image| {
            defer self.sessionAlloc().free(image.data);
            if (r.clipboard.saveImage(self.io, self.sessionAlloc(), image.data, image.ext) catch null) |u| {
                self.appendBytes(u);
                self.dirty = true;
            }
            return;
        }
        self.appendPathRef(text);
    }

    fn appendPathRef(self: *App, text: []const u8) void {
        if (text.len > 0 and text[0] == '/') self.appendBytes("@");
        self.appendBytes(text);
    }

    pub fn inputSlice(self: *const App) []const u8 {
        return self.input_buffer.items;
    }

    pub fn pushHistory(self: *App, text: []const u8) void {
        if (text.len == 0) return;
        const allocator = self.gpa;
        const dupe = allocator.dupe(u8, text) catch return;
        if (self.history.items.len >= MAX_HISTORY) {
            const old = self.history.orderedRemove(0);
            allocator.free(old.text);
        }
        self.history.append(allocator, .{
            .text = dupe,
            .timestamp = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds,
        }) catch {
            allocator.free(dupe);
            return;
        };
        self.history_cursor = self.history.items.len;
    }

    pub fn historyUp(self: *App) void {
        if (self.history.items.len == 0) return;
        if (self.history_cursor == 0) return;
        self.history_cursor -= 1;
        const text = self.history.items[self.history_cursor].text;
        self.input_buffer.clearRetainingCapacity();
        self.input_buffer.appendSlice(self.sessionAlloc(), text) catch {};
        self.input_cursor = @intCast(self.input_buffer.items.len);
        self.syncCompletion();
    }

    pub fn historyDown(self: *App) void {
        if (self.history.items.len == 0) return;
        if (self.history_cursor >= self.history.items.len) return;
        self.history_cursor += 1;
        self.input_buffer.clearRetainingCapacity();
        if (self.history_cursor < self.history.items.len) {
            const text = self.history.items[self.history_cursor].text;
            self.input_buffer.appendSlice(self.sessionAlloc(), text) catch {};
        }
        self.input_cursor = @intCast(self.input_buffer.items.len);
        self.syncCompletion();
    }

    pub fn undoLastUserMessage(self: *App) void {
        if (self.input_mode != .text) return;
        if (self.running) return;
        if (self.chat_entries.items.len == 0) return;

        const last = self.chat_entries.items[self.chat_entries.items.len - 1];
        if (last.role != .user) return;
        const text = chatEntryUserText(last) orelse return;

        const agent = self.mainAgent() orelse return;
        const history = agent.history();
        if (history.len == 0 or history[history.len - 1].role != .user) return;
        agent.setMessages(history[0 .. history.len - 1]) catch return;

        const alloc = self.sessionAlloc();
        self.input_buffer.clearRetainingCapacity();
        self.input_buffer.appendSlice(alloc, text) catch return;
        self.input_cursor = @intCast(self.input_buffer.items.len);

        _ = self.chat_entries.pop();
        if (self.textState()) |t| {
            t.completion_open = false;
            t.completion_selected = 0;
            t.completion_query_len = 0;
        }
        self.dirty = true;
    }

    pub const PromptEntry = struct {
        text: []const u8,
        timestamp: i128,
    };

    pub fn loadHistory(self: *App, config_dir_path: []const u8) void {
        const SaveFormat = struct { prompts: []const PromptEntry };
        const allocator = self.gpa;

        const io = self.io;
        const abs_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir_path, PROMPT_HISTORY_FILENAME }) catch return;
        defer allocator.free(abs_path);

        const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return;
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &read_buf);
        var json_reader = std.json.Reader.init(allocator, &file_reader.interface);
        defer json_reader.deinit();

        const parsed = std.json.parseFromTokenSource(SaveFormat, allocator, &json_reader, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        const src = parsed.value.prompts;
        const start = if (src.len > MAX_HISTORY) src.len - MAX_HISTORY else 0;
        for (src[start..]) |entry| {
            const dupe = allocator.dupe(u8, entry.text) catch return;
            self.history.append(allocator, .{
                .text = dupe,
                .timestamp = entry.timestamp,
            }) catch {
                allocator.free(dupe);
                return;
            };
        }
        self.history_cursor = self.history.items.len;
    }

    pub fn saveHistory(self: *const App, config_dir_path: []const u8) void {
        const SaveFormat = struct { prompts: []const PromptEntry };

        const io = self.io;
        var buf: [512]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ config_dir_path, PROMPT_HISTORY_FILENAME }) catch return;

        const file = std.Io.Dir.createFileAbsolute(io, abs_path, .{}) catch return;
        defer file.close(io);

        const items = self.history.items;
        const start = if (items.len > MAX_HISTORY) items.len - MAX_HISTORY else 0;
        const save_data = SaveFormat{
            .prompts = items[start..],
        };

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        std.json.Stringify.value(save_data, .{ .whitespace = .indent_2 }, &file_writer.interface) catch return;
        file_writer.interface.flush() catch return;
    }

    pub fn popQueuedMessage(self: *App, agent_id: r.AgentId, alloc: std.mem.Allocator) ?[]const r.sdk.Part {
        const queued = self.queued.popFor(agent_id) orelse return null;

        if (queued.entry) |entry| self.appendChatEntry(self.sessionAlloc(), entry) catch {};

        const messages = r.agent_run.cloneMessages(alloc, &.{.{ .role = .user, .content = queued.parts }}) catch return null;
        return messages[0].content;
    }

    pub fn popQueuedMessageOpaque(ptr: *anyopaque, agent_id: r.AgentId, alloc: std.mem.Allocator) ?[]const r.sdk.Part {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.popQueuedMessage(agent_id, alloc);
    }

    pub fn dropStreamingPreview(self: *App) void {
        self.streaming_entry = null;
        self.sdk_preview_parts = .empty;
        _ = self.arena_streaming_snapshot.reset(.free_all);
        _ = self.arena_streaming_preview.reset(.free_all);
    }

    fn appendSdkPreviewText(self: *App, alloc: std.mem.Allocator, kind: SdkPreviewPart.Kind, text: []const u8) !void {
        if (self.sdk_preview_parts.items.len > 0) {
            const last = &self.sdk_preview_parts.items[self.sdk_preview_parts.items.len - 1];
            if (last.kind == kind) {
                try last.text.appendSlice(alloc, text);
                return;
            }
        }
        var part = SdkPreviewPart{ .kind = kind };
        try part.text.appendSlice(alloc, text);
        try self.sdk_preview_parts.append(alloc, part);
    }

    pub fn applyRunEvent(self: *App, agent_id: r.AgentId, event: r.agent_run.Event) !void {
        const alloc = self.sessionAlloc();
        const preview_alloc = self.arena_streaming_preview.allocator();
        const is_main = if (self.main_agent_id) |id| id.pack() == agent_id.pack() else true;
        switch (event) {
            .text => |text| {
                if (!is_main) return;
                self.sdk_preview_flushed = false;
                try self.appendSdkPreviewText(preview_alloc, .message, text);
                try self.refreshSdkPreview(agent_id);
            },
            .reasoning => |reasoning| {
                if (!is_main) return;
                self.sdk_preview_flushed = false;
                try self.appendSdkPreviewText(preview_alloc, .thinking, reasoning);
                try self.refreshSdkPreview(agent_id);
            },
            .tool => |chunk| {
                if (!is_main) return;
                if (chunk.type != .tool_call) return;
                self.sdk_preview_flushed = false;
                try self.sdk_preview_parts.append(preview_alloc, .{
                    .kind = .tool_call,
                    .call = .{
                        .call_id = try preview_alloc.dupe(u8, chunk.tool_call_id),
                        .tool_name = try preview_alloc.dupe(u8, chunk.tool_name),
                    },
                });
                try self.refreshSdkPreview(agent_id);
            },
            .tool_done => |info| {
                try self.setToolResult(agent_id, info.tool_call_id, info.is_error);
            },
            .step => |step| {
                if (is_main) {
                    self.sdk_usage.add(step.usage);
                    self.step_count += 1;
                    self.sdk_run_rendered_steps = step.number;
                }
                const status = self.tool_status_entries.lock(self.io);
                defer status.unlock();
                for (step.tool_results) |result| try status.ptr.setResult(alloc, agent_id, result.tool_call_id, result.is_error);
                if (is_main) try self.flushSdkPreview();
            },
            .provider_error => |provider_error| {
                if (provider_error.will_retry) return;
                if (!is_main) return;
                if (provider_error.is_retryable) {
                    if (self.registry.get(agent_id)) |agent| {
                        if (agent.retry_count < agent.max_retries) {
                            self.dropStreamingPreview();
                            return;
                        }
                    }
                }
                self.dropStreamingPreview();
                const body = std.mem.trim(u8, provider_error.response_body, " \t\r\n");
                const message = if (provider_error.status_code != 0)
                    try std.fmt.allocPrint(alloc, "Provider error (HTTP {d})\n{s}", .{ provider_error.status_code, body })
                else
                    try std.fmt.allocPrint(alloc, "Provider error\n{s}", .{body});
                const parts = try alloc.alloc(ChatPart, 1);
                parts[0] = .{ .plain_text = message };
                try self.appendChatEntry(alloc, .{ .role = .agent, .parts = parts });
            },
            .complete => |result| {
                try self.event_bus.emit(self, .{ .agent_complete = agent_id });
                if (!is_main) return;
                const skip_final = self.sdk_preview_flushed;
                if (!skip_final and self.streaming_entry != null) {
                    try self.flushSdkPreview();
                    return;
                }
                self.dropStreamingPreview();
                if (skip_final) return;
                var index = result.messages.len;
                while (index > 0) {
                    index -= 1;
                    const message = result.messages[index];
                    if (message.role != .assistant) continue;
                    const parts = renderSdkParts(alloc, agent_id, message.parts()) orelse return;
                    try self.appendChatEntry(alloc, .{ .role = .agent, .parts = parts });
                    return;
                }
            },
            .failed => |err| {
                if (self.registry.get(agent_id)) |agent| {
                    if (agent.shouldAutoRetry(err)) {
                        if (is_main) {
                            self.dropStreamingPreview();
                            self.sdk_run_rendered_steps = 0;
                        }
                        return;
                    }
                }
                try self.event_bus.emit(self, .{ .agent_failed = .{ .id = agent_id, .err = @errorName(err) } });
                if (!is_main) return;
                self.dropStreamingPreview();
                const parts = try alloc.alloc(ChatPart, 1);
                parts[0] = .{ .plain_text = try std.fmt.allocPrint(alloc, "Agent failed: {s}", .{@errorName(err)}) };
                try self.appendChatEntry(alloc, .{ .role = .agent, .parts = parts });
            },
        }
        self.dirty = true;
    }

    fn refreshSdkPreview(self: *App, agent_id: r.AgentId) !void {
        self.streaming_entry = null;
        _ = self.arena_streaming_snapshot.reset(.free_all);
        const alloc = self.arena_streaming_snapshot.allocator();
        var parts: std.ArrayList(ChatPart) = .empty;
        for (self.sdk_preview_parts.items) |item| switch (item.kind) {
            .thinking => {
                const trimmed = std.mem.trim(u8, item.text.items, " \t\r\n");
                if (trimmed.len == 0) continue;
                try parts.append(alloc, .{ .thinking = trimmed });
            },
            .message => {
                const trimmed = std.mem.trim(u8, item.text.items, " \t\r\n");
                if (trimmed.len == 0) continue;
                try parts.append(alloc, .{ .message = trimmed });
            },
            .tool_call => try parts.append(alloc, .{ .tool_call = .{
                .agent_id = agent_id,
                .call_id = item.call.call_id,
                .tool_name = item.call.tool_name,
            } }),
        };
        if (parts.items.len == 0) {
            self.streaming_entry = null;
            return;
        }
        self.streaming_entry = .{ .role = .agent, .parts = try parts.toOwnedSlice(alloc) };
    }

    pub fn appendChatEntry(self: *App, alloc: std.mem.Allocator, entry: ChatEntry) !void {
        try self.chat_entries.append(alloc, entry);
    }

    pub fn appendAgentHistory(self: *App, agent_id: r.AgentId, start: usize, skip: usize) !void {
        const agent = self.registry.get(agent_id) orelse return;
        try self.appendSdkHistory(agent_id, agent.history(), start, skip);
    }

    fn appendSdkHistory(self: *App, agent_id: r.AgentId, messages: []const r.sdk.Message, start: usize, skip: usize) !void {
        const alloc = self.sessionAlloc();
        var remaining = skip;
        for (messages[@min(start, messages.len)..]) |message| {
            if (message.role != .assistant) continue;
            if (remaining > 0) {
                remaining -= 1;
                continue;
            }
            const parts = renderSdkParts(alloc, agent_id, message.parts()) orelse continue;
            try self.appendChatEntry(alloc, .{ .role = .agent, .parts = parts });
        }
    }

    /// Send a user prompt to the main agent: emit hook, queue messages, run.
    /// Shared by the TUI Enter handler and headless mode.
    pub fn sendPrompt(self: *App, io: std.Io, parts: []const r.sdk.Part, chat_text: []const u8) !void {
        try self.waitForMcpTools();
        const alloc = self.sessionAlloc();
        const chat_entry = try ChatEntry.userMessageSimple(alloc, .user, chat_text);
        try self.event_bus.emit(self, .{ .user_message_sent = chat_text });

        if (self.main_agent_id) |id| {
            try self.appendChatEntry(alloc, chat_entry);
            const agent = self.registry.get(id).?;
            try agent.queueMessages(&.{.{ .role = .user, .content = parts }});
            self.sdk_run_rendered_steps = 0;
            try self.registry.run(id, .{ .max_steps = std.math.maxInt(usize) });
        } else {
            const id = self.registry.reserve().?;
            self.cmd_queue.append(io, .{
                .spawn_agent = .{
                    .agent_id = id,
                    .agent_type = @intFromEnum(r.ContextFactory.AgentType.general),
                    .prompt = parts,
                    .chat_entry = chat_entry,
                    .cwd = self.cwd,
                },
            }) catch |err| {
                self.registry.releaseReservation(id);
                return err;
            };
        }
        self.running = true;
    }

    pub fn flushSdkPreview(self: *App) !void {
        const entry = self.streaming_entry orelse {
            self.dropStreamingPreview();
            return;
        };
        const alloc = self.sessionAlloc();
        try self.appendChatEntry(alloc, try r.util.deepClone(ChatEntry, entry, alloc));
        self.sdk_preview_flushed = true;
        self.dropStreamingPreview();
    }

    pub fn persist_permission_to_history(
        self: *App,
        perm: *const r.permissions.Request,
    ) !void {

        // skip sub agent diffs
        if (perm.agent_id != self.main_agent_id) return;

        switch (perm.payload) {
            .diff => |diff| {
                try self.flushSdkPreview();
                const alloc = self.sessionAlloc();
                var parts = try alloc.alloc(r.app.ChatPart, 1);
                parts[0] = try diffChatPart(alloc, diff);
                try self.appendChatEntry(alloc, .{
                    .role = .agent,
                    .parts = parts,
                });
            },
            else => {},
        }
    }
};

fn pushDiffLine(out: *std.ArrayList(r.tui.DiffLine), alloc: std.mem.Allocator, line: r.tui.DiffLine) void {
    const owned_content = alloc.dupe(u8, line.content) catch return;
    out.append(alloc, .{
        .kind = line.kind,
        .line_number = line.line_number,
        .content = owned_content,
    }) catch return;
}

pub fn emitDiffLines(out: *std.ArrayList(r.tui.DiffLine), snap: r.permissions.ToolDiff, alloc: std.mem.Allocator) void {
    if (snap.before) |before| {
        const old_lines = splitLinesAlloc(before, alloc) orelse return;
        const new_lines = splitLinesAlloc(snap.after, alloc) orelse return;
        emitMyersDiff(out, old_lines, new_lines, alloc);
    } else {
        var new_iter = std.mem.splitScalar(u8, snap.after, '\n');
        var ln: u32 = 1;
        while (new_iter.next()) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .line_number = ln, .content = line });
            ln += 1;
        }
    }
}

fn diffChatPart(alloc: std.mem.Allocator, diff: r.permissions.ToolDiff) !ChatPart {
    var lines = std.ArrayList(r.tui.DiffLine).empty;
    emitDiffLines(&lines, diff, alloc);
    return .{ .diff = .{
        .path = try alloc.dupe(u8, diff.path),
        .diff_lines = try lines.toOwnedSlice(alloc),
    } };
}

/// Myers' O(ND) shortest edit script with context collapsing. Old-file line
/// numbers are 1-based.
fn emitMyersDiff(
    out: *std.ArrayList(r.tui.DiffLine),
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    alloc: std.mem.Allocator,
) void {
    const ops = myersDiff(old_lines, new_lines, alloc) orelse {
        for (old_lines, 0..) |line, i| {
            pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = @as(u32, @intCast(i)) + 1, .content = line });
        }
        for (new_lines) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .content = line });
        }
        return;
    };

    if (ops.len == 0) return;

    const ctx_radius = 3;

    const visible = alloc.alloc(bool, ops.len) catch {
        emitAllOps(out, ops, alloc);
        return;
    };
    @memset(visible, false);

    for (ops, 0..) |op, idx| {
        if (op != .keep) {
            const start = if (idx >= ctx_radius) idx - ctx_radius else 0;
            const end = @min(idx + ctx_radius + 1, ops.len);
            @memset(visible[start..end], true);
        }
    }

    var old_ln: u32 = 0;
    var in_gap = false;
    var emitted_any = false;
    for (ops, 0..) |op, idx| {
        if (!visible[idx]) {
            if (op == .keep or op == .delete) old_ln += 1;
            in_gap = true;
            continue;
        }

        if (in_gap and emitted_any) {
            pushDiffLine(out, alloc, .{ .kind = .header, .content = "..." });
        }
        in_gap = false;
        emitted_any = true;

        switch (op) {
            .keep => |content| {
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

fn emitAllOps(out: *std.ArrayList(r.tui.DiffLine), ops: []const DiffOp, alloc: std.mem.Allocator) void {
    var old_ln: u32 = 0;
    for (ops) |op| {
        switch (op) {
            .keep => |content| {
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

const RegistryDrainContext = struct {
    app: *App,
    id: r.AgentId,
};

fn applyRegistryEvent(ctx: ?*anyopaque, event: r.agent_run.Event) void {
    const value: *RegistryDrainContext = @ptrCast(@alignCast(ctx.?));
    value.app.applyRunEvent(value.id, event) catch |err| {
        switch (event) {
            .tool => |chunk| log.err("failed to apply tool stream event type={s} id={s} name={s}: {s}", .{ @tagName(chunk.type), chunk.tool_call_id, chunk.tool_name, @errorName(err) }),
            else => log.err("failed to apply {s} stream event: {s}", .{ @tagName(event), @errorName(err) }),
        }
    };
}

pub const ChatEntry = struct {
    role: ChatRole,
    parts: []ChatPart,

    pub fn free(self: *ChatEntry, alloc: std.mem.Allocator) void {
        for (self.parts) |part| {
            switch (part) {
                .message => |slice| alloc.free(slice),
                .plain_text => |slice| alloc.free(slice),
                .thinking => |slice| alloc.free(slice),
                .tool_call => |call| {
                    alloc.free(call.call_id);
                    alloc.free(call.tool_name);
                },
                .diff => |diff| {
                    alloc.free(diff.diff_lines);
                    alloc.free(diff.path);
                },
            }
        }

        alloc.free(self.parts);
    }

    pub fn userMessageSimple(alloc: std.mem.Allocator, role: ChatRole, msg: []const u8) !ChatEntry {
        var parts = try alloc.alloc(ChatPart, 1);
        parts[0] = .{ .message = msg };
        return .{ .role = role, .parts = parts };
    }
};

pub const ChatPart = union(enum) {
    // TODO add time tracking
    thinking: []const u8,
    message: []const u8,
    plain_text: []const u8,
    diff: DiffEntry,
    tool_call: ToolCallEntry,

    pub const ToolCallEntry = struct {
        agent_id: r.AgentId,
        call_id: []const u8,
        tool_name: []const u8,
    };

    pub const DiffEntry = struct {
        path: []const u8,
        diff_lines: []const r.tui.DiffLine,
    };
};

fn chatEntryUserText(entry: ChatEntry) ?[]const u8 {
    for (entry.parts) |part| switch (part) {
        .message => |m| return m,
        .plain_text => |t| return t,
        else => {},
    };
    return null;
}

const SdkPreviewCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
};

const SdkPreviewPart = struct {
    const Kind = enum { thinking, message, tool_call };
    kind: Kind,
    text: std.ArrayList(u8) = .empty,
    call: SdkPreviewCall = .{ .call_id = "", .tool_name = "" },
};

fn renderSdkParts(
    alloc: std.mem.Allocator,
    agent_id: r.AgentId,
    parts: []const r.sdk.Part,
) ?[]ChatPart {
    var out: std.ArrayList(ChatPart) = .empty;
    for (parts) |part| switch (part) {
        .text => |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) continue;
            out.append(alloc, .{ .message = alloc.dupe(u8, trimmed) catch continue }) catch continue;
        },
        .reasoning => |reasoning| {
            const trimmed = std.mem.trim(u8, reasoning.text, " \t\r\n");
            if (trimmed.len == 0) continue;
            out.append(alloc, .{ .thinking = alloc.dupe(u8, trimmed) catch continue }) catch continue;
        },
        .tool_call => |call| out.append(alloc, .{ .tool_call = .{
            .agent_id = agent_id,
            .call_id = alloc.dupe(u8, call.id) catch continue,
            .tool_name = alloc.dupe(u8, call.name) catch continue,
        } }) catch continue,
        else => {},
    };
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(alloc) catch null;
}

pub fn splitLinesAlloc(text: []const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
    // Count lines first
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next() != null) count += 1;

    const buf = alloc.alloc([]const u8, count) catch return null;
    var i: usize = 0;
    var iter2 = std.mem.splitScalar(u8, text, '\n');
    while (iter2.next()) |line| {
        buf[i] = line;
        i += 1;
    }
    return buf[0..i];
}

// ── Myers Diff ──

pub const DiffOp = union(enum) {
    keep: []const u8,
    delete: []const u8,
    insert: []const u8,
};

/// Myers O(ND) diff. Returns null on allocation failure.
pub fn myersDiff(old: []const []const u8, new: []const []const u8, alloc: std.mem.Allocator) ?[]const DiffOp {
    const n = old.len;
    const m = new.len;
    const max_d = n + m;
    if (max_d == 0) return alloc.alloc(DiffOp, 0) catch null;

    // V array indexed by k in [-max_d..max_d], offset so k=0 is at index max_d
    const v_size = 2 * max_d + 1;

    // Store V snapshots for each d to reconstruct the path
    const vs = alloc.alloc([]usize, max_d + 1) catch return null;

    const v_buf = alloc.alloc(usize, v_size) catch return null;
    // Initialize with 0
    @memset(v_buf, 0);

    const offset: isize = @intCast(max_d);

    var ses_len: usize = 0;

    outer: for (0..max_d + 1) |d| {
        const d_i: isize = @intCast(d);
        var k: isize = -d_i;
        while (k <= d_i) : (k += 2) {
            const k_idx: usize = @intCast(k + offset);

            var x: usize = undefined;
            if (k == -d_i or (k != d_i and v_buf[@intCast(k - 1 + offset)] < v_buf[@intCast(k + 1 + offset)])) {
                x = v_buf[@intCast(k + 1 + offset)]; // move down (insert)
            } else {
                x = v_buf[@intCast(k - 1 + offset)] + 1; // move right (delete)
            }

            var y: usize = @intCast(@as(isize, @intCast(x)) - k);

            // Follow diagonal (matching lines)
            while (x < n and y < m and std.mem.eql(u8, old[x], new[y])) {
                x += 1;
                y += 1;
            }

            v_buf[k_idx] = x;

            if (x >= n and y >= m) {
                ses_len = d;
                // Snapshot after this step completes
                vs[d] = alloc.dupe(usize, v_buf) catch return null;
                break :outer;
            }
        }
        // Snapshot V after processing step d
        vs[d] = alloc.dupe(usize, v_buf) catch return null;
    }

    // Backtrack to build edit script
    const result = alloc.alloc(DiffOp, n + m) catch return null;
    var result_len: usize = 0;

    var cx: isize = @intCast(n);
    var cy: isize = @intCast(m);

    var d_i: isize = @intCast(ses_len);
    while (d_i > 0) : (d_i -= 1) {
        const d_u: usize = @intCast(d_i);
        const v_prev = vs[d_u - 1];
        const ck: isize = cx - cy;

        const is_insert = (ck == -d_i or (ck != d_i and v_prev[@intCast(ck - 1 + offset)] < v_prev[@intCast(ck + 1 + offset)]));

        const prev_k: isize = if (is_insert) ck + 1 else ck - 1;
        const prev_end_x: isize = @intCast(v_prev[@intCast(prev_k + offset)]);
        const prev_end_y: isize = prev_end_x - prev_k;

        // After the edit move, we land here and then slide diagonally to (cx, cy)
        var mid_x: isize = undefined;
        var mid_y: isize = undefined;
        if (is_insert) {
            // Insert: move down from (prev_end_x, prev_end_y) to (prev_end_x, prev_end_y + 1)
            mid_x = prev_end_x;
            mid_y = prev_end_y + 1;
        } else {
            // Delete: move right from (prev_end_x, prev_end_y) to (prev_end_x + 1, prev_end_y)
            mid_x = prev_end_x + 1;
            mid_y = prev_end_y;
        }

        // Emit diagonal (keep) from (cx, cy) back to (mid_x, mid_y)
        while (cx > mid_x and cy > mid_y) {
            cx -= 1;
            cy -= 1;
            result[result_len] = .{ .keep = old[@intCast(cx)] };
            result_len += 1;
        }

        // Emit the edit
        if (is_insert) {
            cy -= 1;
            result[result_len] = .{ .insert = new[@intCast(cy)] };
            result_len += 1;
        } else {
            cx -= 1;
            result[result_len] = .{ .delete = old[@intCast(cx)] };
            result_len += 1;
        }
    }

    // Remaining diagonal at d=0
    while (cx > 0 and cy > 0) {
        cx -= 1;
        cy -= 1;
        result[result_len] = .{ .keep = old[@intCast(cx)] };
        result_len += 1;
    }

    // Reverse the result (we built it backwards)
    const ops = result[0..result_len];
    std.mem.reverse(DiffOp, ops);
    return ops;
}

fn commandCompletionPrefix(input: []const u8, cursor: u32) []const u8 {
    if (input.len == 0) return "";
    const end = @min(@as(usize, cursor), input.len);
    const command_end = std.mem.indexOfScalar(u8, input[0..end], ' ') orelse end;
    return input[0..command_end];
}

fn filterPrefix(input: []const u8, cursor: u32, query_len: usize, open: bool) []const u8 {
    if (open and query_len > 0 and query_len <= input.len) return input[0..query_len];
    return commandCompletionPrefix(input, cursor);
}

fn containsCommandCompletion(items: []?CommandCompletion, needle: []const u8) bool {
    for (items) |item| {
        const value = item orelse continue;
        if (std.mem.eql(u8, value.text, needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(c) != std.ascii.toLower(value[i])) return false;
    }
    return true;
}

fn completionMatches(completion: []const u8, prefix: []const u8) bool {
    return startsWithIgnoreCase(completion, prefix) and !std.ascii.eqlIgnoreCase(completion, prefix);
}

fn commandTokenActive(input: []const u8, cursor: u32) bool {
    if (input.len == 0) return false;
    const end = @min(@as(usize, cursor), input.len);
    if (end == 0) return false;
    if (input[0] != '/') return false;
    return std.mem.indexOfScalar(u8, input[0..end], ' ') == null;
}

fn completionVisible(input: []const u8, cursor: u32, match_count: usize) bool {
    return match_count > 0 and commandTokenActive(input, cursor);
}

fn textWidthCols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn descriptionWidth(description: ?[]const u8) usize {
    const desc = description orelse return 0;
    return textWidthCols(desc);
}

fn appendBuiltinCommandCompletions(prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    for (builtin_command_completions) |completion| {
        if (count.* >= out.len) return;
        if (!completionMatches(completion.text, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], completion.text)) continue;

        out[count.*] = completion;
        count.* += 1;
    }
}

fn appendLuaCommandCompletions(app: *App, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;
    if (!app.lua_vm.vm_mu.tryLock()) return;
    defer app.lua_vm.vm_mu.unlock(app.io);
    app.lua_vm.appendCommandCompletions(prefix, out, count);
}

fn appendSkillCommandCompletions(app: *App, alloc: std.mem.Allocator, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;

    for (app.context_factory.skill_names.items) |name| {
        if (count.* >= out.len) return;
        const formatted = std.fmt.allocPrint(alloc, "/skill-{s}", .{name}) catch return;
        if (!completionMatches(formatted, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], formatted)) continue;

        out[count.*] = .{ .text = formatted };
        count.* += 1;
    }
}

fn appendSshAliasCompletions(app: *App, alloc: std.mem.Allocator, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;

    for (app.context_factory.ssh_aliases.items) |alias| {
        if (count.* >= out.len) return;
        const formatted = std.fmt.allocPrint(alloc, "/ssh-{s}", .{alias.name}) catch return;
        if (!completionMatches(formatted, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], formatted)) continue;

        out[count.*] = .{ .text = formatted };
        count.* += 1;
    }
}

const CompletionRows = struct {
    items: [COMMAND_COMPLETION_ROWS]CommandCompletion = [_]CommandCompletion{.{ .text = "" }} ** COMMAND_COMPLETION_ROWS,
    len: usize = 0,
};

fn commandCompletions(app: *App, alloc: std.mem.Allocator, input: []const u8, cursor: u32) CompletionRows {
    var matches: [COMMAND_COMPLETION_ROWS]?CommandCompletion = [_]?CommandCompletion{null} ** COMMAND_COMPLETION_ROWS;
    var count: usize = 0;

    const prefix = switch (app.input_mode) {
        .text => |t| filterPrefix(input, cursor, t.completion_query_len, t.completion_open),
        else => commandCompletionPrefix(input, cursor),
    };
    appendBuiltinCommandCompletions(prefix, &matches, &count);
    appendLuaCommandCompletions(app, prefix, &matches, &count);
    appendSkillCommandCompletions(app, alloc, prefix, &matches, &count);
    appendSshAliasCompletions(app, alloc, prefix, &matches, &count);

    var rows = CompletionRows{};
    for (matches[0..count]) |item| {
        const value = item orelse continue;
        if (!completionMatches(value.text, prefix)) continue;
        rows.items[rows.len] = value;
        rows.len += 1;
    }
    return rows;
}

fn insertCompletionToken(self: *App, entry: []const u8) void {
    const token_end = std.mem.indexOfScalar(u8, self.input_buffer.items, ' ') orelse self.input_buffer.items.len;
    self.input_buffer.replaceRange(self.sessionAlloc(), 0, token_end, entry) catch return;
    self.input_cursor = @intCast(entry.len);
}

fn renderInputWidget(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, progress_h: u16, progress_line: ?r.tui.Line, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });

    // 1-row top/bottom padding, 2-column left/right padding.
    const content: r.tui.Rect = .{
        .x = area.x +| 2,
        .y = area.y +| 1,
        .width = area.width -| 4,
        .height = area.height -| 2,
    };
    if (content.width == 0 or content.height == 0) return;

    if (progress_line) |l| {
        l.render(content.x, content.y, content.width, buf);
    }

    const input_area: r.tui.Rect = .{
        .x = content.x,
        .y = content.y +| progress_h,
        .width = content.width,
        .height = content.height -| progress_h -| 1,
    };
    const status_area: r.tui.Rect = .{
        .x = content.x,
        .y = content.y +| content.height -| 1,
        .width = content.width,
        .height = 1,
    };

    switch (app.input_mode) {
        .text => renderInputContent(app, arena, input_area, buf) catch {},
        .passphrase => renderPassphraseInput(app, input_area, buf),
        .perm_message => |*pm| renderPermMessageContent(app, pm, input_area, buf),
        .perm_select => renderPermissionContent(app, input_area, buf),
        .wizard => renderWizardContent(app, arena, input_area, buf),
        .session_picker => renderSessionPickerContent(app, arena, input_area, buf),
    }

    renderStatusBar(app, status_area, buf);
}

fn renderInputContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) !void {
    const border_color = app.theme.muted;

    var para = r.tui.Paragraph{
        .border = .none,
        .style = .{ .fg = border_color },
        .padding = .{ .left = 1 }, // ❯ prompt column
    };
    const inner = para.inner(area);

    const display = app.displayInput(arena);
    const text = display.text;
    const cursor: usize = display.cursor;
    const input_text_style: r.tui.Style = .{ .fg = app.theme.text_hl };
    const cursor_style: r.tui.Style = .{ .fg = app.theme.text_hl, .bg = border_color };

    var cursor_visual_row: usize = 0;
    var accumulated_rows: usize = 0;
    var it = std.mem.splitAny(u8, text, "\n");
    var consumed: usize = 0;
    while (it.next()) |raw_line| {
        const line_start = consumed;
        const line_end = line_start + raw_line.len;

        var wrapped: std.ArrayList(r.tui.Line) = .empty;
        defer wrapped.deinit(arena);
        if (cursor >= line_start and cursor <= line_end) {
            var line = r.tui.Line{};
            const off = cursor - line_start;
            const before = raw_line[0..off];
            try line.pushText(arena, before, input_text_style);
            if (off < raw_line.len) {
                const len = std.unicode.utf8ByteSequenceLength(raw_line[off]) catch 1;
                const end = @min(off + len, raw_line.len);
                try line.pushText(arena, raw_line[off..end], cursor_style);
                try line.pushText(arena, raw_line[end..], input_text_style);
            } else {
                try line.pushText(arena, " ", cursor_style);
            }
            try r.tui.wrapLine(arena, &line, inner.width, &wrapped);
        } else {
            try pushPlainWrappedLine(app, arena, raw_line, inner.width, &wrapped);
        }

        if (cursor >= line_start and cursor <= line_end) {
            outer: for (wrapped.items, 0..) |*row, i| {
                for (row.spans.items) |span| {
                    if (span.style.fg.eql(cursor_style.fg) and span.style.bg.eql(cursor_style.bg)) {
                        cursor_visual_row = accumulated_rows + i;
                        break :outer;
                    }
                }
            }
        }

        try para.lines.appendSlice(arena, wrapped.items);
        accumulated_rows += wrapped.items.len;
        consumed = line_end + 1;
    }

    const visible_height = inner.height;
    if (cursor_visual_row >= visible_height) {
        app.input_scroll_offset = @intCast(cursor_visual_row - visible_height + 1);
    } else {
        app.input_scroll_offset = 0;
    }
    para.scroll_offset = app.input_scroll_offset;

    para.render(arena, area, area, buf);
    buf.set(area.x, area.y, .{ .char = '❯' });
    if (app.screenshot_buf != null) {
        buf.setString(area.x, area.y, r.tui.icon.eye, .{ .fg = app.theme.ok });
    }
}

fn pushPlainWrappedLine(app: *App, arena: std.mem.Allocator, raw_line: []const u8, inner_w: u16, out: *std.ArrayList(r.tui.Line)) !void {
    var line = r.tui.Line{};
    try line.pushText(arena, raw_line, .{ .fg = app.theme.text_hl });
    try r.tui.wrapLine(arena, &line, inner_w, out);
}

/// Number of visual rows the input text wraps to at `inner_w` columns.
fn inputWrappedRows(app: *App, arena: std.mem.Allocator, inner_w: u16) u16 {
    const display = app.displayInput(arena);
    var rows: u16 = 0;
    var it = std.mem.splitAny(u8, display.text, "\n");
    while (it.next()) |raw_line| {
        var wrapped: std.ArrayList(r.tui.Line) = .empty;
        defer wrapped.deinit(arena);
        pushPlainWrappedLine(app, arena, raw_line, inner_w, &wrapped) catch break;
        rows +|= @intCast(wrapped.items.len);
    }
    return @max(rows, 1);
}

fn renderPermMessageContent(app: *App, pm: *const InputMode.PermMessage, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const input_widget: r.tui.Input = .{
        .text = pm.buf[0..pm.len],
        .border_style = .{ .fg = app.theme.warn },
        .screenshot_style = .{ .fg = app.theme.ok },
        .has_screenshot = app.screenshot_buf != null,
    };
    input_widget.render(area, buf);
}

fn renderPassphraseInput(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const pp = &app.input_mode.passphrase;
    const style: r.tui.Style = .{ .fg = app.theme.warn };
    const label = "❯ Passphrase: ";
    const label_width: u16 = 14;
    if (area.width <= label_width) {
        buf.setStringMax(area.x, area.y, label, style, area.width);
        return;
    }
    buf.setString(area.x, area.y, label, style);

    var x: u16 = area.x +| label_width;
    const y: u16 = area.y;
    const max_chars = area.width -| label_width -| 1;
    const shown: usize = @min(pp.len, max_chars);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        buf.set(x, y, .{ .char = '*', .style = style });
        x += 1;
    }
    buf.set(x, y, .{ .char = '_', .style = style });
}

const WIZARD_HELP_TEXT = "↑/↓ select · enter next · esc abort";

fn wizardSelStyle(selected: bool) r.tui.Style {
    return if (selected) .{ .modifier = .{ .reverse = true } } else .{};
}

fn renderWizardContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });
    const w = &app.input_mode.wizard;
    var para: r.tui.Paragraph = .{ .border = .none, .padding = .{ .left = 2, .right = 2 } };
    const title_style: r.tui.Style = .{ .fg = app.theme.info, .modifier = .{ .bold = true } };
    const muted_style: r.tui.Style = .{ .fg = app.theme.muted };
    const err_style: r.tui.Style = .{ .fg = app.theme.err };

    var l = r.tui.Line{};
    l.pushText(arena, "Setup — blitzdenk first-run wizard", title_style) catch {};
    para.lines.append(arena, l) catch {};
    var help = r.tui.Line{};
    help.pushText(arena, WIZARD_HELP_TEXT, muted_style) catch {};
    para.lines.append(arena, help) catch {};
    para.lines.append(arena, .{}) catch {};

    switch (w.step) {
        .welcome => {
            wizardAppendHeading(arena, &para, "Welcome to blitzdenk");
            wizardAppendHeading(arena, &para, "Pick a model provider to get started, or skip to use the built-in defaults.");
            wizardAppendHeading(arena, &para, "");
            wizardAppendOption(arena, &para, "Continue", w.list_selected == 0);
            wizardAppendOption(arena, &para, "Skip (use defaults)", w.list_selected == 1);
        },
        .provider => {
            wizardAppendHeading(arena, &para, "Choose a provider:");
            for (r.wizard.catalog, 0..) |entry, i| {
                wizardAppendOption(arena, &para, entry.name, i == w.list_selected);
            }
        },
        .provider_type => {
            wizardAppendHeading(arena, &para, "Custom endpoint — provider type:");
            for (r.wizard.provider_types, 0..) |name, i| {
                wizardAppendOption(arena, &para, name, i == w.list_selected);
            }
        },
        .url => {
            wizardAppendHeading(arena, &para, "Endpoint url (enter keeps the shown value):");
            wizardAppendInputLine(arena, &para, w.url_buf[0..w.url_len], true);
        },
        .key => {
            wizardAppendHeading(arena, &para, "Paste your api key (stored in provider.lua):");
            wizardAppendInputLine(arena, &para, w.key_buf[0..w.key_len], true);
        },
        .model => {
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            if (entry.free_text_model_only) {
                wizardAppendHeading(arena, &para, "Model id:");
                wizardAppendInputLine(arena, &para, w.model_buf[0..w.model_len], true);
            } else {
                wizardAppendHeading(arena, &para, "Choose a model (pick the last row to type your own):");
                for (entry.models, 0..) |model, i| {
                    wizardAppendOption(arena, &para, model.name, !w.model_free_text and w.model_curated_index == i);
                }
                wizardAppendOption(arena, &para, "Enter model id…", w.model_free_text);
                if (w.model_free_text) wizardAppendInputLine(arena, &para, w.model_buf[0..w.model_len], true);
            }
        },
        .vision => {
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            const detected = r.wizard.selectModel(entry, w.model_buf[0..w.model_len]).vision;
            wizardAppendHeading(arena, &para, "Custom model id — should image input be enabled?");
            wizardAppendHeading(arena, &para, "Catalogued models skip this; vision follows the catalogue.");
            wizardAppendKeyValue(app, arena, &para, "model", w.model_buf[0..w.model_len]);
            wizardAppendKeyValue(app, arena, &para, "catalogue", if (detected) "vision" else "no vision");
            wizardAppendHeading(arena, &para, "");
            wizardAppendOption(arena, &para, "Enable vision", w.vision_override == true);
            wizardAppendOption(arena, &para, "Text only", w.vision_override != true);
        },
        .confirm => {
            wizardAppendHeading(arena, &para, "Confirm — write provider.lua with these choices?");
            const selection = app.wizardSelection(w);
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            const vision_text = if (selection) |sel| (if (sel.vision) "true" else "false") else "unknown";
            wizardAppendKeyValue(app, arena, &para, "schema", w.provider_type_buf[0..w.provider_type_len]);
            wizardAppendKeyValue(app, arena, &para, "provider", entry.name);
            wizardAppendKeyValue(app, arena, &para, "url", w.url_buf[0..w.url_len]);
            wizardAppendKeyValue(app, arena, &para, "key", if (w.key_len > 0) "<set>" else "");
            wizardAppendKeyValue(app, arena, &para, "vision", vision_text);
            wizardAppendKeyValue(app, arena, &para, "model", w.model_buf[0..w.model_len]);
            wizardAppendHeading(arena, &para, "");
            wizardAppendOption(arena, &para, "Write provider.lua", w.accept_selected);
            wizardAppendOption(arena, &para, "Back", !w.accept_selected);
        },
        .done => {
            wizardAppendHeading(arena, &para, "Setup complete — happy hacking.");
            wizardAppendHeading(arena, &para, "provider.lua is live; edit it and it hot-reloads like any config lua.");
        },
    }

    if (w.error_msg) |msg| {
        var err_line = r.tui.Line{};
        err_line.pushText(arena, msg, err_style) catch {};
        para.lines.append(arena, err_line) catch {};
    }

    para.renderSimple(arena, area, buf);
}

fn wizardAppendHeading(arena: std.mem.Allocator, para: *r.tui.Paragraph, text: []const u8) void {
    var line = r.tui.Line{};
    line.pushText(arena, text, .{}) catch return;
    para.lines.append(arena, line) catch {};
}

pub fn renderSessionPickerContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });
    const picker = &app.input_mode.session_picker;
    var para: r.tui.Paragraph = .{ .border = .none, .padding = .{ .left = 2, .right = 2 } };

    var title = r.tui.Line{};
    title.pushText(arena, "Sessions — continue a recorded session", .{ .fg = app.theme.info, .modifier = .{ .bold = true } }) catch {};
    para.lines.append(arena, title) catch {};

    var help = r.tui.Line{};
    help.pushText(arena, "↑/↓ or j/k select · enter continue · esc quit", .{ .fg = app.theme.muted }) catch {};
    para.lines.append(arena, help) catch {};
    para.lines.append(arena, .{}) catch {};

    const visible_rows: usize = @max(area.height, 3) - 3;
    if (visible_rows == 0) {
        para.renderSimple(arena, area, buf);
        return;
    }
    picker.syncScroll(visible_rows);
    const start = @min(picker.scroll, picker.rows.len -| visible_rows);
    const end = @min(start + visible_rows, picker.rows.len);
    var index: usize = start;
    while (index < end) : (index += 1) {
        const row = picker.rows[index];
        const selected = index == picker.selected;
        var line = r.tui.Line{};
        if (r.session_picker.isNewSession(row)) {
            line.pushText(arena, if (selected) "❯ " else "  ", .{ .modifier = .{ .bold = true } }) catch return;
            line.pushText(arena, row.prompt, .{ .fg = app.theme.ok, .modifier = .{ .bold = selected } }) catch return;
            para.lines.append(arena, line) catch {};
            continue;
        }
        line.pushText(arena, if (selected) "❯ " else "  ", .{ .modifier = .{ .bold = true } }) catch return;
        line.pushText(arena, row.date, .{ .fg = app.theme.role_agent }) catch return;
        line.pushText(arena, "  ", .{}) catch return;
        line.pushText(arena, row.id, .{ .fg = app.theme.muted }) catch return;
        line.pushText(arena, "  ", .{}) catch return;
        const prompt = if (row.prompt.len > 0) row.prompt else r.session_picker.EMPTY_PROMPT_LABEL;
        line.pushText(arena, clipPromptToWidth(arena, prompt, pickerMaxPromptWidth(area.width)), if (selected) .{ .fg = app.theme.text_hl, .modifier = .{ .bold = true } } else .{ .fg = app.theme.info }) catch return;
        para.lines.append(arena, line) catch {};
    }

    para.renderSimple(arena, area, buf);
}

fn pickerMaxPromptWidth(area_width: u16) usize {
    const widget_padding = 4;
    const para_padding = 4;
    const prefix = 2 + 16 + 2 + r.session_store.ID_LEN + 2;
    return @as(usize, area_width) -| (widget_padding + para_padding + prefix);
}

fn clipPromptToWidth(arena: std.mem.Allocator, text: []const u8, max: usize) []const u8 {
    const width = textWidthCols(text);
    if (width <= max) return text;
    var cut: usize = 0;
    var cols: usize = 0;
    const limit = max -| 1;
    while (cut < text.len and cols < limit) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[cut]) catch 1;
        const end = @min(cut + seq_len, text.len);
        cols += 1;
        cut = end;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..cut]}) catch text;
}

fn wizardAppendOption(arena: std.mem.Allocator, para: *r.tui.Paragraph, text: []const u8, selected: bool) void {
    var line = r.tui.Line{};
    line.pushText(arena, if (selected) "❯ " else "  ", wizardSelStyle(selected)) catch return;
    line.pushText(arena, text, wizardSelStyle(selected)) catch return;
    para.lines.append(arena, line) catch {};
}

fn wizardAppendInputLine(arena: std.mem.Allocator, para: *r.tui.Paragraph, text: []const u8, selected: bool) void {
    var line = r.tui.Line{};
    line.pushText(arena, "  ", .{}) catch return;
    line.pushText(arena, text, wizardSelStyle(selected)) catch return;
    line.pushText(arena, "_", wizardSelStyle(selected)) catch return;
    para.lines.append(arena, line) catch {};
}

fn wizardAppendKeyValue(app: *App, arena: std.mem.Allocator, para: *r.tui.Paragraph, key: []const u8, value: []const u8) void {
    var line = r.tui.Line{};
    const padded = std.fmt.allocPrint(arena, "  {s:<10}", .{key}) catch return;
    line.pushText(arena, padded, .{ .fg = app.theme.muted }) catch return;
    line.pushText(arena, value, .{ .fg = app.theme.text }) catch return;
    para.lines.append(arena, line) catch {};
}

fn renderNotifications(app: *App, arena: std.mem.Allocator, full_area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const notif_w: u16 = @min(full_area.width / 3, 40);
    if (notif_w < 4) return;

    var y = full_area.y;
    const max_y = full_area.y +| full_area.height;
    var rendered: usize = 0;
    var iter = app.notifications.iter();
    while (iter.next()) |entry| {
        if (rendered >= Notifications.MAX_VISIBLE or y >= max_y) break;

        switch (entry.*) {
            .used => |en| {
                var para = r.tui.Paragraph{
                    .border = .single,
                    .style = .{ .fg = app.theme.text, .bg = app.theme.overlay_dark },
                    .padding = .{ .left = 1, .right = 1, .top = 0, .bottom = 0 },
                };
                var l = r.tui.Line{};
                l.pushText(arena, en.msg, .{}) catch {};
                para.lines.append(arena, l) catch {};

                const total_h = para.totalHeight(notif_w);
                if (total_h == 0) continue;

                const area = r.tui.Rect{
                    .x = full_area.x +| full_area.width -| notif_w,
                    .y = y,
                    .width = notif_w,
                    .height = @min(total_h, max_y -| y),
                };
                para.renderSimple(arena, area, buf);

                y +|= total_h +| 1;
                rendered += 1;
            },
            else => {},
        }
    }
}

fn renderStatusBar(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const alloc = app.arena_frame.allocator();
    var line = statusBarLine(app, alloc) catch return;
    line.render(area.x, area.y, area.width, buf);
}

fn statusBarLine(app: *App, alloc: std.mem.Allocator) !r.tui.Line {
    if (app.lua_status_bar_enabled and app.lua_status_bar_cache_len > 0) {
        const parsed = try r.tui.Text.fromAnsi(alloc, app.lua_status_bar_cache[0..app.lua_status_bar_cache_len]);
        if (parsed.lines.items.len > 0) {
            var line = parsed.lines.items[0];
            line.style = .{ .fg = app.theme.muted };
            return line;
        }
        return .{};
    }

    const ctx_pct: u8 = @intFromFloat(@min(app.contextPercent(), 100));
    var status_buf: [256]u8 = undefined;
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var cache_buf: [16]u8 = undefined;
    const usage = app.registry.usage();
    const status = std.fmt.bufPrint(
        &status_buf,
        "IN:{s} OUT:{s} CACHE:{s} | CTX:{d}% {s}",
        .{
            formatTokenCount(&in_buf, usage.input_tokens),
            formatTokenCount(&out_buf, usage.output_tokens),
            formatTokenCount(&cache_buf, usage.cache_read_tokens + usage.cache_write_tokens),
            ctx_pct,
            if (app.flags.skip_permissions) "| AUTO APPROVAL" else "",
        },
    ) catch " ?? ";
    return r.tui.Line.new(alloc, "{s}", .{status}, .{ .fg = app.theme.muted });
}

fn refreshLuaStatusBar(app: *App) void {
    if (!app.lua_status_bar_enabled) return;
    if (app.lua_vm.vm_mu.tryLock()) {
        defer app.lua_vm.vm_mu.unlock(app.io);
        if (app.lua_vm.renderStatusBar(&app.lua_status_bar_cache)) |status| {
            app.lua_status_bar_cache_len = status.len;
        }
    }
}

fn luaErrorParagraph(app: *App, arena: std.mem.Allocator, msg: []const u8) !r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .style = .{ .fg = app.theme.on_err, .bg = app.theme.err },
    };
    try p.appendText(arena, msg, .{ .fg = app.theme.on_err, .bg = app.theme.err });
    return p;
}

fn luaErrorHeight(app: *App, arena: std.mem.Allocator, width: u16, max_height: u16) !u16 {
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0 or width == 0 or max_height == 0) return 0;

    var p = try luaErrorParagraph(app, arena, msg);
    return @min(p.totalHeight(width), max_height);
}

fn renderLuaError(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) !void {
    if (area.width == 0 or area.height == 0) return;
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0) return;

    var p = try luaErrorParagraph(app, arena, msg);
    p.renderSimple(arena, area, buf);
}

const RenderParagraphItem = struct {
    p: r.tui.Paragraph,
    h: usize,
    is_tool_block: bool = false,
};

/// Zero the facing padding between the last two stack items when both are tool
/// blocks, keeping `total` in sync. Only tool groups set `is_tool_block`, so
/// this fires only when a tool group is appended after a tool group.
fn collapseToolPadding(
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    inner_w: u16,
) void {
    if (out.items.len < 2) return;
    const prev = &out.items[out.items.len - 2];
    const next = &out.items[out.items.len - 1];
    if (!prev.is_tool_block or !next.is_tool_block) return;

    const old_prev_h = prev.h;
    prev.p.padding.top = 0;
    prev.h = prev.p.totalHeightLong(inner_w);
    total.* -= old_prev_h - prev.h;

    const old_next_h = next.h;
    next.p.padding.bottom = 0;
    next.h = next.p.totalHeightLong(inner_w);
    total.* -= old_next_h - next.h;
}

fn appendToolGroup(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    app: *App,
    calls: *std.ArrayList(ChatPart.ToolCallEntry),
    inner_w: u16,
) !void {
    if (calls.items.len == 0) return;
    std.mem.reverse(ChatPart.ToolCallEntry, calls.items);
    const para = try buildToolGroupParagraph(app, arena, calls.items, inner_w);
    try out.append(arena, para);
    total.* += para.h;
    collapseToolPadding(out, total, inner_w);
    calls.clearRetainingCapacity();
}

/// Build one r.tui.Paragraph per ChatEntry. Allocations live in `arena`; do not
/// deinit the result. All paragraphs use `reverse = true` so the chat-area
/// caller can stack them bottom-up.
fn buildChatEntryParagraph(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    app: *App,
    entry: ChatEntry,
    inner_w: u16,
) !void {
    // var buf: [255]u8 = undefined;

    var header_para = r.tui.Paragraph{};
    var header_line = r.tui.Line{};

    var has_text = false;

    // Header last so it renders on top (stack is bottom-up)
    var tool_call_list = std.ArrayList(ChatPart.ToolCallEntry).empty;

    for (0..entry.parts.len) |i| {
        const part = entry.parts[entry.parts.len - i - 1];
        switch (part) {
            .tool_call => |call| try tool_call_list.append(arena, call),
            else => {
                try appendToolGroup(arena, out, total, app, &tool_call_list, inner_w);
                switch (part) {
                    .thinking => |text| {
                        if (app.flags.show_thinking) {
                            var p = r.tui.Paragraph{};
                            try p.appendText(arena, text, .{ .fg = app.theme.muted });
                            const h = p.totalHeightLong(inner_w);
                            try out.append(arena, .{ .p = p, .h = h });
                            total.* += h;
                        }
                    },
                    .message => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{};
                        try appendMarkdownText(&p, app.gpa, arena, text, inner_w, app.theme);
                        const h = p.totalHeightLong(inner_w);
                        try out.append(arena, .{ .p = p, .h = h });
                        total.* += h;
                    },
                    .plain_text => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{};
                        try p.appendText(arena, text, .{});
                        const h = p.totalHeightLong(inner_w);
                        try out.append(arena, .{ .p = p, .h = h });
                        total.* += h;
                    },
                    .diff => |diff| {
                        const p = buildDiffParagraph(arena, app, diff);
                        const h = p.totalHeightLong(inner_w);
                        try out.append(arena, .{ .p = p, .h = h });
                        total.* += h;
                    },
                    .tool_call => unreachable,
                }
            },
        }
    }

    try appendToolGroup(arena, out, total, app, &tool_call_list, inner_w);

    const show_header = entry.role != .agent or has_text;
    if (show_header) {
        const role_text: []const u8 = switch (entry.role) {
            .user => "❯ you:",
            .agent => "❯ blitz:",
            .system => "❯ system:",
        };

        const role_color: r.tui.Color = switch (entry.role) {
            .user => app.theme.role_user,
            .agent => app.theme.role_agent,
            .system => app.theme.role_system,
        };

        try header_line.pushSpan(arena, .{ .content = role_text, .style = .{ .modifier = .{ .bold = true }, .fg = role_color } });
        try header_para.lines.append(arena, header_line);
        try out.append(arena, .{ .p = header_para, .h = 1 });
        total.* += 1;
    }
}

fn buildToolGroupParagraph(
    app: *App,
    arena: std.mem.Allocator,
    calls: []const ChatPart.ToolCallEntry,
    inner_w: u16,
) !RenderParagraphItem {
    var p = r.tui.Paragraph{ .wrap = false };

    p.style.bg = app.theme.bg;
    p.padding = .all(1);

    const statuses = app.tool_status_entries.lock(app.io);
    defer statuses.unlock();

    for (calls) |call| {
        const agent = app.registry.get(call.agent_id) orelse continue;
        var line = r.tui.Line{};

        const status_agent = &statuses.ptr.agents[call.agent_id.index];
        const status = if (status_agent.generation == call.agent_id.generation)
            status_agent.entries.getPtr(call.call_id)
        else
            null;
        const live_result: ?r.sdk.ToolResult = findToolResult(agent, call.call_id);
        const is_error = if (live_result) |result| result.is_error else if (status) |entry| entry.is_error else null;
        if (is_error) |failed| {
            if (failed) {
                try line.pushSpan(arena, .{ .content = r.tui.icon.fail, .style = .{ .fg = app.theme.err, .modifier = .{ .bold = true } } });
            } else {
                try line.pushSpan(arena, .{ .content = r.tui.icon.ok, .style = .{ .fg = app.theme.ok, .modifier = .{ .bold = true } } });
            }
        } else {
            try line.pushSpan(arena, .{ .content = text_utils.spinnerDots(app.frame_count), .style = .{ .fg = app.theme.text } });
        }

        try line.pushSpan(arena, .{ .content = " " });
        if (status) |entry| {
            if (entry.lines.items.len > 0) {
                line.style = entry.lines.items[0].style;
                for (entry.lines.items[0].spans.items) |span| try line.pushSpan(arena, span);
            } else {
                try line.pushSpan(arena, .{ .content = call.tool_name });
            }

            if (entry.child_id) |child_id| {
                if (app.registry.get(child_id)) |child| {
                    const activity = child.activity;
                    if (activity != .idle) try line.pushSpan(arena, .{ .content = switch (activity) {
                        .idle => "",
                        .thinking => "  thinking",
                        .writing => "  writing",
                        .calling => "  calling",
                        .retrying => "  retrying",
                    }, .style = .{ .fg = app.theme.muted } });
                    if (activity != .idle) {
                        try line.pushSpan(arena, .{ .content = " " });
                        try line.pushSpan(arena, .{ .content = text_utils.spinnerBar(app.frame_count) });
                    }
                }
            }

            if (entry.child_id) |child_id| {
                if (app.registry.get(child_id)) |child| {
                    if (child.tokens_per_second > 0) {
                        try line.pushSpan(arena, .{ .content = "  " });
                        line.pushSpanPrint(arena, "{d}", .{@as(u32, @intFromFloat(child.tokens_per_second))}, .{ .fg = app.theme.text, .modifier = .{ .bold = true } }) catch {};
                        line.pushSpanPrint(arena, " T/s", .{}, .{ .fg = app.theme.info }) catch {};
                    }
                }
            }
        } else {
            try line.pushSpan(arena, .{ .content = call.tool_name });
        }
        try p.lines.append(arena, line);

        if (status) |entry| {
            if (entry.lines.items.len > 1) {
                for (entry.lines.items[1..]) |status_line| {
                    var extra = r.tui.Line{ .style = status_line.style };
                    try extra.pushSpan(arena, .{ .content = "  " });
                    for (status_line.spans.items) |span| try extra.pushSpan(arena, span);
                    try p.lines.append(arena, extra);
                }
            }

            const child_id = entry.child_id orelse continue;
            if (child_id.index >= r.agent_registry.max_agents) continue;
            const child_status = &statuses.ptr.agents[child_id.index];
            if (child_status.generation != child_id.generation) continue;

            var child_lines: std.ArrayList(r.tui.Line) = .empty;
            var entry_starts: std.ArrayList(usize) = .empty;
            var it = child_status.entries.iterator();
            const skip = if (child_status.entries.count() > 3) child_status.entries.count() - 3 else 0;
            var i: usize = 0;
            while (it.next()) |child_entry| {
                i += 1;
                if (i <= skip) continue;
                try entry_starts.append(arena, child_lines.items.len);
                for (child_entry.value_ptr.lines.items) |child_line| try child_lines.append(arena, child_line);
            }

            const total_child_lines = child_lines.items.len;
            var start_cursor: usize = 0;
            for (child_lines.items, 0..) |child_line, n| {
                var nested = r.tui.Line{ .style = child_line.style };

                const is_last = n + 1 == total_child_lines;
                const starts_entry = start_cursor < entry_starts.items.len and n == entry_starts.items[start_cursor];
                if (starts_entry) start_cursor += 1;
                const glyph: []const u8 = if (is_last) r.tui.icon.box_bl else if (starts_entry) r.tui.icon.box_t_right else r.tui.icon.box_v;
                try nested.pushSpanPrint(arena, " {s} ", .{glyph}, .{});
                for (child_line.spans.items) |span| try nested.pushSpan(arena, span);
                try p.lines.append(arena, nested);
            }
        }
    }

    return .{
        .h = p.totalHeightLong(inner_w),
        .p = p,
        .is_tool_block = true,
    };
}

/// Scan chat history for a tool_result with the given call_id. Source of
/// truth for "did this tool finish": `tool_call_done` is cleared right
/// after commit, but the result lives on in the chat as a tool_result part.
fn findToolResult(agent: *r.agent.Agent, call_id: []const u8) ?r.sdk.ToolResult {
    var i = agent.history().len;
    while (i > 0) {
        i -= 1;
        const msg = agent.history()[i];
        for (msg.parts()) |part| switch (part) {
            .tool_result => |res| if (std.mem.eql(u8, res.id, call_id)) return .{
                .tool_call_id = res.id,
                .tool_name = res.name,
                .output = res.output,
                .is_error = res.is_error,
                .exit_loop = res.exit_loop,
            },
            else => {},
        };
    }
    return null;
}

fn buildDiffParagraph(arena: std.mem.Allocator, app: *App, d: ChatPart.DiffEntry) r.tui.Paragraph {
    const theme = app.theme;
    var p: r.tui.Paragraph = .{
        .border = .single,
        .sides = .left_only,
        .dynamic_border = false,
        .reverse = true,
        .style = .{ .bg = theme.diff_surface },
    };

    var header_line = r.tui.Line{};
    header_line.pushSpan(arena, .{ .content = "file: ", .style = .{ .fg = theme.muted, .modifier = .{ .bold = true } } }) catch {};
    header_line.pushSpan(arena, .{ .content = d.path, .style = .{ .fg = theme.info } }) catch {};
    p.lines.append(arena, header_line) catch {};

    for (d.diff_lines) |dl| {
        const dl_info: struct { prefix: []const u8, style: r.tui.Style, bg: r.tui.Color } = switch (dl.kind) {
            .deletion => .{ .prefix = "- ", .style = .{ .fg = theme.diff_remove }, .bg = theme.diff_surface },
            .addition => .{ .prefix = "+ ", .style = .{ .fg = theme.diff_add }, .bg = theme.diff_surface },
            .context => .{ .prefix = "  ", .style = .{ .fg = theme.text }, .bg = theme.diff_surface },
            .header => .{ .prefix = "@ ", .style = .{ .fg = theme.info, .modifier = .{ .bold = true } }, .bg = .reset },
        };
        const num_str = if (dl.line_number) |n|
            std.fmt.allocPrint(arena, "{d:>4} ", .{n}) catch "     "
        else
            "     ";

        var src: r.tui.Line = .{ .style = .{ .bg = dl_info.bg } };
        src.pushText(arena, num_str, .{ .fg = theme.muted, .bg = dl_info.bg }) catch {};
        src.pushSpan(arena, .{ .content = dl_info.prefix, .style = dl_info.style }) catch {};
        src.pushSpan(arena, .{ .content = dl.content, .style = dl_info.style }) catch {};
        p.lines.append(arena, src) catch break;
    }
    return p;
}

fn markdownTheme(theme: Theme) r.tui.HighlightTheme {
    return .{
        .heading = .{ .fg = theme.info, .modifier = .{ .bold = true } },
        .bold = .{ .fg = theme.text, .modifier = .{ .bold = true } },
        .italic = .{ .fg = theme.text, .modifier = .{ .italic = true } },
        .inline_code = .{ .fg = theme.warn },
        .code_default = .{ .fg = theme.text_hl },
        .code_keyword = .{ .fg = theme.warn, .modifier = .{ .bold = true } },
        .code_expression = .{ .fg = theme.info },
        .code_string = .{ .fg = theme.ok },
        .code_number = .{ .fg = theme.warn },
        .code_comment = .{ .fg = theme.muted, .modifier = .{ .italic = true } },
        .list_marker = .{ .fg = theme.info },
        .quote = .{ .fg = theme.info, .modifier = .{ .italic = true } },
        .hr = .{ .fg = theme.info },
        .plain = .{ .fg = theme.text },
        .mermaid = .{
            .text = .{ .fg = theme.text },
            .strong = .{ .fg = theme.text_hl, .modifier = .{ .bold = true } },
            .muted = .{ .fg = theme.muted },
            .border = .{ .fg = theme.text_hl },
            .edge = .{ .fg = theme.text_hl },
            .accent = .{ .fg = theme.info },
        },
    };
}

fn appendMarkdownText(p: *r.tui.Paragraph, gpa: std.mem.Allocator, arena: std.mem.Allocator, raw: []const u8, width: u16, theme: Theme) !void {
    if (raw.len == 0) return;
    const md_theme = markdownTheme(theme);
    var renderer = r.tui.MarkdownStreamRenderer.initWithOptions(gpa, arena, width, md_theme, .{});
    defer renderer.deinit();
    try renderer.feed(raw);
    renderer.finish();
    if (width > 0) p.wrap = false;
    while (try renderer.next()) |line| {
        try p.lines.append(arena, line);
    }
}

const ChatStack = struct {
    items: std.ArrayList(RenderParagraphItem) = .empty,
    total: usize = 0,
    scroll_offset: usize = 0,
};

fn buildChatStack(app: *App, alloc: std.mem.Allocator, inner_w: u16, inner_h: u16) !ChatStack {
    var s = ChatStack{};
    const maybe_agent: ?*r.agent.Agent = if (app.main_agent_id) |id| app.registry.get(id) else null;

    var scroll_offset_usize: usize = if (app.auto_scroll) 0 else app.scroll_offset;
    const target: usize = @as(usize, inner_h) +| scroll_offset_usize;

    // Failed agent path
    if (app.main_agent_id) |id| {
        const slot = &app.registry.slots[id.index];
        if (slot.state.load(.acquire) == .failed) {
            const detail = if (slot.agent.?.last_error) |err| @errorName(err) else null;

            var para = r.tui.Paragraph{};
            try para.appendLineSpan(alloc, &.{
                .{ .content = "ERROR: ", .style = .{ .fg = app.theme.warn, .modifier = .{ .bold = true } } },
                .{ .content = "Press Ctrl+R to retry", .style = .{ .fg = app.theme.muted } },
            });

            if (detail) |txt| {
                try para.appendText(alloc, txt, .{ .fg = app.theme.warn, .modifier = .{ .italic = true } });
            }
            const h = para.totalHeightLong(inner_w);
            try s.items.append(alloc, .{ .p = para, .h = h });
            s.total += h;
        }
    }

    // build in reverse
    var i = app.chat_entries.items.len;

    // TODO: Add propose preview
    // preview diff
    if (app.active_permission) |perm| {
        if (perm.payload == .diff) {
            var parts = try alloc.alloc(ChatPart, 1);
            parts[0] = try diffChatPart(alloc, perm.payload.diff);
            try buildChatEntryParagraph(alloc, &s.items, &s.total, app, .{
                .role = .agent,
                .parts = parts,
            }, inner_w);
        }
    }

    if (app.streaming_entry) |entry| {
        try buildChatEntryParagraph(alloc, &s.items, &s.total, app, entry, inner_w);
    }

    while (i > 0 and s.total < target) {
        i -= 1;
        const entry = app.chat_entries.items[i];

        if (maybe_agent == null and entry.role != .system) continue;

        try buildChatEntryParagraph(alloc, &s.items, &s.total, app, entry, inner_w);
    }

    if (i == 0) {
        const max_scroll: usize = if (s.total > inner_h) @intCast(s.total - inner_h) else 0;
        if (scroll_offset_usize > max_scroll) {
            scroll_offset_usize = max_scroll;
            app.scroll_offset = max_scroll;
            if (max_scroll == 0) app.auto_scroll = true;
        }
    }

    s.scroll_offset = scroll_offset_usize;
    return s;
}

fn renderChatStack(app: *App, s: ChatStack, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (area.width == 0 or area.height == 0) return;

    const alloc = app.arena_frame.allocator();
    const inner_w: u16 = area.width;
    const inner_h: u16 = area.height;
    const scroll_offset_usize: usize = s.scroll_offset;

    // Render bottom-up. anchor_y is the row JUST BELOW the next paragraph's
    // bottom border. When the stack does not fill the area, anchor below the
    // last visible row instead of the area bottom — keeps short chats top-aligned
    // and lets paragraphs grow downward until they hit the input.
    const viewport_top: i128 = area.y;
    const viewport_bottom: i128 = @as(i128, area.y) + @as(i128, inner_h);
    const fill_bottom: usize = @min(s.total, @as(usize, inner_h));
    var anchor_y: i128 = @as(i128, area.y) + @as(i128, @intCast(fill_bottom)) + @as(i128, @intCast(scroll_offset_usize));

    for (s.items.items) |e| {
        const item_bottom = anchor_y;
        const item_top = item_bottom - @as(i128, @intCast(e.h));
        defer anchor_y = item_top;

        if (item_bottom <= viewport_top) break;
        if (item_top >= viewport_bottom) continue;

        const visible_top = @max(item_top, viewport_top);
        const visible_bottom = @min(item_bottom, viewport_bottom);
        if (visible_top >= visible_bottom) continue;

        var p = e.p;
        if (p.reverse) {
            p.scroll_offset = @intCast(item_bottom - visible_bottom);
        } else {
            p.scroll_offset +|= @intCast(visible_top - item_top);
        }

        const sub: r.tui.Rect = .{
            .x = area.x,
            .y = @intCast(visible_top),
            .width = inner_w,
            .height = @intCast(visible_bottom - visible_top),
        };
        p.render(alloc, sub, area, buf);
    }
}

fn mainProgressLine(app: *App, alloc: std.mem.Allocator) ?r.tui.Line {
    const aid = app.main_agent_id orelse return null;
    const slot = &app.registry.slots[aid.index];
    const state = slot.state.load(.acquire);
    if (state != .active and state != .complete and state != .failed) return null;

    const agent = if (slot.agent) |*value| value else return null;
    const active_agent_count = app.registry.countActive();
    const waiting = active_agent_count > 0;
    const secs = app.sessionRunSecs();

    const hl: r.tui.Style = .{ .fg = app.theme.text, .modifier = .{ .bold = true } };
    const info: r.tui.Style = .{ .fg = app.theme.info };

    var dur_buf: [32]u8 = undefined;
    const dur = formatDuration(&dur_buf, secs);

    const exec_pool = app.exec_pool;
    const ssh_suffix: []const u8 = if (exec_pool.ssh_active and exec_pool.ssh_target != null) " (SSH ON)" else "";

    var l = r.tui.Line{};
    if (state == .active) {
        const spinner_str = text_utils.spinnerDots(app.frame_count);
        if (agent.status == .compacting) {
            l.pushSpanPrint(alloc, "{s} compacting", .{spinner_str}, info) catch {};
            return l;
        }

        var queued_buf: [64]u8 = undefined;
        const queued_count = app.queued.count();
        const queued_suffix: []const u8 = if (queued_count == 0)
            ""
        else if (queued_count == 1)
            "(1 message queued up)"
        else
            std.fmt.bufPrint(&queued_buf, "({d} queued messages up)", .{queued_count}) catch "(queued messages up)";

        const state_str: []const u8 = switch (agent.activity) {
            .idle => "",
            .thinking => "thinking",
            .writing => "writing",
            .calling => "calling",
            .retrying => "retrying",
        };

        l.pushSpanPrint(alloc, "{s} (", .{spinner_str}, info) catch {};
        l.pushSpanPrint(alloc, "{s}", .{dur}, hl) catch {};
        l.pushSpanPrint(alloc, ") Consuming Tokens at ", .{}, info) catch {};
        l.pushSpanPrint(alloc, "{d} T/s", .{@as(u32, @intFromFloat(agent.tokens_per_second))}, hl) catch {};

        if (state_str.len > 0) {
            l.pushSpanPrint(alloc, " while ", .{}, info) catch {};
            l.pushSpanPrint(alloc, "{s}", .{state_str}, hl) catch {};
        }

        l.pushSpanPrint(alloc, "{s} {s}", .{ ssh_suffix, queued_suffix }, info) catch {};

        if (active_agent_count > 1) {
            l.pushSpanPrint(alloc, "(", .{}, info) catch {};
            l.pushSpanPrint(alloc, "{d} ", .{active_agent_count -| 1}, hl) catch {};
            l.pushSpanPrint(alloc, "background agents)", .{}, info) catch {};
        }
    } else if (waiting and state == .complete) {
        l.pushSpanPrint(alloc, "Waiting for ", .{}, info) catch {};
        l.pushSpanPrint(alloc, "{d}", .{active_agent_count}, hl) catch {};
        l.pushSpanPrint(alloc, " agents (", .{}, info) catch {};
        l.pushSpanPrint(alloc, "{s}", .{dur}, hl) catch {};
        l.pushSpanPrint(alloc, ") {s}", .{ssh_suffix}, info) catch {};
    } else {
        const label = if (state == .complete) "Done" else "Failed";
        l.pushSpanPrint(alloc, "{s} ({s}){s}", .{ label, dur, ssh_suffix }, info) catch {};
    }
    return l;
}

fn formatDuration(buf: []u8, secs: u32) []const u8 {
    if (secs >= 60)
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ secs / 60, secs % 60 }) catch "…";
    return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "…";
}

fn currentSelection(app: *App) u8 {
    return switch (app.input_mode) {
        .perm_select => |ps| ps.selected,
        else => 0,
    };
}

fn renderPermissionContent(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const block: r.tui.Block = .{
        .style = .{ .fg = app.theme.warn },
        .borders = .{ .bottom = true, .left = true, .right = true },
    };

    block.render(area, buf);
    const inner = block.innerArea(area);
    if (inner.width == 0 or inner.height == 0) return;

    const entry = app.active_permission orelse return;

    if (entry.payload == .ask) {
        renderAskWidget(app, entry, inner, buf);
        return;
    }

    var header_buf: [256]u8 = undefined;
    const header_line: []const u8 = switch (entry.payload) {
        .call => |p| p.description,
        .diff => |p| blk: {
            const n = std.fmt.bufPrint(&header_buf, "edit: {s}", .{p.path}) catch "edit";
            break :blk n;
        },
        .plan => |p| blk: {
            const plan_trunc = if (p.plan_text.len > 60) p.plan_text[0..60] else p.plan_text;
            const n = std.fmt.bufPrint(&header_buf, "plan: {s}", .{plan_trunc}) catch "plan";
            break :blk n;
        },
        .ask => unreachable,
    };

    const width = inner.width -| 1;
    const header_rows = text_utils.wrappedRowCount(header_line, width);
    _ = text_utils.renderWrappedText(buf, header_line, inner.x + 1, inner.y, width, header_rows, 0, .{ .fg = app.theme.warn });

    const labels = [3][]const u8{ "allow?  yes", "        no", "        enter message" };
    const labels_sel = [3][]const u8{ "allow? >yes", "       >no", "       >enter message" };

    const plan_labels = [4][]const u8{ "plan?  approve & clear", "       approve & keep", "       no", "       enter message" };
    const plan_labels_sel = [4][]const u8{ "plan? >approve & clear", "      >approve & keep", "      >no", "      >enter message" };

    const is_plan = entry.payload == .plan;
    const count: usize = if (is_plan) 4 else 3;

    const cur_sel = currentSelection(app);
    for (0..count) |i| {
        const y = inner.y + header_rows + @as(u16, @intCast(i));
        if (y >= inner.y +| inner.height) break;
        const selected = cur_sel == @as(u8, @intCast(i));
        const style: r.tui.Style = if (selected) .{ .modifier = .{ .reverse = true } } else .{};
        const label = if (is_plan)
            (if (selected) plan_labels_sel[i] else plan_labels[i])
        else
            (if (selected) labels_sel[i] else labels[i]);
        buf.setStringMax(inner.x + 1, y, label, style, inner.width -| 1);
    }
}

fn renderAskWidget(app: *App, req: *r.permissions.Request, inner: r.tui.Rect, buf: *r.tui.Buffer) void {
    const args = req.payload.ask;
    const opts_len = @min(args.options.len, r.tools.ask.MAX_OPTIONS);
    const total_rows: usize = opts_len + 1; // + "enter message"

    // Clamp selection.
    const ps = &app.input_mode.perm_select;
    if (ps.selected >= total_rows) ps.selected = @intCast(total_rows - 1);
    const cur_sel = currentSelection(app);

    // Line 0+: "[header] question" (wrapped)
    var header_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&header_buf, "[{s}] {s}", .{ args.header, args.question }) catch args.question;
    const width = inner.width -| 1;

    var opts_rows: u16 = 1; // "enter message"
    opts_rows +|= wrappedOptionRows(args.options[0..opts_len], width);

    const max_q_rows = inner.height -| opts_rows -| 1;
    const q_rows = text_utils.renderWrappedText(buf, header_line, inner.x + 1, inner.y, width, max_q_rows, 0, .{ .fg = app.theme.info });

    // Options and "enter message" tail, each wrapped.
    var y: u16 = inner.y +| 1 +| q_rows;
    var row: usize = 0;
    while (row < total_rows and y < inner.y +| inner.height) : (row += 1) {
        const selected = cur_sel == @as(u8, @intCast(row));
        const style: r.tui.Style = if (selected) .{ .modifier = .{ .reverse = true } } else .{};
        const prefix: []const u8 = if (selected) "> " else "  ";
        const label: []const u8 = if (row < opts_len) args.options[row] else "enter message";

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ prefix, label }) catch label;
        const used = text_utils.renderWrappedText(buf, line, inner.x + 1, y, width, inner.y +| inner.height -| y, 2, style);
        if (used == 0) break;
        y +|= used;
    }
}

fn askPermissionInputHeight(options: []const []const u8, header: []const u8, question: []const u8, area_width: u16, area_height: u16) u16 {
    const opts_count: usize = @min(options.len, r.tools.ask.MAX_OPTIONS);
    const width = area_width -| 7;
    var rows: u16 = 0;
    var header_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&header_buf, "[{s}] {s}", .{ header, question }) catch question;
    rows +|= text_utils.wrappedRowCount(header_line, width);
    rows +|= 1; // "enter message"
    rows +|= wrappedOptionRows(options[0..opts_count], width);
    const max_area = area_height -| 1;
    return @min(rows +| 6, max_area);
}

fn wrappedOptionRows(options: []const []const u8, width: u16) u16 {
    var rows: u16 = 0;
    for (options) |opt| {
        var opt_buf: [512]u8 = undefined;
        const opt_line = std.fmt.bufPrint(&opt_buf, "  {s}", .{opt}) catch opt;
        rows +|= text_utils.wrappedRowCount(opt_line, width -| 2);
    }
    return rows;
}

fn formatTokenCount(dest: []u8, count: u64) []const u8 {
    if (count < 1000) {
        return std.fmt.bufPrint(dest, "{d}", .{count}) catch "0";
    } else if (count < 1_000_000) {
        const k = @as(f64, @floatFromInt(count)) / 1000.0;
        return std.fmt.bufPrint(dest, "{d:.1}k", .{k}) catch "0k";
    } else {
        const m = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        return std.fmt.bufPrint(dest, "{d:.1}M", .{m}) catch "0M";
    }
}

test "myers diff - single line change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb", "ccc", "ddd" };
    const new = [_][]const u8{ "aaa", "bbb", "xxx", "ddd" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(5, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].keep, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].keep, "bbb"));
    try std.testing.expect(std.mem.eql(u8, ops[2].delete, "ccc"));
    try std.testing.expect(std.mem.eql(u8, ops[3].insert, "xxx"));
    try std.testing.expect(std.mem.eql(u8, ops[4].keep, "ddd"));
}

test "myers diff - insertion only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const new = [_][]const u8{ "aaa", "xxx", "bbb" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(3, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].keep, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].insert, "xxx"));
    try std.testing.expect(std.mem.eql(u8, ops[2].keep, "bbb"));
}

test "myers diff - deletion only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "xxx", "bbb" };
    const new = [_][]const u8{ "aaa", "bbb" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(3, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].keep, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].delete, "xxx"));
    try std.testing.expect(std.mem.eql(u8, ops[2].keep, "bbb"));
}

test "myers diff - identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const ops = myersDiff(&old, &old, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(2, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].keep, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].keep, "bbb"));
}

test "myers diff - completely different" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const new = [_][]const u8{ "xxx", "yyy" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(4, ops.len);
}

test "myers diff - empty old" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{};
    const new = [_][]const u8{ "aaa", "bbb" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(2, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].insert, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].insert, "bbb"));
}

test "myers diff - empty new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const new = [_][]const u8{};
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(2, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].delete, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].delete, "bbb"));
}

test "emitDiffLines owns rendered content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const before = try std.testing.allocator.dupe(u8, "alpha\nbeta\n");
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.dupe(u8, "alpha\nBETA\n");
    defer std.testing.allocator.free(after);

    var lines: std.ArrayList(r.tui.DiffLine) = .empty;
    emitDiffLines(&lines, .{
        .path = "demo.txt",
        .before = before,
        .after = after,
    }, alloc);

    @memset(before, 'x');
    @memset(after, 'y');

    var saw_delete = false;
    var saw_add = false;
    for (lines.items) |line| {
        if (line.kind == .deletion and std.mem.eql(u8, line.content, "beta")) saw_delete = true;
        if (line.kind == .addition and std.mem.eql(u8, line.content, "BETA")) saw_add = true;
    }
    try std.testing.expect(saw_delete);
    try std.testing.expect(saw_add);
}

test "persisted diff owns path" {
    var app: App = undefined;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.chat_entries = .empty;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    app.main_agent_id = .{ .index = 0, .generation = 0 };
    app.event_bus = .{};
    app.dirty = false;

    var preview_parts = [_]ChatPart{.{ .tool_call = .{
        .agent_id = .{ .index = 0, .generation = 0 },
        .call_id = "call_1",
        .tool_name = "edit",
    } }};
    app.streaming_entry = .{ .role = .agent, .parts = &preview_parts };

    const path = try std.testing.allocator.dupe(u8, "demo.txt");
    defer std.testing.allocator.free(path);
    try app.persist_permission_to_history(&.{
        .agent_id = .{ .index = 0, .generation = 0 },
        .payload = .{ .diff = .{ .path = path, .before = null, .after = "content" } },
    });

    @memset(path, 'x');
    try std.testing.expectEqual(@as(usize, 2), app.chat_entries.items.len);
    try std.testing.expectEqualStrings("call_1", app.chat_entries.items[0].parts[0].tool_call.call_id);
    try std.testing.expectEqualStrings("demo.txt", app.chat_entries.items[1].parts[0].diff.path);
    try std.testing.expect(app.streaming_entry == null);

    const final_parts = [_]r.sdk.Part{r.sdk.Part.toolCallPart("call_1", "edit", "{}")};
    const messages = [_]r.sdk.Message{.{ .role = .assistant, .content = &final_parts }};
    var result = r.sdk.TextResult{ .messages = &messages };
    try app.applyRunEvent(.{ .index = 0, .generation = 0 }, .{ .complete = &result });
    try std.testing.expectEqual(@as(usize, 2), app.chat_entries.items.len);
}

test "renderSdkParts keeps streamed final parts together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parts = [_]r.sdk.Part{
        .{ .reasoning = .{ .text = " think ", .signature = "" } },
        .{ .text = " answer " },
        .{ .tool_call = .{ .id = "call_1", .name = "bash", .input = "{}" } },
    };

    const agent_id: r.AgentId = .{ .index = 3, .generation = 7 };
    const rendered = renderSdkParts(alloc, agent_id, &parts) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), rendered.len);
    try std.testing.expectEqualStrings("think", rendered[0].thinking);
    try std.testing.expectEqualStrings("answer", rendered[1].message);
    try std.testing.expectEqualStrings("call_1", rendered[2].tool_call.call_id);
    try std.testing.expectEqualStrings("bash", rendered[2].tool_call.tool_name);
    try std.testing.expectEqual(agent_id, rendered[2].tool_call.agent_id);
}

test "checkpoint history appends only new assistant messages" {
    var app: App = undefined;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.chat_entries = .empty;

    const first_parts = [_]r.sdk.Part{r.sdk.Part.textPart("old")};
    const checkpoint_parts = [_]r.sdk.Part{
        r.sdk.Part.textPart("kept"),
        r.sdk.Part.toolCallPart("call_1", "read", "{}"),
    };
    const result_parts = [_]r.sdk.Part{r.sdk.Part.toolResultPart("call_1", "read", "done")};
    const messages = [_]r.sdk.Message{
        .{ .role = .assistant, .content = &first_parts },
        .{ .role = .assistant, .content = &checkpoint_parts },
        .{ .role = .tool, .content = &result_parts },
    };

    try app.appendSdkHistory(.{ .index = 0, .generation = 0 }, &messages, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), app.chat_entries.items.len);
    try std.testing.expectEqualStrings("kept", app.chat_entries.items[0].parts[0].message);
    try std.testing.expectEqualStrings("call_1", app.chat_entries.items[0].parts[1].tool_call.call_id);
}

test "checkpoint history skips rendered assistant steps" {
    var app: App = undefined;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.chat_entries = .empty;

    const old_parts = [_]r.sdk.Part{r.sdk.Part.textPart("old")};
    const rendered_parts = [_]r.sdk.Part{r.sdk.Part.textPart("rendered")};
    const pending_parts = [_]r.sdk.Part{r.sdk.Part.textPart("pending")};
    const messages = [_]r.sdk.Message{
        .{ .role = .assistant, .content = &old_parts },
        r.sdk.UserMessage("continue"),
        .{ .role = .assistant, .content = &rendered_parts },
        .{ .role = .assistant, .content = &pending_parts },
    };

    try app.appendSdkHistory(.{ .index = 0, .generation = 0 }, &messages, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), app.chat_entries.items.len);
    try std.testing.expectEqualStrings("pending", app.chat_entries.items[0].parts[0].message);
}

test "undoLastUserMessage pops the last user message into the input" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.chat_entries = .empty;
    app.input_buffer = .empty;
    app.input_cursor = 0;
    app.input_mode = .{ .text = .{} };
    app.running = false;
    app.dirty = false;

    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "main", .cwd = "/tmp" } });
    try agent.setMessages(&.{ r.sdk.UserMessage("old"), r.sdk.UserMessage("hello") });
    app.main_agent_id = id;
    app.registry = &registry;

    const alloc = app.sessionAlloc();
    try app.appendChatEntry(alloc, try ChatEntry.userMessageSimple(alloc, .user, "hello"));
    try std.testing.expectEqual(@as(usize, 1), app.chat_entries.items.len);

    app.undoLastUserMessage();

    try std.testing.expectEqual(@as(usize, 0), app.chat_entries.items.len);
    try std.testing.expectEqualStrings("hello", app.input_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), agent.history().len);
    try std.testing.expectEqualStrings("old", agent.history()[0].text());
}

test "undoLastUserMessage does not fire while running" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.chat_entries = .empty;
    app.input_buffer = .empty;
    app.input_cursor = 0;
    app.input_mode = .{ .text = .{} };
    app.running = true;
    app.dirty = false;

    const alloc = app.sessionAlloc();
    try app.appendChatEntry(alloc, try ChatEntry.userMessageSimple(alloc, .user, "hello"));
    app.main_agent_id = null;

    app.undoLastUserMessage();

    try std.testing.expectEqual(@as(usize, 1), app.chat_entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.input_buffer.items.len);
}

test "SDK run events preserve preview final rendering and usage" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.chat_entries = .empty;
    app.streaming_entry = null;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    app.sdk_usage = .{};
    app.tool_status_entries = .{};
    app.main_agent_id = null;
    app.event_bus = .{};
    app.dirty = false;

    const agent_id = r.AgentId{ .index = 2, .generation = 4 };
    try app.applyRunEvent(agent_id, .{ .reasoning = "plan " });
    try app.applyRunEvent(agent_id, .{ .text = "answer" });
    try app.applyRunEvent(agent_id, .{ .tool = .{
        .type = .tool_call,
        .tool_call_id = "call_1",
        .tool_name = "read",
        .tool_input = "{}",
    } });
    try std.testing.expectEqual(@as(usize, 3), app.streaming_entry.?.parts.len);
    try std.testing.expectEqualStrings("plan", app.streaming_entry.?.parts[0].thinking);
    try std.testing.expectEqualStrings("answer", app.streaming_entry.?.parts[1].message);
    try std.testing.expectEqualStrings("call_1", app.streaming_entry.?.parts[2].tool_call.call_id);

    try app.applyRunEvent(agent_id, .{ .step = .{
        .number = 1,
        .usage = .{ .input_tokens = 5, .output_tokens = 2, .total_tokens = 7 },
        .tool_results = &.{.{ .tool_call_id = "call_1", .is_error = false }},
    } });
    try std.testing.expectEqual(@as(u64, 7), app.sdk_usage.total_tokens);
    const status = &app.tool_status_entries.value.agents[agent_id.index];
    try std.testing.expectEqual(false, status.entries.get("call_1").?.is_error.?);
    try std.testing.expect(app.streaming_entry == null);
    try std.testing.expectEqual(@as(usize, 0), app.sdk_preview_parts.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.arena_streaming_preview.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), app.arena_streaming_snapshot.queryCapacity());

    const final_parts = [_]r.sdk.Part{
        r.sdk.Part.reasoningPart("plan", ""),
        r.sdk.Part.textPart("answer"),
        r.sdk.Part.toolCallPart("call_1", "read", "{}"),
    };
    const messages = [_]r.sdk.Message{.{ .role = .assistant, .content = &final_parts }};
    var result = r.sdk.TextResult{ .messages = &messages };
    try app.applyRunEvent(agent_id, .{ .complete = &result });
    try std.testing.expect(app.streaming_entry == null);
    try std.testing.expectEqual(@as(usize, 1), app.chat_entries.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.chat_entries.items[0].parts.len);
}

test "SDK preview coalesces same-type deltas and keeps part order" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.chat_entries = .empty;
    app.streaming_entry = null;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    app.sdk_usage = .{};
    app.tool_status_entries = .{};
    app.main_agent_id = null;
    app.event_bus = .{};
    app.dirty = false;

    const agent_id = r.AgentId{ .index = 1, .generation = 1 };
    try app.applyRunEvent(agent_id, .{ .reasoning = "plan " });
    try app.applyRunEvent(agent_id, .{ .reasoning = "more" });
    try app.applyRunEvent(agent_id, .{ .tool = .{
        .type = .tool_call,
        .tool_call_id = "call_1",
        .tool_name = "read",
        .tool_input = "{}",
    } });
    try app.applyRunEvent(agent_id, .{ .reasoning = " after " });
    try app.applyRunEvent(agent_id, .{ .text = "answer " });
    try app.applyRunEvent(agent_id, .{ .text = "tail" });
    try app.applyRunEvent(agent_id, .{ .tool = .{
        .type = .tool_call,
        .tool_call_id = "call_2",
        .tool_name = "write",
        .tool_input = "{}",
    } });

    const parts = app.streaming_entry.?.parts;
    try std.testing.expectEqual(@as(usize, 5), parts.len);
    try std.testing.expectEqualStrings("plan more", parts[0].thinking);
    try std.testing.expectEqualStrings("call_1", parts[1].tool_call.call_id);
    try std.testing.expectEqualStrings("after", parts[2].thinking);
    try std.testing.expectEqualStrings("answer tail", parts[3].message);
    try std.testing.expectEqualStrings("call_2", parts[4].tool_call.call_id);
}

test "subagent events preserve the main tool call preview" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.chat_entries = .empty;
    app.streaming_entry = null;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    app.sdk_usage = .{};
    app.tool_status_entries = .{};
    app.event_bus = .{};
    app.dirty = false;

    const main_id = r.AgentId{ .index = 1, .generation = 1 };
    const child_id = r.AgentId{ .index = 2, .generation = 1 };
    app.main_agent_id = main_id;
    try app.applyRunEvent(main_id, .{ .tool = .{
        .type = .tool_call,
        .tool_call_id = "agent_1",
        .tool_name = "agent",
        .tool_input = "{}",
    } });
    try app.applyRunEvent(child_id, .{ .reasoning = "working" });
    try app.applyRunEvent(child_id, .{ .text = "done" });
    try app.applyRunEvent(child_id, .{ .step = .{
        .number = 1,
        .tool_results = &.{
            .{ .tool_call_id = "child_1", .is_error = false },
            .{ .tool_call_id = "child_2", .is_error = false },
            .{ .tool_call_id = "child_3", .is_error = false },
            .{ .tool_call_id = "child_4", .is_error = false },
        },
    } });
    var result = r.sdk.TextResult{};
    try app.applyRunEvent(child_id, .{ .complete = &result });

    try std.testing.expectEqual(@as(usize, 1), app.streaming_entry.?.parts.len);
    try std.testing.expectEqualStrings("agent_1", app.streaming_entry.?.parts[0].tool_call.call_id);
    try std.testing.expectEqual(@as(usize, 4), app.tool_status_entries.value.agents[child_id.index].entries.count());
}

test "background agent result is written for read" {
    var agent = try r.agent.Agent.init(std.testing.allocator, std.testing.io, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const parts = [_]r.sdk.Part{ r.sdk.Part.textPart("result"), r.sdk.Part.textPart(" done") };
    try agent.setMessages(&.{.{ .role = .assistant, .content = &parts }});

    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var pool = r.exec.CmdPool.init(std.testing.allocator, std.testing.io, &env);
    defer pool.deinit();
    app.exec_pool = &pool;
    const path = try app.writeBackgroundResult(.{ .index = 127, .generation = 65535 }, &agent);
    defer std.testing.allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/blitz/"));
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited64(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("result done", content);
}

test "appendChatEntry preserves parts order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parts = [_]ChatPart{
        .{ .tool_call = .{ .agent_id = .{ .index = 3, .generation = 7 }, .call_id = "call_1", .tool_name = "bash" } },
        .{ .message = "answer" },
        .{ .thinking = "think" },
        .{ .tool_call = .{ .agent_id = .{ .index = 3, .generation = 7 }, .call_id = "call_2", .tool_name = "grep" } },
    };

    var app: App = undefined;
    app.chat_entries = .empty;
    try app.appendChatEntry(arena.allocator(), .{ .role = .agent, .parts = &parts });

    const entry = app.chat_entries.items[0];
    try std.testing.expectEqual(@as(usize, 4), entry.parts.len);
    try std.testing.expectEqualStrings("call_1", entry.parts[0].tool_call.call_id);
    try std.testing.expectEqualStrings("answer", entry.parts[1].message);
    try std.testing.expectEqualStrings("think", entry.parts[2].thinking);
    try std.testing.expectEqualStrings("call_2", entry.parts[3].tool_call.call_id);
}

test "flushed preview precedes compact status" {
    var app: App = undefined;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.chat_entries = .empty;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    var parts = [_]ChatPart{.{ .message = "latest agent output" }};
    app.streaming_entry = .{ .role = .agent, .parts = &parts };

    try app.flushSdkPreview();
    app.pushSystemMessage("compaction queued for the next turn", .{});

    try std.testing.expectEqual(@as(usize, 2), app.chat_entries.items.len);
    try std.testing.expectEqual(ChatRole.agent, app.chat_entries.items[0].role);
    try std.testing.expectEqual(ChatRole.system, app.chat_entries.items[1].role);
}

test "ToolStatusStore retains terminal tool result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: ToolStatusStore = .{};
    const agent_id: r.AgentId = .{ .index = 1, .generation = 2 };
    try store.setResult(arena.allocator(), agent_id, "call_1", true);

    const agent = &store.agents[agent_id.index];
    try std.testing.expectEqual(agent_id.generation, agent.generation);
    try std.testing.expect(agent.entries.get("call_1").?.is_error.?);
}

test "tool group rail: nested list ends with exactly one corner" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.chat_entries = .empty;
    app.tool_status_entries = .{};
    app.dirty = false;

    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    app.registry = &registry;

    const parent_id = registry.reserve().?;
    const child_id = registry.reserve().?;
    _ = try registry.activate(parent_id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "main", .cwd = "/tmp" } });
    _ = try registry.activate(child_id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "child", .cwd = "/tmp" } });

    try app.setToolChild(parent_id, "call_1", child_id);
    try app.setToolStatus(parent_id, "call_1", "challenger -> task");
    try app.setToolStatus(child_id, "child_1", "bash cmd\nconst std = @import\npub fn main() !void");
    try app.setToolStatus(child_id, "child_2", "bash list files");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try buildToolGroupParagraph(&app, arena.allocator(), &.{
        .{ .agent_id = parent_id, .call_id = "call_1", .tool_name = "agent" },
    }, 80);
    var glyphs = try collectRailGlyphs(std.testing.allocator, rendered.p);
    defer glyphs.deinit(std.testing.allocator);

    const corner = decodeCp("└");
    var corner_count: usize = 0;
    for (glyphs.items) |g| {
        if (g == corner) corner_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), corner_count);
    try std.testing.expectEqual(corner, glyphs.items[glyphs.items.len - 1]);
}

fn collectRailGlyphs(alloc: std.mem.Allocator, p: r.tui.Paragraph) !std.ArrayList(u21) {
    var glyphs: std.ArrayList(u21) = .empty;
    errdefer glyphs.deinit(alloc);
    for (p.lines.items) |line| {
        if (line.spans.items.len == 0) continue;
        const first = line.spans.items[0].content;
        if (first.len < 3 or first[0] != ' ') continue;
        const len = std.unicode.utf8ByteSequenceLength(first[1]) catch continue;
        const decoded = std.unicode.utf8Decode(first[1..][0..len]) catch continue;
        try glyphs.append(alloc, decoded);
    }
    return glyphs;
}

fn decodeCp(text: *const [3:0]u8) u21 {
    return std.unicode.utf8Decode(text[0..3]) catch 0;
}

test "appendMarkdownText fills headline to width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p: r.tui.Paragraph = .{};
    try appendMarkdownText(&p, std.testing.allocator, alloc, "# Hi\n## Bye\n### Low\n", 20, .default);

    try std.testing.expectEqual(@as(usize, 3), p.lines.items.len);

    const h1 = p.lines.items[0];
    try std.testing.expectEqual(@as(usize, 4), h1.spans.items.len);
    try std.testing.expectEqualStrings("====", h1.spans.items[0].content);
    try std.testing.expectEqualStrings("Hi", h1.spans.items[1].content);
    try std.testing.expectEqualStrings("====", h1.spans.items[2].content);
    try std.testing.expectEqual(@as(usize, 10), h1.spans.items[3].content.len);
    for (h1.spans.items[3].content) |c| try std.testing.expectEqual(@as(u8, '='), c);
    try std.testing.expectEqual(@as(usize, 20), h1.widthCols());
    try std.testing.expect(h1.spans.items[1].style.modifier.bold);

    const h2 = p.lines.items[1];
    try std.testing.expectEqual(@as(usize, 4), h2.spans.items.len);
    try std.testing.expectEqualStrings("----", h2.spans.items[0].content);
    try std.testing.expectEqualStrings("Bye", h2.spans.items[1].content);
    try std.testing.expectEqualStrings("----", h2.spans.items[2].content);
    try std.testing.expectEqual(@as(usize, 9), h2.spans.items[3].content.len);
    for (h2.spans.items[3].content) |c| try std.testing.expectEqual(@as(u8, '-'), c);
    try std.testing.expectEqual(@as(usize, 20), h2.widthCols());

    const h3 = p.lines.items[2];
    try std.testing.expectEqual(@as(usize, 1), h3.spans.items.len);
    try std.testing.expectEqualStrings("Low", h3.spans.items[0].content);
    try std.testing.expect(!h3.spans.items[0].style.modifier.bold);
    try std.testing.expect(h3.spans.items[0].style.fg != .reset);
}

test "completion matcher excludes exact prefix" {
    const skills = [_][]const u8{ "/skill-ponytail", "/skill-ponytail-audit" };
    try std.testing.expect(!completionMatches(skills[0], "/skill-ponytail"));
    try std.testing.expect(completionMatches(skills[1], "/skill-ponytail"));
    try std.testing.expect(completionMatches(skills[0], "/skill"));
    try std.testing.expect(completionMatches(skills[1], "/skill"));
}

test "completion visibility rule" {
    try std.testing.expect(completionVisible("/ski", 4, 2));
    try std.testing.expect(!completionVisible("/skill-x ", 9, 2));
    try std.testing.expect(!completionVisible("hello", 5, 2));
    try std.testing.expect(!completionVisible("/cd /tm", 7, 2));
    try std.testing.expect(!completionVisible("/ski", 4, 0));
}

test "completion filter keeps original query after insert" {
    try std.testing.expectEqualStrings("/sk", filterPrefix("/skill-ponytail", 15, 3, true));
    try std.testing.expectEqualStrings("/skill-ponytail", filterPrefix("/skill-ponytail", 15, 3, false));
    try std.testing.expectEqualStrings("/ski", filterPrefix("/ski", 4, 0, true));
}

test "wizard confirm writes provider.lua and marker then returns to text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    const lua_vm = try r.lua.LuaVm.init(std.testing.allocator);
    defer lua_vm.deinit();
    app.lua_vm = lua_vm;
    app.lua_config_dir = null;

    app.enterWizard();
    const w = app.wizardState().?;
    const entry = r.wizard.catalog[0];
    w.provider_index = 0;
    w.provider_type_len = entry.provider_type.len;
    @memcpy(w.provider_type_buf[0..w.provider_type_len], entry.provider_type);
    w.url_len = entry.default_url.len;
    @memcpy(w.url_buf[0..w.url_len], entry.default_url);
    w.key_len = "sk-ant-secret".len;
    @memcpy(w.key_buf[0..w.key_len], "sk-ant-secret");
    w.model_len = entry.models[0].name.len;
    @memcpy(w.model_buf[0..w.model_len], entry.models[0].name);

    app.wizardConfirm(tmp.dir);

    try std.testing.expect(app.input_mode == .text);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, r.wizard.PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tkey = \"sk-ant-secret\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tname = \"claude-fable-5\",\n") != null);
    try tmp.dir.access(std.testing.io, r.wizard.DONE_MARKER, .{});
}

test "wizard skip writes defaults, honors marker, and existing provider.lua wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    const lua_vm = try r.lua.LuaVm.init(std.testing.allocator);
    defer lua_vm.deinit();
    app.lua_vm = lua_vm;
    app.lua_config_dir = null;

    app.enterWizard();
    const w = app.wizardState().?;
    w.key_len = "leftover".len;
    @memcpy(w.key_buf[0..w.key_len], "leftover");
    app.wizardSkip(tmp.dir);

    try std.testing.expect(app.input_mode == .text);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, r.wizard.PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "https://opencode.ai/zen/go/v1") != null);
    try tmp.dir.access(std.testing.io, r.wizard.DONE_MARKER, .{});
    for (w.key_buf[0.."leftover".len]) |ch| try std.testing.expectEqual(@as(u8, 0), ch);

    const existing = "local model = 42\nreturn model\n";
    {
        const file = try tmp.dir.createFile(std.testing.io, r.wizard.PROVIDER_LUA, .{ .truncate = true });
        defer file.close(std.testing.io);
        var buf: [64]u8 = undefined;
        var fw = file.writer(std.testing.io, &buf);
        try fw.interface.writeAll(existing);
        try fw.interface.flush();
    }

    app.enterWizard();
    app.wizardSkip(tmp.dir);
    try std.testing.expect(app.input_mode == .text);
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, r.wizard.PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings(existing, preserved);
}
