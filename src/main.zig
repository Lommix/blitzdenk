// ----------------------------------------------------------------
// Blitzdenk 0.1
// Copyright (c) 2026 Lorenz Mielke. All Rights Reserved.
// ----------------------------------------------------------------
const std = @import("std");
const builtin = @import("builtin");
const ct = @import("ctime");
const r = @import("root.zig");
const App = r.app.App;
const BlitzdenkCfg = r.config.BlitzdenkCfg;

const TimelineEntry = r.app.TimelineEntry;
const lua = r.lua;
const reg = r.ContextFactory;
const skills = r.skills;
const keys = r.keys;
const util = r.util;
const session = r.session;
const session_store = r.session_store;
const tui = r.tui;
const tools = r.tools;
const config_watch = @import("config_watch.zig");

// ----------------------------------------------------------------
pub const DEFAULT_CONFIG_PATH = r.defaults.CONFIG_DIR;
pub const DEFAULT_LUA_CONFIG = "blitz.lua";
const IO_THREAD_STACK_SIZE = 2 * 1024 * 1024;

test {
    std.testing.refAllDecls(@This());
}

// TUI owns stderr; Route std.log to debug.log in the cache dir instead. Using a raw POSIX fd with O_APPEND.
var debug_log_fd: std.posix.fd_t = -1;
fn openDebugLog(io: std.Io, env: *const std.process.Environ.Map) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const cache_dir = util.cacheDir(arena.allocator(), env) catch return;
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch return;
    const path = std.fmt.allocPrint(arena.allocator(), "{s}/debug.log", .{cache_dir}) catch return;
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    debug_log_fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o644) catch -1;
}

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (debug_log_fd < 0) return;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ts: std.posix.timespec = undefined;
    var tm: ct.struct_tm = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) == 0 and ct.localtime_r(&ts.sec, &tm) != null)
        w.print("[{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}] ", .{
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
        }) catch return;
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ ") ";
    w.print(prefix ++ fmt ++ "\n", args) catch return;
    _ = std.c.write(debug_log_fd, buf[0..w.end].ptr, w.end);
}

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
};

const ConfigLuaInfo = struct {
    abs_path: []const u8,
    dir_path: []const u8,
};

fn ensureConfigLua(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !ConfigLuaInfo {
    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    var home_dir = try std.Io.Dir.openDirAbsolute(io, HOME, .{});
    defer home_dir.close(io);

    r.defaults.ensure(io, home_dir);

    const raw_dir: []const u8 = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ HOME, DEFAULT_CONFIG_PATH });
    const dir_path: []const u8 = std.Io.Dir.cwd().realPathFileAlloc(io, raw_dir, alloc) catch raw_dir;
    const abs_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, DEFAULT_LUA_CONFIG });
    return .{ .abs_path = abs_path, .dir_path = dir_path };
}

fn handleWizardEnter(app: *App) void {
    const w = app.wizardState() orelse return;
    const dir_path = app.lua_config_dir orelse return;
    var config_dir = std.Io.Dir.openDirAbsolute(app.io, dir_path, .{}) catch return;
    defer config_dir.close(app.io);
    switch (w.step) {
        .welcome => {
            if (w.list_selected == 1) {
                app.wizardSkip(config_dir);
                return;
            }
            w.step = .provider;
            w.list_selected = 0;
        },
        .provider => w.enterProvider(),
        .provider_type => w.finishProviderType(),
        .url => w.step = r.wizard.nextStep(.url, r.wizard.catalogEntry(w.provider_index) orelse return, w.model.slice()),
        .key => w.step = r.wizard.nextStep(.key, r.wizard.catalogEntry(w.provider_index) orelse return, w.model.slice()),
        .model => {
            if (w.model.isEmpty()) return;
            w.step = r.wizard.nextStep(.model, r.wizard.catalogEntry(w.provider_index) orelse return, w.model.slice());
            w.list_selected = 0;
            if (w.step == .vision) w.vision_override = true;
            w.accept_selected = true;
        },
        .confirm => {
            if (!w.accept_selected) {
                w.step = .welcome;
                w.list_selected = 0;
                w.resetModel();
                w.provider_type_len = 0;
                w.url.clear();
                w.abortClearSecrets();
                return;
            }
            app.wizardConfirm(config_dir);
            return;
        },
        .vision => {
            w.step = .confirm;
            w.list_selected = 0;
        },
        .done => {},
    }
    const fresh = app.wizardState() orelse return;
    fresh.syncModelStep();
}

fn cwdBlitzLuaExists(io: std.Io) bool {
    _ = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch |err| {
        return err != error.FileNotFound;
    };
    return true;
}

fn globalBlitzLuaExists(io: std.Io, env: *const std.process.Environ.Map) bool {
    const HOME = env.get("HOME") orelse return true;
    var home_dir = std.Io.Dir.openDirAbsolute(io, HOME, .{}) catch return true;
    defer home_dir.close(io);
    _ = home_dir.statFile(io, r.defaults.CONFIG_DIR ++ DEFAULT_LUA_CONFIG, .{}) catch return false;
    return true;
}

fn stdinIsInteractiveTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn setupMarkerExistsAbsolute(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) bool {
    const HOME = env.get("HOME") orelse return false;
    const path = std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ HOME, r.defaults.CONFIG_DIR, name }) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    try r.exec.shim.enter(init);
    var io_state = std.Io.Threaded.init(init.gpa, .{
        .stack_size = IO_THREAD_STACK_SIZE,
        .async_limit = .unlimited,
        .concurrent_limit = .unlimited,
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer io_state.deinit();
    const io = io_state.io();
    r.dash.start_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;

    var pos_buf: [16][:0]const u8 = undefined;
    const split = CliArgs.split(init.minimal.args, &pos_buf);
    const cli_flags = split.flags;
    const command_result = CliCommand.parse(split.positional);
    const cleanup_cmd = split.prompt == null and (switch (command_result) {
        .cmd => |parsed| parsed == .cleanup,
        .err, .none => false,
    });
    if ((cli_flags.debug_log or builtin.mode == .debug) and !cleanup_cmd) openDebugLog(io, init.environ_map);

    const cmd: CliCommand = if (split.prompt) |p|
        CliCommand{ .prompt = p }
    else switch (command_result) {
        .err => |txt| {
            std.debug.print("Error: {s}", .{txt});
            return;
        },
        .cmd => |cmd| cmd,
        .none => CliCommand{ .run = "." },
    };

    if (cli_flags.headless and cmd != .prompt) {
        std.debug.print("Error: --headless requires --prompt\n", .{});
        std.process.exit(1);
    }

    switch (cmd) {
        .run => |cwd_arg| {
            var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const len = try std.Io.Dir.cwd().realPathFile(io, cwd_arg, &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                io,
                init.environ_map,
                cli_flags,
                null,
                null,
                false,
            );
        },
        .prompt => |prompt| {
            var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const cwd_arg: []const u8 = if (split.prompt != null and split.positional.len > 0) split.positional[0] else ".";
            const len = try std.Io.Dir.cwd().realPathFile(io, cwd_arg, &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                io,
                init.environ_map,
                cli_flags,
                prompt,
                null,
                cli_flags.headless,
            );
        },
        .cont => |prefix| {
            var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            const project = openSessionProject(io, init.arena.allocator(), init.environ_map, cwd) catch |err| {
                std.debug.print("Error: resolving session dir failed: {s}\n", .{@errorName(err)});
                return;
            };
            const cwd_dir = project.dir;
            defer cwd_dir.close(io);
            const resolved: ?[]const u8 = if (prefix) |p|
                session_store.resolve(init.arena.allocator(), io, cwd_dir, p) catch |err| switch (err) {
                    error.AmbiguousSessionId => {
                        std.debug.print("Error: '{s}' matches multiple sessions\n", .{p});
                        return;
                    },
                    else => {
                        std.debug.print("Error: resolving '{s}' failed: {s}\n", .{ p, @errorName(err) });
                        return;
                    },
                }
            else blk: {
                const entries = session_store.list(init.arena.allocator(), io, cwd_dir) catch |err| {
                    std.debug.print("Error: listing sessions failed: {s}\n", .{@errorName(err)});
                    return;
                };
                break :blk if (entries.len > 0) entries[0].id else null;
            };
            const id = resolved orelse {
                if (prefix != null) {
                    std.debug.print("Error: no session matching '{s}'\n", .{prefix.?});
                } else {
                    std.debug.print("Error: no sessions found in {s}\n", .{project.path});
                }
                return;
            };
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                io,
                init.environ_map,
                cli_flags,
                null,
                id,
                false,
            );
        },
        .update => {
            try updateCli(io, init.gpa, init.environ_map);
        },
        .cleanup => {
            try cleanupCli(io, init.arena.allocator(), init.environ_map, cli_flags.cleanup_sessions);
        },
        .sessions => {
            sessionsTui(io, init.gpa, init.arena.allocator(), init.environ_map) catch |err| {
                std.debug.print("Error: session picker failed: {s}\n", .{@errorName(err)});
            };
        },
        .help => {
            std.debug.print(
                \\Blitzdenk tui v{s}
                \\Usage: blitz CMD --flag
                \\
                \\Commands:
                \\/any/path            start tui in rel path to current cwd (optional)
                \\help                 display this
                \\prompt "STRING"      run in current cwd with initial input
                \\continue [ID]        resume a session in cwd (default: most recent)
                \\sessions             pick a recorded session in cwd to continue
                \\update               download and replace the running binary
                \\cleanup              delete tmp artifacts and the debug log
                \\
                \\Flags:
                \\  --log              write debug.log in path
                \\  --approval <mode>  strict|default|yolo (default: default)
                \\  --strict           shortcut for --approval strict
                \\  --yolo             shortcut for --approval yolo
                \\  --clean            skip local user context
                \\  --prompt "STRING"  prefill input in current cwd
                \\  --headless         with --prompt: run headless, print final message
                \\  --sessions         with cleanup: also delete recorded sessions
                \\
            , .{r.VERSION});
        },
    }
}

