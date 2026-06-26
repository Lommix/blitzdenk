// ----------------------------------------------------------------
// Blitzdenk 0.1
// Copyright (c) 2026 Lorenz Mielke. All Rights Reserved.
// ----------------------------------------------------------------
const std = @import("std");
const r = @import("root.zig");
const App = r.app.App;
const BlitzdenkCfg = r.prv.config.BlitzdenkCfg;
const ChatEntry = r.app.ChatEntry;
const prompts = r.prompts;
const lua = r.lua;
const reg = r.ContextFactory;
const keys = r.keys;
const util = r.util;
const session = r.session;
const tui = r.tui;
const inbuilt = r.prv.inbuilt;
const prv = r.prv;
const tools = r.tools;

// ----------------------------------------------------------------
pub const LUA_DEFAULT_FILE = @embedFile("blitz_default.lua");
pub const LUA_META_FILE = @embedFile("blitz_defs.lua");
pub const DEFAULT_CONFIG_PATH = ".config/blitzdenk/";
pub const DEFAULT_CACHE_PATH = "cache.zon";
pub const DEFAULT_LUA_CONFIG = "blitz.lua";
pub const DEFAULT_LUA_META = "meta.lua";

test {
    std.testing.refAllDecls(@This());
}

// TUI owns stderr; Route std.log to debug.log in cwd instead. Using a raw POSIX fd with O_APPEND.
var debug_log_fd: std.posix.fd_t = -1;
fn openDebugLog() void {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    debug_log_fd = std.posix.openat(std.posix.AT.FDCWD, ".blitz/debug.log", flags, 0o644) catch -1;
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

    const rel_path = DEFAULT_CONFIG_PATH ++ DEFAULT_LUA_CONFIG;

    _ = home_dir.statFile(io, rel_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var buf: [2048]u8 = undefined;
            try home_dir.createDirPath(io, DEFAULT_CONFIG_PATH);

            // meta file
            const meta_rel = DEFAULT_CONFIG_PATH ++ DEFAULT_LUA_META;
            const mf = try home_dir.createFile(io, meta_rel, .{});
            defer mf.close(io);
            var mw = mf.writer(io, &buf);
            try mw.interface.writeAll(LUA_META_FILE);
            try mw.interface.flush();

            // config file
            const f = try home_dir.createFile(io, rel_path, .{});
            defer f.close(io);
            var writer = f.writer(io, &buf);
            try writer.interface.writeAll(LUA_DEFAULT_FILE);
            try writer.interface.flush();
        } else return err;
    };

    const abs_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ HOME, rel_path });
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
    if (cli_flags.debug_log) openDebugLog();

    const cmd: CliCommand = switch (command_result) {
        .err => |txt| {
            std.debug.print("Error: {s}", .{txt});
            return;
        },
        .cmd => |cmd| cmd,
        .none => CliCommand{ .run = "." },
    };

    switch (cmd) {
        .debug => |debug_cmd| {
            switch (debug_cmd) {
                .webfetch => |uri| {
                    const result = try std.process.run(init.arena.allocator(), init.io, .{
                        .argv = &.{
                            "chromium",
                            "--headless",
                            "--disable-gpu",
                            "--virtual-time-budget=2000",
                            "--dump-dom",
                            uri,
                        },
                        .stdout_limit = .limited(2 * 1024 * 1024),
                    });

                    if (result.stdout.len == 0) {
                        std.debug.print("curl returned empty response\n", .{});
                        return;
                    }
                    const md = try tools.parse.htmlToMarkdown(init.arena.allocator(), result.stdout);
                    std.debug.print("=== MARKDOWN OUTPUT ===\n{s}\n=== END ===\n", .{md});
                },
            }
        },
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
            );
        },
        .prompt => |prompt| {
            var cwd_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const len = try std.Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            const cwd = cwd_buffer[0..len];
            try run(
                cwd,
                init.gpa,
                init.arena.allocator(),
                init.io,
                init.environ_map,
                cli_flags,
                prompt,
            );
        },
        .help => {
            std.debug.print(
                \\Blitzdenk tui v0.1
                \\Usage: blitz CMD --flag
                \\
                \\Commands:
                \\/any/path            start tui in rel path to current cwd (optional)
                \\help                 display this
                \\prompt "STRING"      run in current cwd with initial input
                \\debug
                \\  webfetch URL       test webfetch
                \\
                \\Flags:
                \\  --log              write debug.log in path
                \\  --strict           request permissions
                \\
            , .{});
        },
    }
}

