// ----------------------------------------------------------------
// Blitzdenk 0.1
// Copyright (c) 2026 Lorenz Mielke. All Rights Reserved.
// ----------------------------------------------------------------
const std = @import("std");
const builtin = @import("builtin");
const ct = @cImport({
    @cInclude("time.h");
});
const r = @import("root.zig");
const App = r.app.App;
const BlitzdenkCfg = r.config.BlitzdenkCfg;

const ChatEntry = r.app.ChatEntry;
const lua = r.lua;
const reg = r.ContextFactory;
const skills = r.skills;
const keys = r.keys;
const util = r.util;
const session = r.session;
const session_store = r.session_store;
const tui = r.tui;
const tools = r.tools;

// ----------------------------------------------------------------
pub const DEFAULT_CONFIG_PATH = r.defaults.CONFIG_DIR;
pub const DEFAULT_CACHE_PATH = "cache.zon";
pub const DEFAULT_LUA_CONFIG = "blitz.lua";
const IO_THREAD_STACK_SIZE = 2 * 1024 * 1024;
const IO_THREAD_LIMIT = 32;

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

    const abs_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ HOME, DEFAULT_CONFIG_PATH ++ DEFAULT_LUA_CONFIG });
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ HOME, DEFAULT_CONFIG_PATH });
    return .{ .abs_path = abs_path, .dir_path = dir_path };
}

fn scanDirMaxMtime(io: std.Io, path: []const u8) i128 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var max_mtime: i128 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!isReloadableConfigLua(entry.name)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.nanoseconds > max_mtime) max_mtime = stat.mtime.nanoseconds;
    }
    return max_mtime;
}