fn updateCli(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    var pool = r.exec.CmdPool.init(gpa, io, env);
    defer pool.deinit();

    const update = r.update.checkForUpdate(&pool, gpa) catch |err| {
        std.debug.print("blitz: update check failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer update.deinit(gpa);

    if (!update.available) {
        std.debug.print("blitz is up to date ({s})\n", .{r.VERSION});
        return;
    }

    r.update.installUpdate(io, &pool, gpa, update) catch |err| {
        std.debug.print("blitz: update failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("blitz updated to {s} - restart to apply\n", .{update.latest});
}

fn cleanupLine(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const out = std.Io.File.stdout();
    var buf: [512]u8 = undefined;
    var w = out.writerStreaming(io, &buf);
    try w.interface.print(fmt ++ "\n", args);
    try w.interface.flush();
}

fn cleanupRemoved(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try std.Io.Dir.cwd().deleteTree(io, path);
    return true;
}

fn cleanupTarget(io: std.Io, path: []const u8) !void {
    if (try cleanupRemoved(io, path)) {
        try cleanupLine(io, "removed {s}", .{path});
    } else {
        try cleanupLine(io, "nothing to remove: {s}", .{path});
    }
}

fn cleanupSessions(io: std.Io, alloc: std.mem.Allocator, cache_dir: []const u8) !void {
    var cache = std.Io.Dir.openDirAbsolute(io, cache_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try cleanupLine(io, "nothing to remove: {s}/*/sessions", .{cache_dir});
            return;
        },
        else => return err,
    };
    defer cache.close(io);
    var removed = false;
    var it = cache.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) {
            const info = cache.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            if (info.kind != .directory) continue;
        }
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}/sessions", .{ cache_dir, entry.name });
        if (try cleanupRemoved(io, path)) {
            removed = true;
            try cleanupLine(io, "removed {s}", .{path});
        }
    }
    if (!removed) try cleanupLine(io, "nothing to remove: {s}/*/sessions", .{cache_dir});
}

fn cleanupCli(io: std.Io, alloc: std.mem.Allocator, env: *const std.process.Environ.Map, with_sessions: bool) !void {
    const cache_dir = try std.fs.path.resolve(alloc, &.{try util.cacheDir(alloc, env)});
    if (!std.fs.path.isAbsolute(cache_dir)) {
        try cleanupLine(io, "refusing: {s} is not an absolute cache dir", .{cache_dir});
        return error.CacheDirNotAbsolute;
    }
    if (std.mem.eql(u8, util.TMP_DIR, cache_dir)) {
        try cleanupLine(io, "refusing: {s} is both the tmp dir and the cache dir", .{cache_dir});
        return error.TmpDirIsCacheDir;
    }
    const log_path = try std.fmt.allocPrint(alloc, "{s}/debug.log", .{cache_dir});
    try cleanupTarget(io, log_path);
    if (with_sessions) try cleanupSessions(io, alloc, cache_dir);
    try cleanupTarget(io, util.TMP_DIR);
}

fn sessionProjectDir(alloc: std.mem.Allocator, cache_dir: []const u8, project_cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{x:0>16}", .{ cache_dir, std.hash.Fnv1a_64.hash(project_cwd) });
}

const SessionProject = struct { dir: std.Io.Dir, path: []const u8 };

fn openSessionProject(
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
) !SessionProject {
    const path = try sessionProjectDir(alloc, try util.cacheDir(alloc, env), cwd);
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
    return .{ .dir = try std.Io.Dir.cwd().openDir(io, path, .{}), .path = path };
}

fn openHistoryStoreDir(io: std.Io, alloc: std.mem.Allocator, env: *const std.process.Environ.Map, cwd: []const u8) !std.Io.Dir {
    const path = try std.fmt.allocPrint(alloc, "{s}/history/{x:0>16}", .{ try util.cacheDir(alloc, env), std.hash.Fnv1a_64.hash(cwd) });
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
    return std.Io.Dir.cwd().openDir(io, path, .{});
}

fn localTime(buf: []u8, millis: i64) []const u8 {
    const seconds: std.c.time_t = @intCast(@divTrunc(millis, std.time.ms_per_s));
    var tm: ct.struct_tm = undefined;
    if (ct.localtime_r(&seconds, &tm) == null) return "unknown time";
    // Zero padding needs unsigned ints: `{d:0>2}` on an i32 prints "+8".
    const year: u32 = @intCast(@as(i32, tm.tm_year) + 1900);
    const month: u32 = @intCast(@as(i32, tm.tm_mon) + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
    }) catch "unknown time";
}

fn renderPickerScreen(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    _ = app.arena_frame.reset(.free_all);
    r.app.renderSessionPickerContent(app, app.arena_frame.allocator(), area, buf);
}

fn sessionsTui(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const project = try openSessionProject(io, arena, env, cwd);
    defer project.dir.close(io);

    const rows = blk: {
        const summaries = session_store.summaries(arena, io, project.dir) catch |err| {
            std.debug.print("Error: listing sessions failed: {s}\n", .{@errorName(err)});
            return;
        };
        const picker_rows = try arena.alloc(r.session_picker.Row, summaries.len + 1);
        picker_rows[0] = r.session_picker.new_session;
        for (summaries, 0..) |summary, i| {
            var when_buf: [16]u8 = undefined;
            picker_rows[i + 1] = .{
                .id = summary.id,
                .date = try arena.dupe(u8, localTime(&when_buf, summary.modified_ms)),
                .prompt = summary.prompt,
            };
        }
        break :blk picker_rows;
    };

    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    const context_factory = try r.ContextFactory.init(gpa, io, HOME, cwd);
    var app = try App.init(io, gpa, context_factory, cwd);
    app.kitty_graphics = tui.kitty.graphicsSupported(env);
    var registry = r.agent_registry.Registry.init(gpa, io);
    var exec_pool = r.exec.CmdPool.init(gpa, io, env);
    app.registry = &registry;
    app.exec_pool = &exec_pool;
    defer {
        app.cancelPermissions(null);
        registry.cancelAll();
        app.deinit();
        registry.deinit();
        exec_pool.deinit();
    }
    app.enterSessionPicker(rows);

    var term = try tui.Terminal.init(arena, io);
    if (!app.kitty_graphics) app.kitty_graphics = term.probeKittyGraphics(100);
    term.kitty_graphics = app.kitty_graphics;
    defer term.deinit();

    var picked: ?r.session_picker.Row = null;
    draw: while (true) {
        try term.drawWith(&app, renderPickerScreen);
        app.dirty = false;

        term.pollAndEnqueue(16);
        while (true) {
            const event = term.nextEvent();
            switch (event) {
                .key => |k| {
                    if (k.code == .char) {
                        if (k.code.char == 'q') break :draw;
                        if (app.input_mode == .session_picker and (k.code.char == 'j' or k.code.char == 'k')) {
                            app.input_mode.session_picker.move(if (k.code.char == 'j') 1 else -1);
                            continue :draw;
                        }
                    }
                    switch (k.code) {
                        .esc => break :draw,
                        .arrow_up => {
                            if (app.input_mode == .session_picker) app.input_mode.session_picker.move(-1);
                            continue :draw;
                        },
                        .arrow_down => {
                            if (app.input_mode == .session_picker) app.input_mode.session_picker.move(1);
                            continue :draw;
                        },
                        .enter => {
                            if (app.input_mode == .session_picker) picked = app.input_mode.session_picker.pick();
                            break :draw;
                        },
                        else => {},
                    }
                },
                .resize => continue :draw,
                .none => break,
                else => {},
            }
        }
    }

    const chosen_full = picked orelse return;
    if (r.session_picker.isNewSession(chosen_full)) {
        try run(cwd, gpa, arena, io, env, .{}, null, null, false);
        return;
    }
    const resolved = session_store.resolve(arena, io, project.dir, chosen_full.id) catch |err| {
        std.debug.print("Error: resolving session '{s}' failed: {s}\n", .{ chosen_full.id, @errorName(err) });
        return;
    };
    const id = resolved orelse {
        std.debug.print("Error: session '{s}' no longer exists\n", .{chosen_full.id});
        return;
    };
    try run(cwd, gpa, arena, io, env, .{}, null, id, false);
}

