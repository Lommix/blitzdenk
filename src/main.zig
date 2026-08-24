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
const tui = r.tui;
const tools = r.tools;

// ----------------------------------------------------------------
pub const DEFAULT_CONFIG_PATH = r.defaults.CONFIG_DIR;
pub const DEFAULT_CACHE_PATH = "cache.zon";
pub const DEFAULT_LUA_CONFIG = "blitz.lua";

test {
    std.testing.refAllDecls(@This());
}

// TUI owns stderr; Route std.log to debug.log in cwd instead. Using a raw POSIX fd with O_APPEND.
var debug_log_fd: std.posix.fd_t = -1;
fn openDebugLog(io: std.Io) void {
    util.ensureBlitzDir(std.Io.Dir.cwd(), io) catch return;
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    debug_log_fd = std.posix.openat(std.posix.AT.FDCWD, util.BLITZ_DIR ++ "/debug.log", flags, 0o644) catch -1;
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
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.nanoseconds > max_mtime) max_mtime = stat.mtime.nanoseconds;
    }
    return max_mtime;
}

fn cwdBlitzLuaExists(io: std.Io) bool {
    _ = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch |err| {
        return err != error.FileNotFound;
    };
    return true;
}

pub fn main(init: std.process.Init) !void {
    var pos_buf: [16][:0]const u8 = undefined;
    const split = CliArgs.split(init.minimal.args, &pos_buf);
    const cli_flags = split.flags;
    const command_result = CliCommand.parse(split.positional);
    if (cli_flags.debug_log or builtin.mode == .Debug) openDebugLog(init.io);

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
            const len = try std.Io.Dir.cwd().realPathFile(init.io, cwd_arg, &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                init.io,
                init.environ_map,
                cli_flags,
                null,
                false,
            );
        },
        .prompt => |prompt| {
            var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const cwd_arg: []const u8 = if (split.prompt != null and split.positional.len > 0) split.positional[0] else ".";
            const len = try std.Io.Dir.cwd().realPathFile(init.io, cwd_arg, &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                init.io,
                init.environ_map,
                cli_flags,
                prompt,
                cli_flags.headless,
            );
        },
        .update => {
            try updateCli(init.io, init.gpa, init.environ_map);
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
                \\update               download and replace the running binary
                \\
                \\Flags:
                \\  --log              write debug.log in path
                \\  --strict           request permissions
                \\  --clean            skip local user context
                \\  --report           write per-agent markdown reports on exit
                \\  --yolo             auto-approve all requests in ssh sessions
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

pub fn run(
    cwd: []const u8,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    flags: CliFlags,
    prompt: ?[]const u8,
    headless: bool,
) !void {
    // Ensure config blitz.lua exists, get paths
    const config_lua: ?ConfigLuaInfo = ensureConfigLua(arena, io, env) catch null;

    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    const context_factory = try r.ContextFactory.init(gpa, io, HOME, cwd);
    context_factory.flags.skip_local_context_file = flags.no_context;

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
        app.cancelPermissions();
        exec_pool.cancelAll();
        registry.cancelAll();
        app.deinit();
        registry.deinit();
        exec_pool.deinit();
    }
    registry.report_enabled = flags.report;

    // Lua VM holds an opaque pointer to App + a getter for the mutable cfg
    // (swarm.cfg is *const, so a sibling accessor unwraps the const).
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
    const mcp_servers = try app.lua_vm.getEnabledMcpServers(arena);
    app.mcp_manager.loadServers(mcp_servers);
    var mcp_tools = app.mcp_manager.registeredTools();

    for (lua_tools) |tool| {
        try context_factory.add(tool, .all);
    }
    for (mcp_tools) |tool| {
        try context_factory.add(tool.tool, tool.flags);
    }

    for (lua_binds) |bind| {
        try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn } });
    }

    var cwd_lua_mtime: i128 = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch break :blk 0;
        break :blk stat.mtime.nanoseconds;
    };
    var config_lua_mtime: i128 = if (config_lua) |info| scanDirMaxMtime(io, info.dir_path) else 0;
    var reload_tick: u32 = 0;

    app.reset();
    app.flags.skip_permissions = !flags.strict_mode;
    app.flags.skip_ssh_permissions = flags.yolo;
    app.warnUnboundAgentModels();

    if (config_lua) |info| app.loadHistory(info.dir_path);

    if (headless) {
        try runHeadless(&app, io, prompt.?);
        return;
    }

    app.startUpdateCheck();

    if (prompt) |p| {
        try app.input_buffer.appendSlice(app.sessionAlloc(), p);
        app.input_cursor = @intCast(app.input_buffer.items.len);
    }

    var term = try tui.Terminal.init(arena, io);
    errdefer term.deinit();
    defer term.deinit();

    main_loop: while (true) {
        // tick notifications
        const had_visible_notifications = app.notifications.hasVisible();
        app.notifications.tick(1.0 / 60.0);
        if (had_visible_notifications or app.notifications.hasVisible()) app.dirty = true;

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

                // check permission level against flags
                app.mu.lockUncancelable(app.io);
                const skip_permissions = app.flags.skip_permissions;
                const skip_ssh_permissions = app.flags.skip_ssh_permissions;
                app.mu.unlock(app.io);
                if (skip_permissions and !app.exec_pool.ssh_active and !is_ask) {
                    try app.persist_permission_to_history(next);
                    next.state = .approved;
                    next.event.set(app.io);
                    continue;
                }

                if (skip_ssh_permissions and !is_ask) {
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

        // Drive input_mode from perm presence — single source of truth.
        switch (app.input_mode) {
            .text => if (app.active_permission != null) app.enterPermSelect(),
            .perm_select, .perm_message => if (app.active_permission == null) app.returnToText(),
            .passphrase => {},
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
                // Tool worker may currently hold
                // vm_mu. Skip this tick if busy — mtime stays unchanged so we retry.
                if (!app.lua_vm.vm_mu.tryLock()) break :blk;
                defer app.lua_vm.vm_mu.unlock(io);

                cwd_lua_mtime = new_cwd_mtime;
                config_lua_mtime = new_config_mtime;

                app.lua_vm.clearLastError();
                app.event_bus.clear(app.gpa, app.io);
                app.lua_inject_hooks_enabled.store(false, .release);
                var lua_reload_failed = false;

                app.lua_vm.reset() catch |err| {
                    lua_reload_failed = true;
                    std.log.scoped(.lua).err("hot-reload: failed to reset lua vm ({any})", .{err});
                };
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
                app.warnUnboundAgentModels();
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

                const reloaded_mcp_servers = app.lua_vm.getEnabledMcpServers(arena) catch |err| {
                    std.log.scoped(.mcp).err("failed to load MCP server defs {any}", .{err});
                    if (reload_requested) {
                        app.lua_reload_failed.store(true, .release);
                        app.markLuaReloadDone();
                    }
                    break :blk;
                };
                app.mcp_manager.loadServers(reloaded_mcp_servers);
                mcp_tools = app.mcp_manager.registeredTools();
                for (mcp_tools) |tool| try context_factory.add(tool.tool, tool.flags);

                lua_binds = try app.lua_vm.getRegisteredKeybinds(arena);
                app.keymap.custom.clearRetainingCapacity();
                for (lua_binds) |bind| {
                    try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn } });
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
                                if (app.active_permission == null and app.running) {
                                    try app.cmd_queue.append(io, .cancel);
                                } else {
                                    break :main_loop;
                                }
                                continue;
                            },
                            .cancel => {
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
                                app.undoLastUserMessage();
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
                                    const entry = app.active_permission orelse break;

                                    const max_sel: u8 = switch (entry.payload) {
                                        .ask => |a| @intCast(@min(a.options.len, tools.ask.MAX_OPTIONS)),
                                        .plan => 3,
                                        else => 2,
                                    };
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
                            }
                        },
                        .arrow_up => switch (app.input_mode) {
                            .text => if (!app.running) app.historyUp(),
                            .perm_select => |*ps| {
                                if (ps.selected > 0) ps.selected -= 1;
                            },
                            .perm_message => {},
                            .passphrase => {},
                        },
                        .arrow_down => switch (app.input_mode) {
                            .text => if (!app.running) app.historyDown(),
                            .perm_select => |*ps| {
                                const entry = app.active_permission orelse break;
                                const max_sel: u8 = switch (entry.payload) {
                                    .ask => |a| @intCast(@min(a.options.len, tools.ask.MAX_OPTIONS)),
                                    .plan => 3,
                                    else => 2,
                                };
                                if (ps.selected < max_sel) ps.selected += 1;
                            },
                            .perm_message => {},
                            .passphrase => {},
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
                        },
                        .enter => switch (app.input_mode) {
                            .perm_message => |*pm| {
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
                                if (app.input_buffer.items.len == 0) break;
                                const input = std.fmt.allocPrint(app.sessionAlloc(), "{f}", .{std.unicode.fmtUtf8(app.inputSlice())}) catch break;
                                var send_text: []const u8 = input;
                                var chat_text: []const u8 = input;

                                // -- user commands (processed even while a session is running)
                                if (input[0] == '/') {
                                    if (app.lua_vm.vm_mu.tryLock()) {
                                        defer app.lua_vm.vm_mu.unlock(io);
                                        if (app.lua_vm.invokeCommand(input)) {
                                            app.pushHistory(input);
                                            if (config_lua) |info| app.saveHistory(info.dir_path);
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
                                    app.pushHistory(input);
                                    if (config_lua) |info| app.saveHistory(info.dir_path);
                                    try app.event_bus.emit(&app, .{ .user_message_sent = chat_text });
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

                                app.pushHistory(input);
                                if (config_lua) |info| app.saveHistory(info.dir_path);

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
    }
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
            .ask => |a| .{ .choice = recommendedOption(a.options) },
            else => .approved,
        };
        next.event.set(io);
    }
}

fn recommendedOption(options: []const []const u8) u8 {
    for (options, 0..) |opt, i| {
        if (std.mem.indexOf(u8, opt, "(recommended)") != null) return @intCast(i);
    }
    return 0;
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
        state.notifications.append(gpa, "SSH mode enabled: {s}@{s}", .{ args.user, args.host }) catch {};
        state.remote_cwd = args.cwd;
    } else {
        state.enterPassphrase(args.user, args.host, args.cwd);
    }
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

pub const CliFlags = packed struct {
    /// enable debug log writing
    debug_log: bool = false,
    /// permission required
    strict_mode: bool = false,
    /// don't load AGENTS.md
    no_context: bool = false,
    /// write per-agent markdown reports on exit
    report: bool = false,
    /// run --prompt headless, print final message instead of tui
    headless: bool = false,
    /// auto-approve every request during ssh sessions
    yolo: bool = false,

    fn applyToken(self: *CliFlags, tok: []const u8) bool {
        if (std.mem.eql(u8, tok, "--log")) {
            self.debug_log = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--strict")) {
            self.strict_mode = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--clean")) {
            self.strict_mode = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--report")) {
            self.report = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--headless")) {
            self.headless = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--yolo")) {
            self.yolo = true;
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
        while (it.next()) |arg| {
            if (pending_prompt) {
                pending_prompt = false;
                if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                    _ = flags.applyToken(arg);
                } else {
                    prompt = arg;
                }
                continue;
            }
            if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--prompt")) {
                    pending_prompt = true;
                    continue;
                }
                _ = flags.applyToken(arg);
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

        if (std.mem.eql(u8, head, "update")) return .{ .cmd = .update };

        if (std.mem.eql(u8, head, "help")) return .{ .cmd = .help };

        return .{ .cmd = .{ .run = head } };
    }
};
