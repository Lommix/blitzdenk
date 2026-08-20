const r = @import("root.zig");
const std = @import("std");

pub const AgentTool = r.Tool{
    .def = .{
        .name = "agent",
        .description =
        \\Launch a new agent to handle a tasks autonomously.
        \\
        ,
        .prompt_snippet = "Launch a subagent",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "description": {"type": "string", "description": "A short (3-5 word) description of the task"},
        \\      "prompt": {"type": "string", "description": "The task for the agent to perform"},
        \\      "agent_type": {"type": "string", "enum": {AGENT_LIST}, "description": "The type of specialized agent to use for this task"},
        \\      "cwd": {"type": "string", "description": "The working directoy of the agent. Defaults to current"}
        \\  },
        \\  "required": ["description","prompt","agent_type"]
        \\}
        ,
    },
    .func = &run,
};

const ctxf = @import("../context_factory.zig");

// TODO: redesign overwrite tool def api
pub fn dynamic_def(alloc: std.mem.Allocator, agent_defs: []const ctxf.AgentMeta) !struct { desc: []const u8, schema: []const u8 } {
    var w = std.Io.Writer.Allocating.init(alloc);
    try w.writer.print("{s}\n\nAvailable agent types:\n", .{AgentTool.def.description});

    var count: u32 = 1;
    for (agent_defs) |def| {
        try w.writer.print("{d}. name: {s}\ndescription: {s}\n\n", .{ count, def.name, def.description });
        count += 1;
    }

    try w.writer.flush();
    const final_description = try w.toOwnedSlice();

    try w.writer.writeAll("[");
    for (agent_defs, 0..) |def, i| {
        if (i != 0) try w.writer.print(",", .{});
        try w.writer.print("\"{s}\"", .{def.name});
    }
    try w.writer.writeAll("]");
    try w.writer.flush();

    const schema = try std.mem.replaceOwned(
        u8,
        alloc,
        AgentTool.def.parameters_schema,
        "{AGENT_LIST}",
        try w.toOwnedSlice(),
    );

    return .{
        .desc = final_description,
        .schema = schema,
    };
}

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const self = ctx.base.registry.get(ctx.base.self_id) orelse
        return r.errResult(call, "agent not found");
    if (self.depth > 0)
        return r.errResult(call, "subagents cannot spawn subagents");

    const Args = struct {
        description: []const u8,
        prompt: []const u8,
        agent_type: []const u8,
        cwd: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(
        Args,
        ctx.alloc,
        call.input,
        .{ .ignore_unknown_fields = true },
    ) catch return r.errResult(call, "invalid arguments");
    const args = parsed.value;
    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    const agent_type = app.context_factory.findAgentType(args.agent_type) orelse
        return r.errResult(call, "unknown agent type");

    const cwd = if (args.cwd) |cwd|
        std.fs.path.resolve(ctx.alloc, &.{ ctx.base.cwd, cwd }) catch
            return r.errResult(call, "invalid cwd")
    else
        ctx.base.cwd;

    const child_id = ctx.base.registry.reserve() orelse
        return r.errResult(call, "No agent slots left");

    const prompt = std.fmt.allocPrint(ctx.alloc,
        \\Your Task: "{s}"
        \\
        \\{s}
    , .{ args.description, args.prompt }) catch return r.errResult(call, "out of memory");

    const parts = ctx.alloc.alloc(r.r.sdk.Part, 1) catch
        return r.errResult(call, "oom");

    parts[0] = .{ .text = prompt };
    app.cmd_queue.append(ctx.io, .{
        .spawn_agent = .{
            .agent_id = child_id,
            .parent_id = ctx.base.self_id,
            .agent_type = @intFromEnum(agent_type),
            .prompt = parts,
            .cwd = cwd,
        },
    }) catch {
        ctx.base.registry.releaseReservation(child_id);
        return r.errResult(call, "command queue is full, inform user");
    };

    r.setToolChild(ctx, call, child_id);

    var status_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&status_buf);
    w.styledPrint(.{ .modifier = .{ .bold = true }, .fg = app.theme.info }, "{s}", .{args.agent_type});
    w.styled(.{ .fg = app.theme.text }, " -> ");
    w.styledPrint(.{ .modifier = .{ .bold = true } }, "{s}", .{args.description});
    r.setToolStatus(ctx, call, w.finish()) catch {};

    return awaitChildResult(ctx, call, child_id, true);
}

fn childGone(call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    return r.errResult(call, "child agent spawn failed or was canceled");
}

fn bail(ctx: r.ToolContext, call: r.r.sdk.ToolCall, child_id: r.r.AgentId, msg: []const u8) r.r.sdk.ToolOutput {
    releaseChild(ctx, child_id);
    return r.errResult(call, msg);
}

fn releaseChild(ctx: r.ToolContext, child_id: r.r.AgentId) void {
    const st = ctx.base.registry.state(child_id) orelse return;
    switch (st) {
        .reserved => ctx.base.registry.releaseReservation(child_id),
        else => ctx.base.registry.release(child_id),
    }
}

fn awaitChildResult(
    ctx: r.ToolContext,
    call: r.r.sdk.ToolCall,
    child_id: r.r.AgentId,
    despawn: bool,
) r.r.sdk.ToolOutput {
    while (true) {
        const state = ctx.base.registry.state(child_id) orelse return childGone(call);
        if (state != .active and state != .reserved) break;
        if (waitForChild(ctx, child_id)) break;
        if (ctx.isCanceled()) return bail(ctx, call, child_id, "canceled");
    }

    const state = ctx.base.registry.state(child_id) orelse return childGone(call);
    const is_err = state == .failed;
    const text = extractChildResult(ctx.base.registry, child_id);
    const owned = ctx.alloc.dupe(u8, text) catch return bail(ctx, call, child_id, "oom");

    if (despawn) releaseChild(ctx, child_id);

    return .{ .content = owned, .is_error = is_err };
}

fn waitForChild(ctx: r.ToolContext, child_id: r.r.AgentId) bool {
    const registry = ctx.base.registry;
    const token = ctx.cancellation() orelse {
        _ = registry.wait(child_id) catch return true;
        return false;
    };
    while (true) {
        const state = registry.state(child_id) orelse return true;
        if (state != .active and state != .reserved) return true;
        if (token.isCancelled()) return false;
        std.Io.sleep(ctx.io, .fromMilliseconds(100), .awake) catch return false;
    }
}

fn extractChildResult(registry: *r.r.agent_registry.Registry, child_id: r.r.AgentId) []const u8 {
    const child = registry.get(child_id) orelse return "child agent not found";
    var index = child.history().len;
    while (index > 0) {
        index -= 1;
        const message = child.history()[index];
        if (message.role != .assistant) continue;
        for (message.parts()) |part| switch (part) {
            .text => |text| return text,
            else => {},
        };
    }
    return "child produced no text output";
}