pub fn run(
    cwd: []const u8,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    flags: CliFlags,
    prompt: ?[]const u8,
    resume_session: ?[]const u8,
    headless: bool,
) !void {
    const first_install = !globalBlitzLuaExists(io, env);
    const done_marker_exists = setupMarkerExistsAbsolute(arena, io, env, r.wizard.DONE_MARKER);
    const pending_marker_exists = setupMarkerExistsAbsolute(arena, io, env, r.wizard.PENDING_MARKER);
    const wizard_pending = !done_marker_exists and (first_install or pending_marker_exists);

    const interactive = stdinIsInteractiveTty(io);
    if (wizard_pending and !interactive) {
        std.debug.print("Error: first-run setup wizard is pending — run blitz interactively once to complete it\n", .{});
        std.process.exit(1);
    }

    const config_lua: ?ConfigLuaInfo = ensureConfigLua(arena, io, env) catch null;

    if (wizard_pending and first_install) {
        if (config_lua) |info| {
            if (std.Io.Dir.openDirAbsolute(io, info.dir_path, .{})) |opened| {
                var config_dir = opened;
                r.wizard.writePendingMarker(io, config_dir);
                config_dir.close(io);
            } else |_| {}
        }
    }

    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    const context_factory = try r.ContextFactory.init(gpa, io, HOME, cwd);
    context_factory.flags.skip_local_context_file = flags.no_context;

    const project = try openSessionProject(io, arena, env, cwd);
    const cwd_dir = project.dir;
    defer cwd_dir.close(io);

    var history_store_dir = try openHistoryStoreDir(io, arena, env, cwd);
    defer history_store_dir.close(io);

    session_store.collectGarbage(arena, io, cwd_dir, session_store.GC_AGE_MS);

    var app = try App.init(io, gpa, context_factory, cwd);
    app.kitty_graphics = tui.kitty.graphicsSupported(env);
    var registry = r.agent_registry.Registry.init(gpa, io);
    var exec_pool = r.exec.CmdPool.init(gpa, io, env);
    app.registry = &registry;
    app.exec_pool = &exec_pool;
    if (config_lua) |info| {
        app.lua_config_dir = info.dir_path;
        app.lua_config_abs = info.abs_path;
    }
    defer {
        app.cancelPermissions(null);
        registry.cancelAll();
        app.deinit();
        registry.deinit();
        exec_pool.deinit();
    }
    app.lua_vm.setApp(&app);
    app.lua_vm.clearLastError();

    var lua_load_failed = false;
    if (config_lua) |info| {
        const inject = try std.fmt.allocPrint(arena, "package.path = \"{s}/?.lua;\" .. package.path", .{info.dir_path});
        app.lua_vm.exec(inject) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to configure lua package.path: {s} ({any})", .{ app.lua_vm.getLastError(), err });
        };
        app.lua_vm.load(info.abs_path) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to load {s}: {s} ({any})", .{ info.abs_path, app.lua_vm.getLastError(), err });
        };
    }
    if (cwdBlitzLuaExists(io) and !app.localLuaIsGlobal()) {
        app.lua_vm.load("blitz.lua") catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to load blitz.lua: {s} ({any})", .{ app.lua_vm.getLastError(), err });
        };
    }
    if (!lua_load_failed) app.lua_vm.clearLastError();
    app.lua_vm.readConfigFields();
    try app.lua_vm.publishAvailableSystems(context_factory);
    var lua_tools = try app.lua_vm.getRegisteredTools(arena);
    var lua_binds = try app.lua_vm.getRegisteredKeybinds(arena);

    for (lua_tools) |tool| {
        try context_factory.add(tool, .all);
    }
    context_factory.precalcGeneralPromptSize(&app.config);

    for (lua_binds) |bind| {
        try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn }, .description = bind.description });
    }

    var watch = config_watch.Watch.init(gpa);
    defer watch.deinit();
    {
        var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch 0;
        if (cwd_len > 0) watch.blitz_path = try std.fmt.allocPrint(arena, "{s}/blitz.lua", .{cwd_buf[0..cwd_len]});
    }
    if (config_lua) |info| watch.config_dir = info.dir_path;
    watch.refreshAfterReload(io);
    var reload_tick: u32 = 0;

    app.reset();
    if (flags.approval_explicit) app.flags.approval_mode = flags.approval_mode;
    if (wizard_pending) app.enterWizard();
    if (app.input_mode != .wizard) app.warnUnboundAgentModels();

    var store = session_store.Store{ .io = io, .gpa = gpa, .base = cwd_dir };
    defer {
        app.registry.cancelAll();
        app.checkpoint();
        for (&app.registry.slots) |*slot| if (slot.agent) |*agent| {
            agent.journal = null;
        };
        app.session_store = null;
        store.deinit();
    }
    app.session_store = &store;
    var session_id_buf: [session_store.ID_LEN]u8 = undefined;
    if (resume_session) |prefix| {
        const resolved_opt = session_store.resolve(arena, io, cwd_dir, prefix) catch |err| blk: {
            if (err == error.AmbiguousSessionId) {
                std.debug.print("Error: '{s}' matches multiple sessions\n", .{prefix});
            } else {
                std.debug.print("Error: resolving session '{s}' failed: {s}\n", .{ prefix, @errorName(err) });
            }
            break :blk null;
        };
        const resolved = resolved_opt orelse return error.SessionNotFound;
        const file_name = try session_store.fileName(arena, resolved);
        const loaded_opt = session_store.load(arena, io, cwd_dir, file_name) catch |err| {
            std.debug.print("Error: reading session '{s}' failed: {s}\n", .{ resolved, @errorName(err) });
            return error.SessionNotFound;
        };
        const loaded = loaded_opt orelse {
            std.debug.print("Error: session '{s}' has no usable header\n", .{resolved});
            return error.SessionNotFound;
        };
        var resumed = false;
        if (session.applySaveState(&app, &loaded.save)) |_| {
            resumed = true;
        } else |err| {
            std.log.scoped(.session).warn("resume of {s} failed: {s}", .{ resolved, @errorName(err) });
        }
        if (resumed) {
            try store.open(cwd, file_name);
            session.bindJournal(&app);
        } else {
            store.create(cwd) catch |create_err| {
                std.log.scoped(.session).warn("session journal unavailable: {s}", .{@errorName(create_err)});
            };
        }
    } else {
        store.create(cwd) catch |err| {
            std.log.scoped(.session).warn("session journal unavailable: {s}", .{@errorName(err)});
        };
    }
    app.checkpoint();

    app.loadHistory(history_store_dir);
    try app.cmd_queue.apply(io, &app);

    if (headless) {
        try runHeadless(&app, io, prompt.?);
        app.checkpoint();
        printSessionHint(&store, &session_id_buf);
        return;
    }

    app.startUpdateCheck();

    if (prompt) |p| {
        app.input.set(p);
    }

    // Terminal is scoped so its restore happens before the session hint is
    // printed — on the normal screen, where the user can actually read it.
    var exit_hint: bool = false;
    {
        var term = try tui.Terminal.init(arena, io);
        if (!app.kitty_graphics) app.kitty_graphics = term.probeKittyGraphics(100);
        term.kitty_graphics = app.kitty_graphics;
        defer term.deinit();
        app.frame_snapshot = &term.previous;
        app.frame_snapshot_resize_gen = &term.resize_generation;

        var was_running = app.running;
        var error_fade_pending = false;
        var last_frame_ns: i128 = 0;
        var mouse_press: ?struct { x: u16, y: u16 } = null;
        main_loop: while (true) {
            const now_ns: i128 = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
            const notifications_before = app.notifications.hasVisible();
            app.notifications.tick(1.0 / 60.0);
            const error_fading = app.lua_vm.errorNeedsFrame(now_ns);
            const fading_before = notifications_before or error_fade_pending;
            const fading_now = app.notifications.hasVisible() or error_fading;
            error_fade_pending = error_fading;
            if (fading_before and !fading_now) app.dirty = true;

            if (app.lua_redraw.swap(false, .acq_rel)) app.dirty = true;
            if (app.inline_images_ready.load(.acquire)) app.dirty = true;

            const animated = app.animationActive() or fading_now;
            app.frame_snapshot_blocked = term.selectionActive();
            if (app.dirty or (animated and now_ns -| last_frame_ns >= 16 * std.time.ns_per_ms)) {
                last_frame_ns = now_ns;
                app.cell_px = term.cellPixels();
                try term.drawWith(&app, App.render);
                syncGraphics(io, &term, &app);
                app.frame_count +%= 1;
                app.dirty = false;
            }

            // Drain new agent messages from broadcast into the timeline
            // app.drainBroadcast();
            // Mirror in-progress streaming message so TUI shows tokens as they arrive.
            {
                var g = app.permission_queue.lock(io);
                const pending_before = app.pending_permissions.items.len;
                const active_before = app.active_permission;
                while (g.ptr.items.len > 0) {
                    const next = g.ptr.swapRemove(0);
                    g.unlock();

                    app.fillAgentInfo(next);

                    const decided = app.luaPermissionDecision(next);

                    g = app.permission_queue.lock(io);
                    if (decided) |d| {
                        next.state = d;
                        next.event.set(app.io);
                        continue;
                    }

                    if (app.registry.state(next.agent_id) != .active) {
                        next.state = .denied;
                        next.event.set(app.io);
                        continue;
                    }

                    const lua_stage = app.event_bus.willDeliver(io, .permission_requested);
                    if (!lua_stage and app.permissionModeApproves(next)) {
                        next.state = .approved;
                        next.event.set(app.io);
                        continue;
                    }

                    app.permission_ticket_next += 1;
                    next.ticket = app.permission_ticket_next;
                    next.stage = if (lua_stage) .in_lua else .in_tui;
                    app.pending_permissions.append(app.gpa, next) catch {
                        next.state = .denied;
                        next.event.set(app.io);
                        continue;
                    };
                    if (!app.event_bus.emit(&app, .{ .permission_requested = next.ticket })) app.releaseLuaStage(next);
                }

                var index: usize = 0;
                while (index < app.pending_permissions.items.len) {
                    const req = app.pending_permissions.items[index];
                    if (req.state != .pending or app.registry.state(req.agent_id) != .active) {
                        if (req.state == .pending) {
                            app.settlePermission(req, .denied);
                        } else {
                            _ = app.pending_permissions.orderedRemove(index);
                            if (app.active_permission == req) app.active_permission = null;
                        }
                        continue;
                    }
                    if (app.active_permission == null and req.stage == .in_tui) app.active_permission = req;
                    index += 1;
                }
                if (app.pending_permissions.items.len != pending_before or app.active_permission != active_before) app.dirty = true;
                g.unlock();
            }

            // cmd.select requests: show when no permission is on screen.
            if (app.active_permission == null and app.active_selection == null) {
                const g = app.selection_queue.lock(io);
                if (g.ptr.items.len > 0) {
                    app.active_selection = g.ptr.orderedRemove(0);
                    app.dirty = true;
                }
                g.unlock();
            }

            // Drive input_mode from perm presence — single source of truth.
            switch (app.input_mode) {
                .text => if (app.active_permission != null or app.active_selection != null) app.enterPermSelect(),
                .perm_select, .perm_message => if (app.active_permission == null and app.active_selection == null) app.returnToText(),
                .passphrase, .wizard, .session_picker => {},
            }

            reload_tick +%= 1;
            const reload_requested = app.lua_reload_requested.load(.acquire);
            if (reload_tick >= 60 or reload_requested) {
                reload_tick = 0;
                const changed = if (reload_requested) false else watch.pollCycle(io);

                var reload_completed = false;
                var reload_failed = false;
                if (reload_requested or changed) blk: {
                    try app.waitForMcpTools();
                    if (!app.lua_vm.vm_mu.tryLock()) break :blk;
                    defer app.lua_vm.vm_mu.unlock(io);

                    var reset_failed = false;

                    app.lua_vm.clearLastError();
                    app.event_bus.clear(io);
                    app.lua_inject_hooks_enabled.store(false, .release);
                    var lua_reload_failed = false;

                    context_factory.config_reload_in_progress = true;
                    defer context_factory.config_reload_in_progress = false;
                    app.lua_vm.reset() catch |err| {
                        reset_failed = true;
                        lua_reload_failed = true;
                        reload_failed = true;
                        std.log.scoped(.lua).err("hot-reload: failed to reset lua vm ({any})", .{err});
                    };
                    app.clearSelections(false);
                    app.keymap.custom.clearRetainingCapacity();
                    context_factory.resetDefs();
                    try context_factory.resetLoadedTools();
                    if (config_lua) |info| {
                        const inject = std.fmt.allocPrint(arena, "package.path = \"{s}/?.lua;\" .. package.path", .{info.dir_path}) catch null;
                        if (inject) |code| app.lua_vm.exec(code) catch |err| {
                            lua_reload_failed = true;
                            reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to configure lua package.path: {s} ({any})", .{ app.lua_vm.getLastError(), err });
                        };
                        app.lua_vm.load(info.abs_path) catch |err| {
                            lua_reload_failed = true;
                            reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to load {s}: {s} ({any})", .{ info.abs_path, app.lua_vm.getLastError(), err });
                        };
                    }
                    if (cwdBlitzLuaExists(io) and !app.localLuaIsGlobal()) {
                        app.lua_vm.load("blitz.lua") catch |err| {
                            lua_reload_failed = true;
                            reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to load blitz.lua: {s} ({any})", .{ app.lua_vm.getLastError(), err });
                        };
                    }
                    if (!lua_reload_failed) app.lua_vm.clearLastError();
                    context_factory.config_reload_in_progress = false;
                    context_factory.applySessionBindings(&app.config, !lua_reload_failed) catch |err| {
                        std.log.scoped(.lua).err("hot-reload: failed to apply session bindings: {s}", .{@errorName(err)});
                    };
                    app.lua_vm.readConfigFields();
                    app.invalidateTimelineRenderCache();
                    if (app.input_mode != .wizard) app.warnUnboundAgentModels();
                    try app.lua_vm.publishAvailableSystems(context_factory);
                    app.dirty = true;

                    lua_tools = app.lua_vm.getRegisteredTools(arena) catch |err| {
                        std.log.scoped(.lua).err("failed to load lua tool defs {any}", .{err});
                        if (reload_requested) {
                            app.lua_reload_failed.store(true, .release);
                            app.markLuaReloadDone();
                        }
                        break :blk;
                    };
                    for (lua_tools) |tool| try context_factory.add(tool, .all);
                    context_factory.precalcGeneralPromptSize(&app.config);

                    const reloaded_mcp_servers = app.lua_vm.getEnabledMcpServers(arena) catch |err| {
                        std.log.scoped(.mcp).err("failed to load MCP server defs {any}", .{err});
                        if (reload_requested) {
                            app.lua_reload_failed.store(true, .release);
                            app.markLuaReloadDone();
                        }
                        break :blk;
                    };
                    app.loadMcpTools(reloaded_mcp_servers);

                    lua_binds = try app.lua_vm.getRegisteredKeybinds(arena);
                    for (lua_binds) |bind| {
                        try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn }, .description = bind.description });
                    }

                    if (reload_requested) app.lua_reload_failed.store(reload_failed, .release);
                    try app.refreshLiveAgentTools();
                    _ = app.lua_reload_generation.fetchAdd(1, .monotonic);
                    if (reload_requested) app.markLuaReloadDone();
                    if (!reset_failed) watch.refreshAfterReload(io);
                    reload_completed = !reload_failed;
                }
                if (reload_completed and app.flags.notify_on_reload) app.cmd_queue.append(io, .{ .push_notification = "Lua sandbox reloaded" }) catch {};
            }

            term.pollAndEnqueue(16);
            try app.tick();

            while (true) {
                const next_event = term.nextEvent();
                if (next_event != .none) app.dirty = true;
                switch (next_event) {
                    .key => |k| {
                        if (app.image_viewer != null) {
                            if (k.mods.ctrl and k.code == .char and k.textSlice().len == 1 and k.textSlice()[0] == 'c') {
                                app.closeImageViewer();
                                continue;
                            }
                            const res = r.image_view.handleKey(&app.image_viewer.?, k);
                            if (res == .close) app.closeImageViewer();
                            continue;
                        }
                        if (app.keymap.parse(k)) |action| {
                            switch (action) {
                                .exit => {
                                    if (app.input_mode == .wizard) {
                                        app.wizardAbortClearSecrets();
                                        break :main_loop;
                                    }
                                    if (app.active_permission == null and app.running) {
                                        try app.cmd_queue.append(io, .cancel);
                                    } else {
                                        break :main_loop;
                                    }
                                    continue;
                                },
                                .cancel => {
                                    if (app.input_mode == .wizard) {
                                        app.wizardAbortClearSecrets();
                                        break :main_loop;
                                    }
                                    if (app.closeCompletion()) continue;
                                    if (app.running) {
                                        try app.cmd_queue.append(io, .cancel);
                                    } else {
                                        app.screenshot_buf = null;
                                    }
                                },
                                .scroll_down => {
                                    try app.cmd_queue.append(io, .{ .scroll_down = 1 });
                                    continue;
                                },
                                .scroll_up => {
                                    try app.cmd_queue.append(io, .{ .scroll_up = 1 });
                                    continue;
                                },
                                .retry => {
                                    try app.cmd_queue.append(io, .retry);
                                    continue;
                                },
                                .lua => |lua_fn| {
                                    if (app.lua_vm.vm_mu.tryLock()) {
                                        defer app.lua_vm.vm_mu.unlock(io);
                                        app.lua_vm.invokeBind(lua_fn);
                                    }
                                    continue;
                                },
                                .cursor_left => {
                                    _ = app.fieldOp(.left, "");
                                    app.input_desired_col = null;
                                    continue;
                                },
                                .cursor_right => {
                                    _ = app.fieldOp(.right, "");
                                    app.input_desired_col = null;
                                    continue;
                                },
                                .cursor_up => {
                                    if (app.completionIsOpen()) {
                                        app.handleCompletion(.prev);
                                        continue;
                                    }
                                    if (app.moveCursorVertical(-1)) continue;
                                },
                                .cursor_down => {
                                    if (app.completionIsOpen()) {
                                        app.handleCompletion(.next);
                                        continue;
                                    }
                                    if (app.moveCursorVertical(1)) continue;
                                },
                                .history_prev => {
                                    if (app.historyUp()) continue;
                                },
                                .history_next => {
                                    if (app.historyDown()) continue;
                                },
                                .completion_next => {
                                    app.handleCompletion(.next);
                                    continue;
                                },
                                .completion_prev => {
                                    app.handleCompletion(.prev);
                                    continue;
                                },
                                .completion_accept => {
                                    app.handleCompletion(.accept);
                                    continue;
                                },
                                .undo => {
                                    app.undoLastTurn();
                                    continue;
                                },
                                .paste_image => {
                                    app.pasteImage();
                                    continue;
                                },
                            }
                        }
                        switch (k.code) {
                            .char => |c| {
                                if (app.input_mode == .text) {
                                    app.appendBytes(k.textSlice());
                                    continue;
                                }
                                if (app.fieldOp(.insert, k.textSlice())) continue;
                                switch (app.input_mode) {
                                    .perm_select => |*ps| {
                                        const max_sel = app.permSelectMaxIndex();
                                        if (c == 'j' and ps.selected < max_sel) ps.selected += 1;
                                        if (c == 'k' and ps.selected > 0) ps.selected -= 1;
                                    },
                                    .wizard => |*w| {
                                        if (c == 'j') w.moveCursor(1);
                                        if (c == 'k') w.moveCursor(-1);
                                    },
                                    else => {},
                                }
                            },
                            .arrow_up => switch (app.input_mode) {
                                .perm_select => |*ps| {
                                    if (ps.selected > 0) ps.selected -= 1;
                                },
                                .wizard => |*w| {
                                    w.moveCursor(-1);
                                },
                                else => {},
                            },
                            .arrow_down => switch (app.input_mode) {
                                .perm_select => |*ps| {
                                    const max_sel = app.permSelectMaxIndex();
                                    if (ps.selected < max_sel) ps.selected += 1;
                                },
                                .wizard => |*w| {
                                    w.moveCursor(1);
                                },
                                else => {},
                            },
                            .backspace => {
                                if (app.input_mode == .text or app.input_mode == .perm_message) {
                                    app.deleteChar();
                                } else {
                                    _ = app.fieldOp(.backspace, "");
                                }
                            },
                            .home => {
                                app.input_desired_col = null;
                                _ = app.fieldOp(.home, "");
                                if (app.input_mode == .text) app.syncCompletion();
                            },
                            .end => {
                                app.input_desired_col = null;
                                _ = app.fieldOp(.end, "");
                                if (app.input_mode == .text) app.syncCompletion();
                            },
                            .delete => {
                                if (app.input_mode == .text or app.input_mode == .perm_message) {
                                    app.deleteForwardChar();
                                } else {
                                    _ = app.fieldOp(.delete_forward, "");
                                }
                            },
                            .enter => switch (app.input_mode) {
                                .perm_message => |*pm| {
                                    if (app.active_permission == null) {
                                        if (app.active_selection != null) {
                                            if (pm.field.isEmpty()) {
                                                app.enterPermSelect();
                                                break;
                                            }
                                            app.resolveActiveSelection(pm.field.slice(), null);
                                            break;
                                        }
                                    }
                                    const entry = app.active_permission orelse break;

                                    const is_ask = entry.payload == .ask;

                                    if (pm.field.isEmpty()) {
                                        app.enterPermSelect();
                                        break;
                                    }
                                    const msg = pm.field.slice();
                                    if (is_ask) {
                                        app.resolveActivePermission(.{ .message = msg });
                                    } else {
                                        app.resolveActivePermission(.denied);
                                    }
                                    app.auto_scroll = true;
                                    app.scroll_offset = 0;
                                },
                                .perm_select => |*ps| {
                                    if (app.active_permission == null) {
                                        if (app.active_selection) |sel| {
                                            const sel_opts_len: u8 = @intCast(@min(sel.ask.options.len, tools.ask.MAX_OPTIONS));
                                            if (sel.ask.allow_message and ps.selected >= sel_opts_len) {
                                                app.enterPermMessage();
                                                break;
                                            }
                                            app.resolveActiveSelection(sel.ask.options[ps.selected], ps.selected + 1);
                                            break;
                                        }
                                    }

                                    const entry = app.active_permission orelse break;
                                    if (entry.payload == .ask) {
                                        const args = entry.payload.ask;
                                        const opts_len: u8 = @intCast(@min(args.options.len, tools.ask.MAX_OPTIONS));

                                        if (ps.selected >= opts_len) {
                                            app.enterPermMessage();
                                            break;
                                        }

                                        app.resolveActivePermission(.{ .choice = ps.selected });
                                        app.auto_scroll = true;
                                        app.scroll_offset = 0;
                                        break;
                                    }

                                    // Generic 3-option (yes / no / enter message)
                                    switch (ps.selected) {
                                        0 => app.resolveActivePermission(.approved),
                                        1 => app.resolveActivePermission(.denied),
                                        2 => {
                                            app.enterPermMessage();
                                            break;
                                        },
                                        else => {},
                                    }
                                    app.auto_scroll = true;
                                    app.scroll_offset = 0;
                                },
                                .text => {
                                    _ = app.closeCompletion();
                                    if (app.input.isEmpty()) break;
                                    var input: []const u8 = std.fmt.allocPrint(app.sessionAlloc(), "{f}", .{std.unicode.fmtUtf8(app.inputSlice())}) catch break;
                                    if (app.lua_vm.vm_mu.tryLock()) {
                                        defer app.lua_vm.vm_mu.unlock(io);
                                        if (app.lua_vm.runPromptHook(app.sessionAlloc(), input)) |transformed| {
                                            input = std.fmt.allocPrint(app.sessionAlloc(), "{f}", .{std.unicode.fmtUtf8(transformed)}) catch break;
                                        }
                                    } else break;
                                    if (input.len == 0) {
                                        app.setInput("");
                                        break;
                                    }
                                    var send_text: []const u8 = input;
                                    var timeline_text: []const u8 = input;

                                    // -- user commands (processed even while a session is running)
                                    if (input[0] == '/') {
                                        if (app.lua_vm.vm_mu.tryLock()) {
                                            defer app.lua_vm.vm_mu.unlock(io);
                                            if (app.lua_vm.invokeCommand(input)) {
                                                app.pushHistory(history_store_dir, input);
                                                app.input.clear();
                                                break;
                                            }
                                        } else {
                                            break;
                                        }

                                        const cmd = AppCommand.parse(input);

                                        if (cmd) |c| {
                                            switch (c) {
                                                .ssh => |args| {
                                                    app.startSshConnect(args.user, args.host, args.cwd);
                                                    app.input.clear();
                                                },
                                                .ssh_off => {
                                                    app.cancelSshConnect();
                                                    app.exec_pool.clearSsh();
                                                    app.invalidatePathCompletions();
                                                    app.notifications.append(gpa, app.nowMillis(), "SSH mode disabled", .{}) catch {};
                                                    app.input.clear();
                                                },
                                            }
                                            break;
                                        }

                                        if (reg.parseSshAliasCommand(input)) |alias| {
                                            if (app.context_factory.findSshAlias(alias)) |target| {
                                                app.startSshConnect(target.user, target.host, target.cwd);
                                            } else {
                                                app.pushSystemMessage("unknown ssh alias: {s}", .{alias});
                                            }
                                            app.input.clear();
                                            break;
                                        }

                                        if (skills.parseSkillCommand(input)) |sc| {
                                            const entry = app.context_factory.skills.find(sc.name) orelse {
                                                app.pushSystemMessage("unknown skill: {s}", .{sc.name});
                                                app.input.clear();
                                                break;
                                            };
                                            if (!entry.meta.user_invocable) {
                                                app.pushSystemMessage("skill '{s}' is not user-invocable", .{entry.meta.name});
                                                app.input.clear();
                                                break;
                                            }
                                            const loaded = skills.loadSkill(app.io, app.sessionAlloc(), entry) orelse {
                                                app.pushSystemMessage("unknown skill: {s}", .{sc.name});
                                                app.input.clear();
                                                break;
                                            };
                                            send_text = skills.skillSendText(app.sessionAlloc(), entry.meta.name, entry.path, loaded.body, sc.prompt) catch break;
                                            timeline_text = skills.skillTimelineText(app.sessionAlloc(), entry.meta.name, sc.prompt) catch break;
                                        } else {
                                            break;
                                        }
                                    }

                                    if (app.running) {
                                        app.pushHistory(history_store_dir, input);
                                        _ = app.event_bus.emit(&app, .{ .user_message_sent = timeline_text });
                                        if (app.main_agent_id) |agent_id| {
                                            const alloc = app.sessionAlloc();
                                            const len: usize = if (app.screenshot_buf != null) 2 else 1;

                                            const parts = try alloc.alloc(r.sdk.Part, len);
                                            parts[0] = .{ .text = send_text };

                                            if (app.screenshot_buf) |buf| {
                                                parts[1] = .{ .image = .{
                                                    .url = try std.fmt.allocPrint(alloc, "data:image/png;base64,{s}", .{buf}),
                                                    .media_type = "image/png",
                                                } };
                                            }

                                            const entry = try TimelineEntry.userMessageSimple(alloc, .user, timeline_text);
                                            try app.cmd_queue.append(io, .{ .queue_agent_message = .{
                                                .agent_id = agent_id,
                                                .parts = parts,
                                                .timeline_entry = entry,
                                            } });
                                        }

                                        try app.cmd_queue.append(io, .{ .scroll_down = 999999 });
                                        app.screenshot_buf = null;
                                        app.input.clear();
                                        continue;
                                    }

                                    app.pushHistory(history_store_dir, input);

                                    const alloc = app.sessionAlloc();
                                    const parts: []const r.sdk.Part = if (app.screenshot_buf) |img_data|
                                        alloc.dupe(r.sdk.Part, &.{
                                            .{ .text = send_text },
                                            .{ .image = .{ .url = try std.fmt.allocPrint(alloc, "data:image/png;base64,{s}", .{img_data}), .media_type = "image/png" } },
                                        }) catch break
                                    else
                                        alloc.dupe(r.sdk.Part, &.{
                                            .{ .text = send_text },
                                        }) catch break;

                                    app.screenshot_buf = null;

                                    try app.sendPrompt(io, parts, timeline_text);
                                    app.input.clear();
                                },
                                .passphrase => {
                                    app.startSshUnlock();
                                },
                                .wizard => {
                                    handleWizardEnter(&app);
                                },
                                .session_picker => {},
                            },
                            .esc => switch (app.input_mode) {
                                .text => {
                                    const input = app.inputSlice();
                                    if (input.len > 0 and input[0] == '/') {
                                        app.input.clear();
                                        app.input_desired_col = null;
                                    }
                                },
                                .passphrase => {
                                    app.notifications.append(gpa, app.nowMillis(), "SSH: passphrase entry canceled", .{}) catch {};
                                    app.returnToText();
                                },
                                else => {},
                            },
                            else => {},
                        }
                    },
                    .paste => |text| {
                        switch (app.input_mode) {
                            .text, .perm_message => app.pasteImageOrText(text),
                            else => _ = app.fieldOp(.insert, text),
                        }
                    },
                    .mouse => |m| {
                        if (app.image_viewer) |*viewer| {
                            switch (r.image_view.handleMouse(viewer, m)) {
                                .consumed => {},
                                .close => app.closeImageViewer(),
                                .pass => {},
                            }
                        } else {
                            if (!app.handleScrollbarMouse(m)) {
                                const res = term.handleMouse(m);
                                if (res.copied) {
                                    app.notifications.append(gpa, app.nowMillis(), "Copied to clipboard!", .{}) catch {};
                                }
                                if (res.wheel < 0) {
                                    try app.cmd_queue.append(io, .{ .scroll_up = @intCast(-res.wheel) });
                                } else if (res.wheel > 0) {
                                    try app.cmd_queue.append(io, .{ .scroll_down = @intCast(res.wheel) });
                                }
                            }
                            if (m.button == .left and m.action == .press) {
                                mouse_press = .{ .x = m.x, .y = m.y };
                            }
                            if (m.button == .left and m.action == .release) {
                                if (mouse_press) |press| {
                                    if (press.x == m.x and press.y == m.y) {
                                        openImageAt(&app, &term, m.x, m.y);
                                    }
                                }
                                mouse_press = null;
                            }
                        }
                    },
                    .resize => {},
                    .none => break,
                }
            }

            try app.cmd_queue.apply(io, &app);

            if (was_running and !app.running) app.checkpoint();
            was_running = app.running;
        }
        exit_hint = true;
    } // tui_phase

    app.checkpoint();
    if (exit_hint) printSessionHint(&store, &session_id_buf);
}

