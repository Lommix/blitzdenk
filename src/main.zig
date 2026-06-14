// ----------------------------------------------------------------
// Blitzdenk 0.1
// Copyright (c) 2026 Lorenz Mielke. All Rights Reserved.
// ----------------------------------------------------------------

const std = @import("std");
const tui = @import("tui/root.zig");
const prv = @import("provider");
const tools = @import("tools/root.zig");
const app = @import("app.zig");
const inbuilt = prv.inbuilt;
const prompts = @import("prompts.zig");
const BlitzdenkCfg = prv.config.BlitzdenkCfg;
const lua = @import("lua.zig");
const reg = @import("registry.zig");
const keys = @import("keys.zig");
const util = @import("util.zig");
const session = @import("session.zig");

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
    var cfg: BlitzdenkCfg = .{};

    // Ensure config blitz.lua exists, get paths
    const config_lua: ?ConfigLuaInfo = ensureConfigLua(arena, io, env) catch null;

    const HOME = env.get("HOME") orelse return error.NoHomeFound;
    var context_factory = try reg.ContextFactory.init(arena, io, HOME);

    var pool: prv.http.RequestPool = .{};
    try pool.init(gpa, io);
    defer pool.deinit();

    var cmd_pool = prv.exec.CmdPool.init(gpa, io, env);
    defer cmd_pool.deinit();

    var swarm = try prv.Swarm.init(arena, &pool, &cmd_pool, &cfg, env, cwd);
    defer swarm.deinit();

    var term = try tui.Terminal.init(arena, io);
    errdefer term.deinit();
    defer term.deinit();

    var state = try app.App.init(arena, gpa, &swarm, &context_factory, cwd);
    defer state.deinit();

    // Lua VM holds an opaque pointer to App + a getter for the mutable cfg
    // (swarm.cfg is *const, so a sibling accessor unwraps the const).
    state.lua_vm.setApp(&state);
    state.lua_vm.clearLastError();
    var lua_load_failed = false;
    if (config_lua) |info| {
        const inject = try std.fmt.allocPrint(arena, "package.path = \"{s}?.lua;\" .. package.path", .{info.dir_path});
        state.lua_vm.exec(inject) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to configure lua package.path: {s} ({any})", .{ state.lua_vm.getLastError(), err });
        };
        state.lua_vm.load(info.abs_path) catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to load {s}: {s} ({any})", .{ info.abs_path, state.lua_vm.getLastError(), err });
        };
    }
    if (cwdBlitzLuaExists(io)) {
        state.lua_vm.load("blitz.lua") catch |err| {
            lua_load_failed = true;
            std.log.scoped(.lua).err("failed to load blitz.lua: {s} ({any})", .{ state.lua_vm.getLastError(), err });
        };
    }
    if (!lua_load_failed) state.lua_vm.clearLastError();
    state.lua_vm.readConfigFields();
    var lua_tools = try state.lua_vm.getRegisteredTools(arena);
    var lua_binds = try state.lua_vm.getRegisteredKeybinds(arena);
    const mcp_servers = try state.lua_vm.getEnabledMcpServers(arena);
    state.mcp_manager.loadServers(mcp_servers);
    var mcp_tools = state.mcp_manager.registeredTools();

    for (lua_tools) |tool| {
        try context_factory.add(arena, tool, .all);
    }
    for (mcp_tools) |tool| {
        try context_factory.add(arena, tool.tool, tool.flags);
    }

    for (lua_binds) |bind| {
        try state.keymap.custom.append(state.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn } });
    }

    var cwd_lua_mtime: i128 = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, "blitz.lua", .{}) catch break :blk 0;
        break :blk stat.mtime.nanoseconds;
    };
    var config_lua_mtime: i128 = if (config_lua) |info| scanDirMaxMtime(io, info.dir_path) else 0;
    var reload_tick: u32 = 0;

    state.reset();
    state.flags.skip_permissions = !flags.strict_mode;

    const agent_ctx: prv.agent.AgentContext = .{
        .ptr = &state,
        .gen_system_reminders = &app.App.genSystemRemindersOpaque,
        .pop_queued_message = &app.App.popQueuedMessageOpaque,
        .configure_agent = (struct {
            fn configure(ptr: *anyopaque, agent: *prv.agent.Agent) !void {
                const a: *app.App = @ptrCast(@alignCast(ptr));
                try a.configureAgent(agent);
            }
        }).configure,
        .push_system_message = (struct {
            fn pushMsg(ptr: *anyopaque, agent: prv.Swarm.AgentId, msg: []const u8) void {
                const a: *app.App = @ptrCast(@alignCast(ptr));
                a.pushSystemMessage("(Agent {d}v{d}) {s}", .{ agent.index, agent.generation, msg });
            }
        }).pushMsg,
    };

    if (config_lua) |info| state.loadHistory(state.appAlloc(), info.dir_path);

    if (prompt) |p| {
        try state.input_buffer.appendSlice(state.sessionAlloc(), p);
        state.input_cursor = @intCast(state.input_buffer.items.len);
    }

    main_loop: while (true) {
        // tick notifications
        const had_visible_notifications = state.notifications.hasVisible();
        state.notifications.tick(1.0 / 60.0);
        if (had_visible_notifications or state.notifications.hasVisible()) state.dirty = true;

        if (state.dirty or state.main_agent_id == null) {
            try term.drawWith(&state, app.App.render);
            state.frame_count +%= 1;
            state.dirty = false;
        }

        if (state.running) {
            if (!state.swarm.tickAll(agent_ctx)) state.running = false;
            state.dirty = true;
        }

        // Drain new agent messages from broadcast into chat_entries
        state.drainBroadcast();
        // Mirror in-progress streaming message so TUI shows tokens as they arrive.
        state.syncStreamingPreview();
        state.syncCompactionIndicator();

        const pending_perm = state.firstPendingPermission();

        // Drive input_mode from perm presence — single source of truth.
        switch (state.input_mode) {
            .text => if (pending_perm != null) state.enterPermSelect(),
            .perm_select, .perm_message => if (pending_perm == null) state.returnToText(),
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
                if (!state.lua_vm.vm_mu.tryLock()) break :blk;
                defer state.lua_vm.vm_mu.unlock(io);

                cwd_lua_mtime = new_cwd_mtime;
                config_lua_mtime = new_config_mtime;

                state.lua_vm.clearLastError();
                var lua_reload_failed = false;

                state.lua_vm.reset() catch |err| {
                    lua_reload_failed = true;
                    std.log.scoped(.lua).err("hot-reload: failed to reset lua vm ({any})", .{err});
                };
                context_factory.clearAllAgentTools();
                context_factory.resetPrompts();
                if (config_lua) |info| {
                    const inject = std.fmt.allocPrint(arena, "package.path = \"{s}?.lua;\" .. package.path", .{info.dir_path}) catch null;
                    if (inject) |code| state.lua_vm.exec(code) catch |err| {
                        lua_reload_failed = true;
                        std.log.scoped(.lua).err("hot-reload: failed to configure lua package.path: {s} ({any})", .{ state.lua_vm.getLastError(), err });
                    };
                    state.lua_vm.load(info.abs_path) catch |err| {
                        lua_reload_failed = true;
                        std.log.scoped(.lua).err("hot-reload: failed to load {s}: {s} ({any})", .{ info.abs_path, state.lua_vm.getLastError(), err });
                    };
                }
                if (cwdBlitzLuaExists(io)) {
                    state.lua_vm.load("blitz.lua") catch |err| {
                        lua_reload_failed = true;
                        std.log.scoped(.lua).err("hot-reload: failed to load blitz.lua: {s} ({any})", .{ state.lua_vm.getLastError(), err });
                    };
                }
                if (!lua_reload_failed) state.lua_vm.clearLastError();
                state.lua_vm.readConfigFields();
                state.dirty = true;

                for (lua_tools) |tool| context_factory.remove(tool.def.name);
                for (mcp_tools) |tool| context_factory.remove(tool.tool.def.name);
                lua_tools = state.lua_vm.getRegisteredTools(arena) catch |err| {
                    std.log.scoped(.lua).err("failed to load lua tool defs {any}", .{err});
                    break :blk;
                };
                for (lua_tools) |tool| try context_factory.add(arena, tool, .all);

                const reloaded_mcp_servers = state.lua_vm.getEnabledMcpServers(arena) catch |err| {
                    std.log.scoped(.mcp).err("failed to load MCP server defs {any}", .{err});
                    break :blk;
                };
                state.mcp_manager.loadServers(reloaded_mcp_servers);
                mcp_tools = state.mcp_manager.registeredTools();
                for (mcp_tools) |tool| try context_factory.add(arena, tool.tool, tool.flags);

                lua_binds = try state.lua_vm.getRegisteredKeybinds(arena);
                state.keymap.custom.clearRetainingCapacity();
                for (lua_binds) |bind| {
                    try state.keymap.custom.append(state.appAlloc(), .{ .key = bind.key, .action = .{ .lua = bind.lua_fn } });
                }

                if (state.main_agent_id) |id| {
                    if (swarm.getAgent(id)) |agent| {
                        var set = reg.ToolSet{};
                        context_factory.build_toolset(.main, &set) catch {};
                        try agent.setTools(set.slice());
                    }
                }
            }
        }

        term.pollAndEnqueue(16);
        while (true) {
            const next_event = term.nextEvent();
            if (next_event != .none) state.dirty = true;
            switch (next_event) {
                .wheel_down => try state.cmd_queue.append(io, .{ .scroll_down = 1 }),
                .wheel_up => try state.cmd_queue.append(io, .{ .scroll_up = 1 }),
                .key => |k| {
                    if (state.keymap.parse(k)) |action| {
                        switch (action) {
                            .exit => {
                                if (pending_perm == null and state.running) {
                                    try state.cmd_queue.append(io, .cancel);
                                } else {
                                    break :main_loop;
                                }
                                continue;
                            },
                            .cancel => {
                                if (state.running) {
                                    try state.cmd_queue.append(io, .cancel);
                                } else {
                                    state.screenshot_buf = null;
                                }
                            },
                            .scroll_down => {
                                try state.cmd_queue.append(io, .{ .scroll_down = 1 });
                                continue;
                            },
                            .scroll_up => {
                                try state.cmd_queue.append(io, .{ .scroll_up = 1 });
                                continue;
                            },
                            .clear_session => {
                                try state.cmd_queue.append(io, .reset_session);
                                continue;
                            },
                            .retry => {
                                try state.cmd_queue.append(io, .retry);
                                continue;
                            },
                            .lua => |lua_fn| {
                                if (state.lua_vm.vm_mu.tryLock()) {
                                    defer state.lua_vm.vm_mu.unlock(io);
                                    state.lua_vm.invokeBind(lua_fn);
                                }
                                continue;
                            },
                            .open_cmd => {
                                continue;
                            },
                            .cursor_left => state.input_cursor -|= 1,
                            .cursor_right => {
                                state.input_cursor = @min(state.input_cursor + 1, state.input_buffer.items.len);
                            },
                            .cursor_up => {},
                            .cursor_down => {},
                            .toggle_skip => {
                                state.flags.skip_permissions = !state.flags.skip_permissions;
                                state.dirty = true;
                                continue;
                            },
                            .noop => {},
                        }
                    }
                    switch (k.code) {
                        .char => |c| {
                            switch (state.input_mode) {
                                .text => {
                                    state.appendBytes(k.textSlice());
                                },
                                .perm_select => |*ps| {
                                    const pen = pending_perm orelse break;
                                    const entry = state.swarm.permission_requests.getPtr(pen.call_id) orelse break;

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
                        .arrow_up => switch (state.input_mode) {
                            .text => if (!state.running) state.historyUp(),
                            .perm_select => |*ps| {
                                if (ps.selected > 0) ps.selected -= 1;
                            },
                            .perm_message => {},
                            .passphrase => {},
                        },
                        .arrow_down => switch (state.input_mode) {
                            .text => if (!state.running) state.historyDown(),
                            .perm_select => |*ps| {
                                const pen = pending_perm orelse break;
                                const entry = state.swarm.permission_requests.getPtr(pen.call_id) orelse break;
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
                        .backspace => switch (state.input_mode) {
                            .text => state.deleteChar(),
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
                        .enter => switch (state.input_mode) {
                            .perm_message => |*pm| {
                                const pen = pending_perm orelse break;
                                const entry = state.swarm.permission_requests.getPtr(pen.call_id) orelse break;

                                const is_ask = entry.payload == .ask;

                                if (pm.len == 0) {
                                    state.enterPermSelect();
                                    break;
                                }
                                const msg = pm.buf[0..pm.len];
                                if (is_ask) {
                                    state.resolvePermission(pen.call_id, .{ .message = msg });
                                } else {
                                    state.denyAndPopPermission(pen.call_id, msg);
                                }
                                state.auto_scroll = true;
                                state.scroll_offset = 0;
                            },
                            .perm_select => |*ps| {
                                const pen = pending_perm orelse break;
                                const entry = state.swarm.permission_requests.getPtr(pen.call_id) orelse break;

                                if (entry.payload == .ask) {
                                    const args = entry.payload.ask;
                                    const opts_len: u8 = @intCast(@min(args.options.len, tools.ask.MAX_OPTIONS));

                                    if (ps.selected >= opts_len) {
                                        state.enterPermMessage();
                                        break;
                                    }

                                    state.resolvePermission(pen.call_id, .{ .choice = ps.selected });
                                    state.auto_scroll = true;
                                    state.scroll_offset = 0;
                                    break;
                                }

                                // Plan approval: 4 options
                                //   0 = approve & clear, 1 = approve & keep, 2 = no, 3 = enter message
                                if (entry.payload == .plan) {
                                    switch (ps.selected) {
                                        0 => {
                                            // Approve & clear — reset, spawn fresh exec agent.
                                            // No need to resolve; reset() drops the perm map.
                                            // plan_text and plan_entry must survive state.reset() below — stash in app arena.
                                            const plan_text = state.appAlloc().dupe(u8, entry.payload.plan.plan_text) catch break;
                                            const plan_entry_src: app.ChatEntry.PlanEntry = blk: {
                                                for (0..state.chat_entries.items.len) |i| {
                                                    const idx = state.chat_entries.items.len - i - 1;
                                                    switch (state.chat_entries.items[idx]) {
                                                        .plan => |pe| break :blk pe,
                                                        else => continue,
                                                    }
                                                }
                                                return error.NoPlanPreview;
                                            };
                                            const plan_entry = try util.deepClone(app.ChatEntry.PlanEntry, plan_entry_src, state.appAlloc());

                                            state.reset();
                                            state.mode = @enumFromInt(0);

                                            var set = reg.ToolSet{};
                                            context_factory.build_toolset(.main, &set) catch {};

                                            const id = try state.swarm.newAgent(
                                                .max,
                                                null,
                                                @intFromEnum(reg.AgentType.main),
                                                @intFromEnum(state.mode),
                                            );

                                            const agent = state.swarm.getAgent(id).?;
                                            try state.configureAgent(agent);

                                            agent.max_iterations = std.math.maxInt(u32);
                                            agent.max_allowed_tool_calls = std.math.maxInt(u32);
                                            agent.permission_level = .write;

                                            state.pushChatMessage(.user, plan_text);
                                            const plan_entry_session = try util.deepClone(app.ChatEntry.PlanEntry, plan_entry, state.sessionAlloc());
                                            try state.chat_entries.append(state.sessionAlloc(), .{ .plan = plan_entry_session });
                                            state.main_agent_id = id;
                                            state.running = true;
                                            state.auto_scroll = true;
                                            state.scroll_offset = 0;

                                            state.swarm.runAgent(id, &.{.{ .text = plan_text }}) catch break;
                                        },
                                        1 => {
                                            // Approve & keep — same agent, switch mode, lift caps.
                                            state.mode = @enumFromInt(0);

                                            if (state.main_agent_id) |id| {
                                                const agent = state.swarm.getAgent(id) orelse break;
                                                agent.max_iterations = std.math.maxInt(u32);
                                                agent.max_allowed_tool_calls = std.math.maxInt(u32);
                                            }

                                            state.resolvePermission(pen.call_id, .approved);
                                            state.running = true;
                                            state.auto_scroll = true;
                                            state.scroll_offset = 0;
                                        },
                                        2 => {
                                            state.denyAndPopPermission(pen.call_id, null);
                                            state.auto_scroll = true;
                                            state.scroll_offset = 0;
                                        },
                                        3 => state.enterPermMessage(),
                                        else => {},
                                    }
                                    break;
                                }

                                // Generic 3-option (yes / no / enter message)
                                switch (ps.selected) {
                                    0 => state.resolvePermission(pen.call_id, .approved),
                                    1 => state.denyAndPopPermission(pen.call_id, null),
                                    2 => {
                                        state.enterPermMessage();
                                        break;
                                    },
                                    else => {},
                                }
                                state.auto_scroll = true;
                                state.scroll_offset = 0;
                            },
                            .text => {
                                if (state.input_buffer.items.len == 0) break;

                                if (state.running) {
                                    const input = state.inputSlice();
                                    state.pushHistory(state.appAlloc(), input);
                                    if (config_lua) |info| state.saveHistory(info.dir_path);
                                    if (state.main_agent_id) |agent_id| {
                                        const ag = state.swarm.getAgent(agent_id).?;
                                        const alloc = ag.arena.allocator();
                                        const len: usize = if (state.screenshot_buf != null) 2 else 1;

                                        const parts = try alloc.alloc(prv.adapter.ContentPart, len);
                                        parts[0] = .{ .text = try alloc.dupe(u8, input) };

                                        if (state.screenshot_buf) |buf| {
                                            parts[1] = .{ .image = .{
                                                .media_type = "image/png",
                                                .data = buf,
                                            } };
                                        }

                                        try state.cmd_queue.append(io, .{ .queue_agent_message = .{
                                            .agent_id = agent_id,
                                            .parts = parts,
                                        } });
                                    }

                                    try state.cmd_queue.append(io, .{ .scroll_down = 999999 });
                                    state.screenshot_buf = null;
                                    state.input_buffer.clearRetainingCapacity();
                                    continue;
                                }

                                state.pushHistory(state.appAlloc(), state.inputSlice());
                                if (config_lua) |info| state.saveHistory(info.dir_path);
                                const input = swarm.arena.allocator().dupe(u8, state.inputSlice()) catch break;

                                if (input[0] == ':') {
                                    if (state.lua_vm.vm_mu.tryLock()) {
                                        defer state.lua_vm.vm_mu.unlock(io);
                                        if (state.lua_vm.invokeCommand(input)) {
                                            state.input_buffer.clearRetainingCapacity();
                                            break;
                                        }
                                    } else {
                                        break;
                                    }

                                    const cmd = AppCommand.parse(input);

                                    if (cmd) |c| {
                                        switch (c) {
                                            .clear => {
                                                state.reset();
                                                break;
                                            },
                                            .help => {
                                                state.pushSystemMessage("Not yet implemented. You are on your own!", .{});
                                            },
                                            .ssh => |args| {
                                                handleSshCommand(&state, &cmd_pool, gpa, args);
                                                state.input_buffer.clearRetainingCapacity();
                                            },
                                            .cd => |path| {
                                                state.cwd = try state.appAlloc().dupe(u8, path);
                                                state.input_buffer.clearRetainingCapacity();
                                            },
                                            .ssh_off => {
                                                cmd_pool.clearSsh();
                                                state.pushSystemMessage("ssh mode disabled", .{});
                                                state.input_buffer.clearRetainingCapacity();
                                            },
                                        }
                                    }

                                    break;
                                }
                                // state.pushChatMessage(.user, input);

                                const alloc = swarm.arena.allocator();
                                const parts: []const prv.adapter.ContentPart = if (state.screenshot_buf) |img_data|
                                    alloc.dupe(prv.adapter.ContentPart, &.{
                                        .{ .text = input },
                                        .{ .image = .{ .media_type = "image/png", .data = img_data } },
                                    }) catch break
                                else
                                    alloc.dupe(prv.adapter.ContentPart, &.{
                                        .{ .text = input },
                                    }) catch break;

                                state.screenshot_buf = null;

                                const chat_entry = try app.ChatEntry.userMessageSimple(state.sessionAlloc(), input);

                                if (state.main_agent_id) |id| {
                                    try state.cmd_queue.append(io, .{ .push_chat_entry = chat_entry });
                                    state.swarm.runAgent(id, parts) catch {};
                                } else {
                                    const id = state.swarm.reserveFreeSlot().?;
                                    try state.cmd_queue.append(io, .{
                                        .spawn_agent = .{
                                            .agent_id = id,
                                            .effort = .max,
                                            .agent_type = @intFromEnum(reg.AgentType.main),
                                            .prompt = parts,
                                            .tool_budget = 1024,
                                            .chat_entry = chat_entry,
                                            .level = .write,
                                        },
                                    });
                                }

                                state.running = true;
                                state.input_buffer.clearRetainingCapacity();
                            },
                            .passphrase => {
                                handleSshUnlock(&state, &cmd_pool, gpa);
                            },
                        },
                        .esc => switch (state.input_mode) {
                            .text => {
                                const input = state.inputSlice();
                                if (input.len > 0 and input[0] == ':') {
                                    state.input_buffer.clearRetainingCapacity();
                                    state.input_cursor = 0;
                                }
                            },
                            .passphrase => {
                                state.pushSystemMessage("ssh: passphrase entry canceled", .{});
                                state.returnToText();
                            },
                            else => {},
                        },
                        else => {},
                    }
                },
                .paste => |text| switch (state.input_mode) {
                    .text => state.appendBytes(text),
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

        try state.cmd_queue.apply(io, &state);
    }
}

/// Probe `ssh -o BatchMode=yes user@host true`. On success → set SSH target
/// and announce. On failure → open the passphrase modal so the user can
/// unlock a key into ssh-agent and retry.
fn handleSshCommand(
    state: *app.App,
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
fn handleSshUnlock(state: *app.App, cmd_pool: *prv.exec.CmdPool, gpa: std.mem.Allocator) void {
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
    const inherited = state.swarm.env.get("SSH_AUTH_SOCK");
    const sock = cmd_pool.ensureAgent(inherited) catch |err| {
        state.pushSystemMessage("ssh: failed to start ssh-agent ({s})", .{@errorName(err)});
        return;
    };

    // Write helper script to /tmp/blitz-askpass-<pid>.sh (mode 0700).
    const pid = std.os.linux.getpid();
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
        if (state.swarm.env.get(k)) |v| env.put(k, v) catch {};
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
        const input = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
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
