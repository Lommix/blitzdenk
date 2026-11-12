const std = @import("std");
const r = @import("root.zig");
const text_utils = r.tui.text_utils;
const log = std.log.scoped(.app);

const ct = @import("ctime");

pub const CONTEXT_LIMIT = 124 * 1024;
pub const READ_IMAGE_MAX = 2048;
fn moveFieldVertical(app: *App, alloc: std.mem.Allocator, field: anytype, width: usize, delta: i32) void {
    const target = app.verticalFieldTarget(alloc, .{ .text = field.slice(), .cursor = field.cursor }, width, delta) orelse return;
    field.cursor = target;
}

pub fn pathInsideDir(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

pub const TimelineRole = enum { system, user, agent };

pub const AppFlags = packed struct {
    show_thinking: bool = false,
    show_diffs: bool = true,
    inline_images: bool = true,
    notify_on_reload: bool = true,
    debug_log: bool = true,
    approval_mode: r.permissions.ApprovalMode = .default,
};

pub const Theme = struct {
    bg: r.tui.Color,
    overlay_dark: r.tui.Color,
    overlay: r.tui.Color,
    border: r.tui.Color,
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
        .border = .{ .rgb = .{ .r = 86, .g = 95, .b = 137 } },
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
    pub const PermMessage = struct { field: r.tui.Field(8192) = .{} };
    pub const Passphrase = struct {
        field: r.tui.Field(256) = .{},
        // Buffers backing user/host/cwd are owned by App.passphrase_args_buf.
        user: []const u8,
        host: []const u8,
        cwd: []const u8,
    };
    pub const Wizard = r.wizard.Wizard;
};

pub const Notifications = struct {
    list: [MAX_ENTRIES]Entry = @splat(.empty),

    pub const Entry = union(enum) { empty, used: struct { msg: []const u8, alive: f32, sent_ms: i64 } };
    const MAX_ENTRIES = 16;
    pub const DISPLAY_SECONDS: f32 = 8.0;
    pub const SLIDE_SECONDS: f32 = 0.25;
    pub const MAX_VISIBLE: usize = 4;

    pub fn append(self: *Notifications, alloc: std.mem.Allocator, sent_ms: i64, comptime fmt: []const u8, args: anytype) !void {
        var end: usize = 0;
        while (end < MAX_ENTRIES) : (end += 1) switch (self.list[end]) {
            .empty => break,
            else => {},
        };
        if (end == MAX_ENTRIES) {
            switch (self.list[0]) {
                .used => |en| alloc.free(en.msg),
                else => {},
            }
            std.mem.copyForwards(Entry, self.list[0 .. MAX_ENTRIES - 1], self.list[1..]);
            end = MAX_ENTRIES - 1;
        }
        const text = try std.fmt.allocPrint(alloc, fmt, args);
        self.list[end] = .{ .used = .{ .msg = text, .alive = 0, .sent_ms = sent_ms } };
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

    pub fn visibleCount(self: *const Notifications) usize {
        var n: usize = 0;
        var it = self.iter();
        while (it.next()) |_| n += 1;
        return n;
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

const PathCompletion = struct {
    cache: r.completion.DirCache = .{},
    probe_handle: ?r.exec.CmdPool.Handle = null,
    probe_dir: ?[]const u8 = null,
    probe_include_hidden: bool = false,
    probe_started_ms: i64 = 0,
    debounce_ms: i64 = 0,
    remote_home: ?[]const u8 = null,

    fn cancelProbe(self: *PathCompletion, pool: *r.exec.CmdPool, alloc: std.mem.Allocator) void {
        if (self.probe_handle) |h| pool.cancel(h);
        self.probe_handle = null;
        if (self.probe_dir) |d| alloc.free(d);
        self.probe_dir = null;
    }
};

pub const ToolStatusEntry = struct {
    lines: std.ArrayList(r.tui.Line) = .empty,
    child_ids: std.ArrayList(r.AgentId) = .empty,
    interrupted: bool = false,
    is_error: ?bool = null,
    has_image: bool = false,
    image_url: []const u8 = "",
};

const ToolStatusAgent = struct {
    name: []const u8 = "",
    task_description: []const u8 = "",
    generation: u16 = 0,
    entries: std.array_hash_map.String(ToolStatusEntry) = .empty,
    image_calls: std.array_hash_map.String(void) = .empty,
    image_urls: std.array_hash_map.String([]const u8) = .empty,
};

pub const ToolStatusStore = struct {
    agents: [r.agent_registry.max_agents]ToolStatusAgent = @splat(.{}),
    archived: std.AutoHashMapUnmanaged(u32, ToolStatusAgent) = .empty,
    pending_children: std.AutoHashMapUnmanaged(u32, std.ArrayList(struct { owner: r.AgentId, call_id: []const u8 })) = .empty,

    pub fn forWrite(self: *ToolStatusStore, alloc: std.mem.Allocator, id: r.AgentId) !*ToolStatusAgent {
        const current = &self.agents[id.index];
        if (current.generation == id.generation) return current;
        if (self.archived.getPtr(id.pack())) |archived| return archived;
        if (current.entries.count() > 0 or current.image_calls.count() > 0 or current.image_urls.count() > 0 or current.name.len > 0) {
            try self.archived.put(alloc, (r.AgentId{ .index = id.index, .generation = current.generation }).pack(), current.*);
        }
        current.* = .{ .generation = id.generation };
        return current;
    }

    pub fn getAgent(self: *ToolStatusStore, id: r.AgentId) ?*ToolStatusAgent {
        if (id.index >= r.agent_registry.max_agents) return null;
        if (self.agents[id.index].generation == id.generation) return &self.agents[id.index];
        return self.archived.getPtr(id.pack());
    }

    fn markImage(self: *ToolStatusStore, alloc: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, image_url: []const u8) !void {
        const agent = try self.forWrite(alloc, agent_id);
        const image_call = try agent.image_calls.getOrPut(alloc, call_id);
        if (!image_call.found_existing) image_call.key_ptr.* = try alloc.dupe(u8, call_id);
        if (agent.entries.getPtr(call_id)) |entry| {
            entry.has_image = true;
        }
        if (image_url.len > 0 and image_url.len <= r.inline_images.max_source_bytes) {
            const image = try agent.image_urls.getOrPut(alloc, call_id);
            if (!image.found_existing) {
                image.key_ptr.* = try alloc.dupe(u8, call_id);
                image.value_ptr.* = try alloc.dupe(u8, image_url);
            }
            if (agent.entries.getPtr(call_id)) |entry| entry.image_url = image.value_ptr.*;
        } else if (agent.entries.getPtr(call_id)) |entry| {
            if (agent.image_urls.get(call_id)) |image| entry.image_url = image;
        }
    }

    fn setResult(self: *ToolStatusStore, alloc: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, is_error: bool, image_url: []const u8) !void {
        const agent = try self.forWrite(alloc, agent_id);

        const entry = try agent.entries.getOrPut(alloc, call_id);
        if (!entry.found_existing) {
            entry.key_ptr.* = try alloc.dupe(u8, call_id);
            entry.value_ptr.* = .{};
        }
        entry.value_ptr.is_error = is_error;
        entry.value_ptr.has_image = entry.value_ptr.has_image or image_url.len > 0 or agent.image_calls.contains(call_id);
        if (agent.image_urls.get(call_id)) |url| entry.value_ptr.image_url = url;
        if (image_url.len > 0) try self.markImage(alloc, agent_id, call_id, image_url);
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
    /// Render-only state: scroll, timeline caches, frame snapshot, hits.
    view: r.view.State,
    mu: std.Io.Mutex = .init,
    io: std.Io,
    input: r.tui.Field(8192) = .{},
    input_desired_col: ?usize = null,
    // ---------------
    // async interface
    permission_queue: Locked(std.ArrayList(*r.permissions.Request)),
    pending_permissions: std.ArrayList(*r.permissions.Request) = .empty,
    permission_ticket_next: u64 = 0,
    selection_queue: Locked(std.ArrayList(*r.selection.Selection)),
    tool_status_entries: Locked(ToolStatusStore) = .{},
    pending_diffs: Locked(std.ArrayList(r.permissions.ToolDiff)) = .{},
    //-----------------
    active_permission: ?*r.permissions.Request = null,
    active_selection: ?*r.selection.Selection = null,
    /// Widget state of the active ask permission, bound to its ticket.
    /// Selections carry their own session.
    ask_session: ?r.ask_session.Session = null,
    ask_session_ticket: u64 = 0,
    registry: *r.agent_registry.Registry = undefined,
    session_store: ?*r.session_store.Store = null,
    exec_pool: *r.exec.CmdPool = undefined,
    jobs: r.jobs.Jobs = .{},
    /// Running background jobs, refreshed each tick. Counts for the session
    /// timer and progress line, not for `running`.
    jobs_running: u32 = 0,
    update_check: ?r.update.CheckTask = null,
    update_result_seen: bool = false,
    config: r.config.BlitzdenkCfg = .{},
    main_agent_id: ?r.AgentId = null,
    running: bool = false,
    frame_count: usize = 0,
    session_run_ns: i128 = 0,
    session_run_started_ns: i128 = 0,
    input_mode: InputMode = .{ .text = .{} },
    context_factory: *r.ContextFactory,
    theme: Theme = .default,
    cwd: []const u8,
    lua_config_dir: ?[]const u8 = null,
    lua_config_abs: ?[]const u8 = null,
    lua_reload_requested: std.atomic.Value(bool) = .init(false),
    lua_reload_failed: std.atomic.Value(bool) = .init(false),
    lua_reload_generation: std.atomic.Value(u64) = .init(0),
    flags: AppFlags = .{},
    default_context_limit: u32 = CONTEXT_LIMIT,
    read_image_max: std.atomic.Value(u64) = .init(packReadImageMax(READ_IMAGE_MAX, READ_IMAGE_MAX)),
    last_unbound_warn: ?[]const u8 = null,
    screenshot_buf: ?[]const u8 = null,
    dirty: bool = true,
    history: std.ArrayList(PromptEntry) = .empty,
    history_cursor: usize = 0,
    timeline: std.ArrayList(TimelineEntry) = .empty,
    streaming_entry: ?TimelineEntry = null,
    preview_reference: ?[]const TimelinePart = null,
    sdk_preview_parts: std.ArrayList(SdkPreviewPart) = .empty,
    sdk_preview_flushed: bool = false,
    sdk_run_rendered_steps: usize = 0,
    sdk_usage: r.sdk.Usage = .{},
    /// model round-trips of the main agent, incremented on .step events
    step_count: u32 = 0,
    compaction_indicator_active: bool = false,
    compaction_completion_seen_count: usize = 0,
    passphrase_args_buf: [512]u8 = undefined,
    keymap: r.keys.KeyMap = .{},
    cmd_queue: r.cmd.CommandQueue,
    lua_vm: *r.lua.LuaVm,
    lua_state: r.lua_state.Store = .{},
    lua_status_bar_enabled: bool = false,
    lua_status_bar_cache: [512]u8 = undefined,
    lua_status_bar_cache_len: usize = 0,
    widget_error_msgs: [r.lua.MAX_LUA_WIDGETS][r.lua.WIDGET_ERROR_CAP]u8 = @splat(@splat(0)),
    widget_error_lens: [r.lua.MAX_LUA_WIDGETS]usize = @splat(0),
    lua_redraw: std.atomic.Value(bool) = .init(false),
    lua_inject_hooks_enabled: std.atomic.Value(bool) = .init(false),
    mcp_manager: r.mcp.Manager,
    mcp_load: ?r.mcp.LoadTask = null,
    mcp_reload_pending: bool = false,
    mcp_auth: ?r.oauth.Task = null,
    mcp_auth_url_shown: bool = false,
    ssh_connect: ?r.ssh.SshConnectTask = null,
    notifications: Notifications = .{},
    event_bus: r.events.EventBus = .{},
    injection_hooks: r.inject.InjectionsHooks = .{},
    path_completion: PathCompletion = .{},
    journal_restoring: bool = false,
    image_viewer: ?r.image_view.Viewer = null,
    image_view_next_id: u32 = 1000,
    image_view_pending_delete: u32 = 0,
    kitty_graphics: bool = false,
    inline_images: r.inline_images.Store = .{},
    inline_placements: std.ArrayListUnmanaged(r.inline_images.Placement) = .empty,
    inline_pending_deletes: std.ArrayListUnmanaged(u32) = .empty,
    inline_images_ready: std.atomic.Value(bool) = .init(false),
    inline_frame_gen: u64 = 0,
    graphics_resize_gen: u64 = 0,
    cell_px: r.tui.kitty.CellPixels = .{},

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
            .view = .{ .arena_timeline_render = .init(gpa) },
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
            .selection_queue = .{
                .value = try .initCapacity(gpa, 4),
            },
        };
    }

    pub fn openImageToken(self: *App, token: []const u8) void {
        if (!self.kitty_graphics) {
            self.notifications.append(self.gpa, self.nowMillis(), "Image view needs a kitty graphics terminal", .{}) catch {};
            return;
        }
        if (self.image_viewer != null) self.closeImageViewer();
        self.image_view_next_id += 1;
        var viewer = r.image_view.open(self.gpa, self.image_view_next_id, self.io, self.cwd, token);
        if (viewer.img) |img| {
            viewer.img = r.image.downsampleMaxSide(self.gpa, img, r.image_view.max_side) catch img;
        }
        self.image_viewer = viewer;
        self.dirty = true;
    }

    pub fn closeImageViewer(self: *App) void {
        if (self.image_viewer) |*viewer| {
            if (viewer.transmitted) self.image_view_pending_delete = viewer.id;
            viewer.close(self.gpa);
        }
        self.image_viewer = null;
        self.dirty = true;
    }

    pub fn localLuaIsGlobal(self: *const App) bool {
        const dir = self.lua_config_dir orelse return false;
        return pathInsideDir(self.cwd, dir);
    }

    pub fn deinit(self: *App) void {
        self.jobs.killAll(self.exec_pool);
        if (self.image_viewer) |*viewer| viewer.close(self.gpa);
        self.image_viewer = null;
        self.inline_images.deinit(self.gpa);
        self.inline_placements.deinit(self.gpa);
        self.inline_pending_deletes.deinit(self.gpa);
        if (self.ask_session) |*s| s.deinit();
        self.ask_session = null;
        self.clearSelections(false);
        self.selection_queue.value.deinit(self.gpa);
        self.event_bus.shutdown(self);
        self.event_bus.joinPending(self.io);
        if (self.update_check) |*task| task.deinit();
        if (self.mcp_load) |*task| task.deinit();
        if (self.mcp_auth) |*task| task.deinit();
        if (self.ssh_connect) |*task| task.deinit();
        self.mcp_manager.deinit();
        self.lua_vm.deinit();
        self.lua_state.deinit(self.gpa);
        self.cmd_queue.deinit();
        self.injection_hooks.deinit(self.gpa);
        self.permission_queue.value.deinit(self.gpa);
        self.pending_permissions.deinit(self.gpa);
        self.notifications.deinit(self.gpa);
        self.event_bus.clear(self.io);
        if (self.last_unbound_warn) |s| self.gpa.free(s);
        for (self.history.items) |e| self.gpa.free(e.text);
        self.history.deinit(self.gpa);
        self.path_completion.cache.clear(self.appAlloc());
        if (self.path_completion.remote_home) |h| self.appAlloc().free(h);
        self.context_factory.deinit();
        self.arena_streaming_preview.deinit();
        self.arena_streaming_snapshot.deinit();
        self.arena_frame.deinit();
        self.view.deinit(self.gpa);
        self.arena_session.deinit();
        self.arena_app.deinit();
    }

    /// Decide one parked request. Callers must hold the permission_queue lock.
    pub fn settlePermission(self: *App, req: *r.permissions.Request, state: r.permissions.State) void {
        req.state = state;
        req.event.set(self.io);
        for (self.pending_permissions.items, 0..) |pending, index| {
            if (pending == req) {
                _ = self.pending_permissions.orderedRemove(index);
                break;
            }
        }
        if (self.active_permission == req) self.active_permission = null;
    }

    pub fn permissionModeApproves(self: *App, req: *r.permissions.Request) bool {
        self.mu.lockUncancelable(self.io);
        const mode = self.flags.approval_mode;
        self.mu.unlock(self.io);
        return r.permissions.shouldAutoApprove(mode, req.payload == .ask, self.exec_pool.ssh_active);
    }

    pub fn finishLuaPermission(self: *App, ticket: u64) void {
        const g = self.permission_queue.lock(self.io);
        defer g.unlock();
        for (self.pending_permissions.items) |req| {
            if (req.ticket != ticket) continue;
            self.releaseLuaStage(req);
            return;
        }
    }

    pub fn releaseLuaStage(self: *App, req: *r.permissions.Request) void {
        if (req.stage != .in_lua) return;
        if (self.permissionModeApproves(req)) {
            self.settlePermission(req, .approved);
        } else {
            req.stage = .in_tui;
        }
    }

    pub fn cancelPermissions(self: *App, only: ?r.AgentId) void {
        var cleared_active = false;
        if (self.active_permission) |req| {
            if (only == null or req.agent_id == only.?) {
                req.state = .denied;
                req.event.set(self.io);
                self.active_permission = null;
                cleared_active = true;
            }
        }

        const g = self.permission_queue.lock(self.io);
        defer g.unlock();

        var index: usize = 0;
        while (index < g.ptr.items.len) {
            const req = g.ptr.items[index];
            if (only == null or req.agent_id == only.?) {
                req.state = .denied;
                req.event.set(self.io);
                _ = g.ptr.swapRemove(index);
            } else index += 1;
        }

        index = 0;
        while (index < self.pending_permissions.items.len) {
            const req = self.pending_permissions.items[index];
            if (only == null or req.agent_id == only.?) {
                self.settlePermission(req, .denied);
            } else index += 1;
        }

        if (only != null) {
            if (cleared_active) self.returnToText();
            return;
        }
        self.clearSelections(true);
        self.returnToText();
    }

    /// Resolve the active selection: run its Lua callback with one answer
    /// list per question (nil on cancel), then free it.
    pub fn resolveActiveSelection(self: *App, answers: ?r.permissions.Answers) void {
        defer if (answers) |a| a.deinit();
        const sel = self.active_selection orelse return;
        self.active_selection = null;
        self.view.auto_scroll = true;
        self.view.scroll_offset = 0;
        self.dirty = true;
        self.lua_vm.invokeSelection(self.io, sel.func_ref, sel.session.questions, answers);
        sel.destroy();
        self.returnToText();
    }

    /// Cancel active and queued selections. With `run_callbacks` each
    /// callback reports nil; otherwise they are dropped silently.
    /// Callbacks run without the queue lock, so they may call cmd.select.
    pub fn clearSelections(self: *App, run_callbacks: bool) void {
        const active = self.active_selection;
        self.active_selection = null;

        const g = self.selection_queue.lock(self.io);
        var queued = g.ptr.*;
        g.ptr.* = .empty;
        g.unlock();
        defer queued.deinit(self.gpa);

        if (!run_callbacks) {
            if (active) |sel| sel.destroy();
            for (queued.items) |sel| sel.destroy();
            return;
        }

        if (active) |sel| {
            self.lua_vm.invokeSelection(self.io, sel.func_ref, sel.session.questions, null);
            sel.destroy();
        }
        for (queued.items) |sel| {
            self.lua_vm.invokeSelection(self.io, sel.func_ref, sel.session.questions, null);
            sel.destroy();
        }
    }

    /// Widget session of the ask on screen: the active ask permission, else
    /// the active selection. The permission session is rebuilt per ticket, so
    /// a new request never inherits stale progress.
    pub fn askSession(self: *App) ?*r.ask_session.Session {
        if (self.active_permission) |perm| {
            if (perm.payload != .ask) return null;
            if (self.ask_session == null or self.ask_session_ticket != perm.ticket) {
                if (self.ask_session) |*s| s.deinit();
                self.ask_session = .init(perm.payload.ask.questions);
                self.ask_session_ticket = perm.ticket;
            }
            return &self.ask_session.?;
        }
        if (self.active_selection) |sel| return &sel.session;
        return null;
    }

    /// Settle the ask on screen with its answers. No-op while a question is
    /// still open.
    pub fn submitAsk(self: *App) void {
        const s = self.askSession() orelse return;
        const answers = s.takeAnswers() orelse return;
        if (self.active_permission != null) {
            self.resolveActivePermission(.{ .answers = answers });
        } else {
            self.resolveActiveSelection(answers);
        }
    }

    /// Cancel only the ask on screen, never the agent run.
    pub fn cancelAsk(self: *App) void {
        if (self.active_permission != null) {
            self.resolveActivePermission(.denied);
        } else {
            self.resolveActiveSelection(null);
        }
        self.view.auto_scroll = true;
        self.view.scroll_offset = 0;
    }

    /// Highest reachable perm_select row for a non-ask permission. Asks
    /// navigate through their session.
    pub fn permSelectMaxIndex(self: *App) u8 {
        const entry = self.active_permission orelse return 0;
        return switch (entry.payload) {
            .ask => 0,
            .call, .diff => 2,
        };
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
        defer self.publishToolStatus(agent_id, call_id, g.ptr);

        const alloc = self.sessionAlloc();
        const agent = try g.ptr.forWrite(alloc, agent_id);

        const res = try agent.entries.getOrPut(alloc, call_id);
        if (!res.found_existing) {
            res.key_ptr.* = try alloc.dupe(u8, call_id);
            res.value_ptr.* = .{};
        } else {
            for (res.value_ptr.lines.items) |*line| line.deinit(alloc);
            res.value_ptr.lines.clearRetainingCapacity();
        }
        res.value_ptr.has_image = agent.image_calls.contains(call_id);
        if (agent.image_urls.get(call_id)) |image_url| res.value_ptr.image_url = image_url;

        var parsed = try r.tui.Text.fromAnsi(alloc, text);
        defer parsed.deinit(alloc);
        for (parsed.lines.items) |*line| {
            try res.value_ptr.lines.append(alloc, line.*);
            line.* = .{};
        }
    }

    pub fn addToolChild(self: *App, agent_id: r.AgentId, call_id: []const u8, child_id: r.AgentId) !void {
        if (agent_id.index >= r.agent_registry.max_agents or child_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();
        defer self.publishToolStatus(agent_id, call_id, g.ptr);

        const alloc = self.sessionAlloc();
        const agent = try g.ptr.forWrite(alloc, agent_id);

        const res = try agent.entries.getOrPut(alloc, call_id);
        if (!res.found_existing) {
            res.key_ptr.* = try alloc.dupe(u8, call_id);
            res.value_ptr.* = .{};
        }
        for (res.value_ptr.child_ids.items) |existing| {
            if (existing.pack() == child_id.pack()) return;
        }
        try res.value_ptr.child_ids.append(alloc, child_id);
        const declared = self.session_store == null or self.session_store.?.declares(child_id.pack());
        if (!self.journal_restoring and !declared) {
            const pending = try g.ptr.pending_children.getOrPut(alloc, child_id.pack());
            if (!pending.found_existing) pending.value_ptr.* = .empty;
            try pending.value_ptr.append(alloc, .{ .owner = agent_id, .call_id = res.key_ptr.* });
        }
    }

    pub fn setToolResult(self: *App, agent_id: r.AgentId, call_id: []const u8, is_error: bool) !void {
        if (agent_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();
        defer self.publishToolStatus(agent_id, call_id, g.ptr);
        try g.ptr.setResult(self.sessionAlloc(), agent_id, call_id, is_error, "");
    }

    pub fn markToolImage(self: *App, agent_id: r.AgentId, call_id: []const u8) !void {
        return self.markToolImageUrl(agent_id, call_id, "");
    }

    pub fn markToolImageUrl(self: *App, agent_id: r.AgentId, call_id: []const u8, image_url: []const u8) !void {
        if (agent_id.index >= r.agent_registry.max_agents) return error.InvalidAgent;
        const g = self.tool_status_entries.lock(self.io);
        defer g.unlock();
        try g.ptr.markImage(self.sessionAlloc(), agent_id, call_id, image_url);
    }

    fn publishToolStatus(self: *App, id: r.AgentId, call_id: []const u8, statuses: *ToolStatusStore) void {
        if (self.journal_restoring) return;
        const store = self.session_store orelse return;
        const status_agent = statuses.getAgent(id) orelse return;
        const entry = status_agent.entries.get(call_id) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const ansi = r.session.linesToAnsi(entry.lines.items, arena.allocator()) catch return;
        const child_buf = arena.allocator().alloc(u32, entry.child_ids.items.len) catch return;
        var child_n: usize = 0;
        for (entry.child_ids.items) |child| {
            if (statuses.pending_children.contains(child.pack())) continue;
            child_buf[child_n] = child.pack();
            child_n += 1;
        }
        store.enqueue(.{
            .kind = .tool_status,
            .agentID = id.pack(),
            .call_id = call_id,
            .ansi = ansi,
            .state = if (entry.interrupted) .interrupted else if (entry.is_error) |failed| (if (failed) .failed else .succeeded) else .pending,
            .children = child_buf[0..child_n],
        }) catch |err| std.log.scoped(.session).err("tool status: {s}", .{@errorName(err)});
    }

    pub fn rememberAgentMetadata(self: *App, id: r.AgentId, name: []const u8, task: []const u8) !void {
        const guard = self.tool_status_entries.lock(self.io);
        defer guard.unlock();
        const entry = try guard.ptr.forWrite(self.sessionAlloc(), id);
        entry.name = try self.sessionAlloc().dupe(u8, name);
        entry.task_description = try self.sessionAlloc().dupe(u8, task);
    }

    pub fn interruptToolStatuses(self: *App, id: r.AgentId) void {
        const guard = self.tool_status_entries.lock(self.io);
        defer guard.unlock();
        const agent = guard.ptr.getAgent(id) orelse return;
        var it = agent.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_error != null) continue;
            entry.value_ptr.interrupted = true;
            entry.value_ptr.is_error = true;
            self.publishToolStatus(id, entry.key_ptr.*, guard.ptr);
        }
    }

    fn publishPendingToolLinks(self: *App, id: r.AgentId) void {
        const guard = self.tool_status_entries.lock(self.io);
        defer guard.unlock();
        const pending = guard.ptr.pending_children.fetchRemove(id.pack()) orelse return;
        for (pending.value.items) |link| self.publishToolStatus(link.owner, link.call_id, guard.ptr);
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

    pub fn checkpoint(self: *App) void {
        _ = self.drainPendingDiffs();
        self.journalFlush();
    }

    pub fn journalFlush(self: *App) void {
        if (self.session_store) |store| {
            store.drainDisplay(self) catch |err| std.log.scoped(.session).warn("journal display failed: {s}", .{@errorName(err)});
            store.flush() catch |err| std.log.scoped(.session).warn("journal flush failed: {s}", .{@errorName(err)});
        }
    }

    pub fn selectMainAgent(self: *App, id: ?r.AgentId) !void {
        if (!self.journal_restoring) if (self.session_store) |store| try store.enqueue(.{ .kind = .main_agent, .agentID = if (id) |value| value.pack() else null });
        self.main_agent_id = id;
        self.preview_reference = null;
    }

    fn journalClear(self: *App) void {
        for (&self.registry.slots) |*slot| if (slot.agent) |*agent| {
            agent.journal = null;
        };
    }

    pub fn reset(self: *App) void {
        self.closeImageViewer();
        for (self.inline_images.entries.items) |entry| {
            if (entry.transmitted or entry.placed_gen != 0) self.inline_pending_deletes.append(self.gpa, entry.kitty_id) catch break;
        }
        self.inline_images.deinit(self.gpa);
        self.inline_images = .{};
        self.inline_placements.clearRetainingCapacity();
        self.registry.cancelAll();
        self.checkpoint();
        if (self.session_store) |store| store.flush() catch |err| {
            std.log.scoped(.session).err("session reset postponed: {s}", .{@errorName(err)});
            return;
        };
        self.context_factory.startSession(&self.config) catch |err| {
            std.log.scoped(.session).err("session model snapshot failed: {s}", .{@errorName(err)});
        };
        self.journalClear();
        if (self.session_store) |store| store.bump();
        if (self.mcp_load) |*task| task.deinit();
        self.mcp_load = null;
        self.cancelSshConnect();
        self.dropStreamingPreview();
        self.clearPendingDiffs();
        self.cancelPermissions(null);
        self.registry.cancelAll();

        self.main_agent_id = null;
        self.running = false;
        self.frame_count = 0;
        self.session_run_ns = 0;
        self.session_run_started_ns = 0;
        self.view.scroll_offset = 0;
        self.view.auto_scroll = true;
        self.input_mode = .{ .text = .{} };
        self.input.clear();
        self.input_desired_col = null;
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
        self.timeline = .empty;
        self.view.tool_runs_expanded = .empty;
        self.view.clearRunHits(self.gpa);
        self.view.invalidateRenderCache();
        self.context_factory.resetLoadedTools() catch {};
        self.lua_vm.disableAllMcp();
        self.lua_state.reset(self.io, self.gpa);
        _ = self.event_bus.emit(self, .session_reset);
        self.reloadMcpTools() catch {};
        self.reloadLuaTools() catch {};

        // cleanup
        self.tool_status_entries = .{};
        {
            const g = self.permission_queue.lock(self.io);
            self.permission_queue.value.clearRetainingCapacity();
            self.pending_permissions.clearRetainingCapacity();
            g.unlock();
        }
    }

    pub fn tick(self: *App) !void {
        try self.finishMcpLoad(false);
        self.finishMcpAuth();
        self.finishSshConnect();
        self.registry.flush();
        const running_before = self.running;
        for (&self.registry.slots, 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;
            const id = r.AgentId{ .index = @intCast(index), .generation = slot.generation };
            var drain_context = RegistryDrainContext{ .app = self, .id = id };
            _ = self.registry.drain(id, 64, &drain_context, applyRegistryEvent);
            const agent = self.registry.get(id) orelse continue;
            const finished_run = agent.task != null;
            if (self.registry.reap(id)) {
                if (finished_run and agent.status == .complete and self.registry.state(id) == .complete) _ = self.event_bus.emit(self, .{ .agent_complete = id });
            }
            // Finished parents can defer their result notice until a live
            // descendant finishes, even when their own turn is already reaped.
            try self.handleReapedAgent(id);
        }
        try self.tickJobs();
        const jobs_before = self.jobs_running;
        self.jobs_running = self.jobs.countRunning(self.io);
        if (self.jobs_running != jobs_before) self.dirty = true;
        if (self.mainAgent()) |agent| self.sdk_usage = agent.usage;
        self.registry.retryDue();
        self.running = self.registry.countActive() > 0;
        if (self.running != running_before) self.dirty = true;
        if (self.drainPendingDiffs() > 0) self.dirty = true;
        self.updateSessionTime();
        self.tickPathCompletion();

        // --------------------------------------------------
        // pop permission
        {}

        self.syncCompactionIndicator();

        if (!self.update_result_seen and self.availableUpdateVersion() != null) {
            self.update_result_seen = true;
            self.dirty = true;
        }

        self.journalFlush();
    }

    pub fn animationActive(self: *const App) bool {
        if (self.running or self.jobs_running > 0) return true;
        if (self.timeline.items.len != 0 or self.isMainAgentCompacting()) return false;
        return self.frame_count < r.dash.welcome_wave_frames;
    }

    fn updateSessionTime(self: *App) void {
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds);
        if (self.running or self.jobs_running > 0) {
            if (self.session_run_started_ns == 0) self.session_run_started_ns = now;
        } else if (self.session_run_started_ns != 0) {
            self.session_run_ns += now - self.session_run_started_ns;
            self.session_run_started_ns = 0;
        }
    }

    pub fn nowMillis(self: *App) i64 {
        const now = std.Io.Clock.Timestamp.now(self.io, .real);
        return @intCast(@divTrunc(now.raw.nanoseconds, std.time.ns_per_ms));
    }

    fn probeHome(self: *const App) []const u8 {
        if (self.exec_pool.ssh_active) return self.path_completion.remote_home orelse "/";
        return self.exec_pool.env.get("HOME") orelse "/";
    }

    pub fn pathTokenActive(self: *const App) bool {
        return self.currentTokenParts() != null;
    }

    fn tickPathCompletion(self: *App) void {
        const pc = &self.path_completion;
        const parts_opt = if (self.input_mode == .text) self.currentTokenParts() else null;
        const parts = parts_opt orelse {
            if (pc.probe_handle != null or pc.debounce_ms != 0) pc.cancelProbe(self.exec_pool, self.appAlloc());
            return;
        };

        const now_ms = self.nowMillis();
        var probed_dir_buf: [1024]u8 = undefined;
        const probe_dir = self.resolveProbeDir(parts.prefix, &probed_dir_buf) orelse {
            if (pc.probe_handle != null or pc.debounce_ms != 0) pc.cancelProbe(self.exec_pool, self.appAlloc());
            return;
        };

        if (pc.cache.find(probe_dir)) |hit| {
            if (hit.fresh(now_ms) and (hit.include_hidden or !parts.include_hidden)) {
                if (pc.probe_handle != null or pc.debounce_ms != 0) pc.cancelProbe(self.exec_pool, self.appAlloc());
                return;
            }
        }

        if (pc.probe_handle) |handle| {
            const slot = &self.exec_pool.slots[@backingInt(handle)];
            if (slot.done.load(.acquire)) {
                self.harvestProbe(handle);
            } else if (now_ms - pc.probe_started_ms > r.completion.PROBE_TIMEOUT_MS) {
                self.timeoutProbe(handle);
            } else {
                pc.debounce_ms = 0;
            }
            return;
        }

        if (pc.debounce_ms == 0) {
            pc.debounce_ms = now_ms;
            return;
        }
        if (now_ms - pc.debounce_ms < r.completion.DEBOUNCE_MS) return;

        self.spawnProbe(probe_dir, parts.include_hidden);
    }

    const TokenParts = struct {
        prefix: []const u8,
        filter: []const u8,
        include_hidden: bool,
    };

    pub fn currentTokenParts(self: *const App) ?TokenParts {
        const tok = r.completion.tokenAt(self.input.slice(), self.input.cursor);
        if (!tok.is_path) return null;
        if (tok.start == 0 and !self.input.isEmpty() and self.input.slice()[0] == '/') {
            if (r.completion.commandTokenOwns(self.input.slice(), self.input.cursor)) return null;
        }
        const token = self.input.slice()[tok.start..tok.end];
        const slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse return null;
        const filter = token[slash + 1 ..];
        return .{
            .prefix = token[0 .. slash + 1],
            .filter = filter,
            .include_hidden = filter.len > 0 and filter[0] == '.',
        };
    }

    pub fn resolveProbeDir(self: *App, insert_prefix: []const u8, buf: *[1024]u8) ?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const parts = r.completion.splitToken(arena.allocator(), insert_prefix, self.probeHome()) catch return null;
        return std.fmt.bufPrint(buf, "{s}", .{parts.dir}) catch null;
    }

    fn spawnProbe(self: *App, dir: []const u8, include_hidden: bool) void {
        const pc = &self.path_completion;
        if (pc.probe_dir) |old| self.appAlloc().free(old);

        const argv: []const []const u8 = if (include_hidden)
            &.{ "ls", "-1pA", dir }
        else
            &.{ "ls", "-1p", dir };

        const handle = self.exec_pool.runWithOpts(.{ .argv = argv, .cwd = self.exec_pool.effectiveCwd(self.cwd) }) catch {
            pc.debounce_ms = 0;
            return;
        };

        pc.probe_handle = handle;
        pc.probe_dir = self.appAlloc().dupe(u8, dir) catch null;
        pc.probe_include_hidden = include_hidden;
        pc.probe_started_ms = self.nowMillis();
        pc.debounce_ms = 0;
    }

    fn harvestProbe(self: *App, handle: r.exec.CmdPool.Handle) void {
        const pc = &self.path_completion;
        const dir = pc.probe_dir orelse "";
        const include_hidden = pc.probe_include_hidden;
        pc.probe_handle = null;
        pc.probe_dir = null;
        defer if (dir.len > 0) self.appAlloc().free(dir);

        const res = self.exec_pool.killAndCollect(handle) catch return;
        defer self.exec_pool.alloc.free(res.stdout);
        defer self.exec_pool.alloc.free(res.stderr);
        if (dir.len == 0) return;

        const alloc = self.appAlloc();
        const list = pc.cache.beginInsert(alloc, dir) catch return;
        list.stamp_ms = self.nowMillis();
        list.valid = true;
        list.include_hidden = include_hidden;
        if (res.ty != .success or res.stdout_truncated) {
            list.valid = false;
            return;
        }
        r.completion.parseLsOutput(alloc, list, res.stdout) catch {
            list.valid = false;
            return;
        };
        r.completion.sortEntries(list.entries.items);

        if (self.input_mode == .text and self.pathTokenActive()) {
            if (self.currentTokenDirMatches(dir)) self.syncCompletion();
        }
        self.dirty = true;
    }

    fn currentTokenDirMatches(self: *App, dir: []const u8) bool {
        var buf: [1024]u8 = undefined;
        const parts = self.currentTokenParts() orelse return false;
        const resolved = self.resolveProbeDir(parts.prefix, &buf) orelse return false;
        return std.mem.eql(u8, resolved, dir);
    }

    fn timeoutProbe(self: *App, handle: r.exec.CmdPool.Handle) void {
        const pc = &self.path_completion;
        const dir = pc.probe_dir orelse return;
        pc.probe_handle = null;
        pc.probe_dir = null;
        defer if (dir.len > 0) self.appAlloc().free(dir);

        const alloc = self.appAlloc();
        const list = pc.cache.beginInsert(alloc, dir) catch return;
        list.stamp_ms = self.nowMillis();
        list.valid = false;
        self.exec_pool.cancel(handle);
    }

    pub fn invalidatePathCompletions(self: *App) void {
        self.path_completion.cache.clear(self.appAlloc());
        if (self.path_completion.remote_home) |h| {
            self.appAlloc().free(h);
            self.path_completion.remote_home = null;
        }
        self.path_completion.cancelProbe(self.exec_pool, self.appAlloc());
    }

    pub fn setRemoteHome(self: *App, home: []const u8) void {
        if (self.path_completion.remote_home) |h| self.appAlloc().free(h);
        self.path_completion.remote_home = self.appAlloc().dupe(u8, home) catch null;
    }

    pub fn sessionRunSecs(self: *const App) u32 {
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds);
        const live: i128 = if (self.session_run_started_ns != 0) @max(0, now - self.session_run_started_ns) else 0;
        return @intCast(@divTrunc(self.session_run_ns + live, std.time.ns_per_s));
    }

    pub fn handleReapedAgent(self: *App, agent_id: r.AgentId) !void {
        const agent = self.registry.get(agent_id) orelse return;
        const state = self.registry.state(agent_id) orelse return;
        if (state == .active) return;
        if (agent.queued_messages.items.len > 0) {
            try self.registry.run(agent_id, .{ .max_steps = std.math.maxInt(usize) });
            _ = self.event_bus.emit(self, .{ .agent_started = .{ .id = agent_id, .fresh = false } });
            return;
        }
        if (agent.reported_task_done) return;
        if (!self.registry.subtreeDone(agent_id)) return;
        agent.reported_task_done = true;
        switch (agent.status) {
            .complete => self.lua_vm.invokeSpawnCallback(self.io, agent_id.pack(), r.lua.AWAIT_COMPLETE),
            .failed => self.lua_vm.invokeSpawnCallback(self.io, agent_id.pack(), r.lua.AWAIT_FAILED),
            .canceled => self.lua_vm.invokeSpawnCallback(self.io, agent_id.pack(), r.lua.AWAIT_CANCELED),
            else => {},
        }
        if (agent.background) {
            try self.finishBackgroundAgent(agent_id, agent);
            return;
        }
        const is_main = if (self.main_agent_id) |id| id.pack() == agent_id.pack() else false;
        if (!is_main and (agent.status == .failed or agent.status == .canceled)) {
            const err = agent.last_error orelse error.ApiError;
            self.pushSystemMessage("agent {s} failed: {s}", .{ agent.name, @errorName(err) });
        }
    }

    /// Stop and free the agent in `id` without touching its timeline entries.
    /// Used when a spawn replaces the main agent: the old conversation stays
    /// rendered, only the slot goes back to the pool.
    pub fn detachMainAgent(self: *App, id: r.AgentId) void {
        if (self.registry.get(id) == null) return;
        self.registry.cancel(id);
        if (self.registry.get(id)) |agent| agent.cancelAndWait();
        self.lua_vm.invokeSpawnCallback(self.io, id.pack(), r.lua.AWAIT_CANCELED);
        self.registry.release(id);
        if (self.main_agent_id == id) self.main_agent_id = null;
    }

    fn finishBackgroundAgent(self: *App, agent_id: r.AgentId, agent: *r.agent.Agent) !void {
        const packed_id = agent.parent orelse return;
        const parent_id = r.AgentId.unpack(packed_id);
        const parent = self.registry.get(parent_id) orelse return;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.gpa);
        try self.collectBackgroundResult(agent, &content);

        var id_buf: [16]u8 = undefined;
        const spill_id = try std.fmt.bufPrint(&id_buf, "agent-{d}", .{agent_id.pack()});
        const spill = if (r.tools.isOversized(content.items, r.tools.MAX_DISPLAY_BYTES, r.tools.MAX_DISPLAY_LINES))
            r.tools.writeSpillFile(self.exec_pool, self.gpa, spill_id, content.items)
        else
            null;
        defer if (spill) |path| self.gpa.free(path);

        const truncated = r.tools.truncateOutputToOwnedSpill(self.gpa, content.items, r.tools.MAX_DISPLAY_BYTES, r.tools.MAX_DISPLAY_LINES, spill);
        defer if (truncated.ptr != content.items.ptr) self.gpa.free(truncated);

        const notice = try std.fmt.allocPrint(self.gpa, "Agent result done:\n{s}", .{truncated});
        defer self.gpa.free(notice);

        try self.remindAndWake(parent_id, parent, notice);
    }

    /// Queue `notice` as a reminder and start the agent's next turn when idle.
    fn remindAndWake(self: *App, id: r.AgentId, agent: *r.agent.Agent, notice: []const u8) !void {
        try agent.queueReminder(notice);
        if (!agent.isBusy()) {
            try self.registry.run(id, .{ .max_steps = std.math.maxInt(usize) });
            _ = self.event_bus.emit(self, .{ .agent_started = .{ .id = id, .fresh = false } });
        }
    }

    fn tickJobs(self: *App) !void {
        const alloc = self.exec_pool.alloc;
        var finished: std.ArrayList(r.jobs.Finished) = .empty;
        defer {
            for (finished.items) |done| done.deinit(alloc);
            finished.deinit(alloc);
        }
        try self.jobs.tick(self.exec_pool, self, jobOwnerAlive, &finished);
        for (finished.items) |done| {
            const agent = self.registry.get(done.owner) orelse continue;
            const notice = try r.tools.bash.formatJobNotice(self.gpa, done);
            defer self.gpa.free(notice);
            try self.remindAndWake(done.owner, agent, notice);
        }
    }

    fn jobOwnerAlive(self: *App, id: r.AgentId) bool {
        return self.registry.get(id) != null;
    }

    fn collectBackgroundResult(self: *App, agent: *const r.agent.Agent, content: *std.ArrayList(u8)) !void {
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
        if (wrote_text) return;
        if (agent.last_error) |err|
            try content.print(self.gpa, "Agent failed: {s}\n", .{@errorName(err)})
        else
            try content.appendSlice(self.gpa, "Agent produced no text output.\n");
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

    pub fn wizardSelection(self: *App, w: *const InputMode.Wizard) ?r.wizard.Selection {
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

    pub const FieldOp = enum { left, right, home, end, backspace, delete_forward, insert };

    fn applyFieldOp(comptime op: FieldOp, f: anytype, bytes: []const u8) void {
        switch (op) {
            .left => f.left(),
            .right => f.right(),
            .home => f.home(),
            .end => f.end(),
            .backspace => f.backspace(),
            .delete_forward => f.deleteForward(),
            .insert => f.insert(bytes),
        }
    }

    pub fn fieldOp(self: *App, comptime op: FieldOp, bytes: []const u8) bool {
        switch (self.input_mode) {
            .text => applyFieldOp(op, &self.input, bytes),
            .perm_message => |*pm| applyFieldOp(op, &pm.field, bytes),
            .passphrase => |*pp| applyFieldOp(op, &pp.field, bytes),
            .wizard => |*w| return if (w.activeText()) |f| blk: {
                applyFieldOp(op, f, bytes);
                break :blk true;
            } else false,
            else => return false,
        }
        return true;
    }

    pub fn returnToText(self: *App) void {
        // Zero passphrase buffer when leaving the modal so it doesn't linger.
        if (self.input_mode == .passphrase) {
            self.input_mode.passphrase.field.wipe();
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
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (self.pathTokenActive()) {
            const rows = r.view.completion.pathCompletions(self, arena.allocator());
            t.completion_open = rows.len > 0;
        } else {
            t.completion_query_len = r.view.completion.commandCompletionPrefix(self.input.slice(), self.input.cursor).len;
            const rows = r.view.completion.commandCompletions(self, arena.allocator(), self.input.slice(), self.input.cursor);
            t.completion_open = rows.len > 0 and r.view.completion.commandTokenActive(self.input.slice(), self.input.cursor);
        }
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

        const rows = r.view.completion.activeCompletions(self, alloc, self.input.slice(), self.input.cursor);
        if (rows.len == 0) {
            t.completion_open = false;
            t.completion_selected = 0;
            t.completion_query_len = 0;
            return;
        }
        if (t.completion_selected >= rows.len) t.completion_selected = 0;

        const path_mode = self.pathTokenActive();
        if (path_mode and move != .accept) {
            if (move == .next) {
                t.completion_selected = @min(t.completion_selected + 1, rows.len - 1);
            } else {
                t.completion_selected -|= 1;
            }
            return;
        }

        const chosen = rows.items[t.completion_selected].text;
        const cur_token = r.view.completion.commandCompletionPrefix(self.input.slice(), self.input.cursor);
        const already = std.ascii.eqlIgnoreCase(cur_token, chosen);

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

        r.view.completion.insertCompletionToken(self, rows.items[t.completion_selected].text);

        if (move == .accept) {
            const accepted = rows.items[t.completion_selected].text;
            const descend = path_mode and accepted.len > 0 and accepted[accepted.len - 1] == '/';
            t.completion_open = descend;
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
        if (self.mcp_load != null) {
            self.mcp_reload_pending = true;
            return;
        }
        for (self.mcp_manager.registeredTools()) |entry| self.context_factory.remove(entry.tool.def.name);

        self.mcp_load = .init(self.io, &self.mcp_manager, servers);
        self.mcp_load.?.start();
    }

    pub fn waitForMcpTools(self: *App) !void {
        try self.finishMcpLoad(true);
    }

    pub fn startMcpConnect(self: *App, name: []const u8) void {
        self.lua_vm.vm_mu.lockUncancelable(self.io);
        const cfg = self.lua_vm.mcpConfig(name) orelse {
            self.lua_vm.vm_mu.unlock(self.io);
            self.notifications.append(self.gpa, self.nowMillis(), "MCP: unknown server {s}", .{name}) catch {};
            return;
        };
        const store_dir = self.mcp_manager.token_dir;
        if (!r.mcp.wantsOAuth(cfg) or store_dir == null) {
            _ = self.lua_vm.enableMcp(name);
            self.lua_vm.vm_mu.unlock(self.io);
            self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: enabled", .{name}) catch {};
            self.reloadMcpTools() catch {};
            return;
        }
        self.cancelMcpAuth();
        const task = r.oauth.Task.init(self.gpa, self.io, .{
            .name = cfg.name,
            .url = cfg.url.?,
            .client_id = cfg.client_id,
            .client_secret = cfg.client_secret,
            .scopes = cfg.scopes,
            .redirect_port = cfg.redirect_port,
            .store_dir = store_dir.?,
        }, r.oauth.browser_opener);
        self.lua_vm.vm_mu.unlock(self.io);
        self.mcp_auth = task catch {
            self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: out of memory", .{name}) catch {};
            return;
        };
        self.mcp_auth.?.start();
        self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: authorizing", .{name}) catch {};
        self.dirty = true;
    }

    pub fn cancelMcpAuth(self: *App) void {
        if (self.mcp_auth) |*task| task.deinit();
        self.mcp_auth = null;
        self.mcp_auth_url_shown = false;
    }

    fn finishMcpAuth(self: *App) void {
        const task = if (self.mcp_auth) |*task| task else return;
        if (!self.mcp_auth_url_shown and task.phase() == .awaiting_callback) {
            self.mcp_auth_url_shown = true;
            if (task.opener_failed) self.pushSystemMessage("Open this URL to authorize MCP server `{s}`:\n{s}", .{ task.name(), task.auth_url });
        }
        if (!task.isFinished()) return;
        defer {
            self.cancelMcpAuth();
            self.dirty = true;
        }
        switch (task.outcome) {
            .authorized, .no_auth_needed => {
                {
                    self.lua_vm.vm_mu.lockUncancelable(self.io);
                    defer self.lua_vm.vm_mu.unlock(self.io);
                    _ = self.lua_vm.enableMcp(task.name());
                }
                self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: authorized", .{task.name()}) catch {};
                self.reloadMcpTools() catch {};
            },
            .failed => self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: auth failed: {s}", .{ task.name(), task.err_kind.text() }) catch {},
        }
    }

    pub fn cancelSshConnect(self: *App) void {
        if (self.ssh_connect) |*task| task.deinit();
        self.ssh_connect = null;
    }

    pub fn startSshConnect(self: *App, user: []const u8, host: []const u8, cwd: []const u8) void {
        self.cancelSshConnect();
        self.exec_pool.clearSsh();
        if (!self.initSshTask(user, host, cwd, false)) return;
        self.toastSshConnecting(user, host);
        self.ssh_connect.?.start();
        self.dirty = true;
    }

    pub fn startSshUnlock(self: *App) void {
        if (self.input_mode != .passphrase) return;
        const pp = &self.input_mode.passphrase;
        if (pp.field.isEmpty()) {
            self.notifications.append(self.gpa, self.nowMillis(), "SSH: empty secret, canceled", .{}) catch {};
            self.returnToText();
            return;
        }
        self.cancelSshConnect();
        if (!self.initSshTask(pp.user, pp.host, pp.cwd, true)) {
            self.returnToText();
            return;
        }
        const task = &self.ssh_connect.?;
        const pass = pp.field.slice();
        const n = @min(pass.len, task.pass_buf.len);
        @memcpy(task.pass_buf[0..n], pass[0..n]);
        task.pass_len = n;
        self.returnToText();
        self.toastSshConnecting(task.user(), task.host());
        task.start();
        self.dirty = true;
    }

    fn toastSshConnecting(self: *App, user: []const u8, host: []const u8) void {
        self.notifications.append(self.gpa, self.nowMillis(), "SSH: connecting to {s}@{s}", .{ user, host }) catch {};
    }

    fn initSshTask(self: *App, user: []const u8, host: []const u8, cwd: []const u8, unlock: bool) bool {
        if (user.len > r.ssh.SshConnectTask.MAX_USER or host.len > r.ssh.SshConnectTask.MAX_HOST or cwd.len > r.ssh.SshConnectTask.MAX_CWD or
            user.len + host.len + cwd.len > self.passphrase_args_buf.len)
        {
            self.notifications.append(self.gpa, self.nowMillis(), "SSH: target too long", .{}) catch {};
            return false;
        }
        self.ssh_connect = .{ .pool = self.exec_pool, .gpa = self.gpa, .unlock = unlock };
        const task = &self.ssh_connect.?;
        @memcpy(task.user_buf[0..user.len], user);
        task.user_len = user.len;
        @memcpy(task.host_buf[0..host.len], host);
        task.host_len = host.len;
        @memcpy(task.cwd_buf[0..cwd.len], cwd);
        task.cwd_len = cwd.len;
        return true;
    }

    fn finishSshConnect(self: *App) void {
        const task = if (self.ssh_connect) |*task| task else return;
        if (!task.isFinished()) return;
        defer {
            task.deinit();
            self.ssh_connect = null;
            self.dirty = true;
        }
        switch (task.outcome) {
            .connected => {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = r.util.expandHomePath(task.cwd(), task.home(), &cwd_buf);
                self.exec_pool.setSsh(task.user(), task.host(), cwd, task.control()) catch {
                    self.notifications.append(self.gpa, self.nowMillis(), "SSH: failed: failed to allocate target", .{}) catch {};
                    return;
                };
                if (task.home_len > 0) self.setRemoteHome(task.home());
                self.notifications.append(self.gpa, self.nowMillis(), "SSH mode enabled: {s}@{s}", .{ task.user(), task.host() }) catch {};
            },
            .need_pass => {
                if (self.input_mode == .text) {
                    self.enterPassphrase(task.user(), task.host(), task.cwd());
                } else {
                    self.notifications.append(self.gpa, self.nowMillis(), "SSH: auth refused (retry /ssh for password)", .{}) catch {};
                }
            },
            .failed => self.notifications.append(self.gpa, self.nowMillis(), "SSH: failed: {s}", .{r.ssh.truncateUtf8(task.reason(), 96)}) catch {},
        }
    }

    fn finishMcpLoad(self: *App, wait: bool) !void {
        const task = if (self.mcp_load) |*task| task else return;
        if (!wait and !task.isFinished()) return;
        task.wait();
        task.deinit();
        self.mcp_load = null;

        {
            self.lua_vm.vm_mu.lockUncancelable(self.io);
            defer self.lua_vm.vm_mu.unlock(self.io);
            for (self.mcp_manager.registeredTools()) |entry| try self.context_factory.add(entry.tool, entry.flags);
            try self.refreshLiveAgentTools();
        }
        _ = self.event_bus.emit(self, .mcp_tools_reloaded);
        self.dirty = true;
        for (self.mcp_manager.serverStatuses()) |*status| switch (status.state) {
            .loaded => if (status.oauth) self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: loaded", .{status.name()}) catch {},
            .auth_required => self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: auth required, run /mcp connect {s}", .{ status.name(), status.name() }) catch {},
            .failed => self.notifications.append(self.gpa, self.nowMillis(), "MCP {s}: failed: {s}", .{ status.name(), status.reason() }) catch {},
        };
        if (self.mcp_reload_pending) {
            self.mcp_reload_pending = false;
            try self.reloadMcpTools();
        }
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
                try self.context_factory.refreshAgentTools(agent, self.toolBase(.{ .index = @intCast(index), .generation = slot.generation }));
            }
        }
    }

    pub fn refreshLiveAgentModels(self: *App, agent_type: r.ContextFactory.AgentType) !void {
        const config = switch (self.context_factory.buildAgentApiConfig(agent_type, &self.config, self.exec_pool.env)) {
            .config => |config| config,
            .diagnostic => return error.InvalidProviderConfiguration,
        };
        for (&self.registry.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;
            const agent = &slot.agent.?;
            if (agent.type_idx != @backingInt(agent_type)) continue;
            agent.updateModel(config) catch |err| {
                std.log.scoped(.app).warn("model update failed for agent `{s}`: {s}", .{ agent.name, @errorName(err) });
            };
        }
    }

    pub fn requestLuaReload(self: *App) void {
        self.lua_reload_requested.store(true, .release);
    }

    pub fn markLuaReloadDone(self: *App) void {
        self.lua_reload_requested.store(false, .release);
    }

    pub fn setReadImageMax(self: *App, width: u32, height: u32) void {
        self.read_image_max.store(packReadImageMax(width, height), .release);
    }

    pub fn readImageMax(self: *const App) r.image.Size {
        const value = self.read_image_max.load(.acquire);
        return .{
            .width = @truncate(value >> 32),
            .height = @truncate(value),
        };
    }

    pub fn resetReadImageMax(self: *App) void {
        self.setReadImageMax(READ_IMAGE_MAX, READ_IMAGE_MAX);
    }

    fn packReadImageMax(width: u32, height: u32) u64 {
        return @as(u64, width) << 32 | height;
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
        try self.context_factory.refreshAgentToolsLive(agent, self.toolBase(id));
    }

    pub fn pushSystemMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.sessionAlloc();
        const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
        const parts = alloc.alloc(TimelinePart, 1) catch return;
        parts[0] = .{ .message = text };

        self.appendTimelineEntry(alloc, .{
            .role = .system,
            .parts = parts,
        }) catch return;
        self.dirty = true;
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
            "Agent(s) without a bound model: {s}. Bind `model` per agent with `blitz.set_agent_model(AGENT_TYPE, model)` or `model =` in `blitz.add_agent`.",
            .{joined},
        );
        self.notifications.append(self.gpa, self.nowMillis(), "Agent(s) without a bound model: {s}", .{joined}) catch {};
    }

    pub fn mainAgent(self: *const App) ?*r.agent.Agent {
        const id = self.main_agent_id orelse return null;
        return self.registry.get(id);
    }

    pub fn mainSkillTarget(self: *const App) ?r.skills.Target {
        if (self.mainAgent()) |agent| {
            const def = self.context_factory.agentTypeAt(agent.type_idx) orelse return null;
            return .{ .name = def.name, .is_main = true, .filter = def.skills };
        }
        const def = self.context_factory.agentTypeAt(@backingInt(r.ContextFactory.AgentType.general)) orelse return null;
        return .{ .name = def.name, .is_main = true, .filter = def.skills };
    }

    pub fn configureAgent(self: *const App, id: r.AgentId, agent: *r.agent.Agent) !void {
        try @constCast(self).rememberAgentMetadata(id, agent.name, agent.task_description);
        if (!self.journal_restoring and agent.journal == null) {
            agent.journal = self.session_store;
            agent.journal_id = id.pack();
            try agent.publishMetadata(.agent);
            @constCast(self).publishPendingToolLinks(id);
            if (agent.history().len > 0) if (agent.journal) |store| try store.publish(id.pack(), .append, agent.history());
        }
        try self.context_factory.configureAgent(agent, self.toolBase(id));
        agent.context_limit = self.default_context_limit;
        agent.lua_reload_generation_seen = self.lua_reload_generation.load(.monotonic);
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
            .cwd = if (agent.cwd.len > 0) agent.cwd else self.cwd,
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

    pub fn fillAgentInfo(self: *App, request: *r.permissions.Request) void {
        const agent = self.registry.get(request.agent_id) orelse {
            request.agent = .{};
            return;
        };
        const def = self.context_factory.agentTypeAt(agent.type_idx);
        const alloc = self.sessionAlloc();
        request.agent = .{
            .name = alloc.dupe(u8, if (def) |d| d.name else agent.name) catch "",
            .description = alloc.dupe(u8, if (def) |d| d.description else "") catch "",
            .task = alloc.dupe(u8, agent.task_description) catch "",
            .cwd = alloc.dupe(u8, agent.cwd) catch "",
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
                _ = self.event_bus.emit(self, .{ .compaction_started = agent_id });
            }
            return;
        }

        if (self.compaction_indicator_active) self.compaction_indicator_active = false;

        const compacted_count = agent.compaction.completion_count.load(.acquire);
        if (compacted_count == 0 or compacted_count == self.compaction_completion_seen_count) return;

        self.compaction_completion_seen_count = compacted_count;
        _ = self.event_bus.emit(self, .{ .compaction_complete = agent_id });
        self.pushSystemMessage("compact complete", .{});
        self.dirty = true;
    }

    fn buildReminderOpaque(ptr: ?*anyopaque, agent: *r.agent.Agent) anyerror!?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        return try self.injection_hooks.build(self, agent);
    }

    pub fn resolveActivePermission(self: *App, state: r.permissions.State) void {
        const g = self.permission_queue.lock(self.io);
        defer g.unlock();
        const perm = self.active_permission orelse return;
        self.active_permission = null;
        self.enterPermSelect();
        const live = perm.state == .pending and self.registry.state(perm.agent_id) == .active;
        if (!live and state == .answers) state.answers.deinit();
        if (perm.state != .pending) return;
        self.settlePermission(perm, if (live) state else .denied);
    }

    /// Invoke the Lua permission hook for `perm` under vm_mu. Returns the
    /// hook decision, or null when the hook is absent or returns "fallback".
    /// A hook error denies with the reason in the message.
    pub fn luaPermissionDecision(self: *App, perm: *r.permissions.Request) ?r.permissions.State {
        return self.lua_vm.permissionHookDecision(perm);
    }

    pub fn setInput(self: *App, text: []const u8) void {
        self.input.set(text);
        self.input_desired_col = null;
        self.syncCompletion();
    }

    pub fn moveCursorVertical(self: *App, delta: i32) bool {
        const content_width = r.view.composer.inputContentWidth(self.view.widget_frame_input_area.width);
        const width: usize = switch (self.input_mode) {
            .perm_message => r.view.permission.permFieldTextWidth(self, content_width -| 2),
            else => r.view.composer.inputTextWidth(content_width, r.view.composer.modePromptCols(&self.input_mode)),
        };
        if (width == 0) return false;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        switch (self.input_mode) {
            .text => self.moveMaskedVertical(alloc, &self.input, width, delta),
            .perm_message => |*pm| self.moveMaskedVertical(alloc, &pm.field, width, delta),
            .passphrase => |*pp| moveFieldVertical(self, alloc, &pp.field, width, delta),
            .wizard => |*w| {
                const f = w.activeText() orelse return false;
                moveFieldVertical(self, alloc, f, width, delta);
            },
            else => return false,
        }
        return true;
    }

    fn moveMaskedVertical(self: *App, alloc: std.mem.Allocator, f: *r.tui.Field(8192), width: usize, delta: i32) void {
        const buf = f.slice();
        if (f.cursor > buf.len) f.cursor = buf.len;
        const display: r.clipboard.Display = r.clipboard.toDisplay(alloc, buf, f.cursor) catch
            .{ .text = buf, .cursor = f.cursor };
        if (self.verticalFieldTarget(alloc, display, width, delta)) |target| {
            f.cursor = r.clipboard.fromDisplayPos(buf, target);
        }
    }

    fn verticalFieldTarget(
        self: *App,
        alloc: std.mem.Allocator,
        display: r.clipboard.Display,
        width: usize,
        delta: i32,
    ) ?usize {
        var l = r.tui.input_layout.layout(alloc, display.text, display.cursor, width, .{}, .{}, null) catch return null;
        defer l.deinit(alloc);
        const desired: usize = self.input_desired_col orelse l.cursor.col;
        self.input_desired_col = desired;
        return r.tui.input_layout.verticalTarget(&l, delta, desired);
    }

    pub fn appendBytes(self: *App, bytes: []const u8) void {
        self.input_desired_col = null;
        _ = self.fieldOp(.insert, bytes);
        self.syncCompletion();
    }

    pub fn pasteField(self: *App) ?*r.tui.Field(8192) {
        return switch (self.input_mode) {
            .text => &self.input,
            .perm_message => |*pm| &pm.field,
            else => null,
        };
    }

    pub fn deleteChar(self: *App) void {
        self.input_desired_col = null;
        const f = self.pasteField() orelse return;

        // Pasted image: deleting anywhere inside (or right after) the masked
        // `[Image]` token removes the whole link.
        if (r.clipboard.findPasteAt(f.slice(), f.cursor)) |rg| {
            f.deleteRange(rg.start, rg.end);
        } else {
            f.backspace();
        }
        self.syncCompletion();
    }

    pub fn deleteForwardChar(self: *App) void {
        self.input_desired_col = null;
        const f = self.pasteField() orelse return;
        if (r.clipboard.findPasteAt(f.slice(), f.cursor + 1)) |rg| {
            if (rg.start == f.cursor) {
                f.deleteRange(rg.start, rg.end);
                self.syncCompletion();
                return;
            }
        }
        f.deleteForward();
        self.syncCompletion();
    }

    /// The input as rendered: pasted-image URLs are masked with `[Image]` and
    /// `cursor` is remapped to the display position.
    pub fn displayInput(self: *const App, arena: std.mem.Allocator) r.clipboard.Display {
        return r.clipboard.toDisplay(arena, self.input.slice(), self.input.cursor) catch {
            return .{ .text = self.input.slice(), .cursor = self.input.cursor };
        };
    }

    /// Ctrl+V handler. When the system clipboard holds an image, saves it to a
    /// temp file and embeds its `file://` URL (masked as `[Image]`) instead of
    /// inserting the raw paste text. Reports the outcome with a notification.
    fn generalAgentVision(self: *App) bool {
        for (&self.registry.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .reserved) continue;
            const agent = &slot.agent.?;
            if (agent.type_idx != @backingInt(r.ContextFactory.AgentType.general)) continue;
            return agent.flags.vision;
        }
        return self.context_factory.agentVision(&self.config, .general);
    }

    fn pasteVision(self: *App) bool {
        if (self.active_permission) |perm| {
            if (self.registry.get(perm.agent_id)) |agent| return agent.flags.vision;
        }
        return self.generalAgentVision();
    }

    pub fn pasteImage(self: *App) void {
        const f = self.pasteField() orelse return;
        if (!self.pasteVision()) {
            self.notifications.append(self.gpa, self.nowMillis(), "Current model does not support images", .{}) catch {};
            return;
        }
        const img = r.clipboard.readImage(self.sessionAlloc(), self.exec_pool) catch null;
        if (img) |image| {
            defer self.sessionAlloc().free(image.data);
            const url = r.clipboard.saveImage(self.io, self.sessionAlloc(), image.data, image.ext) catch null;
            if (url) |u| {
                self.insertPasteUrl(f, u);
                self.notifications.append(self.gpa, self.nowMillis(), "Image pasted", .{}) catch {};
                return;
            }
            self.notifications.append(self.gpa, self.nowMillis(), "Failed to save clipboard image", .{}) catch {};
            return;
        }
        self.notifications.append(self.gpa, self.nowMillis(), "Clipboard holds no image", .{}) catch {};
    }

    /// Terminal paste event handler. Pastes the clipboard image if one is
    /// present, otherwise appends the raw paste `text`.
    pub fn pasteImageOrText(self: *App, text: []const u8) void {
        const f = self.pasteField() orelse return;
        if (!self.pasteVision()) {
            self.appendPasteText(f, text);
            return;
        }
        const img = r.clipboard.readImage(self.sessionAlloc(), self.exec_pool) catch null;
        if (img) |image| {
            defer self.sessionAlloc().free(image.data);
            if (r.clipboard.saveImage(self.io, self.sessionAlloc(), image.data, image.ext) catch null) |u| {
                self.insertPasteUrl(f, u);
            }
            return;
        }
        self.appendPasteText(f, text);
    }

    fn insertPasteUrl(self: *App, f: *r.tui.Field(8192), url: []const u8) void {
        self.input_desired_col = null;
        f.insert(url);
        self.syncCompletion();
        self.dirty = true;
    }

    fn appendPasteText(self: *App, f: *r.tui.Field(8192), text: []const u8) void {
        if (self.input_mode == .text) {
            self.appendPathRef(text);
            return;
        }
        self.input_desired_col = null;
        f.insert(text);
    }

    fn appendPathRef(self: *App, text: []const u8) void {
        if (text.len > 0 and text[0] == '/') self.appendBytes("@");
        self.appendBytes(text);
    }

    pub fn inputSlice(self: *const App) []const u8 {
        return self.input.slice();
    }

    pub fn pushHistory(self: *App, store_dir: std.Io.Dir, text: []const u8) void {
        if (text.len == 0) return;
        r.prompt_history.append(self.gpa, self.io, store_dir, text) catch |err| {
            log.warn("prompt history append failed: {s}", .{@errorName(err)});
        };
        const allocator = self.gpa;
        const dupe = allocator.dupe(u8, text) catch return;
        if (self.history.items.len >= r.prompt_history.MAX_ENTRIES) {
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

    pub fn historyUp(self: *App) bool {
        if (self.input_mode != .text) return false;
        if (self.history_cursor == 0) return true;
        if (self.running) return true;
        self.history_cursor -= 1;
        self.input.set(self.history.items[self.history_cursor].text);
        self.input_desired_col = null;
        self.syncCompletion();
        return true;
    }

    pub fn historyDown(self: *App) bool {
        if (self.input_mode != .text) return false;
        if (self.history_cursor >= self.history.items.len) return true;
        if (self.running) return true;
        self.history_cursor += 1;
        if (self.history_cursor < self.history.items.len) {
            self.input.set(self.history.items[self.history_cursor].text);
        } else {
            self.input.clear();
        }
        self.input_desired_col = null;
        self.syncCompletion();
        return true;
    }

    pub fn undoLastTurn(self: *App) void {
        if (self.input_mode != .text) return;
        if (self.running) return;
        if (self.timeline.items.len == 0) return;

        var start = self.timeline.items.len;
        while (start > 0) {
            start -= 1;
            if (self.timeline.items[start].role == .user) break;
        }
        if (self.timeline.items[start].role != .user) return;
        const text = timelineEntryUserText(self.timeline.items[start]) orelse return;

        const agent = self.mainAgent() orelse return;
        const history = agent.history();
        var cut: ?usize = null;
        for (history, 0..) |message, index| {
            if (message.role != .user) continue;
            if (r.session.isReminderText(message.text())) continue;
            if (r.compact.isSummaryMessage(message)) continue;
            cut = index;
        }
        const turn_start = cut orelse return;
        if (self.session_store) |store| store.drainDisplay(self) catch return;
        agent.replaceMessages(history[0..turn_start], .rewind) catch return;
        if (self.session_store) |store| store.enqueue(.{ .kind = .timeline_truncate, .length = start }) catch return;

        self.timeline.shrinkRetainingCapacity(start);
        self.preview_reference = null;
        if (self.view.entry_cache.items.len > start) {
            self.view.entry_cache.shrinkRetainingCapacity(start);
        }
        if (text.len > 0) {
            self.input.set(text);
            self.input_desired_col = null;
        }

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

    pub fn loadHistory(self: *App, store_dir: std.Io.Dir) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const loaded = r.prompt_history.load(arena.allocator(), self.io, store_dir) catch return;
        for (loaded) |entry| {
            const dupe = self.gpa.dupe(u8, entry.text) catch return;
            self.history.append(self.gpa, .{
                .text = dupe,
                .timestamp = entry.timestamp,
            }) catch {
                self.gpa.free(dupe);
                return;
            };
        }
        self.history_cursor = self.history.items.len;
    }

    pub fn dropStreamingPreview(self: *App) void {
        self.streaming_entry = null;
        self.preview_reference = null;
        self.sdk_preview_parts = .empty;
        _ = self.arena_streaming_snapshot.reset(.free_all);
        _ = self.arena_streaming_preview.reset(.free_all);
    }

    fn timelineCoversText(shown: []const TimelinePart, kind: SdkPreviewPart.Kind, text: []const u8) bool {
        if (text.len == 0) return true;
        for (shown) |part| switch (part) {
            .message => |available| if (kind == .message and std.mem.indexOf(u8, available, text) != null) return true,
            .thinking => |available| if (kind == .thinking and std.mem.indexOf(u8, available, text) != null) return true,
            else => {},
        };
        return false;
    }

    fn timelineCoversCall(shown: []const TimelinePart, call_id: []const u8) bool {
        for (shown) |part| {
            if (part == .tool_call and std.mem.eql(u8, part.tool_call.call_id, call_id)) return true;
        }
        return false;
    }

    fn timelinePartsCovered(shown: []const TimelinePart, parts: []const TimelinePart) bool {
        for (parts) |part| switch (part) {
            .message => |text| if (!timelineCoversText(shown, .message, text)) return false,
            .thinking => |text| if (!timelineCoversText(shown, .thinking, text)) return false,
            .tool_call => |call| if (!timelineCoversCall(shown, call.call_id)) return false,
            .plain_text, .diff => return false,
        };
        return true;
    }

    pub fn adoptDisplayedPreview(self: *App, shown: []const TimelinePart) void {
        if (self.streaming_entry) |entry| {
            if (!timelinePartsCovered(shown, entry.parts)) return;
            self.dropStreamingPreview();
        } else if (self.sdk_preview_parts.items.len > 0) {
            return;
        }
        if (self.preview_reference == null) self.preview_reference = shown;
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
        const is_main = if (self.main_agent_id) |id| id.pack() == agent_id.pack() else if (self.registry.get(agent_id)) |agent| !agent.background else false;
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
                for (step.tool_results) |result| {
                    try status.ptr.setResult(alloc, agent_id, result.tool_call_id, result.is_error, result.image_url);
                    if (result.image_url.len > 0) {
                        _ = self.inline_images.remember(self.gpa, agent_id, result.tool_call_id, result.image_url);
                        if (self.kitty_graphics and self.flags.inline_images) {
                            _ = self.inline_images.request(self.gpa, agent_id, result.tool_call_id, result.image_url, &self.inline_images_ready);
                        }
                    }
                }
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
                const parts = try alloc.alloc(TimelinePart, 1);
                parts[0] = .{ .plain_text = message };
                try self.appendTimelineEntry(alloc, .{ .role = .agent, .parts = parts });
            },
            .complete => |result| {
                if (!is_main or self.session_store != null) return;
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
                    try self.appendTimelineEntry(alloc, .{ .role = .agent, .parts = parts });
                    return;
                }
            },
            .failed => |err| {
                const canceled = err == error.Canceled;
                if (self.registry.get(agent_id)) |agent| {
                    if (agent.shouldAutoRetry(err)) {
                        if (is_main) {
                            self.dropStreamingPreview();
                            self.sdk_run_rendered_steps = 0;
                        }
                        return;
                    }
                }
                if (!canceled) _ = self.event_bus.emit(self, .{ .agent_failed = .{ .id = agent_id, .err = @errorName(err) } });
                if (!is_main) return;
                self.dropStreamingPreview();
                if (canceled) return;
                const parts = try alloc.alloc(TimelinePart, 1);
                parts[0] = .{ .plain_text = try std.fmt.allocPrint(alloc, "Agent failed: {s}", .{@errorName(err)}) };
                try self.appendTimelineEntry(alloc, .{ .role = .agent, .parts = parts });
            },
        }
        self.dirty = true;
    }

    fn refreshSdkPreview(self: *App, agent_id: r.AgentId) !void {
        self.streaming_entry = null;
        _ = self.arena_streaming_snapshot.reset(.free_all);
        const alloc = self.arena_streaming_snapshot.allocator();
        var parts: std.ArrayList(TimelinePart) = .empty;
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
            return;
        }
        if (self.preview_reference) |shown| {
            if (timelinePartsCovered(shown, parts.items)) {
                return;
            }
        }
        self.streaming_entry = .{ .role = .agent, .parts = try parts.toOwnedSlice(alloc) };
    }

    pub fn appendTimelineEntry(self: *App, alloc: std.mem.Allocator, entry: TimelineEntry) !void {
        if (!self.journal_restoring) if (self.session_store) |store| {
            try store.drainDisplay(self);
            try store.enqueue(.{ .kind = .timeline_append, .entry = entry });
        };
        try self.timeline.append(alloc, entry);
    }

    pub fn appendAgentHistory(self: *App, agent_id: r.AgentId, start: usize, skip: usize) !void {
        const agent = self.registry.get(agent_id) orelse return;
        try self.appendSdkHistory(agent_id, agent.history(), start, skip);
    }

    fn appendSdkHistory(self: *App, agent_id: r.AgentId, messages: []const r.sdk.Message, start: usize, skip: usize) !void {
        if (self.session_store != null) return;
        const alloc = self.sessionAlloc();
        var remaining = skip;
        for (messages[@min(start, messages.len)..]) |message| {
            if (message.role != .assistant) continue;
            if (remaining > 0) {
                remaining -= 1;
                continue;
            }
            const parts = renderSdkParts(alloc, agent_id, message.parts()) orelse continue;
            try self.appendTimelineEntry(alloc, .{ .role = .agent, .parts = parts });
        }
    }

    /// Send a user prompt to the main agent: emit hook, queue messages, run.
    /// Shared by the TUI Enter handler and headless mode.
    pub fn sendPrompt(self: *App, io: std.Io, parts: []const r.sdk.Part, timeline_text: []const u8) !void {
        try self.waitForMcpTools();
        self.preview_reference = null;
        const alloc = self.sessionAlloc();
        const timeline_entry = try TimelineEntry.userMessageSimple(alloc, .user, timeline_text);
        _ = self.event_bus.emit(self, .{ .user_message_sent = timeline_text });

        if (self.main_agent_id) |id| {
            try self.appendTimelineEntry(alloc, timeline_entry);
            const agent = self.registry.get(id).?;
            try agent.queueMessages(&.{.{ .role = .user, .content = parts }});
            self.sdk_run_rendered_steps = 0;
            if (!agent.isBusy()) {
                try self.registry.run(id, .{ .max_steps = std.math.maxInt(usize) });
                _ = self.event_bus.emit(self, .{ .agent_started = .{ .id = id, .fresh = false } });
            }
        } else {
            const id = self.registry.reserve(null).?;
            self.cmd_queue.append(io, .{
                .spawn_agent = .{
                    .agent_id = id,
                    .agent_type = @backingInt(r.ContextFactory.AgentType.general),
                    .prompt = parts,
                    .timeline_entry = timeline_entry,
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
        if (self.session_store != null) {
            self.dropStreamingPreview();
            return;
        }
        const entry = self.streaming_entry orelse {
            self.dropStreamingPreview();
            return;
        };
        const alloc = self.sessionAlloc();
        try self.appendTimelineEntry(alloc, try r.util.deepClone(TimelineEntry, entry, alloc));
        self.sdk_preview_flushed = true;
        self.dropStreamingPreview();
    }

    pub fn persistDiffToHistory(self: *App, diff: r.permissions.ToolDiff) !void {
        try self.flushSdkPreview();
        const alloc = self.sessionAlloc();
        var parts = try alloc.alloc(r.app.TimelinePart, 1);
        parts[0] = try diffTimelinePart(alloc, diff);
        try self.appendTimelineEntry(alloc, .{
            .role = .agent,
            .parts = parts,
        });
    }

    pub fn queueDiffToHistory(self: *App, diff: r.permissions.ToolDiff) !void {
        const g = self.pending_diffs.lock(self.io);
        defer g.unlock();
        const path = try self.gpa.dupe(u8, diff.path);
        errdefer self.gpa.free(path);
        const before: ?[]const u8 = if (diff.before) |b| try self.gpa.dupe(u8, b) else null;
        errdefer if (before) |b| self.gpa.free(b);
        const after = try self.gpa.dupe(u8, diff.after);
        errdefer self.gpa.free(after);
        try g.ptr.append(self.gpa, .{ .path = path, .before = before, .after = after });
    }

    pub fn drainPendingDiffs(self: *App) usize {
        const g = self.pending_diffs.lock(self.io);
        const items = g.ptr.toOwnedSlice(self.gpa) catch {
            g.unlock();
            return 0;
        };
        g.unlock();
        for (items) |d| {
            self.persistDiffToHistory(d) catch {};
            self.gpa.free(d.path);
            if (d.before) |b| self.gpa.free(b);
            self.gpa.free(d.after);
        }
        self.gpa.free(items);
        return items.len;
    }

    pub fn clearPendingDiffs(self: *App) void {
        const g = self.pending_diffs.lock(self.io);
        defer g.unlock();
        for (g.ptr.items) |d| {
            self.gpa.free(d.path);
            if (d.before) |b| self.gpa.free(b);
            self.gpa.free(d.after);
        }
        g.ptr.clearRetainingCapacity();
    }
};

pub fn diffTimelinePart(alloc: std.mem.Allocator, diff: r.permissions.ToolDiff) !TimelinePart {
    var lines = std.ArrayList(r.tui.DiffLine).empty;
    r.diff.emitDiffLines(&lines, diff, alloc);
    return .{ .diff = .{
        .path = try alloc.dupe(u8, diff.path),
        .diff_lines = try lines.toOwnedSlice(alloc),
    } };
}

const RegistryDrainContext = struct {
    app: *App,
    id: r.AgentId,
};

fn applyRegistryEvent(ctx: ?*anyopaque, event: r.agent_run.Event) void {
    const value: *RegistryDrainContext = @ptrCast(@alignCast(ctx.?));
    value.app.dirty = true;
    value.app.applyRunEvent(value.id, event) catch |err| {
        switch (event) {
            .tool => |chunk| log.err("failed to apply tool stream event type={s} id={s} name={s}: {s}", .{ @tagName(chunk.type), chunk.tool_call_id, chunk.tool_name, @errorName(err) }),
            else => log.err("failed to apply {s} stream event: {s}", .{ @tagName(event), @errorName(err) }),
        }
    };
}

pub const TimelineEntry = struct {
    role: TimelineRole,
    parts: []TimelinePart,

    pub fn userMessageSimple(alloc: std.mem.Allocator, role: TimelineRole, msg: []const u8) !TimelineEntry {
        var parts = try alloc.alloc(TimelinePart, 1);
        parts[0] = .{ .message = msg };
        return .{ .role = role, .parts = parts };
    }
};

pub const TimelinePart = union(enum) {
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

pub fn timelineEntryUserText(entry: TimelineEntry) ?[]const u8 {
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

pub fn renderSdkParts(
    alloc: std.mem.Allocator,
    agent_id: r.AgentId,
    parts: []const r.sdk.Part,
) ?[]TimelinePart {
    var out: std.ArrayList(TimelinePart) = .empty;
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

test "finished retained agents survive reaping and take queued messages" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    const lua_vm = try r.lua.LuaVm.init(std.testing.allocator);
    defer lua_vm.deinit();
    app.lua_vm = lua_vm;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.timeline = .empty;
    app.streaming_entry = null;
    app.preview_reference = null;
    app.sdk_preview_parts = .empty;
    app.sdk_preview_flushed = false;
    app.sdk_usage = .{};
    app.tool_status_entries = .{};
    app.main_agent_id = null;
    app.event_bus = .{};
    app.dirty = false;
    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    app.registry = &registry;

    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: r.agent_run.Event) void {}
    };
    const child_id = registry.reserve(null).?;
    const child = try registry.activate(child_id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{ .identity = .{ .type_idx = 1, .name = "child", .cwd = "/tmp" } });
    try registry.run(child_id, .{ .max_steps = 0 });
    while (registry.state(child_id) == .active) {
        _ = registry.drain(child_id, 64, null, Fixture.discard);
        _ = registry.reap(child_id);
        if (registry.state(child_id) == .active) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try app.handleReapedAgent(child_id);

    try std.testing.expectEqual(r.agent_registry.SlotState.complete, registry.state(child_id).?);
    try std.testing.expect(registry.get(child_id) != null);
    try std.testing.expect(child.reported_task_done);
    try app.handleReapedAgent(child_id);
    try std.testing.expectEqual(@as(usize, 0), app.timeline.items.len);

    try child.queueMessages(&.{r.sdk.UserMessage("next question")});
    try app.handleReapedAgent(child_id);
    try std.testing.expectEqual(r.agent_registry.SlotState.active, registry.state(child_id).?);
    try std.testing.expect(!child.reported_task_done);
    while (registry.state(child_id) == .active) {
        _ = registry.drain(child_id, 64, null, Fixture.discard);
        _ = registry.reap(child_id);
        if (registry.state(child_id) == .active) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }

    app.detachMainAgent(child_id);
    try std.testing.expect(registry.state(child_id) == null);
    try std.testing.expectEqual(@as(usize, 0), app.timeline.items.len);
}

test "background agent result is collected" {
    var agent = try r.agent.Agent.init(std.testing.allocator, std.testing.io, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const parts = [_]r.sdk.Part{ r.sdk.Part.textPart("result"), r.sdk.Part.textPart(" done") };
    try agent.setMessages(&.{.{ .role = .assistant, .content = &parts }});

    var app: App = undefined;
    app.gpa = std.testing.allocator;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(std.testing.allocator);
    try app.collectBackgroundResult(&agent, &collected);
    try std.testing.expectEqualStrings("result done", collected.items);
}

fn lineText(arena: std.mem.Allocator, line: r.tui.Line) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (line.spans.items) |span| try out.appendSlice(arena, span.content);
    return out.items;
}

fn activateTestAgent(reg: *r.agent_registry.Registry, name: []const u8) !r.AgentId {
    return activateTestAgentWithParent(reg, name, null);
}

fn activateTestAgentWithParent(reg: *r.agent_registry.Registry, name: []const u8, parent: ?r.AgentId) !r.AgentId {
    const id = reg.reserve(parent).?;
    _ = try reg.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{ .identity = .{ .name = name, .cwd = "/tmp", .parent = if (parent) |pid| pid.pack() else null } });
    return id;
}

const PathCompletionFixture = struct {
    tmp: std.testing.TmpDir = undefined,
    env: std.process.Environ.Map = undefined,
    pool: r.exec.CmdPool = undefined,
    app: App = undefined,

    fn init(f: *PathCompletionFixture) !void {
        const testing = std.testing;
        f.tmp = testing.tmpDir(.{});
        f.env = try std.process.Environ.createMap(testing.environ, testing.allocator);
        f.pool = r.exec.CmdPool.init(testing.allocator, testing.io, &f.env);
        f.app = undefined;
        f.app.io = testing.io;
        f.app.gpa = testing.allocator;
        f.app.arena_app = std.heap.ArenaAllocator.init(testing.allocator);
        f.app.arena_session = std.heap.ArenaAllocator.init(testing.allocator);
        f.app.exec_pool = &f.pool;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try f.tmp.dir.realPathFile(testing.io, ".", &buf);
        f.app.cwd = try f.app.appAlloc().dupe(u8, buf[0..root_len]);
        f.app.input_mode = .{ .text = .{} };
        f.app.input = .{};
        f.app.path_completion = .{};
    }

    fn deinit(f: *PathCompletionFixture) void {
        f.app.path_completion.cache.clear(f.app.appAlloc());
        f.app.arena_session.deinit();
        f.app.arena_app.deinit();
        f.pool.deinit();
        f.env.deinit();
        f.tmp.cleanup();
    }

    fn waitForDirList(f: *PathCompletionFixture, dir: []const u8) !void {
        var waited: usize = 0;
        while (f.app.path_completion.cache.find(dir) == null and waited < 200) : (waited += 1) {
            f.app.tickPathCompletion();
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }
};

test "path completion probes dirs and lists entries" {
    const testing = std.testing;
    var f: PathCompletionFixture = .{};
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDir(testing.io, "sub", .default_dir);
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "zz.txt", .data = "x" });

    f.app.input.set("./");
    f.app.input.cursor = 2;
    try f.waitForDirList(".");
    try testing.expect(f.app.path_completion.cache.find(".") != null);

    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    const rows = r.view.completion.pathCompletions(&f.app, frame.allocator());
    try testing.expect(rows.len >= 2);

    var saw_dir = false;
    var saw_file = false;
    for (rows.items[0..rows.len]) |row| {
        if (std.mem.eql(u8, row.text, "./sub/")) saw_dir = true;
        if (std.mem.eql(u8, row.text, "./zz.txt")) saw_file = true;
    }
    try testing.expect(saw_dir);
    try testing.expect(saw_file);
    try testing.expectEqualStrings("dir", rows.items[0].description.?);
}

test "command completion spans spaces in multi word commands" {
    const testing = std.testing;
    var app: App = undefined;
    app.io = testing.io;
    app.gpa = testing.allocator;
    const lua_vm = try r.lua.LuaVm.init(testing.allocator);
    defer lua_vm.deinit();
    app.lua_vm = lua_vm;
    var factory: r.ContextFactory = undefined;
    factory.ssh_aliases = .empty;
    factory.skills = .{};
    factory.agent_counter = 0;
    app.context_factory = &factory;
    app.main_agent_id = null;
    app.input_mode = .{ .text = .{} };
    app.input = .{};

    app.input.set("/mcp ");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    try testing.expect(app.completionIsOpen());

    app.input.set("/mcp co");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    try testing.expect(app.completionIsOpen());
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    const rows = r.view.completion.commandCompletions(&app, frame.allocator(), app.input.slice(), app.input.cursor);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("/mcp connect", rows.items[0].text);

    app.input.set("/mcp ");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    app.handleCompletion(.next);
    try testing.expectEqualStrings("/mcp connect", app.input.slice());
    app.handleCompletion(.next);
    try testing.expectEqualStrings("/mcp cancel", app.input.slice());
    app.handleCompletion(.accept);
    try testing.expectEqualStrings("/mcp cancel", app.input.slice());
    try testing.expect(!app.completionIsOpen());

    app.input.set("/mcp connect ");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    try testing.expect(!app.completionIsOpen());

    try lua_vm.mcp_entries.appendBounded(.{ .name = "linear", .tools_prefix = "linear" });
    try lua_vm.mcp_entries.appendBounded(.{ .name = "github", .tools_prefix = "github" });

    app.input.set("/mcp ");
    app.input.cursor = app.input.len;
    const mcp_rows = r.view.completion.commandCompletions(&app, frame.allocator(), app.input.slice(), app.input.cursor);
    try testing.expectEqual(@as(usize, 2), mcp_rows.len);

    app.input.set("/mcp connect ");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    try testing.expect(app.completionIsOpen());
    const server_rows = r.view.completion.commandCompletions(&app, frame.allocator(), app.input.slice(), app.input.cursor);
    try testing.expectEqual(@as(usize, 2), server_rows.len);

    app.input.set("/mcp connect gi");
    app.input.cursor = app.input.len;
    app.syncCompletion();
    app.handleCompletion(.accept);
    try testing.expectEqualStrings("/mcp connect github", app.input.slice());

    app.input.set("/mcp connect gixx");
    app.input.cursor = "/mcp connect gi".len;
    app.syncCompletion();
    app.handleCompletion(.accept);
    try testing.expectEqualStrings("/mcp connect github", app.input.slice());
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
    w.url.set(entry.default_url);
    w.key.set("sk-ant-secret");
    w.model.set(entry.models[0].name);

    app.wizardConfirm(tmp.dir);

    try std.testing.expect(app.input_mode == .text);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, r.wizard.PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tkey = \"sk-ant-secret\",\n") != null);
    const expected_name = try std.fmt.allocPrint(std.testing.allocator, "\tname = \"{s}\",\n", .{entry.models[0].name});
    defer std.testing.allocator.free(expected_name);
    try std.testing.expect(std.mem.indexOf(u8, contents, expected_name) != null);
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
    w.key.set("leftover");
    app.wizardSkip(tmp.dir);

    try std.testing.expect(app.input_mode == .text);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, r.wizard.PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "https://opencode.ai/zen/go/v1") != null);
    try tmp.dir.access(std.testing.io, r.wizard.DONE_MARKER, .{});
    for (w.key.buf[0.."leftover".len]) |ch| try std.testing.expectEqual(@as(u8, 0), ch);

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