const image_token_punct = "\"'`([{<,;:";

fn trimToken(token: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = token.len;
    while (start < end and (std.mem.indexOfScalar(u8, image_token_punct, token[start]) != null or token[start] == '(')) start += 1;
    while (end > start and (std.mem.indexOfScalar(u8, ")]}>.,;:'\"`", token[end - 1]) != null)) end -= 1;
    return token[start..end];
}

fn openImageAt(app: *App, term: *tui.Terminal, x: u16, y: u16) void {
    const w = term.previous.rect.width;
    const h = term.previous.rect.height;
    if (x >= w or y >= h) return;
    var left: i32 = @as(i32, x);
    while (left >= 0 and term.previous.get(@intCast(left), y).char != ' ') left -= 1;
    var right: u16 = x;
    while (right < w and term.previous.get(right, y).char != ' ') right += 1;
    if (right -| @as(u16, @intCast(left + 1)) == 0) return;

    var token_buf: [std.fs.max_path_bytes]u8 = undefined;
    var len: usize = 0;
    var cx: u16 = @intCast(left + 1);
    while (cx < right) : (cx += 1) {
        const cell = term.previous.get(cx, y);
        if (cell.char == ' ') continue;
        if (len + 4 > token_buf.len) return;
        const n = std.unicode.utf8Encode(cell.char, token_buf[len..]) catch return;
        len += n;
    }
    const token = trimToken(token_buf[0..len]);
    if (token.len > 4 and r.image_view.hasImageExtension(token)) {
        app.openImageToken(token);
    }
}

