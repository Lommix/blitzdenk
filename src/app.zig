const std = @import("std");
const r = @import("root.zig");
const prv = @import("provider");
const text_utils = r.tui.text_utils;
const log = std.log.scoped(.app);

pub const FULL_MODE_REMINDER_AFTER_USER_MSG_COUNT = 4;
pub const PROMPT_HISTORY_FILENAME = "prompt_history.json";
pub const MAX_HISTORY = 32;
pub const CONTEXT_LIMIT = 124 * 1024;
const COMMAND_COMPLETION_ROWS = 4;

const builtin_command_completions: []const []const u8 = &.{
    ":clear",
    ":help",
    ":ssh user@host:/path/to/cwd",
    ":cd /path/to/new/cwd",
};

const HEADER_ART =
    \\██████╗ ██╗     ██╗████████╗███████╗██████╗ ███████╗███╗   ██╗██╗  ██╗
    \\██╔══██╗██║     ██║╚══██╔══╝╚══███╔╝██╔══██╗██╔════╝████╗  ██║██║ ██╔╝
    \\██████╔╝██║     ██║   ██║     ███╔╝ ██║  ██║█████╗  ██╔██╗ ██║█████╔╝
    \\██╔══██╗██║     ██║   ██║    ███╔╝  ██║  ██║██╔══╝  ██║╚██╗██║██╔═██╗
    \\██████╔╝███████╗██║   ██║   ███████╗██████╔╝███████╗██║ ╚████║██║  ██╗
    \\╚═════╝ ╚══════╝╚═╝   ╚═╝   ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝
