const std = @import("std");
const r = @import("root.zig");

pub const Callback = *const fn (w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) anyerror!void;

pub const LuaInjectHook = struct {
    main_only: bool = false,
    digest: bool = false,
    last_digest: ?u64 = null,

    pub fn allows(self: *const LuaInjectHook, main_id: ?r.AgentId, agent_id: r.AgentId) bool {
        if (!self.main_only) return true;
        const main = main_id orelse return false;
        return main.pack() == agent_id.pack();
    }

    pub fn accepts(self: *const LuaInjectHook, text: []const u8) bool {
        if (!self.digest) return true;
        const digest = std.hash.Wyhash.hash(0, text);
        if (self.last_digest) |last| {
            if (last == digest) return false;
        }
        return true;
    }

    pub fn remember(self: *LuaInjectHook, text: []const u8) void {
        if (!self.digest) return;
        self.last_digest = std.hash.Wyhash.hash(0, text);
    }
};

///!Inject system reminder on tool turn finish
///!Too make models behave and don't loose focus
pub const InjectionsHooks = struct {
    const Self = @This();
    _hooks: std.ArrayList(Callback) = .empty,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var self = Self{};

        inline for (.{
            &inject_datetime_information,
            &inject_cwd_information,
            &inject_available_skills,
            &inject_capability_catalog,
            &inject_lua_reload_notice,
        }) |cb| {
            try self._hooks.append(alloc, cb);
        }

        return self;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self._hooks.deinit(alloc);
    }

    pub fn build(self: *const Self, app: *r.app.App, agent: *r.agent.Agent) !?[]const u8 {
        if (agent.clean) return null;

        const alloc = agent.injection_arena.allocator();

        var writer = std.Io.Writer.Allocating.init(alloc);
        var w = &writer.writer;

        // applying standard name conventions for now
        try w.print("<system-reminder>\n", .{});

        for (self._hooks.items) |cb| {
            var hook_w = std.Io.Writer.Allocating.init(alloc);

            try cb(&hook_w.writer, app, agent);

            const hook_res = try hook_w.toOwnedSlice();
            defer alloc.free(hook_res);

            if (hook_res.len > 0) {
                try w.writeAll(hook_res);
            }
            try w.flush();
        }

        if (app.lua_inject_hooks_enabled.load(.acquire)) {
            if (app.registry.idForAgent(agent)) |agent_id| {
                var hook_w = std.Io.Writer.Allocating.init(alloc);
                app.lua_vm.emitInjectHooks(&hook_w.writer, agent_id, if (agent.task) |*t| &t.cancellation else null);
                const hook_res = try hook_w.toOwnedSlice();
                defer alloc.free(hook_res);
                if (hook_res.len > 0) {
                    try w.writeAll(hook_res);
                    if (hook_res[hook_res.len - 1] != '\n') try w.writeAll("\n");
                }
                try w.flush();
            }
        }

        try w.print("</system-reminder>\n", .{});
        try w.flush();

        return w.toArrayList().items;
    }
};

fn inject_cwd_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (agent.flags.cwd_seen) return;
    agent.flags.cwd_seen = true;

    const os_res = app.exec_pool.runAndWait(.{ .argv = &.{ "uname", "-s" } }) catch null;
    defer if (os_res) |ores| {
        app.exec_pool.alloc.free(ores.stdout);
        app.exec_pool.alloc.free(ores.stderr);
    };

    const cwd = app.exec_pool.effectiveCwd(if (agent.cwd.len > 0) agent.cwd else app.cwd);

    const os_name = if (os_res) |ores|
        if (ores.ty == .success and ores.stdout.len > 0)
            std.mem.trimEnd(u8, ores.stdout, "\n")
        else
            "unknown"
    else
        "unknown";

    try w.print("[CWD] {s}\n[OS] {s}\n[TMP TESTING DIR] {s}/{d}/\n", .{ cwd, os_name, r.util.TMP_DIR, std.c.getpid() });
}

fn inject_datetime_information(w: *std.Io.Writer, app: *r.app.App, _: *r.agent.Agent) !void {
    const res = app.exec_pool.runAndWait(.{ .argv = &.{ "date", "+%Y-%m-%d %H:%M:%S %Z" } }) catch return;
    defer app.exec_pool.alloc.free(res.stdout);
    defer app.exec_pool.alloc.free(res.stderr);
    if (res.ty != .success or res.stdout.len == 0) return;

    const datetime = std.mem.trimEnd(u8, res.stdout, "\n");
    try w.print("[TIME] {s}\n", .{datetime});
}

fn inject_available_skills(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    const alloc = app.gpa;
    const reg = &app.context_factory.skills;
    var rows = std.Io.Writer.Allocating.init(alloc);
    var count: usize = 0;

    for (reg.entries.items) |entry| {
        if (!entry.meta.model_invocable) continue;
        count += 1;
        try rows.writer.print("- `{s}`: ", .{entry.meta.name});
        try writeCatalogField(&rows.writer, entry.meta.description);
        try rows.writer.writeByte('\n');
    }

    const serialized = try rows.toOwnedSlice();
    defer alloc.free(serialized);

    try emitCatalog(w, "available_skills", count, serialized, &agent.skill_catalog_digest);
}

fn emitCatalog(w: *std.Io.Writer, tag: []const u8, count: usize, serialized: []const u8, digest_slot: *?u64) !void {
    const digest = std.hash.Wyhash.hash(0, serialized);
    if (digest_slot.*) |last| {
        if (last == digest) return;
    }
    try w.print("<{s}>\n", .{tag});
    if (count == 0) {
        try w.writeAll("(none)\n");
    } else {
        try w.writeAll(serialized);
    }
    try w.print("</{s}>\n", .{tag});
    digest_slot.* = digest;
}

fn inject_capability_catalog(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (!agentHasBashTool(agent)) return;

    const factory = app.context_factory;
    try factory.ensureCapabilityCatalog(app.exec_pool);

    factory.capability_catalog_mu.lockUncancelable(factory.io);
    const body = agent.injection_arena.allocator().dupe(u8, factory.capability_catalog_body) catch "";
    const route = factory.capability_catalog_route;
    factory.capability_catalog_mu.unlock(factory.io);

    if (body.len == 0) return;

    const digest = std.hash.Wyhash.hash(route orelse 0, body);
    if (agent.capability_catalog_digest) |last| {
        if (last == digest) return;
    }

    try w.writeAll(body);
    agent.capability_catalog_digest = digest;
}

fn inject_lua_reload_notice(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    const generation = app.lua_reload_generation.load(.acquire);
    if (generation == agent.lua_reload_generation_seen) return;
    agent.lua_reload_generation_seen = generation;
    try w.writeAll("[LUA VM RELOADED]\n");
}

fn agentHasBashTool(agent: *const r.agent.Agent) bool {
    for (agent.tools) |tool| {
        if (std.mem.eql(u8, tool.name, r.tools.bash.BashTool.def.name)) return true;
    }
    return false;
}

fn writeCatalogField(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '\n', '\r' => try w.writeByte(' '),
            else => try w.writeByte(c),
        }
    }
}