test "markConfigTouched flags only paths inside the lua config dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(config_dir);
    const blitz_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/blitz.lua", .{config_dir});
    defer std.testing.allocator.free(blitz_abs);
    var app: App = undefined;
    app.io = io;
    app.gpa = std.testing.allocator;
    app.lua_config_dir = config_dir;
    app.lua_config_abs = blitz_abs;
    app.lua_reload_requested = .init(false);

    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var exec_pool = r.exec.CmdPool.init(std.testing.allocator, io, &env);
    defer exec_pool.deinit();
    var registry = r.agent_registry.Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve(null).?;
    _ = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{});
    const ctx: r.tools.ToolContext = .{
        .alloc = std.testing.allocator,
        .io = io,
        .base = .{
            .registry = &registry,
            .exec_pool = &exec_pool,
            .self_id = id,
            .cwd = "/tmp",
            .display = .{ .ctx = &app },
        },
    };

    const sibling = try std.fmt.allocPrint(std.testing.allocator, "{s}-backup/x.lua", .{config_dir});
    defer std.testing.allocator.free(sibling);
    r.tools.markConfigTouched(ctx, sibling);
    try std.testing.expectEqual(false, app.lua_reload_requested.load(.acquire));

    const inside = try std.fmt.allocPrint(std.testing.allocator, "{s}/x.lua", .{config_dir});
    defer std.testing.allocator.free(inside);
    r.tools.markConfigTouched(ctx, inside);
    try std.testing.expectEqual(true, app.lua_reload_requested.load(.acquire));

    app.markLuaReloadDone();
    r.tools.markConfigTouched(ctx, blitz_abs);
    try std.testing.expectEqual(true, app.lua_reload_requested.load(.acquire));
}