fn isReloadableConfigLua(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".lua") and !std.mem.eql(u8, name, "meta.lua");
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
        .url => w.step = r.wizard.nextStep(.url, r.wizard.catalogEntry(w.provider_index) orelse return, w.model_buf[0..w.model_len]),
        .key => w.step = r.wizard.nextStep(.key, r.wizard.catalogEntry(w.provider_index) orelse return, w.model_buf[0..w.model_len]),
        .model => {
            if (w.model_len == 0) return;
            w.step = r.wizard.nextStep(.model, r.wizard.catalogEntry(w.provider_index) orelse return, w.model_buf[0..w.model_len]);
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
                w.url_len = 0;
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
    var io_state = std.Io.Threaded.init(init.gpa, .{
        .stack_size = IO_THREAD_STACK_SIZE,
        .async_limit = .limited(IO_THREAD_LIMIT),
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
    if (cli_flags.debug_log or builtin.mode == .Debug) openDebugLog(io, init.environ_map);

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
                \\
                \\Flags:
                \\  --log              write debug.log in path
                \\  --approval <mode>  strict|default|yolo|smart (default: default)
                \\  --strict           shortcut for --approval strict
                \\  --yolo             shortcut for --approval yolo
                \\  --clean            skip local user context
                \\  --prompt "STRING"  prefill input in current cwd
                \\  --headless         with --prompt: run headless, print final message
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
    defer app.deinit();
    app.enterSessionPicker(rows);

    var term = try tui.Terminal.init(arena, io);
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
        exec_pool.cancelAll();
        registry.cancelAll();
        r.artifact.cleanup(&exec_pool);
        app.deinit();
        registry.deinit();
        exec_pool.deinit();
    }
    app.lua_vm.setApp(&app);
    app.lua_vm.clearLastError();

    var lua_load_failed = false;
    if (config_lua) |info| {
        const inject = try std.fmt.allocPrint(arena, "package.path = \"{s}?.lua;\" .. package.path", .{info.dir_path});
        app.lua_vm.exec(inject) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to configure lua package.path: {s} ({any})", .{ app.lua_vm.getLastError(), err });
        };
        app.lua_vm.load(info.abs_path) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to load {s}: {s} ({any})", .{ info.abs_path, app.lua_vm.getLastError(), err });
        };
    }
    if (cwdBlitzLuaExists(io)) {
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
    context_factory.precalcGeneralPromptSize();

    for (lua_binds) |bind| {
        try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn }, .description = bind.description });
    }

    var cwd_lua_mtime: i128 = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch break :blk 0;
        break :blk stat.mtime.nanoseconds;
    };
    var config_lua_mtime: i128 = if (config_lua) |info| scanDirMaxMtime(io, info.dir_path) else 0;
    var reload_tick: u32 = 0;

    app.reset();
    app.flags.approval_mode = flags.approval_mode;
    if (wizard_pending) app.enterWizard();
    if (app.input_mode != .wizard) app.warnUnboundAgentModels();

    var store = session_store.Store{ .io = io, .gpa = gpa, .base = cwd_dir };
    defer store.deinit();
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
            std.debug.print("Error: session '{s}' has no usable checkpoint\n", .{resolved});
            return error.SessionNotFound;
        };
        var resumed = false;
        if (session.applySaveState(&app, &loaded.save)) |_| {
            resumed = true;
        } else |err| {
            // Fall back to a fresh journal: binding the resumed one would let
            // a later compaction destroy the session's original checkpoints.
            std.log.scoped(.session).warn("resume of {s} failed: {s}", .{ resolved, @errorName(err) });
        }
        if (resumed) {
            try store.open(file_name);
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
    checkpoint(&app, &store);

    app.loadHistory(history_store_dir);
    try app.cmd_queue.apply(io, &app);

    if (headless) {
        try runHeadless(&app, io, prompt.?);
        checkpoint(&app, &store);
        printSessionHint(&store, &session_id_buf);
        return;
    }

    app.startUpdateCheck();

    if (prompt) |p| {
        try app.input_buffer.appendSlice(app.sessionAlloc(), p);
        app.input_cursor = @intCast(app.input_buffer.items.len);
    }

    // Terminal is scoped so its restore happens before the session hint is
    // printed — on the normal screen, where the user can actually read it.
    var exit_hint: bool = false;
    {
        var term = try tui.Terminal.init(arena, io);
        defer term.deinit();

        var was_running = app.running;
        var error_fade_pending = false;
        main_loop: while (true) {
            // tick notifications
            const had_visible_notifications = app.notifications.hasVisible();
            app.notifications.tick(1.0 / 60.0);
            if (had_visible_notifications or app.notifications.hasVisible()) app.dirty = true;
            const error_fading = app.lua_vm.errorNeedsFrame(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
            if (error_fading or error_fade_pending) app.dirty = true;
            error_fade_pending = error_fading;

            if (app.dirty or app.main_agent_id == null) {
                try term.drawWith(&app, App.render);
                app.frame_count +%= 1;
                app.dirty = false;
            }

            // TODO: cleanup state
            if (app.running) app.dirty = true;

            // Drain new agent messages from broadcast into chat_entries
            // app.drainBroadcast();
            // Mirror in-progress streaming message so TUI shows tokens as they arrive.
            perm: {
                if (app.active_permission != null) break :perm;

                const g = app.permission_queue.lock(io);
                defer g.unlock();

                if (g.ptr.items.len == 0) break :perm;

                for (0..g.ptr.items.len) |_| {
                    const next = g.ptr.swapRemove(0);
                    const is_ask = next.payload == .ask or next.payload == .plan;

                    // The Lua hook decides first. Only the fallback path
                    // reaches the approval-mode check and the TUI.
                    if (app.luaPermissionDecision(next)) |decision| {
                        try app.persist_permission_to_history(next);
                        next.state = decision;
                        next.event.set(app.io);
                        continue;
                    }

                    // check permission level against flags
                    app.mu.lockUncancelable(app.io);
                    const mode = app.flags.approval_mode;
                    app.mu.unlock(app.io);
                    if (r.permissions.shouldAutoApprove(mode, is_ask, app.exec_pool.ssh_active)) {
                        try app.persist_permission_to_history(next);
                        next.state = .approved;
                        next.event.set(app.io);
                        continue;
                    }

                    if (app.registry.state(next.agent_id) == .active) {
                        app.active_permission = next;
                        break :perm;
                    }
                }
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

            // Lua hot-reload: poll mtime every ~1s (cwd blitz.lua + config dir)
            reload_tick +%= 1;
            const reload_requested = app.lua_reload_requested.load(.acquire);
            if (reload_tick >= 60 or reload_requested) {
                reload_tick = 0;
                const new_cwd_mtime: i128 = blk: {
                    const stat = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch break :blk 0;
                    break :blk stat.mtime.nanoseconds;
                };
                const new_config_mtime: i128 = if (config_lua) |info| scanDirMaxMtime(io, info.dir_path) else 0;

                if (reload_requested or new_cwd_mtime != cwd_lua_mtime or new_config_mtime != config_lua_mtime) blk: {
                    try app.waitForMcpTools();
                    // Tool worker may currently hold
                    // vm_mu. Skip this tick if busy — mtime stays unchanged so we retry.
                    if (!app.lua_vm.vm_mu.tryLock()) break :blk;
                    defer app.lua_vm.vm_mu.unlock(io);

                    cwd_lua_mtime = new_cwd_mtime;
                    config_lua_mtime = new_config_mtime;

                    app.lua_vm.clearLastError();
                    app.event_bus.clear(io);
                    app.lua_inject_hooks_enabled.store(false, .release);
                    var lua_reload_failed = false;

                    app.lua_vm.reset() catch |err| {
                        lua_reload_failed = true;
                        std.log.scoped(.lua).err("hot-reload: failed to reset lua vm ({any})", .{err});
                    };
                    app.clearSelections(false);
                    context_factory.resetDefs();
                    try context_factory.resetLoadedTools();
                    if (config_lua) |info| {
                        const inject = std.fmt.allocPrint(arena, "package.path = \"{s}?.lua;\" .. package.path", .{info.dir_path}) catch null;
                        if (inject) |code| app.lua_vm.exec(code) catch |err| {
                            lua_reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to configure lua package.path: {s} ({any})", .{ app.lua_vm.getLastError(), err });
                        };
                        app.lua_vm.load(info.abs_path) catch |err| {
                            lua_reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to load {s}: {s} ({any})", .{ info.abs_path, app.lua_vm.getLastError(), err });
                        };
                    }
                    if (cwdBlitzLuaExists(io)) {
                        app.lua_vm.load("blitz.lua") catch |err| {
                            lua_reload_failed = true;
                            std.log.scoped(.lua).err("hot-reload: failed to load blitz.lua: {s} ({any})", .{ app.lua_vm.getLastError(), err });
                        };
                    }
                    if (!lua_reload_failed) app.lua_vm.clearLastError();
                    app.lua_vm.readConfigFields();
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
                    context_factory.precalcGeneralPromptSize();

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
                    app.keymap.custom.clearRetainingCapacity();
                    for (lua_binds) |bind| {
                        try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn }, .description = bind.description });
                    }

                    if (reload_requested) app.lua_reload_failed.store(false, .release);
                    try app.refreshLiveAgentTools();
                    if (reload_requested) app.markLuaReloadDone();
                }
            }

            term.pollAndEnqueue(16);
            try app.tick();

            while (true) {
                const next_event = term.nextEvent();
                if (next_event != .none) app.dirty = true;
                switch (next_event) {
                    .key => |k| {
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
                                .clear_session => {
                                    try app.cmd_queue.append(io, .reset_session);
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
                                .cursor_left => app.input_cursor -|= 1,
                                .cursor_right => {
                                    app.input_cursor = @min(app.input_cursor + 1, app.input_buffer.items.len);
                                },
                                .cursor_up => {
                                    if (app.completionIsOpen()) {
                                        app.handleCompletion(.prev);
                                        continue;
                                    }
                                },
                                .cursor_down => {
                                    if (app.completionIsOpen()) {
                                        app.handleCompletion(.next);
                                        continue;
                                    }
                                },
                                .noop => {},
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
                                    if (app.input_mode == .text) app.pasteImage();
                                    continue;
                                },
                            }
                        }
                        switch (k.code) {
                            .char => |c| {
                                switch (app.input_mode) {
                                    .text => {
                                        app.appendBytes(k.textSlice());
                                    },
                                    .perm_select => |*ps| {
                                        const max_sel = app.permSelectMaxIndex();
                                        if (c == 'j' and ps.selected < max_sel) ps.selected += 1;
                                        if (c == 'k' and ps.selected > 0) ps.selected -= 1;
                                    },
                                    .perm_message => |*pm| {
                                        const ts = k.textSlice();
                                        if (pm.len + ts.len <= pm.buf.len) {
                                            @memcpy(pm.buf[pm.len..][0..ts.len], ts);
                                            pm.len += ts.len;
                                        }
                                    },
                                    .passphrase => |*pp| {
                                        const ts = k.textSlice();
                                        if (pp.len + ts.len <= pp.buf.len) {
                                            @memcpy(pp.buf[pp.len..][0..ts.len], ts);
                                            pp.len += ts.len;
                                        }
                                    },
                                    .wizard => |*w| {
                                        if (w.stepIsList()) {
                                            if (c == 'j') w.moveCursor(1);
                                            if (c == 'k') w.moveCursor(-1);
                                        } else {
                                            w.storeText(k.textSlice());
                                        }
                                    },
                                    .session_picker => {},
                                }
                            },
                            .arrow_up => switch (app.input_mode) {
                                .text => if (!app.running) app.historyUp(),
                                .perm_select => |*ps| {
                                    if (ps.selected > 0) ps.selected -= 1;
                                },
                                .perm_message => {},
                                .passphrase => {},
                                .wizard => |*w| {
                                    w.moveCursor(-1);
                                },
                                .session_picker => {},
                            },
                            .arrow_down => switch (app.input_mode) {
                                .text => if (!app.running) app.historyDown(),
                                .perm_select => |*ps| {
                                    const max_sel = app.permSelectMaxIndex();
                                    if (ps.selected < max_sel) ps.selected += 1;
                                },
                                .perm_message => {},
                                .passphrase => {},
                                .wizard => |*w| {
                                    w.moveCursor(1);
                                },
                                .session_picker => {},
                            },
                            .backspace => switch (app.input_mode) {
                                .text => app.deleteChar(),
                                .perm_select => {},
                                .perm_message => |*pm| {
                                    while (pm.len > 0) {
                                        pm.len -= 1;
                                        if ((pm.buf[pm.len] & 0xC0) != 0x80) break;
                                    }
                                },
                                .passphrase => |*pp| {
                                    while (pp.len > 0) {
                                        pp.len -= 1;
                                        if ((pp.buf[pp.len] & 0xC0) != 0x80) break;
                                    }
                                },
                                .wizard => |*w| {
                                    if (w.activeText()) |target| {
                                        if (target.len.* > 0) {
                                            target.len.* -= 1;
                                            while (target.len.* > 0 and (target.buf[target.len.*] & 0xC0) == 0x80) {
                                                target.len.* -= 1;
                                            }
                                            @memset(target.buf[target.len.*..], 0);
                                        }
                                    }
                                },
                                .session_picker => {},
                            },
                            .enter => switch (app.input_mode) {
                                .perm_message => |*pm| {
                                    if (app.active_permission == null) {
                                        if (app.active_selection != null) {
                                            if (pm.len == 0) {
                                                app.enterPermSelect();
                                                break;
                                            }
                                            const sel_msg = pm.buf[0..pm.len];
                                            app.resolveActiveSelection(sel_msg, null);
                                            break;
                                        }
                                    }
                                    const entry = app.active_permission orelse break;

                                    const is_ask = entry.payload == .ask;

                                    if (pm.len == 0) {
                                        app.enterPermSelect();
                                        break;
                                    }
                                    const msg = pm.buf[0..pm.len];
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
                                        0 => {
                                            try app.persist_permission_to_history(entry);
                                            app.resolveActivePermission(.approved);
                                        },
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
                                    if (app.input_buffer.items.len == 0) break;
                                    const input = std.fmt.allocPrint(app.sessionAlloc(), "{f}", .{std.unicode.fmtUtf8(app.inputSlice())}) catch break;
                                    var send_text: []const u8 = input;
                                    var chat_text: []const u8 = input;

                                    // -- user commands (processed even while a session is running)
                                    if (input[0] == '/') {
                                        if (app.lua_vm.vm_mu.tryLock()) {
                                            defer app.lua_vm.vm_mu.unlock(io);
                                            if (app.lua_vm.invokeCommand(input)) {
                                                app.pushHistory(history_store_dir, input);
                                                app.input_buffer.clearRetainingCapacity();
                                                break;
                                            }
                                        } else {
                                            break;
                                        }

                                        const cmd = AppCommand.parse(input);

                                        if (cmd) |c| {
                                            switch (c) {
                                                .ssh => |args| {
                                                    handleSshCommand(&app, app.exec_pool, gpa, args);
                                                    app.input_buffer.clearRetainingCapacity();
                                                },
                                                .ssh_off => {
                                                    app.exec_pool.clearSsh();
                                                    app.invalidatePathCompletions();
                                                    app.notifications.append(gpa, "SSH mode disabled", .{}) catch {};
                                                    app.input_buffer.clearRetainingCapacity();
                                                },
                                            }
                                            break;
                                        }

                                        if (reg.parseSshAliasCommand(input)) |alias| {
                                            if (app.context_factory.findSshAlias(alias)) |target| {
                                                handleSshCommand(&app, app.exec_pool, gpa, .{
                                                    .user = target.user,
                                                    .host = target.host,
                                                    .cwd = target.cwd,
                                                });
                                            } else {
                                                app.pushSystemMessage("unknown ssh alias: {s}", .{alias});
                                            }
                                            app.input_buffer.clearRetainingCapacity();
                                            break;
                                        }

                                        if (skills.parseSkillCommand(input)) |sc| {
                                            const entry = app.context_factory.skills.find(sc.name) orelse {
                                                app.pushSystemMessage("unknown skill: {s}", .{sc.name});
                                                app.input_buffer.clearRetainingCapacity();
                                                break;
                                            };
                                            if (!entry.meta.user_invocable) {
                                                app.pushSystemMessage("skill '{s}' is not user-invocable", .{entry.meta.name});
                                                app.input_buffer.clearRetainingCapacity();
                                                break;
                                            }
                                            const loaded = skills.loadSkill(app.io, app.sessionAlloc(), entry) orelse {
                                                app.pushSystemMessage("unknown skill: {s}", .{sc.name});
                                                app.input_buffer.clearRetainingCapacity();
                                                break;
                                            };
                                            send_text = skills.skillSendText(app.sessionAlloc(), loaded.body, sc.prompt) catch break;
                                            chat_text = skills.skillChatText(app.sessionAlloc(), entry.meta.name, sc.prompt) catch break;
                                        } else {
                                            break;
                                        }
                                    }

                                    if (app.running) {
                                        app.pushHistory(history_store_dir, input);
                                        app.event_bus.emit(&app, .{ .user_message_sent = chat_text });
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

                                            const chat_msg = try ChatEntry.userMessageSimple(alloc, .user, chat_text);
                                            try app.cmd_queue.append(io, .{ .queue_agent_message = .{
                                                .agent_id = agent_id,
                                                .parts = parts,
                                                .chat_entry = chat_msg,
                                            } });
                                        }

                                        try app.cmd_queue.append(io, .{ .scroll_down = 999999 });
                                        app.screenshot_buf = null;
                                        app.input_buffer.clearRetainingCapacity();
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

                                    try app.sendPrompt(io, parts, chat_text);
                                    app.input_buffer.clearRetainingCapacity();
                                },
                                .passphrase => {
                                    handleSshUnlock(&app, app.exec_pool, gpa);
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
                                        app.input_buffer.clearRetainingCapacity();
                                        app.input_cursor = 0;
                                    }
                                },
                                .passphrase => {
                                    app.pushSystemMessage("ssh: passphrase entry canceled", .{});
                                    app.returnToText();
                                },
                                else => {},
                            },
                            else => {},
                        }
                    },
                    .paste => |text| switch (app.input_mode) {
                        .text => app.pasteImageOrText(text),
                        .perm_message => |*pm| {
                            if (pm.len + text.len <= pm.buf.len) {
                                @memcpy(pm.buf[pm.len..][0..text.len], text);
                                pm.len += text.len;
                            }
                        },
                        .perm_select => {},
                        .passphrase => |*pp| {
                            if (pp.len + text.len <= pp.buf.len) {
                                @memcpy(pp.buf[pp.len..][0..text.len], text);
                                pp.len += text.len;
                            }
                        },
                        .wizard => |*w| {
                            w.storeText(text);
                        },
                        .session_picker => {},
                    },
                    .mouse => |m| {
                        const wheel = term.handleMouse(m);
                        if (wheel < 0) {
                            try app.cmd_queue.append(io, .{ .scroll_up = @intCast(-wheel) });
                        } else if (wheel > 0) {
                            try app.cmd_queue.append(io, .{ .scroll_down = @intCast(wheel) });
                        }
                    },
                    .resize => {},
                    .none => break,
                }
            }

            try app.cmd_queue.apply(io, &app);

            if (was_running and !app.running) checkpoint(&app, &store);
            was_running = app.running;
        }
        exit_hint = true;
    } // tui_phase

    checkpoint(&app, &store);
    if (exit_hint) printSessionHint(&store, &session_id_buf);
}