pub fn run(
    cwd: []const u8,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    flags: CliFlags,
    prompt: ?[]const u8,
) !void {
    // Ensure config blitz.lua exists, get paths
    const config_lua: ?ConfigLuaInfo = ensureConfigLua(arena, io, env) catch null;

    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    var context_factory = try r.ContextFactory.init(arena, io, HOME);

    var term = try tui.Terminal.init(arena, io);
    errdefer term.deinit();
    defer term.deinit();

    var app = try App.init(arena, io, gpa, &context_factory, cwd);
    const swarm = try gpa.create(prv.Swarm);
    defer {
        swarm.deinit();
        app.deinit();
        gpa.destroy(swarm);
    }

    try swarm.init(gpa, io, .{
        .ptr = &app,
        .broadcast = (struct {
            fn func(ptr: *anyopaque, en: prv.Swarm.BroadcastEntry) void {
                const a: *App = @ptrCast(@alignCast(ptr));

                if (en.agent_id != a.main_agent_id) return;
                if (en.role == .user) return;
                if (en.role == .system) return;

                const g = a.broadcast_queue.lock(a.io);
                defer g.unlock();

                g.ptr.appendBounded(en) catch return;
            }
        }).func,
        .permission = (struct {
            fn func(ptr: *anyopaque, en: *prv.Swarm.PermissionReq) void {
                const a: *App = @ptrCast(@alignCast(ptr));
                const g = a.permission_queue.lock(a.io);
                defer g.unlock();

                g.ptr.appendBounded(en) catch {
                    en.state = .denied;
                    en.event.set(a.io);
                };
            }
        }).func,
        .build_config = (struct {
            fn func(ptr: *anyopaque, agent_type_idx: u8) anyerror!r.prv.adapter.Config {
                const a: *App = @ptrCast(@alignCast(ptr));
                const config = a.context_factory.buildAgentApiConfig(
                    @enumFromInt(agent_type_idx),
                    &a.config,
                    a.swarm.exec.env,
                ) orelse return error.FailedToBuildAgent;
                return try r.prv.adapter.cloneConfig(a.appAlloc(), config);
            }
        }).func,
        .cwd = (struct {
            fn func(ptr: *anyopaque) []const u8 {
                const a: *App = @ptrCast(@alignCast(ptr));
                return a.cwd;
            }
        }).func,
        .gen_system_reminders = &App.genSystemRemindersOpaque,
        .pop_queued_message = &App.popQueuedMessageOpaque,
    }, env);

    app.swarm = swarm;

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
    try app.lua_vm.publishAvailableSystems(&context_factory);
    var lua_tools = try app.lua_vm.getRegisteredTools(arena);
    var lua_binds = try app.lua_vm.getRegisteredKeybinds(arena);
    const mcp_servers = try app.lua_vm.getEnabledMcpServers(arena);
    app.mcp_manager.loadServers(mcp_servers);
    var mcp_tools = app.mcp_manager.registeredTools();
    const lsp_servers = try app.lua_vm.getEnabledLspServers(arena);
    app.lsp_manager.loadServers(lsp_servers);
    var lsp_tools = app.lsp_manager.registeredTools();

    for (lua_tools) |tool| {
        try context_factory.add(arena, tool, .all);
    }
    for (mcp_tools) |tool| {
        try context_factory.add(arena, tool.tool, tool.flags);
    }
    for (lsp_tools) |tool| {
        try context_factory.add(arena, tool.tool, tool.flags);
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

    if (config_lua) |info| app.loadHistory(app.appAlloc(), info.dir_path);

    if (prompt) |p| {
        try app.input_buffer.appendSlice(app.sessionAlloc(), p);
        app.input_cursor = @intCast(app.input_buffer.items.len);
    }

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
        if (app.running) {
            if (!app.swarm.tickAll()) {
                if (app.main_agent_id) |agent_id| {
                    const slot_state = app.swarm.getSlotState(agent_id);
                    if (slot_state == .failed) {
                        try app.event_bus.emit(&app, .{ .agent_failed = .{ .id = agent_id, .err = "" } });
                    } else {
                        try app.event_bus.emit(&app, .{ .agent_complete = agent_id });
                    }
                }
                app.running = false;
            }
            app.dirty = true;
        }

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
                if (app.flags.skip_permissions and !app.swarm.exec.ssh_active and !is_ask) {
                    try app.persist_permission_to_history(next);
                    next.state = .approved;
                    next.event.set(app.io);
                    continue;
                }

                if (app.swarm.getSlotState(next.agent_id) == .active) {
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
        if (reload_tick >= 60) {
            reload_tick = 0;
            const new_cwd_mtime: i128 = blk: {
                const stat = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch break :blk 0;
                break :blk stat.mtime.nanoseconds;
            };
            const new_config_mtime: i128 = if (config_lua) |info| scanDirMaxMtime(io, info.dir_path) else 0;

            if (new_cwd_mtime != cwd_lua_mtime or new_config_mtime != config_lua_mtime) blk: {
                // Tool worker may currently hold
                // vm_mu. Skip this tick if busy — mtime stays unchanged so we retry.
                if (!app.lua_vm.vm_mu.tryLock()) break :blk;
                defer app.lua_vm.vm_mu.unlock(io);

                cwd_lua_mtime = new_cwd_mtime;
                config_lua_mtime = new_config_mtime;

                app.lua_vm.clearLastError();
                app.event_bus.listner.clearAndFree(app.appAlloc());
                var lua_reload_failed = false;

                app.lua_vm.reset() catch |err| {
                    lua_reload_failed = true;
                    std.log.scoped(.lua).err("hot-reload: failed to reset lua vm ({any})", .{err});
                };
                context_factory.resetDefs();
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
                try app.lua_vm.publishAvailableSystems(&context_factory);
                app.dirty = true;

                context_factory.clearTools();
                inline for (reg.general_default_tool_set) |tool| {
                    try context_factory.add(arena, tool, .all);
                }
                lua_tools = app.lua_vm.getRegisteredTools(arena) catch |err| {
                    std.log.scoped(.lua).err("failed to load lua tool defs {any}", .{err});
                    break :blk;
                };
                for (lua_tools) |tool| try context_factory.add(arena, tool, .all);

                const reloaded_mcp_servers = app.lua_vm.getEnabledMcpServers(arena) catch |err| {
                    std.log.scoped(.mcp).err("failed to load MCP server defs {any}", .{err});
                    break :blk;
                };
                app.mcp_manager.loadServers(reloaded_mcp_servers);
                mcp_tools = app.mcp_manager.registeredTools();
                for (mcp_tools) |tool| try context_factory.add(arena, tool.tool, tool.flags);

                const reloaded_lsp_servers = app.lua_vm.getEnabledLspServers(arena) catch |err| {
                    std.log.scoped(.lsp).err("failed to load LSP server defs {any}", .{err});
                    break :blk;
                };
                app.lsp_manager.loadServers(reloaded_lsp_servers);
                lsp_tools = app.lsp_manager.registeredTools();
                for (lsp_tools) |tool| try context_factory.add(arena, tool.tool, tool.flags);

                lua_binds = try app.lua_vm.getRegisteredKeybinds(arena);
                app.keymap.custom.clearRetainingCapacity();
                for (lua_binds) |bind| {
                    try app.keymap.custom.append(app.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn } });
                }

                if (app.main_agent_id) |id| {
                    if (swarm.getAgent(id)) |agent| {
                        try context_factory.refreshAgentTools(agent);
                    }
                }
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
                            .open_cmd => {
                                continue;
                            },
                            .cursor_left => app.input_cursor -|= 1,
                            .cursor_right => {
                                app.input_cursor = @min(app.input_cursor + 1, app.input_buffer.items.len);
                            },
                            .cursor_up => {},
                            .cursor_down => {},
                            .toggle_skip => {
                                app.flags.skip_permissions = !app.flags.skip_permissions;
                                app.dirty = true;
                                continue;
                            },
                            .noop => {},
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
                                const input = gpa.dupe(u8, app.inputSlice()) catch break;

                                // -- user commands (processed even while a session is running)
                                if (input[0] == ':' or input[0] == '/') {
                                    if (app.lua_vm.vm_mu.tryLock()) {
                                        defer app.lua_vm.vm_mu.unlock(io);
                                        if (app.lua_vm.invokeCommand(input)) {
                                            app.input_buffer.clearRetainingCapacity();
                                            break;
                                        }
                                    } else {
                                        break;
                                    }

                                    const cmd = AppCommand.parse(input);

                                    if (cmd) |c| {
                                        switch (c) {
                                            .clear => {
                                                app.reset();
                                                break;
                                            },
                                            .help => {
                                                app.pushSystemMessage("Not yet implemented. You are on your own!", .{});
                                            },
                                            .ssh => |args| {
                                                handleSshCommand(&app, &app.swarm.exec, gpa, args);
                                                app.input_buffer.clearRetainingCapacity();
                                            },
                                            .cd => |path| {
                                                app.cwd = try app.appAlloc().dupe(u8, path);
                                                app.input_buffer.clearRetainingCapacity();
                                            },
                                            .ssh_off => {
                                                app.swarm.exec.clearSsh();
                                                app.pushSystemMessage("ssh mode disabled", .{});
                                                app.input_buffer.clearRetainingCapacity();
                                            },
                                        }
                                    }

                                    break;
                                }

                                if (app.running) {
                                    app.pushHistory(app.appAlloc(), input);
                                    if (config_lua) |info| app.saveHistory(info.dir_path);
                                    try app.event_bus.emit(&app, .{ .user_message_sent = input });
                                    if (app.main_agent_id) |agent_id| {
                                        const ag = app.swarm.getAgent(agent_id).?;
                                        const alloc = ag.arena.allocator();
                                        const len: usize = if (app.screenshot_buf != null) 2 else 1;

                                        const parts = try alloc.alloc(prv.adapter.ContentPart, len);
                                        parts[0] = .{ .text = input };

                                        if (app.screenshot_buf) |buf| {
                                            parts[1] = .{ .image = .{
                                                .media_type = "image/png",
                                                .data = buf,
                                            } };
                                        }

                                        const chat_msg = try ChatEntry.userMessageSimple(alloc, .user, input);
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

                                app.pushHistory(app.appAlloc(), app.inputSlice());
                                if (config_lua) |info| app.saveHistory(info.dir_path);
                                try app.event_bus.emit(&app, .{ .user_message_sent = app.inputSlice() });
                                // state.pushChatMessage(.user, input);

                                const alloc = gpa;
                                const parts: []const prv.adapter.ContentPart = if (app.screenshot_buf) |img_data|
                                    alloc.dupe(prv.adapter.ContentPart, &.{
                                        .{ .text = input },
                                        .{ .image = .{ .media_type = "image/png", .data = img_data } },
                                    }) catch break
                                else
                                    alloc.dupe(prv.adapter.ContentPart, &.{
                                        .{ .text = input },
                                    }) catch break;

                                app.screenshot_buf = null;

                                const chat_entry = try ChatEntry.userMessageSimple(app.sessionAlloc(), .user, input);

                                if (app.main_agent_id) |id| {
                                    try app.chat_entries.append(alloc, chat_entry);
                                    try app.swarm.runAgentWithMsg(id, parts);
                                } else {
                                    const id = app.swarm.reserveFreeSlot().?;
                                    try app.cmd_queue.append(io, .{
                                        .spawn_agent = .{
                                            .agent_id = id,
                                            .agent_type = @intFromEnum(reg.AgentType.general),
                                            .prompt = parts,
                                            .chat_entry = chat_entry,
                                        },
                                    });
                                }

                                app.running = true;
                                app.input_buffer.clearRetainingCapacity();
                            },
                            .passphrase => {
                                handleSshUnlock(&app, &app.swarm.exec, gpa);
                            },
                        },
                        .esc => switch (app.input_mode) {
                            .text => {
                                const input = app.inputSlice();
                                if (input.len > 0 and input[0] == ':') {
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
                    .text => app.appendBytes(text),
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
                .resize => {},
                .none => break,
            }
        }

        try app.cmd_queue.apply(io, &app);
    }
}

/// Probe `ssh -o BatchMode=yes user@host true`. On success → set SSH target
/// and announce. On failure → open the passphrase modal so the user can
/// unlock a key into ssh-agent and retry.
fn handleSshCommand(
    state: *App,
    cmd_pool: *prv.exec.CmdPool,
    gpa: std.mem.Allocator,
    args: AppCommand.SshArgs,
) void {
    if (sshProbe(cmd_pool, gpa, args.user, args.host)) {
        cmd_pool.setSsh(args.user, args.host, args.cwd) catch {
            state.pushSystemMessage("ssh: failed to allocate target", .{});
            return;
        };
        state.pushSystemMessage("ssh mode enabled: {s}@{s}:{s}", .{ args.user, args.host, args.cwd });
        state.remote_cwd = args.cwd;
    } else {
        state.enterPassphrase(args.user, args.host, args.cwd);
    }
}

/// Returns true iff a non-interactive ssh probe succeeds (key already loaded
/// in agent). Returns false on any failure (auth, network, exit nonzero).
fn sshProbe(cmd_pool: *prv.exec.CmdPool, gpa: std.mem.Allocator, user: []const u8, host: []const u8) bool {
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
fn handleSshUnlock(state: *App, cmd_pool: *prv.exec.CmdPool, gpa: std.mem.Allocator) void {
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
        .argv = &.{ "setsid", "-w", "ssh-add" },
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
    state.pushSystemMessage("ssh mode enabled: {s}@{s}:{s}", .{ user, host, cwd });
}

pub const AppCommand = union(enum) {
    clear,
    help,
    /// :ssh user@domain:/path/to/cwd
    ssh: SshArgs,
    /// :ssh off  (or bare :ssh)
    ssh_off,
    /// change CWD
    cd: []const u8,

    pub const SshArgs = struct { user: []const u8, host: []const u8, cwd: []const u8 };

    pub fn parse(raw: []const u8) ?AppCommand {
        const input = if (raw.len > 0 and (raw[0] == ':' or raw[1] == '/')) raw[1..] else raw;
        var it = std.mem.splitScalar(u8, input, ' ');
        const verb = it.first();
        const rest = it.rest();

        if (std.mem.eql(u8, verb, "cd")) {
            return .{ .cd = rest };
        }

        if (std.mem.eql(u8, verb, "clear")) return .clear;
        if (std.mem.eql(u8, verb, "help")) return .help;
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
        return .{ .ssh = .{
            .user = arg[0..at],
            .host = after_at[0..colon],
            .cwd = after_at[colon + 1 ..],
        } };
    }
};

pub const CliFlags = packed struct {
    /// enable debug log writing
    debug_log: bool = false,
    strict_mode: bool = false,

    fn applyToken(self: *CliFlags, tok: []const u8) bool {
        if (std.mem.eql(u8, tok, "--log")) {
            self.debug_log = true;
            return true;
        }

        if (std.mem.eql(u8, tok, "--strict")) {
            self.strict_mode = true;
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

    pub fn split(args: std.process.Args, buf: [][:0]const u8) CliArgs {
        var flags = CliFlags{};
        var n: usize = 0;

        var it = args.iterate();
        _ = it.next(); // skip exe name

        while (it.next()) |arg| {
            if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                _ = flags.applyToken(arg);
                continue;
            }
            if (n < buf.len) {
                buf[n] = arg;
                n += 1;
            }
        }

        return .{ .flags = flags, .positional = buf[0..n] };
    }
};

pub const CliCommand = union(enum) {
    run: []const u8, // '.', './', /full/path/to/dir
    prompt: []const u8, // prefill input in CWD
    debug: DebugCmd,
    help,

    pub const DebugCmd = union(enum) {
        webfetch: []const u8,
    };

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

        if (std.mem.eql(u8, head, "help")) return .{ .cmd = .help };

        if (std.mem.eql(u8, head, "debug")) {
            if (rest.len == 0) return .{ .err = "missing debug command" };
            const sub = rest[0];
            if (std.mem.eql(u8, sub, "webfetch")) {
                if (rest.len < 2) return .{ .err = "webfetch requires url" };
                return .{ .cmd = .{ .debug = .{ .webfetch = rest[1] } } };
            }
            return .{ .err = "unknown debug command" };
        }

        return .{ .cmd = .{ .run = head } };
    }
};