fn finishWaitingTestTurn(registry: *r.agent_registry.Registry, id: r.AgentId) !void {
    try registry.run(id, .{ .max_steps = 0 });
    registry.get(id).?.task.?.wait();
    while (registry.drain(id, 64, null, struct {
        fn discard(_: ?*anyopaque, _: r.agent_run.Event) void {}
    }.discard) != 0) {}
    try std.testing.expect(registry.reap(id));
}

fn askTestApp(app: *App, registry: *r.agent_registry.Registry) void {
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    app.active_permission = null;
    app.active_selection = null;
    app.selection_queue = .{ .value = .empty };
    app.permission_queue = .{ .value = .empty };
    app.pending_permissions = .empty;
    app.input_mode = .{ .perm_select = .{} };
    app.ask_session = null;
    app.ask_session_ticket = 0;
    app.theme = .default;
    app.view.auto_scroll = true;
    app.view.scroll_offset = 0;
    app.dirty = false;
    app.registry = registry;
}

test "ask permission widget resolves the batch through its session" {
    var app: App = undefined;
    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    askTestApp(&app, &registry);
    defer if (app.ask_session) |*s| s.deinit();
    const agent_id = try activateTestAgent(&registry, "main");

    const questions = [_]r.permissions.Question{
        .{ .header = "Auth", .question = "Which method?", .options = &.{ .{ .label = "OAuth" }, .{ .label = "API key" } } },
        .{ .header = "Regions", .question = "Which regions?", .options = &.{ .{ .label = "eu" }, .{ .label = "us" } }, .multi_select = true },
    };
    var req = r.permissions.Request{
        .agent_id = agent_id,
        .tool_name = "ask",
        .ticket = 1,
        .payload = .{ .ask = .{ .questions = &questions } },
    };
    try app.pending_permissions.append(std.testing.allocator, &req);
    defer app.pending_permissions.deinit(std.testing.allocator);
    app.active_permission = &req;

    const session = app.askSession().?;
    try std.testing.expectEqual(r.ask_session.Outcome.advance, session.enter());
    session.toggle();
    session.moveCursor(1);
    session.toggle();
    session.moveCursor(1);
    try std.testing.expectEqual(r.ask_session.Outcome.submitted, session.enter());

    app.submitAsk();
    try std.testing.expect(app.active_permission == null);
    try std.testing.expect(app.askSession() == null);
    try std.testing.expect(req.event.isSet());
    try std.testing.expectEqual(@as(usize, 0), app.pending_permissions.items.len);
    const answers = req.state.answers;
    try std.testing.expectEqual(@as(u8, 2), answers.len);
    try std.testing.expectEqual(@as(u8, 0b01), answers.items[0].mask);
    try std.testing.expectEqual(@as(u8, 0b11), answers.items[1].mask);
}