fn syncGraphics(io: std.Io, term: *tui.Terminal, app: *App) void {
    if (!app.kitty_graphics) return;
    if (app.graphics_resize_gen != term.resize_generation) {
        app.graphics_resize_gen = term.resize_generation;
        for (app.inline_images.entries.items) |entry| {
            entry.transmitted = false;
            entry.placed_gen = 0;
        }
        if (app.image_viewer) |*viewer| viewer.transmitted = false;
    }
    syncImageViewerGraphics(io, term, app);
    syncInlineGraphics(io, term, app);
}

fn syncImageViewerGraphics(io: std.Io, term: *tui.Terminal, app: *App) void {
    if (app.image_view_pending_delete != 0) {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        tui.kitty.deleteImage(&w, app.image_view_pending_delete) catch {};
        term.writeRaw(buf[0..w.end]);
        app.image_view_pending_delete = 0;
    }
    const viewer = if (app.image_viewer) |*viewer| viewer else return;
    if (viewer.img == null) return;
    viewer.cell_px = term.cellPixels();
    if (!viewer.transmitted) {
        var wbuf: [8192]u8 = undefined;
        var w = term.stdout.writerStreaming(io, &wbuf);
        const img = viewer.img.?;
        tui.kitty.transmitRgba(&w.interface, viewer.id, img.pixels, img.width, img.height) catch {
            w.interface.flush() catch {};
            return;
        };
        w.interface.flush() catch return;
        viewer.transmitted = true;
    }
    const placement = r.image_view.computePlacement(viewer, viewer.cell_px);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    tui.kitty.placeWithId(&w, viewer.id, 1, placement) catch return;
    term.writeRaw(buf[0..w.end]);
}