test "generated Lua metadata is not reloadable config" {
    try std.testing.expect(isReloadableConfigLua("blitz.lua"));
    try std.testing.expect(isReloadableConfigLua("tools.lua"));
    try std.testing.expect(!isReloadableConfigLua("meta.lua"));
    try std.testing.expect(!isReloadableConfigLua(".luarc.json"));
}

fn wizardCatalogIndexOf(name: []const u8) usize {
    for (r.wizard.catalog, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) return i;
    }
    unreachable;
}

test "provider step enter commits the selected catalog row" {
    var w: r.app.InputMode.Wizard = .{};
    w.step = .provider;
    w.list_selected = wizardCatalogIndexOf("Ollama");

    w.enterProvider();

    const ollama = r.wizard.catalog[wizardCatalogIndexOf("Ollama")];
    try std.testing.expectEqualStrings(ollama.provider_type, w.provider_type_buf[0..w.provider_type_len]);
    try std.testing.expectEqualStrings(ollama.default_url, w.url_buf[0..w.url_len]);
    try std.testing.expectEqual(r.wizard.Step.url, w.step);
}

test "model selection change preserves typed free text across row moves" {
    const r_app = r.app;
    var w: r_app.InputMode.Wizard = .{};
    w.step = .model;
    w.provider_index = 0;
    w.model_free_text = true;
    w.list_selected = 3;
    const typed = "my-custom-model";
    w.model_len = typed.len;
    @memcpy(w.model_buf[0..typed.len], typed);

    w.moveCursor(0);

    try std.testing.expect(w.model_free_text);
    try std.testing.expectEqualStrings(typed, w.model_buf[0..w.model_len]);

    w.list_selected = 1;
    w.moveCursor(0);
    try std.testing.expect(!w.model_free_text);
    try std.testing.expectEqualStrings(r.wizard.catalog[0].models[1].name, w.model_buf[0..w.model_len]);
}