test "a new ask request at a reused address starts a fresh session" {
    var app: App = undefined;
    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    askTestApp(&app, &registry);
    defer if (app.ask_session) |*s| s.deinit();
    defer app.pending_permissions.deinit(std.testing.allocator);
    const agent_id = try activateTestAgent(&registry, "main");

    const questions = [_]r.permissions.Question{
        .{ .header = "Auth", .question = "Which method?", .options = &.{ .{ .label = "OAuth" }, .{ .label = "API key" } } },
    };
    // Same Request storage for both asks, like two ctx:ask calls in one frame.
    var req = r.permissions.Request{ .agent_id = agent_id, .ticket = 1, .payload = .{ .ask = .{ .questions = &questions } } };
    try app.pending_permissions.append(std.testing.allocator, &req);
    app.active_permission = &req;
    try std.testing.expectEqual(r.ask_session.Outcome.submitted, app.askSession().?.enter());
    app.submitAsk();

    req = .{ .agent_id = agent_id, .ticket = 2, .payload = .{ .ask = .{ .questions = &questions } } };
    try app.pending_permissions.append(std.testing.allocator, &req);
    app.active_permission = &req;
    const fresh = app.askSession().?;
    try std.testing.expect(!fresh.isResolved(0));
    try std.testing.expect(fresh.takeAnswers() == null);
}

