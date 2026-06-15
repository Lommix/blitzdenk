const std = @import("std");
const r = @import("root.zig");

pub const ZigCallback = *const fn (w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) anyerror!void;

pub const Callback = union(enum) {
    zig: ZigCallback,
    lua: c_int,
};

///! System reminder injection
///! Too make models behave and don't loose focus
///! smort teq
pub const InjectionsHooks = struct {
    const Self = @This();
    _hooks: std.StringHashMapUnmanaged(std.ArrayList(Callback)) = .empty,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var self = Self{};

        inline for (.{
            .{ "env", &inject_env_information },
            .{ "mode", &inject_mode_information },
            .{ "task", &inject_task_information },
            .{ "budget", &inject_budget_information },
            .{ "processes", &inject_processes_information },
        }) |entry| {
            var list = std.ArrayList(Callback).empty;
            try list.append(alloc, .{ .zig = entry[1] });
            try self._hooks.put(alloc, entry[0], list);
        }

        return self;
    }

    pub fn build(self: *const Self, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
        var parts = std.ArrayList(r.prv.adapter.ContentPart).empty;

        const alloc = agent.arena.allocator();
        var writer = std.Io.Writer.Allocating.init(alloc);
        var w = &writer.writer;

        var it = self._hooks.iterator();

        while (it.next()) |en| {
            try w.print("<{s}>\n", .{en.key_ptr.*});
            for (en.value_ptr.items) |hook| {
                switch (hook) {
                    .zig => |call| {
                        try call(w, app, agent);
                    },
                    .lua => {
                        @panic("not yet implemented");
                    },
                }
            }
            try w.print("</{s}>\n", .{en.key_ptr.*});
            try w.flush();

            const text = w.toArrayList().items;
            try parts.append(alloc, .{ .text = text });
        }

        try agent.chat.addMessage(alloc, .user, parts.items);
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
                try w.print("Path: {s} cmd: {s} status: COMPLETED! Read the result!\n", .{ en.path, en.command });
                // TODO: it's not the responsibilty of the reminder to clean this up
                _ = g.ptr.list.swapRemove(i);
            } else {
                try w.print("Path: {s} cmd: {s} status: working\n", .{ en.path, en.command });
            }
        }
    }
}

fn inject_budget_information(w: *std.Io.Writer, _: *r.app.App, agent: *r.prv.agent.Agent) !void {
    const tool_call_limit_reached = agent.tool_call_count >= agent.max_allowed_tool_calls;
    if (tool_call_limit_reached) {
        try w.print("Budget limit reached! Summarize your findings and report back to the user\n", .{});
    } else {
        try w.print("Remaining tool call budget: {d}\n", .{agent.max_allowed_tool_calls -| agent.tool_call_count});
    }
}

fn inject_task_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
    var has_tasks: bool = false;
    if (agent.task_list.tryLock(app.swarm.pool.io)) |g| {
        defer g.unlock();
        var unfinished: u32 = 0;

        for (g.ptr.tasks[0..g.ptr.count]) |t| {
            if (t.state != .done) unfinished += 1;
        }

        for (g.ptr.tasks[0..g.ptr.count]) |t| {
            switch (t.state) {
                .in_progress => {
                    try w.print("[Active Task] id:{d} subject: {s}\n{s}\n", .{ t.id, t.subject, t.description });
                    has_tasks = true;
                },
                .pending => {
                    try w.print("[Pending] id:{d} subject: {s}\n", .{ t.id, t.subject });
                    has_tasks = true;
                },
                else => {},
            }
        }
    }
    if (!has_tasks) try w.print("No active tasks yet. Consider creating one.\n", .{});
}

fn inject_mode_information(w: *std.Io.Writer, app: *r.app.App, agent: *r.prv.agent.Agent) !void {
    const mode: r.reg.Mode = @enumFromInt(agent.mode_idx);
    const reminder = if (agent.flags.force_full_reminder)
        app.context_factory.mode_prompts.get(mode)
    else
        app.context_factory.sparse_mode_prompts.get(mode);
    agent.flags.force_full_reminder = false;

    _ = try w.write(reminder);
    try w.flush();
}

fn inject_env_information(w: *std.Io.Writer, app: *r.app.App, _: *r.prv.agent.Agent) !void {
    const cwd = if (app.swarm.exec.ssh_target != null and app.swarm.exec.ssh_active)
        app.remote_cwd
    else
        app.cwd;

    try w.print("CWD: {s}\n", .{cwd});
}