test "entering the model step preselects the first curated row" {
    var w: r.app.InputMode.Wizard = .{};
    w.step = .provider;
    w.list_selected = wizardCatalogIndexOf("Anthropic");
    w.enterProvider();
    try std.testing.expectEqual(r.wizard.Step.key, w.step);
    w.step = .model;
    w.resetModel();

    if (w.step == .model and !w.model_free_text and w.model_len == 0) {
        w.moveCursor(0);
    }

    const anthropic = r.wizard.catalog[wizardCatalogIndexOf("Anthropic")];
    try std.testing.expectEqualStrings(anthropic.models[0].name, w.model_buf[0..w.model_len]);
    try std.testing.expect(!w.model_free_text);
}

test "custom endpoint model step accepts typed input immediately" {
    var w: r.app.InputMode.Wizard = .{};
    w.step = .provider;
    w.list_selected = wizardCatalogIndexOf("Custom endpoint");
    w.enterProvider();

    try std.testing.expectEqual(r.wizard.Step.provider_type, w.step);
    w.finishProviderType();
    try std.testing.expectEqual(r.wizard.Step.url, w.step);
    w.step = r.wizard.Step.model;
    w.syncModelStep();

    try std.testing.expect(!w.stepIsList());
    try std.testing.expect(w.activeText() != null);
    try std.testing.expectEqualStrings("", w.model_buf[0..w.model_len]);

    w.storeText("my-model-id");
    try std.testing.expectEqualStrings("my-model-id", w.model_buf[0..w.model_len]);
    try std.testing.expect(w.model_len > 0);

    w.moveCursor(1);
    try std.testing.expectEqualStrings("my-model-id", w.model_buf[0..w.model_len]);
}