fn syncInlineGraphics(io: std.Io, term: *tui.Terminal, app: *App) void {
    if (!app.kitty_graphics) return;

    while (app.inline_pending_deletes.items.len > 0) {
        const id = app.inline_pending_deletes.pop().?;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        tui.kitty.deleteImage(&w, id) catch continue;
        term.writeRaw(buf[0..w.end]);
    }

    app.inline_frame_gen += 1;
    const frame_gen = app.inline_frame_gen;

    const hidden = app.image_viewer != null;
    if (!hidden) {
        for (app.inline_placements.items) |pl| {
            const entry = pl.entry;
            if (entry.state.load(.acquire) != .ready) continue;
            const img = entry.img orelse continue;
            if (!entry.transmitted) {
                var wbuf: [8192]u8 = undefined;
                var w = term.stdout.writerStreaming(io, &wbuf);
                tui.kitty.transmitRgba(&w.interface, entry.kitty_id, img.pixels, img.width, img.height) catch {
                    w.interface.flush() catch {};
                    continue;
                };
                w.interface.flush() catch continue;
                entry.transmitted = true;
            }
            var buf: [160]u8 = undefined;
            var pw = std.Io.Writer.fixed(&buf);
            tui.kitty.placeWithId(&pw, entry.kitty_id, r.inline_images.placement_id, .{
                .col = pl.rect.x,
                .row = pl.rect.y,
                .cols = pl.rect.width,
                .rows = pl.rect.height,
                .src = pl.src,
            }) catch continue;
            term.writeRaw(buf[0..pw.end]);
            entry.placed_gen = frame_gen;
        }
    }

    for (app.inline_images.entries.items) |entry| {
        if (entry.placed_gen == 0 or entry.placed_gen == frame_gen) continue;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        tui.kitty.deletePlacement(&w, entry.kitty_id, r.inline_images.placement_id) catch continue;
        term.writeRaw(buf[0..w.end]);
        entry.placed_gen = 0;
    }
}