test "waiting main agent shows waiting progress and cancel stops the tree" {
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = std.testing.allocator;
    app.arena_session = .init(std.testing.allocator);
    defer app.arena_session.deinit();
    app.arena_streaming_preview = .init(std.testing.allocator);
    defer app.arena_streaming_preview.deinit();
    app.arena_streaming_snapshot = .init(std.testing.allocator);
    defer app.arena_streaming_snapshot.deinit();
    app.timeline = .empty;
    app.preview_reference = null;
    app.sdk_run_rendered_steps = 0;
    app.event_bus = .{};
    app.active_permission = null;
    app.permission_queue = .{ .value = .empty };
    app.pending_permissions = .empty;
    app.active_selection = null;
    app.selection_queue = .{ .value = .empty };
    app.ask_session = null;
    app.ask_session_ticket = 0;
    app.input_mode = .{ .text = .{} };
    app.session_run_ns = 0;
    app.session_run_started_ns = 0;
    app.frame_count = 0;
    app.jobs_running = 0;
    app.theme = .default;
    var registry = r.agent_registry.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    app.registry = &registry;
    const parent_id = try activateTestAgent(&registry, "main");
    app.main_agent_id = parent_id;
    const child_id = registry.reserve(parent_id).?;
    const child = try registry.activate(child_id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{ .identity = .{ .parent = parent_id.pack(), .depth = 1 } });
    try finishWaitingTestTurn(&registry, parent_id);
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var pool = r.exec.CmdPool.init(std.testing.allocator, std.testing.io, &env);
    defer pool.deinit();
    app.exec_pool = &pool;
    const line = r.view.chrome.mainProgressLine(&app, app.sessionAlloc()).?;
    const text = try lineText(app.sessionAlloc(), line);
    try std.testing.expect(std.mem.startsWith(u8, text, "waiting for 1 agents ("));
    var command: r.cmd.Command = .cancel;
    try command.execute(&app);
    try std.testing.expectEqual(r.agent.Status.canceled, registry.get(parent_id).?.status);
    try std.testing.expectEqual(r.agent.Status.canceled, child.status);
    try std.testing.expectEqual(@as(u32, 0), registry.countActive());
}