test "free text survives curated row detours" {
    var w: r.app.InputMode.Wizard = .{};
    w.step = .model;
    w.provider_index = wizardCatalogIndexOf("Anthropic");
    w.resetModel();
    w.list_selected = r.wizard.catalog[wizardCatalogIndexOf("Anthropic")].models.len;
    w.moveCursor(0);
    try std.testing.expect(w.model_free_text);

    w.storeText("claude-custom");
    const free_row = r.wizard.catalog[wizardCatalogIndexOf("Anthropic")].models.len;
    w.list_selected = free_row - 1;
    w.moveCursor(0);
    try std.testing.expect(!w.model_free_text);
    try std.testing.expectEqualStrings(r.wizard.catalog[wizardCatalogIndexOf("Anthropic")].models[2].name, w.model_buf[0..w.model_len]);

    w.list_selected = free_row;
    w.moveCursor(0);
    try std.testing.expect(w.model_free_text);
    try std.testing.expectEqualStrings("claude-custom", w.model_buf[0..w.model_len]);
}

/// Journal materializes lazily in appendCheckpoint; do not gate on file_name.
fn checkpoint(app: *App, store: *session_store.Store) void {
    const agent = app.mainAgent() orelse return;

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const save = session.buildSaveState(app, agent, alloc) catch |err| {
        std.log.scoped(.session).warn("checkpoint encode failed: {s}", .{@errorName(err)});
        return;
    };
    if (save.chat.len == 0) return;

    store.appendCheckpoint(save) catch |err| {
        std.log.scoped(.session).warn("checkpoint write failed: {s}", .{@errorName(err)});
    };
}