fn captureGraphics(app: *App, resize_generation: u64) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "graphics", .{});
    defer file.close(std.testing.io);
    var term: tui.Terminal = undefined;
    term.stdout = file;
    term.io = std.testing.io;
    term.resize_generation = resize_generation;
    syncGraphics(std.testing.io, &term, app);
    return tmp.dir.readFileAlloc(std.testing.io, "graphics", std.testing.allocator, .limited(4096));
}

test "resized graphics retransmit pixels before placing visible and previously hidden images" {
    const gpa = std.testing.allocator;
    var pixels = [_]u8{ 255, 0, 0, 255 };
    var entry: r.inline_images.Entry = .{
        .agent_id = .{ .index = 1, .generation = 0 },
        .call_id = "image",
        .kitty_id = 1_000_000,
        .img = .{ .width = 1, .height = 1, .pixels = &pixels },
        .state = .init(.ready),
    };
    var hidden = entry;
    hidden.kitty_id += 1;
    hidden.transmitted = true;
    var app: App = undefined;
    app.gpa = gpa;
    app.kitty_graphics = true;
    app.graphics_resize_gen = 0;
    app.inline_frame_gen = 0;
    app.inline_images = .{};
    defer app.inline_images.entries.deinit(gpa);
    try app.inline_images.entries.appendSlice(gpa, &.{ &entry, &hidden });
    app.inline_pending_deletes = .empty;
    defer app.inline_pending_deletes.deinit(gpa);
    app.inline_placements = .empty;
    defer app.inline_placements.deinit(gpa);
    try app.inline_placements.append(gpa, .{
        .entry = &entry,
        .rect = .{ .x = 2, .y = 3, .width = 1, .height = 1 },
        .src = .{ .w = 1, .h = 1 },
    });
    app.image_viewer = null;
    app.image_view_pending_delete = 0;

    const transmit = "a=t,f=32,s=1,v=1,i=1000000";
    const place = "a=p,i=1000000,p=1";
    for ([_]u64{ 0, 0, 1, 1, 2 }) |generation| {
        const was_transmitted = entry.transmitted;
        const resized = app.graphics_resize_gen != generation;
        const bytes = try captureGraphics(&app, generation);
        defer gpa.free(bytes);
        const placement = std.mem.indexOf(u8, bytes, place) orelse return error.TestUnexpectedResult;
        const transmission = std.mem.indexOf(u8, bytes, transmit);
        if (resized or !was_transmitted) {
            try std.testing.expect(transmission != null);
            try std.testing.expect(transmission.? < placement);
        } else {
            try std.testing.expect(transmission == null);
        }
        try std.testing.expect(entry.transmitted);
        try std.testing.expect(entry.placed_gen != 0);
    }
    try std.testing.expect(!hidden.transmitted);
    app.inline_placements.items[0].entry = &hidden;
    const restored = try captureGraphics(&app, 2);
    defer gpa.free(restored);
    try std.testing.expect(std.mem.indexOf(u8, restored, "a=t,f=32,s=1,v=1,i=1000001") != null);
    try std.testing.expect(std.mem.indexOf(u8, restored, "a=p,i=1000001,p=1") != null);

    app.image_viewer = .{
        .id = 1001,
        .img = entry.img,
        .image_rect = .{ .width = 2, .height = 2 },
        .transmitted = true,
    };
    const viewer_bytes = try captureGraphics(&app, 3);
    defer gpa.free(viewer_bytes);
    const viewer_transmit = std.mem.indexOf(u8, viewer_bytes, "a=t,f=32,s=1,v=1,i=1001") orelse return error.TestUnexpectedResult;
    const viewer_place = std.mem.indexOf(u8, viewer_bytes, "a=p,i=1001,p=1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(viewer_transmit < viewer_place);
    try std.testing.expect(app.image_viewer.?.transmitted);
    try std.testing.expect(!hidden.transmitted);
    const next_frame = try captureGraphics(&app, 3);
    defer gpa.free(next_frame);
    try std.testing.expect(std.mem.indexOf(u8, next_frame, "a=t") == null);
    app.image_viewer = null;
    const reopened = try captureGraphics(&app, 3);
    defer gpa.free(reopened);
    try std.testing.expect(std.mem.indexOf(u8, reopened, "a=t,f=32,s=1,v=1,i=1000001") != null);
}

/// Prints the resume hint once the terminal is back on the normal screen.
fn printSessionHint(store: *session_store.Store, id_buf: *[session_store.ID_LEN]u8) void {
    if (!store.holdsChat()) return;
    const id = store.currentId(id_buf) orelse return;
    std.debug.print("session saved: {s} - blitz continue {s}\n", .{ id, id });
}

/// Headless mode: send the prompt, drain the agent loop, print the final
/// assistant message to stdout. Permissions are always skipped; ask_user
/// auto-picks the "(recommended)" option.
fn runHeadless(app: *App, io: std.Io, prompt: []const u8) !void {
    const alloc = app.sessionAlloc();
    const parts = try alloc.dupe(r.sdk.Part, &.{.{ .text = prompt }});
    try app.sendPrompt(io, parts, prompt);

    while (app.running) {
        try app.cmd_queue.apply(io, app);
        try app.tick();
        resolvePermissionsHeadless(app, io);
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    const out = std.Io.File.stdout();
    var found = false;
    var i = app.timeline.items.len;
    while (i > 0) {
        i -= 1;
        const entry = app.timeline.items[i];
        if (entry.role != .agent) continue;
        for (entry.parts) |part| switch (part) {
            .message, .plain_text => |m| {
                try out.writeStreamingAll(io, m);
                try out.writeStreamingAll(io, "\n");
            },
            else => {},
        };
        found = true;
        break;
    }
    if (!found) {
        std.debug.print("Error: no agent response\n", .{});
        std.process.exit(1);
    }
    _ = app.drainPendingDiffs();
    printHeadlessFooter(app, io);
}

fn printHeadlessFooter(app: *App, io: std.Io) void {
    const agent = app.mainAgent() orelse return;
    const g = app.tool_status_entries.lock(io);
    const tool_count = g.ptr.agents[app.main_agent_id.?.index].entries.count();
    g.unlock();
    const cost = app.context_factory.modelCost(&app.config, agent.model.languageModel().modelId(), app.sdk_usage);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("\n[turns: {d}  tool-calls: {d}  tokens: {d}  cost: ${d:.4}]\n", .{
        app.step_count,
        tool_count,
        app.sdk_usage.total_tokens,
        cost,
    }) catch return;
    std.debug.print("{s}", .{buf[0..w.end]});
}

fn resolvePermissionsHeadless(app: *App, io: std.Io) void {
    const g = app.permission_queue.lock(io);
    defer g.unlock();
    while (g.ptr.items.len > 0) {
        const next = g.ptr.swapRemove(0);
        if (app.registry.state(next.agent_id) != .active) continue;
        next.state = switch (next.payload) {
            .ask => |a| r.permissions.recommendedChoice(a.options),
            else => .approved,
        };
        next.event.set(io);
    }
}

pub const AppCommand = union(enum) {
    /// /ssh user@domain:/path/to/cwd
    ssh: SshArgs,
    /// /ssh off  (or bare /ssh)
    ssh_off,

    pub const SshArgs = struct { user: []const u8, host: []const u8, cwd: []const u8 };

    pub fn parse(raw: []const u8) ?AppCommand {
        const input = if (raw.len > 0 and raw[0] == '/') raw[1..] else raw;
        var it = std.mem.splitScalar(u8, input, ' ');
        const verb = it.first();
        const rest = it.rest();

        if (std.mem.eql(u8, verb, "ssh")) {
            if (rest.len == 0 or std.mem.eql(u8, rest, "off")) return .ssh_off;
            return parseSsh(rest);
        }
        return null;
    }

    fn parseSsh(arg: []const u8) ?AppCommand {
        const at = std.mem.indexOfScalar(u8, arg, '@') orelse return null;
        const after_at = arg[at + 1 ..];
        const colon = std.mem.indexOfScalar(u8, after_at, ':') orelse return null;
        const cwd = std.mem.trim(u8, after_at[colon + 1 ..], " \t");
        return .{ .ssh = .{
            .user = arg[0..at],
            .host = after_at[0..colon],
            .cwd = if (cwd.len == 0) "/" else cwd,
        } };
    }
};

fn approvalFail(val: []const u8) noreturn {
    std.debug.print("blitz: invalid --approval mode '{s}' (strict|default|yolo)\n", .{val});
    std.process.exit(2);
}

pub const CliFlags = packed struct {
    /// enable debug log writing
    debug_log: bool = false,
    /// permission required
    approval_mode: r.permissions.ApprovalMode = .default,
    approval_explicit: bool = false,
    /// don't inject the local AGENTS.md
    no_context: bool = false,
    /// run --prompt headless, print final message instead of tui
    headless: bool = false,
    cleanup_sessions: bool = false,

    fn applyToken(self: *CliFlags, tok: []const u8, value: ?[]const u8) bool {
        if (std.mem.eql(u8, tok, "--log")) {
            self.debug_log = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--strict")) {
            self.approval_mode = .strict;
            self.approval_explicit = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--yolo")) {
            self.approval_mode = .yolo;
            self.approval_explicit = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--approval")) {
            const val = value orelse approvalFail("");
            if (val.len == 0 or val[0] == '-') approvalFail(val);
            var buf: [16]u8 = undefined;
            if (val.len > buf.len) approvalFail(val);
            self.approval_mode = r.permissions.parseApprovalMode(
                std.ascii.lowerString(&buf, val),
            ) orelse approvalFail(val);
            self.approval_explicit = true;
            return true;
        }

        if (std.mem.startsWith(u8, tok, "--approval=")) {
            const inline_value = tok["--approval=".len..];
            _ = self.applyToken("--approval", inline_value);
            return true;
        }

        if (std.mem.eql(u8, tok, "--clean")) {
            self.no_context = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--headless")) {
            self.headless = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--sessions")) {
            self.cleanup_sessions = true;
            return true;
        }

        return false;
    }
};

/// Splits raw args into flags and positionals. Flags may appear anywhere;
/// positionals keep their relative order. Unknown `--*` tokens are dropped
/// silently to avoid them being misparsed as commands.
pub const CliArgs = struct {
    flags: CliFlags,
    positional: []const [:0]const u8,
    /// value of `--prompt`; maps onto the `prompt` command, headless when combined with --headless
    prompt: ?[:0]const u8 = null,

    pub fn split(args: std.process.Args, buf: [][:0]const u8) CliArgs {
        var flags = CliFlags{};
        var n: usize = 0;
        var prompt: ?[:0]const u8 = null;

        var it = args.iterate();
        _ = it.next(); // skip exe name

        var pending_prompt = false;
        var pending_approval = false;
        while (it.next()) |arg| {
            if (pending_prompt) {
                pending_prompt = false;
                if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                    _ = flags.applyToken(arg, null);
                } else {
                    prompt = arg;
                }
                continue;
            }
            if (pending_approval) {
                pending_approval = false;
                _ = flags.applyToken("--approval", arg);
                continue;
            }
            if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--prompt")) {
                    pending_prompt = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--approval")) {
                    pending_approval = true;
                    continue;
                }
                _ = flags.applyToken(arg, null);
                continue;
            }
            if (n < buf.len) {
                buf[n] = arg;
                n += 1;
            }
        }

        return .{ .flags = flags, .positional = buf[0..n], .prompt = prompt };
    }
};

