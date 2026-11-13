const std = @import("std");
const builtin = @import("builtin");
const ct = @import("ctime");
const r = @import("root.zig");

pub const Callback = *const fn (w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) anyerror!void;

pub const LuaInjectHook = struct {
    main_only: bool = false,
    digest: bool = false,

    pub fn allows(self: *const LuaInjectHook, main_id: ?r.AgentId, agent_id: r.AgentId) bool {
        if (!self.main_only) return true;
        const main = main_id orelse return false;
        return main.pack() == agent_id.pack();
    }
};

pub const LuaHookDigests = struct {
    hooks_generation: u64 = 0,
    map: std.AutoHashMapUnmanaged(usize, u64) = .empty,
};

///!Inject system reminder on tool turn finish
///!Too make models behave and don't loose focus
pub const InjectionsHooks = struct {
    const hooks = [_]Callback{
        inject_datetime_information,
        inject_cwd_information,
        inject_agents_context,
        inject_available_skills,
        inject_mcp_catalog,
        inject_capability_catalog,
        inject_lua_reload_notice,
    };

    pub fn build(app: *r.app.App, agent: *r.agent.Agent) !?[]const u8 {
        if (agent.clean) return null;

        const alloc = agent.step_arena.allocator();

        var writer = std.Io.Writer.Allocating.init(alloc);
        var w = &writer.writer;

        // applying standard name conventions for now
        try w.print("<system-reminder>\n", .{});

        for (hooks) |cb| {
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
                app.lua_vm.emitInjectHooks(&hook_w.writer, agent_id, agent.type_idx, if (agent.task) |*t| &t.cancellation else null, &agent.lua_hook_digests, agent.alloc);
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

    const cwd = if (agent.cwd.len > 0) agent.cwd else app.cwd;
    const os_name = switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        else => @tagName(builtin.os.tag),
    };

    try w.print("[CWD] {s}\n[OS] {s}\n[TMP TESTING DIR] {s}/{d}/\n", .{ cwd, os_name, r.util.TMP_DIR, std.c.getpid() });
}

const CONTEXT_FILE_CAP: usize = 8192;

const ContextFile = struct {
    text: []const u8,
    truncated: bool,
};

fn readContextFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?ContextFile {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [CONTEXT_FILE_CAP + 1]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    if (n == 0) return null;
    const text = r.util.sanitizeUtf8(alloc, buf[0..@min(n, CONTEXT_FILE_CAP)]) catch return null;
    return .{ .text = text, .truncated = n > CONTEXT_FILE_CAP };
}

fn inject_agents_context(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (agent.flags.agents_context_files_seen) return;

    const alloc = agent.step_arena.allocator();
    const factory = app.context_factory;

    if (app.lua_config_dir) |dir_path| {
        const path = std.fmt.allocPrint(alloc, "{s}/AGENTS.md", .{std.mem.trimEnd(u8, dir_path, "/")}) catch return;
        if (readContextFile(app.io, alloc, path)) |file| {
            try w.print("<user_instructions>\n{s}", .{file.text});
            if (file.truncated) try w.print("\n[truncated at {d} bytes]", .{CONTEXT_FILE_CAP});
            try w.writeAll("\n</user_instructions>\n");
        }
    }

    if (!factory.flags.skip_local_context_file) {
        const cwd = if (agent.cwd.len > 0) agent.cwd else app.cwd;
        const path = std.fmt.allocPrint(alloc, "{s}/AGENTS.md", .{std.mem.trimEnd(u8, cwd, "/")}) catch return;
        if (readContextFile(app.io, alloc, path)) |file| {
            try w.print("<project_instructions>\n{s}", .{file.text});
            if (file.truncated) try w.print("\n[truncated at {d} bytes]", .{CONTEXT_FILE_CAP});
            try w.writeAll("\n</project_instructions>\n");
        }
    }

    agent.flags.agents_context_files_seen = true;
}

fn inject_datetime_information(w: *std.Io.Writer, _: *r.app.App, _: *r.agent.Agent) !void {
    var ts: std.posix.timespec = undefined;
    var tm: ct.struct_tm = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0 or ct.localtime_r(&ts.sec, &tm) == null) return;
    var buf: [64]u8 = undefined;
    const n = ct.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S %Z", &tm);
    if (n == 0) return;
    try w.print("[TIME] {s}\n", .{buf[0..n]});
}