/// Prints the resume hint once the terminal is back on the normal screen.
/// Suppressed when the journal has no checkpoints, so a `blitz continue <id>`
/// built from the hint can never hit "no usable checkpoint".
fn printSessionHint(store: *session_store.Store, id_buf: *[session_store.ID_LEN]u8) void {
    if (store.checkpoint_count == 0) return;
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
    var i = app.chat_entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = app.chat_entries.items[i];
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
    printHeadlessFooter(app, io);
}

fn printHeadlessFooter(app: *App, io: std.Io) void {
    const agent = app.mainAgent() orelse return;
    const g = app.tool_status_entries.lock(io);
    const tool_count = g.ptr.agents[app.main_agent_id.?.index].entries.count();
    g.unlock();
    const cost = app.config.modelCost(agent.model.languageModel().modelId(), app.sdk_usage);

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

fn recommendedOption(options: []const []const u8) u8 {
    switch (r.permissions.recommendedChoice(options)) {
        .choice => |i| return i,
        else => unreachable,
    }
}

/// Probe `ssh -o BatchMode=yes user@host true`. On success → set SSH target
/// and announce. On failure → open the passphrase modal so the user can
/// unlock a key into ssh-agent and retry.
fn handleSshCommand(
    state: *App,
    cmd_pool: *r.exec.CmdPool,
    gpa: std.mem.Allocator,
    args: AppCommand.SshArgs,
) void {
    if (sshProbe(cmd_pool, gpa, args.user, args.host)) {
        cmd_pool.setSsh(args.user, args.host, args.cwd) catch {
            state.pushSystemMessage("ssh: failed to allocate target", .{});
            return;
        };
        probeRemoteHome(state, cmd_pool);
        state.notifications.append(gpa, "SSH mode enabled: {s}@{s}", .{ args.user, args.host }) catch {};
        state.remote_cwd = args.cwd;
    } else {
        state.enterPassphrase(args.user, args.host, args.cwd);
    }
}

fn probeRemoteHome(state: *App, cmd_pool: *r.exec.CmdPool) void {
    const res = cmd_pool.runAndWait(.{
        .argv = &.{ "sh", "-lc", "echo $HOME" },
    }) catch return;
    defer cmd_pool.alloc.free(res.stdout);
    defer cmd_pool.alloc.free(res.stderr);
    if (res.ty != .success) return;
    const home = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (home.len == 0 or home[0] != '/') return;
    state.setRemoteHome(home);
}

/// Returns true iff a non-interactive ssh probe succeeds (key already loaded
/// in agent). Returns false on any failure (auth, network, exit nonzero).
fn sshProbe(cmd_pool: *r.exec.CmdPool, gpa: std.mem.Allocator, user: []const u8, host: []const u8) bool {
    const target = std.fmt.allocPrint(gpa, "{s}@{s}", .{ user, host }) catch return false;
    defer gpa.free(target);
    const res = cmd_pool.runAndWait(.{
        .argv = &.{ "ssh", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "ConnectTimeout=5", target, "true" },
        .force_local = true,
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return res.ty == .success;
}

/// Called when user presses Enter inside the passphrase modal.
/// 1. Write a transient SSH_ASKPASS helper script to a tempfile.
/// 2. Run `setsid -w ssh-add` with env carrying the passphrase + SSH_ASKPASS.
/// 3. On success, re-probe → setSsh → status. On failure → status with stderr.
/// 4. Always zero passphrase + delete tempfile.
fn handleSshUnlock(state: *App, cmd_pool: *r.exec.CmdPool, gpa: std.mem.Allocator) void {
    const pp = &state.input_mode.passphrase;
    const passphrase = pp.buf[0..pp.len];
    const user = pp.user;
    const host = pp.host;
    const cwd = pp.cwd;

    defer state.returnToText();

    if (passphrase.len == 0) {
        state.pushSystemMessage("ssh: empty passphrase, canceled", .{});
        return;
    }

    // ssh-add talks to the agent over $SSH_AUTH_SOCK. Reuse an inherited
    // agent if its socket is alive; otherwise spawn one we own (killed on exit).
    const inherited = cmd_pool.env.get("SSH_AUTH_SOCK");
    const sock = cmd_pool.ensureAgent(inherited) catch |err| {
        state.pushSystemMessage("ssh: failed to start ssh-agent ({s})", .{@errorName(err)});
        return;
    };

    // Write helper script to /tmp/blitz-askpass-<pid>.sh (mode 0700).
    const pid = std.c.getpid();
    const script_path = std.fmt.allocPrint(gpa, "/tmp/blitz-askpass-{d}.sh", .{pid}) catch {
        state.pushSystemMessage("ssh: out of memory", .{});
        return;
    };
    defer gpa.free(script_path);

    const io = cmd_pool.io;
    defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};

    const script = "#!/bin/sh\nprintf '%s' \"$BLITZ_PASSPHRASE\"\n";
    {
        const f = std.Io.Dir.createFileAbsolute(io, script_path, .{}) catch {
            state.pushSystemMessage("ssh: failed to create askpass helper", .{});
            return;
        };
        defer f.close(io);
        std.Io.File.writeStreamingAll(f, io, script) catch {
            state.pushSystemMessage("ssh: failed to write askpass helper", .{});
            return;
        };
    }
    // Make the helper executable. Best-effort; ssh-add may fall back to other
    // discovery methods if this fails.
    {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..script_path.len], script_path);
        path_buf[script_path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&path_buf);
        _ = std.posix.system.chmod(z, 0o700);
    }

    // Build env with SSH_AUTH_SOCK (and other inherited vars), plus the overlay.
    var env = std.process.Environ.Map.init(gpa);
    var env_keep = false;
    defer if (!env_keep) {
        for (env.values()) |v| @memset(@constCast(v), 0);
        env.deinit();
    };

    const inherit_keys = [_][]const u8{ "HOME", "USER", "PATH", "TERM", "LANG", "LC_ALL" };
    for (inherit_keys) |k| {
        if (cmd_pool.env.get(k)) |v| env.put(k, v) catch {};
    }
    env.put("SSH_AUTH_SOCK", sock) catch {};
    env.put("SSH_ASKPASS", script_path) catch {};
    env.put("SSH_ASKPASS_REQUIRE", "force") catch {};
    env.put("DISPLAY", ":0") catch {};
    env.put("BLITZ_PASSPHRASE", passphrase) catch {};

    // Run ssh-add detached from any controlling tty so SSH_ASKPASS is used.
    env_keep = true; // ownership transfers into runAndWait
    const res = cmd_pool.runAndWait(.{
        .argv = &.{"ssh-add"},
        .env_overlay = env,
        .force_local = true,
    }) catch {
        state.pushSystemMessage("ssh: ssh-add failed to spawn", .{});
        // Pool consumed env; nothing to free here.
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    // Zero the passphrase in the modal buffer ASAP.
    @memset(pp.buf[0..pp.len], 0);

    if (res.ty != .success) {
        const trimmed = std.mem.trim(u8, res.stderr, " \t\r\n");
        if (trimmed.len > 0) {
            state.pushSystemMessage("ssh-add: {s}", .{trimmed});
        } else {
            state.pushSystemMessage("ssh-add: failed", .{});
        }
        return;
    }

    if (!sshProbe(cmd_pool, gpa, user, host)) {
        state.pushSystemMessage("ssh: key unlocked but probe failed", .{});
        return;
    }

    cmd_pool.setSsh(user, host, cwd) catch {
        state.pushSystemMessage("ssh: failed to allocate target", .{});
        return;
    };
    probeRemoteHome(state, cmd_pool);
    state.notifications.append(gpa, "SSH mode enabled: {s}@{s}", .{ user, host }) catch {};
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
    std.debug.print("blitz: invalid --approval mode '{s}' (strict|default|yolo|smart)\n", .{val});
    std.process.exit(2);
}

pub const CliFlags = packed struct {
    /// enable debug log writing
    debug_log: bool = false,
    /// permission required
    approval_mode: r.permissions.ApprovalMode = .default,
    /// don't load AGENTS.md
    no_context: bool = false,
    /// run --prompt headless, print final message instead of tui
    headless: bool = false,

    fn applyToken(self: *CliFlags, tok: []const u8, value: ?[]const u8) bool {
        if (std.mem.eql(u8, tok, "--log")) {
            self.debug_log = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--strict")) {
            self.approval_mode = .strict;
            return true;
        }

        if (std.mem.eql(u8, tok, "--yolo")) {
            self.approval_mode = .yolo;
            return true;
        }

        if (std.mem.eql(u8, tok, "--smart")) {
            self.approval_mode = .smart;
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

        if (std.mem.eql(u8, head, "help")) return .{ .cmd = .help };

        return .{ .cmd = .{ .run = head } };
    }
};