pub const CliCommand = union(enum) {
    run: []const u8, // '.', './', /full/path/to/dir
    prompt: []const u8, // prefill input in CWD
    cont: ?[]const u8, // resume a session (null = most recent)
    /// list the last sessions recorded for the current directory
    sessions,
    help,
    update,
    cleanup,

    pub const ParseResult = union(enum) {
        cmd: CliCommand,
        err: []const u8,
        none, // no command given — fall through to interactive REPL
    };

    pub fn parse(positional: []const [:0]const u8) ParseResult {
        if (positional.len == 0) return .none;

        const head = positional[0];
        const rest = positional[1..];

        if (std.mem.eql(u8, head, "prompt")) {
            const sub = rest[0];
            return .{ .cmd = .{ .prompt = sub } };
        }

        if (std.mem.eql(u8, head, "continue")) {
            return .{ .cmd = .{ .cont = if (rest.len > 0) rest[0] else null } };
        }

        if (std.mem.eql(u8, head, "sessions")) {
            return .{ .cmd = .sessions };
        }

        if (std.mem.eql(u8, head, "update")) return .{ .cmd = .update };

        if (std.mem.eql(u8, head, "cleanup")) return .{ .cmd = .cleanup };

        if (std.mem.eql(u8, head, "help")) return .{ .cmd = .help };

        return .{ .cmd = .{ .run = head } };
    }
};