const skill_guideline_line = "Summaries only. If the user names a skill, or the task clearly matches one, `read` its path before taking task actions, then follow its full instructions.";
const skill_replacement_line = "The available skill catalog changed. This complete catalog replaces every earlier available-skills list in this session.";

fn inject_available_skills(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    const def = app.context_factory.agentTypeAt(agent.type_idx) orelse return;
    if (!agent.hasTool(r.tools.read.ReadTool.def.name)) return;
    if (!def.skills.enabled) {
        if (agent.skill_catalog_digest != null) {
            try emitCatalog(w, "available_skills", 0, "", &agent.skill_catalog_digest, skill_replacement_line);
        }
        return;
    }

    const alloc = app.gpa;
    const reg = &app.context_factory.skills;
    const is_main = app.mainAgent() == agent;
    var rows = std.Io.Writer.Allocating.init(alloc);
    var count: usize = 0;

    for (reg.entries.items) |entry| {
        if (!entry.meta.model_invocable) continue;
        if (!r.skills.visibleTo(&entry, def.name, is_main, def.skills)) continue;
        if (count == 0) try rows.writer.writeAll(skill_guideline_line ++ "\n");
        count += 1;
        try rows.writer.print("- `{s}` ({s}): ", .{ entry.meta.name, entry.path });
        try writeCatalogField(&rows.writer, entry.meta.description);
        try rows.writer.writeByte('\n');
    }

    const serialized = try rows.toOwnedSlice();
    defer alloc.free(serialized);

    try emitCatalog(w, "available_skills", count, serialized, &agent.skill_catalog_digest, skill_replacement_line);
}

fn inject_mcp_catalog(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (!agent.hasTool(r.tools.start.StartMcpTool.def.name)) return;

    const names = app.context_factory.availableMcpNames();
    if (names.len == 0) {
        agent.mcp_catalog_digest = null;
        return;
    }

    const alloc = app.gpa;
    var rows = std.Io.Writer.Allocating.init(alloc);
    for (names) |name| {
        try rows.writer.print("- name: \"{s}\"\n", .{name});
    }

    const serialized = try rows.toOwnedSlice();
    defer alloc.free(serialized);

    try emitCatalog(w, "available_mcp", names.len, serialized, &agent.mcp_catalog_digest, "");
}

fn emitCatalog(w: *std.Io.Writer, tag: []const u8, count: usize, serialized: []const u8, digest_slot: *?u64, replacement_line: []const u8) !void {
    const digest = std.hash.Wyhash.hash(0, serialized);
    const replaced = digest_slot.* != null and digest_slot.*.? != digest;
    if (digest_slot.*) |last| {
        if (last == digest) return;
    }
    if (replaced and replacement_line.len > 0) try w.print("{s}\n", .{replacement_line});
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
    if (!agent.hasTool(r.tools.bash.BashTool.def.name)) return;

    const factory = app.context_factory;
    try factory.ensureCapabilityCatalog(app.exec_pool);

    var body: []const u8 = "";
    var digest: u64 = 0;
    {
        factory.capability_catalog_mu.lockUncancelable(factory.io);
        defer factory.capability_catalog_mu.unlock(factory.io);
        body = factory.capability_catalog_body;
        if (body.len == 0) return;
        digest = std.hash.Wyhash.hash(0, body);
        if (agent.capability_catalog_digest) |last| {
            if (last == digest) return;
        }
        body = agent.step_arena.allocator().dupe(u8, body) catch "";
    }
    if (body.len == 0) return;

    try w.writeAll(body);
    agent.capability_catalog_digest = digest;
}

fn inject_lua_reload_notice(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    const generation = app.lua_reload_generation.load(.acquire);
    if (generation == agent.lua_reload_generation_seen) return;
    agent.lua_reload_generation_seen = generation;
    try w.writeAll("[LUA VM RELOADED]\n");
}

fn writeCatalogField(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\n', '\r' => try w.writeByte(' '),
            else => try w.writeByte(c),
        }
    }
}
