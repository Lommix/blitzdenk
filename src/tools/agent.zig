const r = @import("root.zig");
const std = @import("std");

pub const AgentTool = r.Tool{
    .def = .{
        .name = "agent",
        .description =
        \\Launch a new agent to handle complex, multistep tasks autonomously.
        \\When using the Agent tool, you must specify an agent_type parameter to select which agent type to use.
        \\By default the tool blocks until the sub-agent finishes and returns its final message as the tool result. Set "run_in_background": true to spawn it in the background instead: the tool returns immediately with the agent id, and the result is read later with the await_agent tool.
        \\
        ,
        .prompt_snippet = "Launch a subagent",
        .prompt_guidelines = "Launch multiple agents concurrently whenever possible.",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "description": {"type": "string", "description": "A short (3-5 word) description of the task"},
        \\      "prompt": {"type": "string", "description": "The task for the agent to perform"},
        \\      "agent_type": {"type": "string", "enum": {AGENT_LIST}, "description": "The type of specialized agent to use for this task"},
        \\      "cwd": {"type": "string", "description": "The working directoy of the agent"},
        \\      "run_in_background": {"type": "boolean", "default": false, "description": "If true, spawn in the background and return immediately with the agent id; read the result later with await_agent. If false (default), block until the agent finishes and return its final message."}
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
    const Args = struct {
        description: []const u8,
        prompt: []const u8,
        agent_type: []const u8,
        cwd: ?[]const u8 = null,
        run_in_background: bool = false,
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

    r.setToolStatusPrint(ctx, call, "{s} -> {s}", .{ args.agent_type, args.description });
    addBgAgent(ctx, child_id, args.description);

    if (args.run_in_background) {
        const text = std.fmt.allocPrint(
            ctx.alloc,
            "Agent spawned. Agent id: {d}",
            .{child_id.pack()},
        ) catch return r.errResult(call, "oom");

        return r.okResult(call, text);
    }

    return awaitChildResult(ctx, call, child_id, true);
}

fn addBgAgent(ctx: r.ToolContext, child_id: r.r.AgentId, description: []const u8) void {
    const agent = ctx.agent();
    const g = agent.bg_agents.lock(ctx.io);
    defer g.unlock();
    const alloc = agent.state_arena.allocator();
    const owned_description = alloc.dupe(u8, description) catch return;
    g.ptr.list.append(alloc, .{
        .agent_id = child_id,
        .description = owned_description,
        .status = .running,
    }) catch {};
}

fn dropBgAgent(ctx: r.ToolContext, child_id: r.r.AgentId) void {
    const g = ctx.agent().bg_agents.lock(ctx.io);
    defer g.unlock();
    for (g.ptr.list.items, 0..) |bg, i| {
        if (bg.agent_id.index == child_id.index and bg.agent_id.generation == child_id.generation) {
            _ = g.ptr.list.swapRemove(i);
            break;
        }
    }
}

fn childGone(ctx: r.ToolContext, call: r.r.sdk.ToolCall, child_id: r.r.AgentId) r.r.sdk.ToolOutput {
    dropBgAgent(ctx, child_id);
    return r.errResult(call, "child agent spawn failed or was canceled");
}

fn bail(ctx: r.ToolContext, call: r.r.sdk.ToolCall, child_id: r.r.AgentId, msg: []const u8) r.r.sdk.ToolOutput {
    releaseChild(ctx, child_id);
    dropBgAgent(ctx, child_id);
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
        const state = ctx.base.registry.state(child_id) orelse return childGone(ctx, call, child_id);
        if (state != .active and state != .reserved) break;
        _ = ctx.base.registry.wait(child_id) catch return bail(ctx, call, child_id, "canceled");
        if (ctx.isCanceled()) return bail(ctx, call, child_id, "canceled");
    }

    const state = ctx.base.registry.state(child_id) orelse return childGone(ctx, call, child_id);
    const is_err = state == .failed;
    const text = extractChildResult(ctx.base.registry, child_id);
    const owned = ctx.alloc.dupe(u8, text) catch return bail(ctx, call, child_id, "oom");

    if (despawn) releaseChild(ctx, child_id);
    dropBgAgent(ctx, child_id);

    return .{ .content = owned, .is_error = is_err };
}

pub const AwaitAgent = r.Tool{
    .def = .{
        .name = "await_agent",
        .description = "Wait for a agent to finish and read its result",
        .prompt_snippet = "Wait for a background agent",
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "agent_id":{"type":"number","description":"the agent id"},
        \\  "despawn":{"type":"boolean", "default": true, "description":"By default agents despawn after their final message is read"}
        \\},"required":["agent_id"]}
        ,
    },
    .func = &run_await_agent,
};

fn run_await_agent(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct {
        agent_id: u32,
        despawn: bool = true,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    const child_id = r.r.AgentId.unpack(args.agent_id);

    r.setToolStatusPrint(ctx, call, "waiting for agent {d}", .{args.agent_id});

    return awaitChildResult(ctx, call, child_id, args.despawn);
}

pub const CancelAgent = r.Tool{
    .def = .{
        .name = "cancel_agent",
        .description = "Cancel a running agent",
        .prompt_snippet = "Cancel a running agent",
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "agent_id":{"type":"number","description":"The agent id to cancel"}
        \\},"required":["agent_id"]}
        ,
    },
    .func = &run_cancel_agent,
};

fn run_cancel_agent(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct {
        agent_id: u32,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    const child_id = r.r.AgentId.unpack(args.agent_id);

    if (ctx.base.registry.state(child_id) != null) {
        const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
        app.cancelAgentPermissions(child_id);
        ctx.base.registry.cancel(child_id);
        releaseChild(ctx, child_id);
    }
    dropBgAgent(ctx, child_id);

    return r.okResult(call, "agent canceled");
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