;
const HEADER_INFO =
    \\├[github.com/lommix/blitzdenk ............................... v0.1337
    \\├[cfg: $HOME/.config/blitzdenk/blitz.lua
    \\│
    \\├[c+g] Toggle permissions
    \\├[ecs] Cancel
    \\├[c+n] Clear session
    \\├[c+c] Quit
    \\│
    \\├[Start SSH ----------------- :ssh user@host:/path/to/cwd
    \\├[Change CWD ---------------- :cd /path/to/new/cwd
    \\│
    \\├[CWD]: {cwd}
    \\│
    \\├[{INFO}
    \\├[Max: {MODEL_MAX}
    \\├[Mid: {MODEL_MID}
    \\└[Min: {MODEL_MIN}
;

pub const PermisionLevel = enum {
    read_only,
    write_safe,
    write_deadly,
};

pub const UiState = union(enum) {
    chat,
    cmd_palette,
    password,
};

pub const AppFlags = packed struct {
    show_thinking: bool = true,
    debug_log: bool = true,
    /// When true, the agent sees the SSH state reminder and gets the
    /// `enter_ssh`/`exit_ssh` r.tools. When false, SSH mode is locked from the
    /// agent's perspective: it cannot toggle and is not informed of the state.
    /// Toggle from TUI / r.lua.
    ssh_agent_control: bool = true,
    skip_permissions: bool = true,
};

pub const Theme = struct {
    bg: r.tui.Color,
    overlay_dark: r.tui.Color,
    overlay: r.tui.Color,
    muted: r.tui.Color,
    text: r.tui.Color,
    ok: r.tui.Color,
    info: r.tui.Color,
    warn: r.tui.Color,
    err: r.tui.Color,
    diff_surface: r.tui.Color,
    diff_add: r.tui.Color,
    diff_remove: r.tui.Color,

    pub const default: Theme = .{
        .bg = .{ .rgb = .{ .r = 18, .g = 18, .b = 24 } },
        .diff_surface = .{ .rgb = .{ .r = 30, .g = 30, .b = 46 } },
        .overlay = .{ .rgb = .{ .r = 49, .g = 50, .b = 68 } },
        .overlay_dark = .{ .rgb = .{ .r = 40, .g = 44, .b = 52 } },
        .muted = .{ .rgb = .{ .r = 108, .g = 112, .b = 134 } },
        .text = .{ .rgb = .{ .r = 205, .g = 214, .b = 244 } },
        .ok = .green,
        .info = .blue,
        .warn = .yellow,
        .err = .red,
        .diff_add = .{ .rgb = .{ .r = 166, .g = 227, .b = 161 } },
        .diff_remove = .{ .rgb = .{ .r = 243, .g = 139, .b = 168 } },
    };
};

pub const InputMode = union(enum) {
    text,
    perm_select: PermSelect,
    perm_message: PermMessage,
    passphrase: Passphrase,

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
};

pub const QueuedMessage = struct {
    agent_id: prv.Swarm.AgentId,
    entry: ?ChatEntry = null,
    parts: []const prv.adapter.ContentPart,
};

pub const MessageQueue = struct {
    items: std.ArrayList(QueuedMessage) = .empty,

    fn sameAgent(a: prv.Swarm.AgentId, b: prv.Swarm.AgentId) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn push(
        self: *MessageQueue,
        alloc: std.mem.Allocator,
        agent_id: prv.Swarm.AgentId,
        entry: ?ChatEntry,
        parts: []const prv.adapter.ContentPart,
    ) !void {
        try self.items.append(alloc, .{
            .agent_id = agent_id,
            .entry = entry,
            .parts = parts,
        });
    }

    pub fn popFor(self: *MessageQueue, agent_id: prv.Swarm.AgentId) ?QueuedMessage {
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

pub const App = struct {
    /// Lives whole app run. Persistent state: history, keymap binds, cwd.
    arena_app: prv.ThreadSafeArena,
    /// Reset between sessions. Chat entries, input buffer, plans, diffs, queued msgs.
    arena_session: std.heap.ArenaAllocator,

    input_buffer: std.ArrayList(u8) = .empty,
    input_cursor: u32 = 0,
    input_scroll_offset: u16 = 0,
    swarm: *prv.Swarm,
    main_agent_id: ?prv.Swarm.AgentId = null,
    running: bool = false,
    frame_count: usize = 0,
    scroll_offset: usize = 0,
    auto_scroll: bool = true,
    input_mode: InputMode = .text,
    mode: r.reg.Mode = @enumFromInt(0),
    context_factory: *r.reg.ContextFactory,
    theme: Theme = .default,
    cwd: []const u8,
    remote_cwd: []const u8 = "/",
    flags: AppFlags = .{},
    default_context_limit: u32 = CONTEXT_LIMIT,
    screenshot_buf: ?[]const u8 = null,
    dirty: bool = true,
    history: std.ArrayList(PromptEntry) = .empty,
    history_cursor: usize = 0,
    pending_perm: ?PendingPerm = null,
    chat_entries: std.ArrayList(ChatEntry) = .empty,
    broadcast_cursor: u64 = 0,
    streaming_preview_idx: ?usize = null,
    compaction_indicator_active: bool = false,
    compaction_completion_seen_count: usize = 0,
    current_plan_file: ?[]const u8 = null,
    passphrase_args_buf: [512]u8 = undefined,
    queued: MessageQueue = .{},
    ui_state: UiState = .chat,
    keymap: r.keys.KeyMap = .{},
    cmd_queue: r.cmd.CommandQueue,
    lua_vm: r.lua.LuaVm,
    lua_status_bar_enabled: bool = false,
    lua_status_bar_cache: [512]u8 = undefined,
    lua_status_bar_cache_len: usize = 0,
    mcp_manager: r.mcp.Manager,
    notifications: Notifications = .{},
    event_bus: r.events.EventBus = .{},
    injection_hooks: r.inject.InjectionsHooks = .{},

    // TODO: cleanup io
    pub fn init(
        allocator: std.mem.Allocator,
        lua_allocator: std.mem.Allocator,
        swarm: *prv.Swarm,
        agent_factory: *r.reg.ContextFactory,
        cwd: []const u8,
    ) !App {
        var lua_vm = try r.lua.LuaVm.init(lua_allocator);
        errdefer lua_vm.deinit();

        return App{
            .arena_app = .init(allocator, agent_factory.io),
            .arena_session = .init(allocator),
            .swarm = swarm,
            .context_factory = agent_factory,
            .cwd = cwd,
            .cmd_queue = try r.cmd.CommandQueue.init(allocator),
            .lua_vm = lua_vm,
            .mcp_manager = r.mcp.Manager.init(allocator, agent_factory.io),
            .injection_hooks = try r.inject.InjectionsHooks.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        // cleanup hanging processes
        if (self.main_agent_id) |id| blk: {
            const a = self.swarm.getAgent(id) orelse break :blk;
            // Agent is being torn down — no tools should be in flight, but
            // go through the lock anyway for consistency.
            const g = a.bg_tasks.tryLock(self.swarm.pool.io) orelse break :blk;
            defer g.unlock();
            for (g.ptr.list.items) |e| self.swarm.exec.cancel(e.handle);
        }

        self.mcp_manager.deinit();
        self.lua_vm.deinit();
        self.arena_session.deinit();
        self.arena_app.deinit();
    }

    /// Session-scoped allocator. Wiped on reset.
    pub fn sessionAlloc(self: *App) std.mem.Allocator {
        return self.arena_session.allocator();
    }

    /// App-scoped allocator. Survives session resets.
    pub fn appAlloc(self: *App) std.mem.Allocator {
        return self.arena_app.allocator();
    }

    pub const PendingPerm = struct {
        call_id: []const u8,
        chat_entry_idx: ?usize,
    };

    pub fn reset(self: *App) void {
        self.main_agent_id = null;
        self.frame_count = 0;
        self.scroll_offset = 0;
        self.input_mode = .text;
        self.input_cursor = 0;
        self.pending_perm = null;
        self.broadcast_cursor = 0;
        self.streaming_preview_idx = null;
        self.compaction_indicator_active = false;
        self.compaction_completion_seen_count = 0;
        self.swarm.reset();
        self.current_plan_file = null;
        self.screenshot_buf = null;
        self.dirty = true;
        _ = self.arena_session.reset(.free_all);
        // Backing storage just got freed — reset list headers to .empty so
        // stale ptr/capacity don't cause UB on next append.
        self.input_buffer = .empty;
        self.chat_entries = .empty;
        self.queued = .{};
        self.lua_vm.disableAllMcp();
        self.reloadMcpTools() catch {};
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

    pub fn returnToText(self: *App) void {
        // Zero passphrase buffer when leaving the modal so it doesn't linger.
        if (self.input_mode == .passphrase) {
            const pp = &self.input_mode.passphrase;
            @memset(pp.buf[0..pp.len], 0);
        }
        self.input_mode = .text;
    }

    pub fn reloadMcpTools(self: *App) !void {
        const alloc = self.sessionAlloc();

        self.lua_vm.vm_mu.lockUncancelable(self.swarm.pool.io);
        defer self.lua_vm.vm_mu.unlock(self.swarm.pool.io);

        const old_tools = self.mcp_manager.registeredTools();
        for (old_tools) |entry| self.context_factory.remove(entry.tool.def.name);

        const servers = try self.lua_vm.getEnabledMcpServers(alloc);
        self.mcp_manager.loadServers(servers);

        const new_tools = self.mcp_manager.registeredTools();
        for (new_tools) |entry| try self.context_factory.add(alloc, entry.tool, entry.flags);

        for (&self.swarm.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;

            var set = r.reg.ToolSet{};
            self.context_factory.build_toolset(@enumFromInt(slot.agent.type_idx), &set) catch continue;
            try slot.agent.setTools(set.slice());
        }

        self.dirty = true;
    }

    pub fn pushSystemMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.sessionAlloc();
        const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
        const parts = alloc.alloc(ChatEntry.MessagePart, 1) catch return;
        parts[0] = .{ .text = text };
        self.chat_entries.append(alloc, .{ .message = .{
            .role = .system,
            .parts = parts,
        } }) catch return;
    }

    pub fn mainAgent(self: *const App) ?*prv.agent.Agent {
        const id = self.main_agent_id orelse return null;
        return self.swarm.getAgent(id);
    }

    pub fn configureAgent(self: *const App, agent: *prv.agent.Agent) !void {
        try self.context_factory.configureAgent(agent, self.swarm.cfg);
        agent.context_limit = self.default_context_limit;
    }

    pub fn contextPercent(self: *const App) f32 {
        const id = self.main_agent_id orelse return 0;
        const slot = &self.swarm.slots[id.index];
        if (slot.generation != id.generation) return 0;
        return slot.agent.getContextPercent();
    }

    pub fn isMainAgentCompacting(self: *const App) bool {
        const agent = self.mainAgent() orelse return false;
        return agent.state == .compacting;
    }

    pub fn syncCompactionIndicator(self: *App) void {
        const agent = self.mainAgent() orelse {
            self.compaction_indicator_active = false;
            return;
        };

        if (agent.state == .compacting) {
            self.compaction_indicator_active = true;
            return;
        }

        if (!self.compaction_indicator_active) return;
        self.compaction_indicator_active = false;

        const compacted_count = agent.compaction.must_progress_past_message_count;
        if (compacted_count == 0 or compacted_count == self.compaction_completion_seen_count) return;

        self.compaction_completion_seen_count = compacted_count;
        self.pushSystemMessage("compact complete", .{});
        self.dirty = true;
    }

    pub fn genSystemRemindersOpaque(ptr: *anyopaque, agent: *prv.agent.Agent) void {
        const self: *App = @ptrCast(@alignCast(ptr));

        self.injection_hooks.build(self, agent) catch |err| {
            log.err("failed reminder injection {any}", .{err});
        };
    }

    pub fn render(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
        //inlining layout the ugliest way possible, deal with it

        buf.fill(area, .{ .style = .{ .bg = app.theme.overlay } });
        var frame_arena = std.heap.ArenaAllocator.init(app.sessionAlloc());
        defer frame_arena.deinit();
        const frame_alloc = frame_arena.allocator();

        // Input Field
        const pending = app.firstPendingPermission();

        const input_height: u16 = blk: {
            switch (app.input_mode) {
                .text, .perm_message, .passphrase => break :blk 5,
                .perm_select => {
                    const p = pending orelse break :blk 5;
                    const entry = app.swarm.permission_requests.getPtr(p.call_id) orelse break :blk 5;

                    if (entry.payload == .ask) {
                        const opts: u16 = @intCast(@min(entry.payload.ask.options.len, r.tools.ask.MAX_OPTIONS));
                        break :blk @min(@as(u16, 4) + opts, area.height / 2);
                    }
                    break :blk 6; // .call, .diff, .plan all have header + options
                },
            }
        };

        const main_status_height: u16 = 3; //renderMainProgressRequiredLines(app);

        // Combined chat + main-agent-status region; status floats right after chat.
        const _combined_area, const _input_area, const _status_area =
            r.tui.Col(area, .{
                r.tui.Constr.fill, // chat + status
                r.tui.Constr{ .fixed = input_height }, // input
                r.tui.Constr{ .fixed = 1 }, // statusbar (pinned bottom)
            });

        const lua_error_height = luaErrorHeight(app, frame_alloc, _combined_area.width, _combined_area.height);
        const _lua_error_area, const _chat_status_area =
            r.tui.Col(_combined_area, .{
                r.tui.Constr{ .fixed = lua_error_height },
                r.tui.Constr.fill,
            });
        renderLuaError(app, frame_alloc, _lua_error_area, buf);

        var used_chat_lines: usize = 0;
        if (app.chat_entries.items.len == 0 and !app.isMainAgentCompacting()) {
            renderWelcome(app, _chat_status_area, buf);
        } else {
            const chat_cap: u16 = _chat_status_area.height -| main_status_height;
            const _chat_area: r.tui.Rect = .{
                .x = _chat_status_area.x,
                .y = _chat_status_area.y,
                .width = _chat_status_area.width,
                .height = chat_cap,
            };
            used_chat_lines = renderChatArea(app, _chat_area, buf);
        }

        var status_y: u16 = _chat_status_area.y +| @as(u16, @intCast(used_chat_lines));
        var status_remaining: u16 = (_chat_status_area.y +| _chat_status_area.height) -| status_y;

        const main_agent_id = app.main_agent_id;

        if (main_agent_id) |ma_id| {
            if (!app.flags.show_thinking and status_remaining > 0) {
                if (app.swarm.getSlot(ma_id)) |slot_ref| {
                    const agent_ref = &slot_ref.agent;
                    if (agent_ref.flags.is_thinking) {
                        const spinner = text_utils.spinnerBar(app.frame_count);
                        var sbuf: [128]u8 = undefined;
                        const content = std.fmt.bufPrint(&sbuf, "thinking {s}", .{spinner}) catch "thinking ..";
                        buf.setString(_chat_status_area.x + 10, status_y -| 1, content, .{ .fg = app.theme.muted });
                        status_y +|= 1;
                        status_remaining -|= 1;
                    }
                }
            }
        }

        renderMainProgress(app, main_agent_id, .{
            .x = _chat_status_area.x,
            .y = status_y,
            .width = _chat_status_area.width,
            .height = @min(main_status_height, status_remaining),
        }, buf);

        // Input/Permission
        switch (app.input_mode) {
            .perm_select => renderPermissionWidget(app, _input_area, buf),
            .perm_message => renderPermMessage(app, _input_area, buf),
            .text => renderInput(app, frame_alloc, _input_area, buf) catch {},
            .passphrase => {
                // Render the normal input bar dimmed underneath, then a centered modal on top.
                renderInput(app, frame_alloc, _input_area, buf) catch {};
                renderPassphraseModal(app, area, buf);
            },
        }

        // Notifications
        renderNotifications(app, frame_alloc, area, buf);

        // Statusbar
        renderStatusBar(app, _status_area, buf);
    }

    /// Set the swarm-side state for a permission. Tools poll this state to
    /// decide whether to proceed. Clears `pending_perm` if it matches.
    pub fn resolvePermission(self: *App, call_id: []const u8, state: prv.Swarm.PermissionState) void {
        self.swarm.resolvePermission(call_id, state);
        if (self.pending_perm) |pp| {
            if (std.mem.eql(u8, pp.call_id, call_id)) self.pending_perm = null;
        }
    }

    /// Deny a pending permission, remove its preview chat entry. `msg` ⇒
    /// `.message = msg` in the swarm so callers that care can read it; bare
    /// deny ⇒ `.denied`.
    pub fn denyAndPopPermission(self: *App, call_id: []const u8, msg: ?[]const u8) void {
        const new_state: prv.Swarm.PermissionState = if (msg) |m| .{ .message = m } else .denied;
        self.swarm.resolvePermission(call_id, new_state);
        if (self.pending_perm) |pp| {
            if (std.mem.eql(u8, pp.call_id, call_id)) {
                if (pp.chat_entry_idx) |idx| {
                    if (idx < self.chat_entries.items.len) {
                        _ = self.chat_entries.orderedRemove(idx);
                    }
                }
                self.pending_perm = null;
            }
        }
    }

    pub fn firstPendingPermission(self: *App) ?PendingPerm {
        if (self.pending_perm) |pen| {
            return pen;
        }

        const next = self.swarm.nextPendingPermission() orelse return null;
        const needs_approval = !self.flags.skip_permissions or self.swarm.exec.ssh_active;

        // create chat entry
        switch (next.req.payload) {
            .plan => |plan| {
                _ = self.appendPlanEntry(plan, self.sessionAlloc());
                const id = self.chat_entries.items.len -| 1;

                self.pending_perm = .{
                    .call_id = next.call_id,
                    .chat_entry_idx = id,
                };
            },
            .diff => |diff| {
                var lines: std.ArrayList(r.tui.DiffLine) = .empty;
                emitDiffLines(&lines, diff, self.sessionAlloc());
                const path_dup = self.sessionAlloc().dupe(u8, diff.path) catch return null;
                self.chat_entries.append(self.sessionAlloc(), .{ .diff = .{
                    .path = path_dup,
                    .diff_lines = lines.items,
                } }) catch return null;

                const id = self.chat_entries.items.len -| 1;

                if (needs_approval) {
                    self.pending_perm = .{
                        .call_id = next.call_id,
                        .chat_entry_idx = id,
                    };
                } else {
                    self.swarm.resolvePermission(next.call_id, .approved);
                }
            },
            .ask => {
                self.pending_perm = .{
                    .call_id = next.call_id,
                    .chat_entry_idx = null,
                };
            },
            .call => {
                if (needs_approval) {
                    self.pending_perm = .{
                        .call_id = next.call_id,
                        .chat_entry_idx = null,
                    };
                } else {
                    self.swarm.resolvePermission(next.call_id, .approved);
                }
            },
        }

        return self.pending_perm;
    }

    /// Build the chat entry for a permission payload and append it. Returns
    /// the chat-entry index, or null if the payload produces no entry.
    fn emitPermissionEntry(
        self: *App,
        payload: anytype,
        alloc: std.mem.Allocator,
    ) ?usize {
        switch (payload) {
            .diff => |d| {
                var lines: std.ArrayList(r.tui.DiffLine) = .empty;
                emitDiffLines(&lines, d, alloc);
                if (lines.items.len == 0) return null;
                const path_dup = alloc.dupe(u8, d.path) catch return null;
                self.chat_entries.append(alloc, .{ .diff = .{
                    .path = path_dup,
                    .diff_lines = lines.items,
                } }) catch return null;
                return self.chat_entries.items.len - 1;
            },
            .plan => |pa| {
                self.current_plan_file = alloc.dupe(u8, pa.path) catch pa.path;
                return self.appendPlanEntry(pa, alloc);
            },
            .call, .ask => return null,
        }
    }

    fn appendPlanEntry(self: *App, payload: prv.Swarm.PlanApprovalPayload, alloc: std.mem.Allocator) ?usize {
        var vlines: std.ArrayList(r.tui.Line) = .empty;

        var hl = r.tui.MarkdownStreamingHighlighter.init(alloc);
        hl.feed(payload.plan_text) catch return null;
        hl.finish();

        var src: r.tui.Line = .{};
        drain: while (true) {
            switch (hl.consume()) {
                .done, .need_bytes => break :drain,
                .span => |s| {
                    if (std.mem.eql(u8, s.content, "\n")) {
                        vlines.append(alloc, src) catch return null;
                        src = .{};
                        continue;
                    }
                    src.pushSpan(alloc, s) catch return null;
                },
            }
        }
        if (src.spans.items.len > 0) {
            vlines.append(alloc, src) catch return null;
        }

        self.chat_entries.append(alloc, .{ .plan = .{ .lines = vlines.items } }) catch return null;
        return self.chat_entries.items.len - 1;
    }

    pub fn appendBytes(self: *App, bytes: []const u8) void {
        if (self.input_cursor > self.input_buffer.items.len) {
            self.input_cursor = @intCast(self.input_buffer.items.len);
        }
        const idx = self.input_cursor;
        self.input_buffer.replaceRange(self.sessionAlloc(), idx, 0, bytes) catch return;
        self.input_cursor += @intCast(bytes.len);
    }

    pub fn deleteChar(self: *App) void {
        if (self.input_cursor > self.input_buffer.items.len) {
            self.input_cursor = @intCast(self.input_buffer.items.len);
        }
        if (self.input_cursor == 0) return;
        var start: usize = self.input_cursor;
        while (start > 0) {
            start -= 1;
            if ((self.input_buffer.items[start] & 0xC0) != 0x80) break;
        }
        const len = self.input_cursor - start;
        self.input_buffer.replaceRange(self.sessionAlloc(), start, len, &.{}) catch return;
        self.input_cursor = @intCast(start);
    }

    pub fn inputSlice(self: *const App) []const u8 {
        return self.input_buffer.items;
    }

    pub fn pushHistory(self: *App, allocator: std.mem.Allocator, text: []const u8) void {
        if (text.len == 0) return;
        const dupe = allocator.dupe(u8, text) catch return;
        self.history.append(allocator, .{
            .text = dupe,
            .timestamp = std.Io.Clock.Timestamp.now(self.swarm.pool.io, .real).raw.nanoseconds,
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
    }

    pub const PromptEntry = struct {
        text: []const u8,
        timestamp: i128,
    };

    pub fn loadHistory(self: *App, allocator: std.mem.Allocator, config_dir_path: []const u8) void {
        const SaveFormat = struct { prompts: []const PromptEntry };

        const io = self.swarm.pool.io;
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

        for (parsed.value.prompts) |entry| {
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

        const io = self.swarm.pool.io;
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

    /// Push a chat message entry.
    pub fn pushChatMessage(self: *App, role: prv.adapter.Role, text: []const u8) void {
        if (text.len < 2) return;
        const alloc = self.sessionAlloc();
        const parts = alloc.alloc(ChatEntry.MessagePart, 1) catch return;
        parts[0] = .{ .text = alloc.dupe(u8, text) catch return };
        self.chat_entries.append(alloc, .{ .message = .{
            .role = role,
            .parts = parts,
        } }) catch return;
    }

    pub fn popQueuedMessage(self: *App, agent_id: prv.Swarm.AgentId, alloc: std.mem.Allocator) ?[]const prv.adapter.ContentPart {
        const queued = self.queued.popFor(agent_id) orelse return null;

        if (queued.entry) |entry| self.chat_entries.append(self.sessionAlloc(), entry) catch {};

        const parts = alloc.alloc(prv.adapter.ContentPart, queued.parts.len) catch return null;
        for (queued.parts, 0..) |*part, i| {
            parts[i] = part.clone(alloc) catch return null;
        }

        self.swarm.recordBroadcast(agent_id, .user, parts);
        return parts;
    }

    pub fn popQueuedMessageOpaque(ptr: *anyopaque, agent_id: prv.Swarm.AgentId, alloc: std.mem.Allocator) ?[]const prv.adapter.ContentPart {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.popQueuedMessage(agent_id, alloc);
    }

    /// Convert an agent message's content parts into renderable ChatEntry
    /// message parts (trim + dupe text/thinking, drop everything else).
    /// Returns null if no renderable parts remain.
    fn renderableParts(alloc: std.mem.Allocator, parts: []const prv.adapter.ContentPart) ?[]ChatEntry.MessagePart {
        var out: std.ArrayList(ChatEntry.MessagePart) = .empty;
        for (parts) |part| {
            switch (part) {
                .text => |txt| {
                    const trimmed = std.mem.trim(u8, txt, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    const dup = alloc.dupe(u8, trimmed) catch continue;
                    out.append(alloc, .{ .text = dup }) catch continue;
                },
                .thinking => |th| {
                    const trimmed = std.mem.trim(u8, th.text, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    const dup = alloc.dupe(u8, trimmed) catch continue;
                    out.append(alloc, .{ .thinking = dup }) catch continue;
                },
                else => {},
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(alloc) catch null;
    }

    /// Mirror the main agent's in-progress streaming message into a preview
    /// chat entry. Called each frame so text accumulates visibly. The final
    /// broadcast entry (pushed by the agent on stream finish) supersedes this
    /// preview in drainBroadcast.
    pub fn syncStreamingPreview(self: *App) void {
        const main_id = self.main_agent_id orelse return;
        const slot = &self.swarm.slots[main_id.index];
        if (slot.state.load(.acquire) != .active) return;
        const agent = &slot.agent;
        const msg_idx = agent.streamingMessageIndex() orelse {
            self.streaming_preview_idx = null;
            return;
        };
        const msg = agent.chat.messages.items[msg_idx];

        const alloc = self.sessionAlloc();
        const slice = renderableParts(alloc, msg.parts) orelse {
            self.streaming_preview_idx = null;
            return;
        };

        if (self.streaming_preview_idx) |idx| {
            if (idx < self.chat_entries.items.len) {
                const entry = &self.chat_entries.items[idx];
                freeMessageParts(alloc, entry.message.parts);
                entry.message.parts = slice;
                return;
            }
            self.streaming_preview_idx = null;
        }
        self.chat_entries.append(alloc, .{ .message = .{
            .role = msg.role,
            .parts = slice,
        } }) catch return;
        self.streaming_preview_idx = self.chat_entries.items.len - 1;
    }

    pub fn dropStreamingPreview(self: *App) void {
        const idx = self.streaming_preview_idx orelse return;
        if (idx < self.chat_entries.items.len) {
            const alloc = self.sessionAlloc();
            const entry = &self.chat_entries.items[idx];
            freeMessageParts(alloc, entry.message.parts);
            _ = self.chat_entries.pop();
        }
        self.streaming_preview_idx = null;
    }

    /// Cleanup after cancel: if the last agent message has any tool_call,
    /// drop it (results would only come chronologically after).
    pub fn cleanupCancelledTurn(self: *App) void {
        const id = self.main_agent_id orelse return;
        const agent = self.swarm.getAgent(id) orelse return;

        const msgs = &agent.chat.messages;
        if (msgs.items.len == 0) return;
        const last = msgs.items[msgs.items.len - 1];
        for (last.parts) |part| switch (part) {
            .tool_call => {
                msgs.items.len -= 1;
                return;
            },
            else => {},
        };
    }

    /// Drain new broadcast entries from the swarm and push agent text messages.
    pub fn drainBroadcast(self: *App) void {
        const main_id = self.main_agent_id orelse return;
        const entries = self.swarm.broadcast.items;
        const base_id = self.swarm.broadcastBaseId();
        const alloc = self.sessionAlloc();

        if (self.broadcast_cursor < base_id) self.broadcast_cursor = base_id;

        while (self.broadcast_cursor < base_id + entries.len) {
            const local_idx: usize = @intCast(self.broadcast_cursor - base_id);
            const entry = entries[local_idx];
            self.broadcast_cursor += 1;

            // Only main agent
            if (entry.agent_id.index != main_id.index or entry.agent_id.generation != main_id.generation) continue;

            for (entry.parts) |part| {
                switch (part) {
                    .tool_call => |call| {
                        self.chat_entries.append(alloc, .{ .tool_call = .{
                            .call_id = call.id,
                            .tool_name = call.name,
                        } }) catch continue;
                    },
                    else => {},
                }
            }

            if (entry.role == .user) continue;
            if (entry.role == .system) continue;

            const final_parts = renderableParts(alloc, entry.parts) orelse continue;

            // Replace the streaming preview with the canonical final message
            if (self.streaming_preview_idx) |idx| {
                if (idx < self.chat_entries.items.len) {
                    const chat_entry = &self.chat_entries.items[idx];
                    freeMessageParts(alloc, chat_entry.message.parts);
                    chat_entry.message.parts = final_parts;
                    self.streaming_preview_idx = null;
                    continue;
                }
                self.streaming_preview_idx = null;
            }

            self.chat_entries.append(alloc, .{ .message = .{
                .role = entry.role,
                .parts = final_parts,
            } }) catch continue;
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

fn emitDiffLines(out: *std.ArrayList(r.tui.DiffLine), snap: prv.Swarm.ToolDiff, alloc: std.mem.Allocator) void {
    if (snap.before) |before| {
        const old_lines = splitLinesAlloc(before, alloc) orelse return;
        const new_lines = splitLinesAlloc(snap.after, alloc) orelse return;
        emitMyersDiff(out, old_lines, new_lines, 1, alloc);
    } else {
        var new_iter = std.mem.splitScalar(u8, snap.after, '\n');
        var ln: u32 = 1;
        while (new_iter.next()) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .line_number = ln, .content = line });
            ln += 1;
        }
    }
}

/// Myers' O(ND) shortest edit script with context collapsing. `base_line` is
/// the 1-based line number in the original where `old_lines` begins.
fn emitMyersDiff(
    out: *std.ArrayList(r.tui.DiffLine),
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    base_line: u32,
    alloc: std.mem.Allocator,
) void {
    const ops = myersDiff(old_lines, new_lines, alloc) orelse {
        for (old_lines, 0..) |line, i| {
            pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = base_line + @as(u32, @intCast(i)), .content = line });
        }
        for (new_lines) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .content = line });
        }
        return;
    };

    if (ops.len == 0) return;

    const ctx_radius = 3;

    const visible = alloc.alloc(bool, ops.len) catch {
        emitAllOps(out, ops, base_line, alloc);
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
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = base_line + old_ln, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = base_line + old_ln, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

fn emitAllOps(out: *std.ArrayList(r.tui.DiffLine), ops: []const DiffOp, base_line: u32, alloc: std.mem.Allocator) void {
    var old_ln: u32 = 0;
    for (ops) |op| {
        switch (op) {
            .keep => |content| {
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = base_line + old_ln, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = base_line + old_ln, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

pub const ChatEntry = union(enum) {
    message: MessageEntry,
    diff: DiffEntry,
    plan: PlanEntry,
    tool_call: ToolCallEntry,

    pub const PlanEntry = struct {
        lines: []const r.tui.Line,
    };

    pub const ToolCallEntry = struct {
        call_id: []const u8,
        tool_name: []const u8,
    };

    pub const MessagePart = union(enum) {
        thinking: []const u8,
        text: []const u8,
    };

    pub const MessageEntry = struct {
        role: prv.adapter.Role,
        parts: []const MessagePart,
    };

    pub const DiffEntry = struct {
        path: []const u8,
        diff_lines: []const r.tui.DiffLine,
    };

    pub fn userMessageSimple(alloc: std.mem.Allocator, msg: []const u8) !ChatEntry {
        var parts = try alloc.alloc(MessagePart, 1);
        parts[0] = .{ .text = msg };
        return .{ .message = .{ .parts = parts, .role = .user } };
    }

    pub fn clone(self: *const ChatEntry, alloc: std.mem.Allocator) ChatEntry {
        _ = alloc; // autofix
        switch (self.*) {
            .message => |msg| {
                _ = msg; // autofix
            },
        }
    }
};

/// Free allocated strings inside a MessagePart slice.
/// Does NOT free the slice itself (caller's responsibility).
fn freeMessageParts(alloc: std.mem.Allocator, parts: []const ChatEntry.MessagePart) void {
    for (parts) |part| {
        switch (part) {
            .text => |txt| alloc.free(txt),
            .thinking => |th| alloc.free(th),
        }
    }
}

fn splitLinesAlloc(text: []const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
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

const DiffOp = union(enum) {
    keep: []const u8,
    delete: []const u8,
    insert: []const u8,
};

/// Myers O(ND) diff. Returns null on allocation failure.
fn myersDiff(old: []const []const u8, new: []const []const u8, alloc: std.mem.Allocator) ?[]const DiffOp {
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

fn commandPaletteActive(app: *const App) bool {
    const input = app.inputSlice();
    return input.len > 0 and input[0] == ':';
}

fn commandCompletionPrefix(input: []const u8, cursor: u32) []const u8 {
    if (input.len == 0) return "";
    const end = @min(@as(usize, cursor), input.len);
    const command_end = std.mem.indexOfScalar(u8, input[0..end], ' ') orelse end;
    return input[0..command_end];
}

fn containsCommandCompletion(items: []?[]const u8, needle: []const u8) bool {
    for (items) |item| {
        const value = item orelse continue;
        if (std.mem.eql(u8, value, needle)) return true;
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

fn appendBuiltinCommandCompletions(prefix: []const u8, out: []?[]const u8, count: *usize) void {
    for (builtin_command_completions) |completion| {
        if (count.* >= out.len) return;
        if (!startsWithIgnoreCase(completion, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], completion)) continue;

        out[count.*] = completion;
        count.* += 1;
    }
}

fn appendLuaCommandCompletions(app: *App, prefix: []const u8, out: []?[]const u8, count: *usize) void {
    if (count.* >= out.len) return;
    if (!app.lua_vm.vm_mu.tryLock()) return;
    defer app.lua_vm.vm_mu.unlock(app.swarm.pool.io);
    app.lua_vm.appendCommandCompletions(prefix, out, count);
}

fn commandCompletions(app: *App, input: []const u8, cursor: u32) [COMMAND_COMPLETION_ROWS][]const u8 {
    var matches: [COMMAND_COMPLETION_ROWS]?[]const u8 = [_]?[]const u8{null} ** COMMAND_COMPLETION_ROWS;
    var count: usize = 0;

    const prefix = commandCompletionPrefix(input, cursor);
    appendBuiltinCommandCompletions(prefix, &matches, &count);
    appendLuaCommandCompletions(app, prefix, &matches, &count);

    if (count == 0 and prefix.len > 1) {
        appendBuiltinCommandCompletions(":", &matches, &count);
        appendLuaCommandCompletions(app, ":", &matches, &count);
    }

    var rows: [COMMAND_COMPLETION_ROWS][]const u8 = [_][]const u8{""} ** COMMAND_COMPLETION_ROWS;
    for (&rows, 0..) |*row, i| row.* = matches[i] orelse "";
    return rows;
}

// TODO: move to input popup instead
fn renderCommandPalette(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) !void {
    _ = arena;

    const input = app.inputSlice();
    const rows = commandCompletions(app, input, app.input_cursor);
    const border_color = app.context_factory.mode_colors.get(app.mode);
    _ = border_color; // autofix

    const palette_w: u16 = @min(@as(u16, 72), area.width -| 4);
    const palette_h: u16 = @min(@as(u16, COMMAND_COMPLETION_ROWS + 4), area.height -| 2);
    if (palette_w == 0 or palette_h == 0) return;

    const palette_area = area.center(palette_w, palette_h);
    const palette = r.tui.widgets.CommandPallet{
        .input_value = input,
        .preview = rows[0..],
        .border = .single,
        .style = .{ .fg = .white, .bg = app.theme.overlay_dark },
        .padding = .{ .left = 2, .right = 2 },
    };
    palette.render(palette_area, buf);
}

fn renderInput(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) !void {
    const border_color = if (app.running)
        app.theme.muted
    else
        app.context_factory.mode_colors.get(app.mode);

    var para = r.tui.Paragraph{
        .border = .none,
        .style = .{ .fg = border_color },
        .padding = .{ .bottom = 1, .left = 2, .right = 2, .top = 1 },
    };
    const inner = para.inner(area);

    const text = app.inputSlice();
    const cursor: usize = app.input_cursor;
    const cursor_style: r.tui.Style = .{ .fg = .black, .bg = border_color };

    var cursor_visual_row: usize = 0;
    var accumulated_rows: usize = 0;
    var it = std.mem.splitAny(u8, text, "\n");
    var consumed: usize = 0;
    while (it.next()) |raw_line| {
        const line_start = consumed;
        const line_end = line_start + raw_line.len;
        var line = r.tui.Line{};

        if (cursor >= line_start and cursor <= line_end) {
            const off = cursor - line_start;
            const before = raw_line[0..off];
            try line.pushText(arena, before, .{});
            if (off < raw_line.len) {
                const len = std.unicode.utf8ByteSequenceLength(raw_line[off]) catch 1;
                const end = @min(off + len, raw_line.len);
                try line.pushText(arena, raw_line[off..end], cursor_style);
                try line.pushText(arena, raw_line[end..], .{});
            } else {
                try line.pushText(arena, " ", cursor_style);
            }
        } else {
            try line.pushText(arena, raw_line, .{});
        }

        // Wrap to temp buffer to detect cursor position
        var wrapped: std.ArrayList(r.tui.Line) = .empty;
        defer wrapped.deinit(arena);
        try r.tui.wrapLine(arena, &line, inner.width, &wrapped);

        // Find which wrapped row has cursor
        if (cursor >= line_start and cursor <= line_end) {
            for (wrapped.items, 0..) |*row, i| {
                for (row.spans.items) |span| {
                    if (span.style.fg.eql(cursor_style.fg)) {
                        cursor_visual_row = accumulated_rows + i;
                        break;
                    }
                }
            }
        }

        // Append wrapped rows to para.lines
        try para.lines.appendSlice(arena, wrapped.items);
        accumulated_rows += wrapped.items.len;
        consumed = line_end + 1;
    }

    // Auto-scroll to keep cursor visible
    const visible_height = inner.height;
    if (cursor_visual_row >= visible_height) {
        app.input_scroll_offset = @intCast(cursor_visual_row - visible_height + 1);
    } else {
        app.input_scroll_offset = 0;
    }
    para.scroll_offset = app.input_scroll_offset;

    const mode_name = app.context_factory.mode_names.get(app.mode);
    const title = try std.fmt.allocPrint(arena, "┤{s}├", .{mode_name});
    const block = r.tui.Block{
        .title = title,
        .title_style = .{ .fg = border_color },
        .style = .{ .fg = border_color, .bg = app.theme.overlay_dark },
        .borders = .{ .top = true, .bottom = false, .left = false, .right = false },
    };

    block.render(area, buf);
    para.render(arena, area, area, buf);
    buf.set(area.x + 1, area.y + 1, .{ .char = '❯' });
    if (app.screenshot_buf != null) {
        buf.set(area.x + 1, area.y, .{});
        buf.setString(area.x, area.y, r.tui.icon.eye, .{ .fg = .green });
    }
}

fn renderPermMessage(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const pm = &app.input_mode.perm_message;
    const input_widget: r.tui.Input = .{
        .text = pm.buf[0..pm.len],
        .border_style = .{ .fg = Theme.default.warn },
        .has_screenshot = app.screenshot_buf != null,
    };
    input_widget.render(area, buf);
}

/// ╭──────── PASSWORD ───────────╮
/// │         ********            │
/// ╰─────────────────────────────╯
fn renderPassphraseModal(app: *App, full_area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const pp = &app.input_mode.passphrase;
    const modal = full_area.center(32, 3);

    const block: r.tui.Block = .{
        .title = " Password or Passphrase ",
        .title_style = .{ .fg = Theme.default.warn, .modifier = .{ .bold = true } },
        .style = .{ .fg = Theme.default.warn },
        .borders = .all,
    };
    const inner = block.innerArea(modal);
    block.render(modal, buf);

    // Mask the entered characters as '*'.
    var x: u16 = inner.x + 2;
    const y: u16 = inner.y;
    const max_chars = inner.width -| 3;
    const shown: usize = @min(pp.len, max_chars);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        buf.set(x, y, .{ .char = '*' });
        x += 1;
    }
    buf.set(x, y, .{ .char = '_', .style = .{ .fg = Theme.default.warn } });
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

                const total_h = para.totalHeight(arena, notif_w);
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
    for (area.x..area.x +| area.width) |x| {
        buf.set(@intCast(x), area.y, .{ .char = ' ', .style = .{ .fg = .white, .bg = app.theme.overlay_dark } });
    }

    if (app.lua_status_bar_enabled) {
        if (app.lua_vm.vm_mu.tryLock()) {
            defer app.lua_vm.vm_mu.unlock(app.swarm.pool.io);
            if (app.lua_vm.renderStatusBar(&app.lua_status_bar_cache)) |status| {
                app.lua_status_bar_cache_len = status.len;
            }
        }

        if (app.lua_status_bar_cache_len > 0) {
            renderCenteredStatusText(app, area, buf, app.lua_status_bar_cache[0..app.lua_status_bar_cache_len]);
            return;
        }
    }

    const ctx_pct: u8 = @intFromFloat(@min(app.contextPercent(), 100));

    var status_buf: [256]u8 = undefined;
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var cache_buf: [16]u8 = undefined;
    var ctx_buf: [8]u8 = undefined;

    const usage = app.swarm.usage();
    const in_str = formatTokenCount(&in_buf, usage.input_tokens);
    const out_str = formatTokenCount(&out_buf, usage.output_tokens);
    const cache_str = formatTokenCount(&cache_buf, usage.cached_tokens);
    const ctx_str = std.fmt.bufPrint(&ctx_buf, "{d}%", .{ctx_pct}) catch "0%";
    const skip_str = if (app.flags.skip_permissions) "| AUTO APPROVAL" else "";

    const status = std.fmt.bufPrint(
        &status_buf,
        "IN:{s} OUT:{s} CACHE:{s} | CTX:{s} {s}",
        .{ in_str, out_str, cache_str, ctx_str, skip_str },
    ) catch " ?? ";

    renderCenteredStatusText(app, area, buf, status);
}

fn statusTextWidth(text: []const u8) u16 {
    var cols: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch break;
        i += len;
        if (cp < 0x20 or cp == 0x7F) continue;
        cols +|= 1;
    }
    return cols;
}

fn renderCenteredStatusText(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer, status: []const u8) void {
    const width = @min(statusTextWidth(status), area.width);
    const offset = @divTrunc(area.width -| width, 2);
    buf.setStringMax(area.x + offset, area.y, status, .{
        .fg = app.context_factory.mode_colors.get(app.mode),
    }, area.width -| offset);
}

fn luaErrorParagraph(arena: std.mem.Allocator, msg: []const u8) r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .style = .{ .fg = .black, .bg = .red },
    };
    appendPlainText(&p, arena, msg, .{ .fg = .black, .bg = .red });
    return p;
}

fn luaErrorHeight(app: *App, arena: std.mem.Allocator, width: u16, max_height: u16) u16 {
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0 or width == 0 or max_height == 0) return 0;

    var p = luaErrorParagraph(arena, msg);
    return @min(p.totalHeight(arena, width), max_height);
}

fn renderLuaError(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (area.width == 0 or area.height == 0) return;
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0) return;

    var p = luaErrorParagraph(arena, msg);
    p.renderSimple(arena, area, buf);
}

/// Build one r.tui.Paragraph per ChatEntry. Allocations live in `arena`; do not
/// deinit the result. All paragraphs use `reverse = true` so the chat-area
/// caller can stack them bottom-up.
fn buildEntryParagraph(
    arena: std.mem.Allocator,
    agent: ?*prv.agent.Agent,
    app: *App,
    entry: ChatEntry,
    show_thinking: bool,
    inner_w: u16,
) r.tui.Paragraph {
    return switch (entry) {
        .message => |m| buildMessageParagraph(arena, m, show_thinking),
        .plan => |p| buildPlanParagraph(arena, p),
        .diff => |d| buildDiffParagraph(arena, d),
        .tool_call => |c| if (agent) |ag|
            buildToolCallParagraph(arena, ag, app, c, inner_w)
        else
            r.tui.Paragraph.empty,
    };
}

fn buildCompactionIndicatorParagraph(arena: std.mem.Allocator, app: *App) r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .border = .none,
        .sides = .left_only,
        .padding = .{ .left = 1, .right = 1 },
        .dynamic_border = true,
        .reverse = true,
    };

    var line = r.tui.Line{};
    line.pushSpan(arena, .{ .content = text_utils.spinnerDots(app.frame_count), .style = .{ .fg = .white } }) catch {};
    line.pushText(arena, " compacting context", .{ .fg = Theme.default.muted, .modifier = .{ .bold = true } }) catch {};
    p.lines.append(arena, line) catch {};

    return p;
}

fn buildMessageParagraph(
    arena: std.mem.Allocator,
    m: ChatEntry.MessageEntry,
    show_thinking: bool,
) r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .border = .none,
        .sides = .left_only,
        .padding = .{ .left = 1, .right = 1 },
        .dynamic_border = true,
        .reverse = true,
    };

    // Role prefix as the first content line.
    const role_text: []const u8 = if (m.role == .user) "❯ you:" else "❯ blitz:";
    const role_style: r.tui.Style = if (m.role == .user)
        .{ .fg = Theme.default.info, .modifier = .{ .bold = true } }
    else
        .{ .fg = Theme.default.ok, .modifier = .{ .bold = true } };
    appendPlainLine(&p, arena, role_text, role_style);

    const muted: r.tui.Style = .{ .fg = Theme.default.muted };

    for (m.parts) |part| switch (part) {
        .text => |txt| {
            if (m.role == .user) {
                appendPlainText(&p, arena, txt, .{});
            } else {
                appendMarkdownText(&p, arena, txt);
            }
        },
        .thinking => |txt| {
            if (!show_thinking) continue;
            appendThinkingText(&p, arena, txt, muted);
        },
    };

    return p;
}

/// Scan chat history for a tool_result with the given call_id. Source of
/// truth for "did this tool finish": `tool_call_done` is cleared right
/// after commit, but the result lives on in the chat as a tool_result part.
fn findToolResult(agent: *prv.agent.Agent, call_id: []const u8) ?prv.adapter.ToolResult {
    var i = agent.chat.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = agent.chat.messages.items[i];
        for (msg.parts) |part| switch (part) {
            .tool_result => |res| if (std.mem.eql(u8, res.call_id, call_id)) return res,
            else => {},
        };
    }
    return null;
}

fn buildToolCallParagraph(
    arena: std.mem.Allocator,
    agent: *prv.agent.Agent,
    app: *App,
    call: ChatEntry.ToolCallEntry,
    inner_w: u16,
) r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .style = .{ .bg = .black },
        .dynamic_border = false,
        .border = .none,
        .sides = .left_only,
        .padding = .all(1),
    };

    const status = agent.tool_display_status.getPtr(call.call_id);
    var line = r.tui.Line{};

    const result_opt: ?prv.adapter.ToolResult = findToolResult(agent, call.call_id) orelse agent.tool_call_done.get(call.call_id);
    if (result_opt) |result| {
        if (result.is_error) {
            line.pushSpan(arena, .{ .content = r.tui.icon.fail, .style = .{ .fg = .red, .modifier = .{ .bold = true } } }) catch {};
        } else {
            line.pushSpan(arena, .{ .content = r.tui.icon.ok, .style = .{ .fg = .green, .modifier = .{ .bold = true } } }) catch {};
        }
    } else {
        line.pushSpan(arena, .{ .content = text_utils.spinnerDots(app.frame_count), .style = .{ .fg = .white } }) catch {};
    }

    const status_text: []const u8 = if (status) |s| s.status_text.items else call.tool_name;
    const txt = std.fmt.allocPrint(arena, " {s}", .{status_text}) catch status_text;
    line.pushText(arena, txt, .{ .modifier = .{ .bold = true }, .fg = .cyan }) catch {};
    p.lines.append(arena, line) catch {};

    if (status) |s| {
        // Connector icon is 2 chars, plus 1 padding each side = 4 chars overhead.
        const log_max = inner_w - 4;

        if (s.child_id) |child_id| blk: {
            const child_ag = app.swarm.getAgent(child_id) orelse break :blk;
            var it = child_ag.tool_display_status.iterator();
            var i: usize = 0;
            while (it.next()) |en| : (i += 1) {
                var l = r.tui.Line{};

                const display_log: []const u8 = if (log_max > 0 and en.value_ptr.status_text.items.len > log_max) cl: {
                    const truncated = en.value_ptr.status_text.items[0 .. log_max - 4];
                    const combined = std.fmt.allocPrint(arena, "{s}...", .{truncated}) catch en.value_ptr.status_text.items;
                    break :cl combined;
                } else en.value_ptr.status_text.items;

                if (child_ag.tool_display_status.entries.len == i + 1)
                    l.pushSpan(arena, .{ .content = r.tui.icon.box_bl ++ r.tui.icon.box_h }) catch {}
                else
                    l.pushSpan(arena, .{ .content = r.tui.icon.box_t_right ++ r.tui.icon.box_h }) catch {};

                l.pushText(arena, display_log, .{ .fg = .white }) catch {};
                p.lines.append(arena, l) catch {};
            }
        }

        for (s.log.items, 0..) |log_slice, i| {
            var l = r.tui.Line{};
            if (s.log.items.len == i + 1)
                l.pushSpan(arena, .{ .content = r.tui.icon.box_bl ++ r.tui.icon.box_h }) catch {}
            else
                l.pushSpan(arena, .{ .content = r.tui.icon.box_t_right ++ r.tui.icon.box_h }) catch {};

            const display_log: []const u8 = if (log_max > 0 and log_slice.len > log_max) blk: {
                const truncated = log_slice[0 .. log_max - 4];
                const combined = std.fmt.allocPrint(arena, "{s}...", .{truncated}) catch log_slice;
                break :blk combined;
            } else log_slice;

            l.pushText(arena, display_log, .{ .fg = .white }) catch {};
            p.lines.append(arena, l) catch {};
        }
    }

    return p;
}

fn buildPlanParagraph(arena: std.mem.Allocator, plan: ChatEntry.PlanEntry) r.tui.Paragraph {
    var p: r.tui.Paragraph = .{
        .border = .double,
        .padding = .all(1),
        .style = .{ .bg = Theme.default.diff_surface },
        .dynamic_border = false,
        .reverse = true,
    };
    for (plan.lines) |ln| {
        p.lines.append(arena, ln) catch return p;
    }
    return p;
}

fn buildDiffParagraph(arena: std.mem.Allocator, d: ChatEntry.DiffEntry) r.tui.Paragraph {
    const theme = Theme.default;
    var p: r.tui.Paragraph = .{
        .border = .single,
        .sides = .left_only,
        .dynamic_border = false,
        .reverse = true,
        .style = .{ .bg = theme.diff_surface },
    };

    // File path header
    var header_line = r.tui.Line{};
    header_line.pushSpan(arena, .{ .content = "file: ", .style = .{ .fg = theme.muted, .modifier = .{ .bold = true } } }) catch {};
    header_line.pushSpan(arena, .{ .content = d.path, .style = .{ .fg = theme.info } }) catch {};
    p.lines.append(arena, header_line) catch {};

    for (d.diff_lines) |dl| {
        const dl_info: struct { prefix: []const u8, fg: r.tui.Color, bg: r.tui.Color } = switch (dl.kind) {
            .deletion => .{ .prefix = "- ", .fg = theme.diff_remove, .bg = theme.diff_surface },
            .addition => .{ .prefix = "+ ", .fg = theme.diff_add, .bg = theme.diff_surface },
            .context => .{ .prefix = "  ", .fg = .reset, .bg = theme.diff_surface },
            .header => .{ .prefix = "@ ", .fg = theme.info, .bg = .reset },
        };
        const num_str = if (dl.line_number) |n|
            std.fmt.allocPrint(arena, "{d:>4} ", .{n}) catch "     "
        else
            "     ";

        var src: r.tui.Line = .{ .style = .{ .bg = dl_info.bg } };
        src.pushText(arena, num_str, .{ .fg = theme.muted, .bg = dl_info.bg }) catch {};
        src.pushText(arena, dl_info.prefix, .{ .fg = dl_info.fg, .bg = dl_info.bg }) catch {};
        src.pushText(arena, dl.content, .{ .fg = dl_info.fg, .bg = dl_info.bg }) catch {};
        p.lines.append(arena, src) catch break;
    }
    return p;
}

/// Append one logical Line to the paragraph, single span, given style.
fn appendPlainLine(p: *r.tui.Paragraph, arena: std.mem.Allocator, text: []const u8, style: r.tui.Style) void {
    var ln: r.tui.Line = .{ .style = style };
    ln.pushText(arena, text, style) catch {};
    p.lines.append(arena, ln) catch {};
}

/// Split `txt` on `\n` and append each segment as a logical Line. Paragraph
/// wraps internally, so do not pre-wrap here.
fn appendPlainText(p: *r.tui.Paragraph, arena: std.mem.Allocator, raw: []const u8, style: r.tui.Style) void {
    const txt = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
    if (txt.len == 0) return;
    var pos: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, txt, pos, '\n');
        const end = nl orelse txt.len;
        const seg = txt[pos..end];
        var ln: r.tui.Line = .{ .style = style };
        if (seg.len > 0) ln.pushText(arena, seg, style) catch {};
        p.lines.append(arena, ln) catch return;
        if (nl == null) break;
        pos = end + 1;
    }
}

/// Prepend `thinking: ` to the first line of `raw`, append rest as plain.
/// All content uses `style` (typically muted).
fn appendThinkingText(p: *r.tui.Paragraph, arena: std.mem.Allocator, raw: []const u8, style: r.tui.Style) void {
    const txt = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
    if (txt.len == 0) {
        appendPlainLine(p, arena, "thinking:", style);
        return;
    }
    var pos: usize = 0;
    var first = true;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, txt, pos, '\n');
        const end = nl orelse txt.len;
        const seg = txt[pos..end];
        var ln: r.tui.Line = .{ .style = style };
        if (first) {
            ln.pushText(arena, "thinking: ", style) catch {};
        }
        if (seg.len > 0) ln.pushText(arena, seg, style) catch {};
        p.lines.append(arena, ln) catch return;
        first = false;
        if (nl == null) break;
        pos = end + 1;
    }
}

/// Run `raw` through the markdown highlighter, build logical Lines from spans
/// (split on literal `"\n"` spans), append to `p.lines`. No pre-wrapping —
/// Paragraph wraps at inner_w during render.
fn appendMarkdownText(p: *r.tui.Paragraph, arena: std.mem.Allocator, raw: []const u8) void {
    if (raw.len == 0) return;
    var hl = r.tui.MarkdownStreamingHighlighter.init(arena);
    hl.feed(raw) catch {
        appendPlainText(p, arena, raw, .{});
        return;
    };
    hl.finish();

    var current: r.tui.Line = .{};
    drain: while (true) switch (hl.consume()) {
        .done, .need_bytes => break :drain,
        .span => |s| {
            if (std.mem.eql(u8, s.content, "\n")) {
                p.lines.append(arena, current) catch return;
                current = .{};
                continue;
            }
            current.pushSpan(arena, s) catch return;
        },
    };
    if (current.spans.items.len > 0) {
        p.lines.append(arena, current) catch return;
    }
}

fn renderChatArea(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) usize {
    if (area.width == 0 or area.height == 0) return 0;

    var scratch = std.heap.ArenaAllocator.init(app.sessionAlloc());
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const maybe_agent: ?*prv.agent.Agent = if (app.main_agent_id) |id| app.swarm.getAgent(id) else null;

    const inner_w: u16 = area.width;
    const inner_h: u16 = area.height;
    const show_thinking = app.flags.show_thinking;

    // Failed agent path
    if (app.main_agent_id) |id| {
        const slot = &app.swarm.slots[id.index];
        if (slot.state.load(.acquire) == .failed) {
            var detail: ?[]const u8 = null;
            if (slot.agent.chat.lastMessage()) |last| {
                for (last.parts) |part| switch (part) {
                    .text => |t| {
                        detail = t;
                        break;
                    },
                    else => {},
                };
            }
            text_utils.renderError(buf, slot.agent.last_error, detail, area.x, area.y, area.width, area.height);
            buf.setString(area.x, area.y +| area.height -| 1, "Press Ctrl+R to retry", .{ .fg = Theme.default.warn });
            return inner_h;
        }
    }

    var scroll_offset_usize: usize = if (app.auto_scroll) 0 else app.scroll_offset;
    var scroll_offset: u16 = @intCast(@min(scroll_offset_usize, std.math.maxInt(u16)));
    const target: u32 = @as(u32, inner_h) + @as(u32, scroll_offset);

    const Item = struct { p: r.tui.Paragraph, h: u16 };
    var stack: std.ArrayList(Item) = .empty;
    var total: u32 = 0;

    if (app.isMainAgentCompacting()) {
        var p = buildCompactionIndicatorParagraph(alloc, app);
        const h = p.totalHeight(alloc, inner_w);
        stack.append(alloc, .{ .p = p, .h = h }) catch {};
        total += h;
    }

    var i = app.chat_entries.items.len;
    while (i > 0 and total < target) {
        i -= 1;
        const entry = app.chat_entries.items[i];
        // Tool-call entries need a live agent to render; skip them entirely
        // when there's no main agent yet (e.g. a system message before the
        // first prompt).
        if (entry == .tool_call and maybe_agent == null) continue;
        var p = buildEntryParagraph(alloc, maybe_agent, app, entry, show_thinking, inner_w);
        const h = p.totalHeight(alloc, inner_w);
        stack.append(alloc, .{ .p = p, .h = h }) catch break;
        total += h;
    }

    if (i == 0) {
        const max_scroll: usize = if (total > inner_h) @intCast(total - inner_h) else 0;
        if (scroll_offset_usize > max_scroll) {
            scroll_offset_usize = max_scroll;
            app.scroll_offset = max_scroll;
            if (max_scroll == 0) app.auto_scroll = true;
            scroll_offset = @intCast(@min(scroll_offset_usize, std.math.maxInt(u16)));
        }
    }

    // Render bottom-up. anchor_y is the row JUST BELOW the next paragraph's
    // bottom border. When the stack does not fill the area, anchor below the
    // last visible row instead of the area bottom — keeps short chats top-aligned
    // and lets paragraphs grow downward until they hit the input.
    const fill_bottom: u32 = @min(total, @as(u32, inner_h));
    const anchor_start: i32 = @as(i32, area.y) + @as(i32, @intCast(fill_bottom)) + @as(i32, scroll_offset);
    var anchor_y: i32 = anchor_start;

    for (stack.items) |e| {
        const sub_top: i32 = anchor_y - @as(i32, e.h);
        // sub.y must be u16; if sub_top is negative, clamp the rect's y to 0
        // and reduce its height by the off-area amount. Paragraph.render will
        // clip the rest against `area` via the clip rect.
        const sub_y: u16 = if (sub_top < 0) 0 else @intCast(sub_top);
        const sub_h_signed: i32 = anchor_y - sub_y;
        const sub_h: u16 = if (sub_h_signed <= 0) 0 else if (sub_h_signed > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(sub_h_signed);
        const sub: r.tui.Rect = .{ .x = area.x, .y = sub_y, .width = inner_w, .height = sub_h };
        // Logical area: keeps the original (possibly oversized / negative-top)
        // footprint by preserving width/height. We pass the same sub_y but
        // the paragraph's reverse layout anchors to sub.y + sub.height which
        // equals anchor_y, so the bottom border lands correctly.
        e.p.render(alloc, sub, area, buf);
        anchor_y = sub_top;
        if (anchor_y <= @as(i32, area.y)) break;
    }

    const consumed: u32 = if (total > scroll_offset) total - scroll_offset else 0;
    return @min(@as(usize, inner_h), consumed);
}

fn renderMainProgress(app: *App, id: ?prv.Swarm.AgentId, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (area.width == 0 or area.height == 0) return;
    if (!app.running) return;

    const aid = id orelse return;
    const slot = &app.swarm.slots[aid.index];
    if (slot.state.load(.acquire) != .active) return;

    const alloc = app.sessionAlloc();
    const spinner_str = text_utils.spinnerDots(app.frame_count);

    var para = r.tui.Paragraph{
        .padding = .all(1),
    };

    const exec_pool = app.swarm.exec;
    const ssh_suffix: []const u8 = if (exec_pool.ssh_active and exec_pool.ssh_target != null) " (SSH ON)" else "";

    var queued_buf: [64]u8 = undefined;
    const queued_count = app.queued.count();
    const queued_suffix: []const u8 = if (queued_count == 0)
        ""
    else if (queued_count == 1)
        "(1 message queued up)"
    else
        std.fmt.bufPrint(&queued_buf, "({d} queued messages up)", .{queued_count}) catch "(queued messages up)";

    var b: [255]u8 = undefined;
    const line = std.fmt.bufPrint(&b, "{s} ({d}s) Consuming tokens …{s} {s}", .{
        spinner_str,
        @as(u32, @intFromFloat(slot.time_elapsed)),
        ssh_suffix,
        queued_suffix,
    }) catch "…";

    var l = r.tui.Line{};

    l.pushText(alloc, line, .{ .fg = .cyan }) catch {};
    para.lines.append(alloc, l) catch {};
    para.render(alloc, area, area, buf);
}

fn renderWelcome(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    var c = area.center(70, 10);
    var line_iter = std.mem.splitAny(u8, HEADER_ART, "\n");
    while (line_iter.next()) |line| : (c.y += 1) {
        var col: u16 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch break;
            if (i + len > line.len) break;
            const cp = std.unicode.utf8Decode(line[i..][0..len]) catch break;
            i += len;
            if (cp < 0x20 or cp == 0x7F) continue;

            const wave_pos = (app.frame_count / 2) % 85;
            const dx = if (col >= wave_pos) col - wave_pos else wave_pos - col;
            const t: u16 = @intCast(@min(dx, 10));
            const blend: u8 = if (t >= 10) 0 else @intCast((10 - t) * 25);
            const fg = r.tui.Color{ .rgb = .{
                .r = blend,
                .g = 200 +| blend / 5,
                .b = 200 +| blend / 5,
            } };

            buf.set(c.x +| col, c.y, .{ .char = cp, .style = .{ .fg = fg } });
            col +|= 1;
        }
    }

    line_iter = std.mem.splitAny(u8, HEADER_INFO, "\n");

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "Loaded {d} Provider {d} Docs {d} Skills", .{
        app.swarm.cfg.provider_count,
        app.swarm.cfg.doc_count,
        app.swarm.cfg.skill_count,
    }) catch "error loading status";

    var buf_a: [255]u8 = undefined;
    var buf_b: [255]u8 = undefined;
    while (line_iter.next()) |line| : (c.y += 1) {
        const l1 = str_replace(&buf_a, "{MODEL_MAX}", app.swarm.cfg.model_max.getName(), line);
        const l2 = str_replace(&buf_b, "{MODEL_MID}", app.swarm.cfg.model_mid.getName(), l1);
        const l3 = str_replace(&buf_a, "{MODEL_MIN}", app.swarm.cfg.model_min.getName(), l2);
        const l4 = str_replace(&buf_b, "{INFO}", status, l3);
        const l5 = str_replace(&buf_a, "{cwd}", app.cwd, l4);

        buf.setString(c.x, c.y, l5, .{ .fg = Theme.default.muted });
    }
}

fn str_replace(buf: []u8, from: []const u8, to: []const u8, input: []const u8) []u8 {
    const len = std.mem.replacementSize(u8, input, from, to);
    if (len > buf.len) return buf;
    _ = std.mem.replace(u8, input, from, to, buf[0..len]);
    return buf[0..len];
}

fn renderPermissionWidget(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const block: r.tui.Block = .{
        .style = .{ .fg = Theme.default.warn },
        .borders = .{ .bottom = true, .left = true, .right = true },
    };

    block.render(area, buf);
    const inner = block.innerArea(area);
    if (inner.width == 0 or inner.height == 0) return;

    const pending = app.firstPendingPermission() orelse return;
    const entry = app.swarm.permission_requests.getPtr(pending.call_id) orelse return;

    if (entry.payload == .ask) {
        renderAskWidget(app, entry, inner, buf);
        return;
    }

    // Render header line with call/diff/plan summary (single line, truncated)
    var header_buf: [256]u8 = undefined;
    const header_line: []const u8 = switch (entry.payload) {
        .call => |p| blk: {
            const args_trunc = if (p.tool_arguments.len > 60) p.tool_arguments[0..60] else p.tool_arguments;
            const n = std.fmt.bufPrint(&header_buf, "{s}({s})", .{ p.tool_name, args_trunc }) catch "{s}";
            break :blk n;
        },
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
    buf.setStringMax(inner.x + 1, inner.y, header_line, .{ .fg = Theme.default.warn }, inner.width -| 1);

    const labels = [3][]const u8{ "allow?  yes", "        no", "        enter message" };
    const labels_sel = [3][]const u8{ "allow? >yes", "       >no", "       >enter message" };

    const plan_labels = [4][]const u8{ "plan?  approve & clear", "       approve & keep", "       no", "       enter message" };
    const plan_labels_sel = [4][]const u8{ "plan? >approve & clear", "      >approve & keep", "      >no", "      >enter message" };

    const is_plan = entry.payload == .plan;
    const count: usize = if (is_plan) 4 else 3;

    const cur_sel: u8 = switch (app.input_mode) {
        .perm_select => |ps| ps.selected,
        else => 0,
    };
    for (0..count) |i| {
        const y = inner.y + 1 + @as(u16, @intCast(i));
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

fn renderAskWidget(app: *App, req: *prv.Swarm.PermissionReq, inner: r.tui.Rect, buf: *r.tui.Buffer) void {
    const args = req.payload.ask;
    const opts_len = @min(args.options.len, r.tools.ask.MAX_OPTIONS);
    const total_rows: usize = opts_len + 1; // + "enter message"

    // Clamp selection.
    if (app.input_mode == .perm_select) {
        const ps = &app.input_mode.perm_select;
        if (ps.selected >= total_rows) ps.selected = @intCast(total_rows - 1);
    }
    const cur_sel: u8 = switch (app.input_mode) {
        .perm_select => |ps| ps.selected,
        else => 0,
    };

    // Line 0: "[header] question"
    var header_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&header_buf, "[{s}] {s}", .{ args.header, args.question }) catch args.question;
    buf.setStringMax(inner.x + 1, inner.y, header_line, .{ .fg = Theme.default.info }, inner.width -| 1);

    // Options and "enter message" tail.
    var row: usize = 0;
    while (row < total_rows) : (row += 1) {
        const y = inner.y +| @as(u16, @intCast(row + 1));
        if (y >= inner.y +| inner.height) break;

        const selected = cur_sel == @as(u8, @intCast(row));
        const style: r.tui.Style = if (selected) .{ .modifier = .{ .reverse = true } } else .{};
        const prefix: []const u8 = if (selected) "> " else "  ";
        const label: []const u8 = if (row < opts_len) args.options[row] else "enter message";

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ prefix, label }) catch label;
        buf.setStringMax(inner.x + 1, y, line, style, inner.width -| 1);
    }
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const ops = myersDiff(&old, &old, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(2, ops.len);
    try std.testing.expect(std.mem.eql(u8, ops[0].keep, "aaa"));
    try std.testing.expect(std.mem.eql(u8, ops[1].keep, "bbb"));
}

test "myers diff - completely different" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_][]const u8{ "aaa", "bbb" };
    const new = [_][]const u8{ "xxx", "yyy" };
    const ops = myersDiff(&old, &new, alloc) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(4, ops.len);
}

test "myers diff - empty old" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
