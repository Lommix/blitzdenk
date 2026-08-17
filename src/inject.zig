const std = @import("std");
const r = @import("root.zig");

pub const ZigCallback = *const fn (w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) anyerror!void;

pub const Callback = union(enum) {
    zig: ZigCallback,
    lua: c_int,
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
            &inject_mode_information,
            &inject_budget_information,
            &inject_processes_information,
            &inject_bg_agents_information,
        }) |cb| {
            try self._hooks.append(alloc, .{ .zig = cb });
        }

        return self;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self._hooks.deinit(alloc);
    }

    pub fn build(self: *const Self, app: *r.app.App, agent: *r.agent.Agent) ![]const u8 {
        const alloc = agent.injection_arena.allocator();

        var writer = std.Io.Writer.Allocating.init(alloc);
        var w = &writer.writer;

        // applying standard name conventions for now
        try w.print("<system-reminder>\n", .{});

        for (self._hooks.items) |cb| {
            var hook_w = std.Io.Writer.Allocating.init(alloc);

            switch (cb) {
                .zig => |call| {
                    try call(&hook_w.writer, app, agent);
                },
                .lua => {
                    @panic("not yet implemented");
                },
            }

            const hook_res = try hook_w.toOwnedSlice();
            defer alloc.free(hook_res);

            if (hook_res.len > 0) {
                try w.writeAll(hook_res);
            }
            try w.flush();
        }

        try w.print("</system-reminder>\n", .{});
        try w.flush();

        return w.toArrayList().items;
    }
};

fn inject_cwd_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    const cwd = app.exec_pool.effectiveCwd(if (agent.cwd.len > 0) agent.cwd else app.cwd);
    if (cwd.len == 0) return;
    try w.print("[CWD] {s}\n", .{cwd});
}

fn inject_datetime_information(w: *std.Io.Writer, app: *r.app.App, _: *r.agent.Agent) !void {
    const res = app.exec_pool.runAndWait(.{ .argv = &.{ "date", "+%Y-%m-%d %H:%M:%S %Z" } }) catch return;
    defer app.exec_pool.alloc.free(res.stdout);
    defer app.exec_pool.alloc.free(res.stderr);
    if (res.ty != .success or res.stdout.len == 0) return;

    const datetime = std.mem.trimEnd(u8, res.stdout, "\n");

    const os_res = app.exec_pool.runAndWait(.{ .argv = &.{ "uname", "-s" } }) catch null;
    defer if (os_res) |ores| {
        app.exec_pool.alloc.free(ores.stdout);
        app.exec_pool.alloc.free(ores.stderr);
    };
    const os_name = if (os_res) |ores|
        if (ores.ty == .success and ores.stdout.len > 0)
            std.mem.trimEnd(u8, ores.stdout, "\n")
        else
            "unknown"
    else
        "unknown";

    try w.print("[TIME] {s} os={s}\n", .{ datetime, os_name });
}

fn inject_processes_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (agent.bg_tasks.tryLock(app.io)) |g| blk: {
        defer g.unlock();
        var i = g.ptr.list.items.len;

        if (i == 0) break :blk;

        // Background tasks stay alive for the agent lifetime. Completed ones are
        // NOT released here: the agent reads their output via read_process, so
        // they must remain readable. Only cancel/teardown frees them.
        while (i > 0) {
            i -|= 1;
            const en = &g.ptr.list.items[i];
            if (app.exec_pool.isDone(en.handle)) {
                try w.print("[BACKGROUND PROCESS] id: {d} cmd: {s} status: complete. Read the output with read_process\n", .{ @intFromEnum(en.handle), en.command });
            } else {
                try w.print("[BACKGROUND PROCESS] id: {d} cmd: {s} status: working\n", .{ @intFromEnum(en.handle), en.command });
            }
        }
    }
}

fn inject_bg_agents_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {
    if (agent.bg_agents.tryLock(app.io)) |g| blk: {
        defer g.unlock();
        var i = g.ptr.list.items.len;
        if (i == 0) break :blk;
        while (i > 0) {
            i -= 1;
            const bg = &g.ptr.list.items[i];
            const state = if (app.registry.state(bg.agent_id)) |s| s else .failed;
            bg.status = switch (state) {
                .complete => .complete,
                .failed => .failed,
                else => .running,
            };

            if (bg.status == .complete) {
                try w.print("[BACKGROUND AGENT COMPLETE] agent_id={d} description: {s}. Read the result with await_agent\n", .{ bg.agent_id.pack(), bg.description });
            } else if (bg.status == .failed) {
                try w.print("[BACKGROUND AGENT FAILED] agent_id={d} description: {s}. Read the result with await_agent\n", .{ bg.agent_id.pack(), bg.description });
            } else {
                try w.print("[BACKGROUND AGENT RUNNING] agent_id={d} description: {s}\n", .{ bg.agent_id.pack(), bg.description });
            }
        }
    }
}

fn inject_budget_information(w: *std.Io.Writer, _: *r.app.App, agent: *r.agent.Agent) !void {
    const count = agent.tool_call_count.load(.acquire);
    const under_half = (agent.max_tool_calls / 2) < count;
    const tool_call_limit_reached = count >= agent.max_tool_calls;

    if (tool_call_limit_reached) {
        try w.print("[BUDGET] Tool call limit reached. Summarize your findings and report back to the user\n", .{});
        return;
    }

    if (under_half) {
        try w.print("[BUDGET] Half of your tool call budget is used up. Consider Summarizing your findings\n", .{});
    }
}

fn inject_mode_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.agent.Agent) !void {

    // mode main agent only
    if (app.mainAgent() != agent) return;

    const mode: r.ContextFactory.Mode = @enumFromInt(agent.mode_idx);
    const def = app.context_factory.getMode(mode);
    const reminder = if (agent.force_full_reminder)
        def.prompt
    else
        def.sparse;
    agent.force_full_reminder = false;

    if (reminder.len == 0) return;
    _ = try w.print("<system-mode>{s}</system-mode>", .{reminder});

    try w.flush();
}
