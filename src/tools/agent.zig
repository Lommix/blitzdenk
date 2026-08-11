const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

pub const AgentTool = prv.tool.Tool{
    .def = .{
        .name = "agent",
        .description =
        \\Launch a new agent to handle complex, multistep tasks autonomously.
        \\
        \\When using the Agent tool, you must specify an agent_type parameter to select which agent type to use.
        \\
        \\By default the tool blocks until the sub-agent finishes and returns its final message as the tool result. Set "run_in_background": true to spawn it in the background instead: the tool returns immediately with the agent id, and the result is read later with the await_agent tool.
        \\
        \\When NOT to use the Agent tool:
        \\- If you want to read a specific file path, use the Read or Glob tool instead of the Agent tool, to find the match more quickly
        \\- If you are searching for a specific class definition like "class Foo", use the Grep tool instead, to find the match more quickly
        \\- If you are searching for code within a specific file or set of 2-3 files, use the Read tool instead of the Agent tool, to find the match more quickly
        \\- If no available agent is a good fit for the task, use other tools directly
        \\
        \\
        \\Usage notes:
        \\1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses (each call blocks until its agent finishes).
        \\2. Once you have delegated work to an agent, do not duplicate that work yourself. Continue with non-overlapping tasks, or wait for the result. For background agents (run_in_background: true) you will be notified automatically when the result is ready.
        \\3. A blocking agent call returns the agent's final message directly as its result. For background agents, read the result with the await_agent tool; the result is not visible to the user, so send a concise summary back to the user yourself.
        \\4. Each agent invocation starts with a fresh context. Your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
        \\5. The agent's outputs should generally be trusted
        \\6. Clearly tell the agent whether you expect it to write code or just to do research (search, file reads, web fetches, etc.), since it is not aware of the user's intent. Tell it how to verify its work if possible (e.g., relevant test commands).
        \\7. If the agent description mentions that it should be used proactively, then you should try your best to use it without the user having to ask for it first. Use your judgement.
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

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
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
        call.arguments,
        .{ .ignore_unknown_fields = true },
    ) catch return r.errResult(call, "invalid arguments");
    const args = parsed.value;
    const app = ctx.swarm.context.cast(@import("../app.zig").App);
    const agent_type = app.context_factory.findAgentType(args.agent_type) orelse
        return r.errResult(call, "unknown agent type");

    const cwd = if (args.cwd) |cwd|
        std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, cwd }) catch
            return r.errResult(call, "invalid cwd")
    else
        ctx.cwd;

    const child_id = ctx.swarm.reserveFreeSlot() orelse
        return r.errResult(call, "No agent slots left");

    const prompt = std.fmt.allocPrint(ctx.alloc,
        \\Your Task: "{s}"
        \\
        \\{s}
    , .{ args.description, args.prompt }) catch return r.errResult(call, "out of memory");

    const parts = ctx.alloc.alloc(prv.adapter.ContentPart, 1) catch
        return r.errResult(call, "oom");

    parts[0] = .{ .text = prompt };
    app.cmd_queue.append(ctx.io, .{
        .spawn_agent = .{
            .agent_id = child_id,
            .parent_id = ctx.self_id,
            .agent_type = @intFromEnum(agent_type),
            .prompt = parts,
            .cwd = cwd,
        },
    }) catch {
        ctx.swarm.releaseReservation(child_id);
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

        return .{
            .call_id = call.id,
            .content = text,
            .name = call.name,
            .comp_strat = .keep,
        };
    }

    return awaitChildResult(ctx, call, child_id, true);
}

fn addBgAgent(ctx: prv.tool.ToolContext, child_id: prv.Swarm.AgentId, description: []const u8) void {
    const g = ctx.agent().bg_agents.lock(ctx.io);
    defer g.unlock();
    g.ptr.list.append(ctx.alloc, .{
        .agent_id = child_id,
        .description = description,
        .status = .running,
    }) catch {};
}

fn dropBgAgent(ctx: prv.tool.ToolContext, child_id: prv.Swarm.AgentId) void {
    const g = ctx.agent().bg_agents.lock(ctx.io);
    defer g.unlock();
    for (g.ptr.list.items, 0..) |bg, i| {
        if (bg.agent_id.index == child_id.index and bg.agent_id.generation == child_id.generation) {
            _ = g.ptr.list.swapRemove(i);
            break;
        }
    }
}

fn childGone(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall, child_id: prv.Swarm.AgentId) prv.adapter.ToolResult {
    dropBgAgent(ctx, child_id);
    return r.errResult(call, "child agent spawn failed or was canceled");
}

fn bail(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall, child_id: prv.Swarm.AgentId, msg: []const u8) prv.adapter.ToolResult {
    releaseChild(ctx, child_id);
    dropBgAgent(ctx, child_id);
    return r.errResult(call, msg);
}

fn releaseChild(ctx: prv.tool.ToolContext, child_id: prv.Swarm.AgentId) void {
    const st = ctx.swarm.getSlotState(child_id) orelse return;
    switch (st) {
        .reserved => ctx.swarm.releaseReservation(child_id),
        else => ctx.swarm.releaseAgent(child_id),
    }
}

fn awaitChildResult(
    ctx: prv.tool.ToolContext,
    call: prv.adapter.ToolCall,
    child_id: prv.Swarm.AgentId,
    despawn: bool,
) prv.adapter.ToolResult {
    while (true) {
        const slot = ctx.swarm.getSlot(child_id) orelse return childGone(ctx, call, child_id);
        const state = slot.state.load(.acquire);
        if (state != .active and state != .reserved) break;

        slot.event.wait(ctx.io) catch return bail(ctx, call, child_id, "canceled");
        if (ctx.isCanceled()) return bail(ctx, call, child_id, "canceled");

        const state2 = slot.state.load(.acquire);
        if (state2 == .reserved or state2 == .active) {
            slot.event.reset();
        }
    }

    const slot = ctx.swarm.getSlot(child_id) orelse return childGone(ctx, call, child_id);
    const is_err = slot.state.load(.acquire) == .failed;
    const text = prv.tool.extractChildResult(ctx.swarm, child_id);
    const owned = ctx.alloc.dupe(u8, text) catch return bail(ctx, call, child_id, "oom");

    if (despawn) releaseChild(ctx, child_id);
    dropBgAgent(ctx, child_id);

    return .{
        .call_id = call.id,
        .name = call.name,
        .content = owned,
        .is_error = is_err,
    };
}

pub const AwaitAgent = prv.tool.Tool{
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

fn run_await_agent(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        agent_id: u32,
        despawn: bool = true,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    const child_id = prv.Swarm.AgentId.unpack(args.agent_id);

    r.setToolStatusPrint(ctx, call, "waiting for agent {d}", .{args.agent_id});

    return awaitChildResult(ctx, call, child_id, args.despawn);
}

pub const CancelAgent = prv.tool.Tool{
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

fn run_cancel_agent(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        agent_id: u32,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    const child_id = prv.Swarm.AgentId.unpack(args.agent_id);

    if (ctx.swarm.getSlot(child_id)) |slot| {
        if (slot.state.load(.acquire) == .active) {
            slot.agent.cancel();
        }
        releaseChild(ctx, child_id);
    }
    dropBgAgent(ctx, child_id);

    return r.okResult(call, "agent canceled");
}
