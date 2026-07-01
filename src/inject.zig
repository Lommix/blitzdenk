const std = @import("std");
const r = @import("root.zig");

pub const ZigCallback = *const fn (w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) anyerror!void;

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
            &inject_mode_information,
            &inject_todo_information,
            &inject_budget_information,
            &inject_processes_information,
            &inject_bg_agents_information,
        }) |cb| {
            try self._hooks.append(alloc, .{ .zig = cb });
        }

        return self;
    }

    pub fn build(self: *const Self, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
        const alloc = agent.arena.allocator();

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

        var parts = try alloc.alloc(r.prv.adapter.ContentPart, 1);
        parts[0] = .{ .text = w.toArrayList().items };

        try agent.chat.messages.append(alloc, .{
            .role = .user,
            .parts = parts,
            .flags = .{ .allow_export = false },
        });
    }
};

fn inject_processes_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
    if (agent.bg_tasks.tryLock(app.swarm.pool.io)) |g| blk: {
        defer g.unlock();
        var i = g.ptr.list.items.len;

        if (i == 0) break :blk;

        while (i > 0) {
            i -|= 1;
            const en = &g.ptr.list.items[i];
            if (app.swarm.exec.isDone(en.handle)) {
                try w.print("[BACKGROUND PROCESS] Path: {s} cmd: {s} status: complete\n", .{ en.path, en.command });
                // TODO: it's not the responsibilty of the reminder to clean this up
                _ = g.ptr.list.swapRemove(i);
            } else {
                try w.print("[BACKGROUND PROCESS] Path: {s} cmd: {s} status: working\n", .{ en.path, en.command });
            }
        }
    }
}

fn inject_bg_agents_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
    if (agent.bg_agents.tryLock(app.swarm.pool.io)) |g| blk: {
        defer g.unlock();
        var i = g.ptr.list.items.len;
        if (i == 0) break :blk;
        while (i > 0) {
            i -= 1;
            const bg = &g.ptr.list.items[i];
            const state = if (app.swarm.getSlotState(bg.agent_id)) |s| s else .failed;
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

fn inject_budget_information(w: *std.Io.Writer, _: *r.app.App, agent: *r.prv.agent.Agent) !void {
    const under_half = (agent.max_allowed_tool_calls / 2) < agent.tool_call_count;
    const tool_call_limit_reached = agent.tool_call_count >= agent.max_allowed_tool_calls;

    if (tool_call_limit_reached) {
        try w.print("[BUDGET] Tool call limit reached. Summarize your findings and report back to the user\n", .{});
        return;
    }

    if (under_half) {
        try w.print("[BUDGET] Half of your tool call budget is used up. Consider Summarizing your findings\n", .{});
    }
}

fn inject_todo_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
    var has_todos: bool = false;
    if (agent.todo_list.tryLock(app.swarm.pool.io)) |g| {
        defer g.unlock();
        var unfinished: u32 = 0;

        for (g.ptr.todos[0..g.ptr.count]) |t| {
            if (t.state != .done) unfinished += 1;
        }

        for (g.ptr.todos[0..g.ptr.count]) |t| {
            switch (t.state) {
                .in_progress => {
                    try w.print("[ACTIVE TODO] id:{d} subject: {s}\n{s}\n", .{ t.id, t.subject, t.description });
                    has_todos = true;
                },
                .pending => {
                    try w.print("[PENDING TODO] id:{d} subject: {s}\n", .{ t.id, t.subject });
                    has_todos = true;
                },
                else => {},
            }
        }
    }
}

fn inject_mode_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {

    // mode main agent only
    if (agent.swarm_id != app.main_agent_id) return;

    const mode: r.ContextFactory.Mode = @enumFromInt(agent.mode_idx);
    const def = app.context_factory.getMode(mode);
    const reminder = if (agent.flags.force_full_reminder)
        def.prompt
    else
        def.sparse;
    agent.flags.force_full_reminder = false;

    if (reminder.len == 0) return;
    _ = try w.print("<system-mode>{s}</system-mode>", .{reminder});

    try w.flush();
}
