const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");
const prompts = @import("../prompts.zig");

pub const AgentTool = prv.tool.Tool{
    .def = .{
        .name = "agent",
        .description =
        \\Launch a new agent to handle complex, multistep tasks autonomously.
        \\
        \\When using the Agent tool, you must specify a subagent_type parameter to select which agent type to use.
        \\
        \\When NOT to use the Agent tool:
        \\- If you want to read a specific file path, use the Read or Glob tool instead of the Agent tool, to find the match more quickly
        \\- If you are searching for a specific class definition like "class Foo", use the Grep tool instead, to find the match more quickly
        \\- If you are searching for code within a specific file or set of 2-3 files, use the Read tool instead of the Agent tool, to find the match more quickly
        \\- If no available agent is a good fit for the task, use other tools directly
        \\
        \\
        \\Usage notes:
        \\1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
        \\2. Once you have delegated work to an agent, do not duplicate that work yourself. Continue with non-overlapping tasks, or wait for the result. For background tasks, you will be notified automatically when the result is ready.
        \\3. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result. The output includes a task_id you can reuse later to continue the same subagent session.
        \\4. Each agent invocation starts with a fresh context unless you provide task_id to resume the same subagent session (which continues with its previous messages and tool outputs). When starting fresh, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
        \\5. The agent's outputs should generally be trusted
        \\6. Clearly tell the agent whether you expect it to write code or just to do research (search, file reads, web fetches, etc.), since it is not aware of the user's intent. Tell it how to verify its work if possible (e.g., relevant test commands).
        \\7. If the agent description mentions that it should be used proactively, then you should try your best to use it without the user having to ask for it first. Use your judgement.
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "description": {"type": "string", "description": "A short (3-5 word) description of the task"},
        \\      "prompt": {"type": "string", "description": "The task for the agent to perform"},
        \\      "agent_type": {"type": "string", "enum": {AGENT_LIST}, "description": "The type of specialized agent to use for this task"}
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

// TODO: subagents types
// - general
// - audit
// - explore

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().depth != 0) {
        return r.errResult(call, "Subagents are not allowed to spawn more subagents");
    }

    const Args = struct {
        description: []const u8,
        prompt: []const u8,
        agent_type: []const u8,
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

    const child_id = ctx.swarm.reserveFreeSlot() orelse
        return r.errResult(call, "No agent slots left");

    const prompt = std.fmt.allocPrint(ctx.alloc,
        \\Your Task: {s}
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
            .level = .read, // TODO: read from type in registry or something
        },
    }) catch return r.errResult(call, "command queue is full, inform user");

    r.setToolChild(ctx, call, child_id);

    r.setToolStatusPrint(ctx, call, "{s} -> {s}", .{ args.agent_type, args.description });
    {
        const g = ctx.agent().bg_agents.lock(ctx.io);
        defer g.unlock();
        g.ptr.list.append(ctx.alloc, .{
            .agent_id = child_id,
            .description = args.description,
            .status = .running,
        }) catch {};
    }

    const text = std.fmt.allocPrint(
        ctx.alloc,
        "Agent spawned. Agent id: {d}",
        .{child_id.pack()},
    ) catch return r.errResult(call, "oom");
    return r.okResult(call, text);
}

pub const SendMessageToAgent = prv.tool.Tool{
    .def = .{
        .name = "send_message_to_agent",
        .description = "send a message to running agent",
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "agent_id":{"type":"number","description":"the agent ID"},
        \\  "message":{"type":"string","description":"the message to the agent"}
        \\},"required":["agent_id", "message"]}
        ,
    },
    .func = &run_send_message_to_agent,
};

fn run_send_message_to_agent(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        agent_id: u32,
        message: []const u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    r.setToolStatusPrint(ctx, call, "sending message to agent {d}", .{args.agent_id});
    const agent_id = prv.Swarm.AgentId.unpack(args.agent_id);

    const app = ctx.swarm.context.cast(@import("../app.zig").App);

    app.cmd_queue.append(ctx.io, .{ .queue_agent_message = .{
        .agent_id = agent_id,
        .parts = &.{.{ .text = args.message }},
    } }) catch return r.errResult(call, "failed to queue message");

    return r.okResult(call, "message sent");
}

pub const AwaitAgent = prv.tool.Tool{
    .def = .{
        .name = "await_agent",
        .description = "Wait for a agent to finish and read its result",
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "agent_id":{"type":"number","description":"the agent ID"}
        \\},"required":["agent_id"]}
        ,
    },
    .func = &run_await_agent,
};

fn run_await_agent(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        agent_id: u32,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments");

    const child_id = prv.Swarm.AgentId.unpack(args.agent_id);

    r.setToolStatusPrint(ctx, call, "waiting for agent {d}", .{args.agent_id});

    const slot = ctx.swarm.getSlot(child_id) orelse
        return r.errResult(call, "agent slot not found");

    const state = slot.state.load(.acquire);
    if (state == .active) {
        slot.event.wait(ctx.io) catch {
            ctx.swarm.releaseAgent(child_id);
            return r.errResult(call, "canceled");
        };
    }

    if (ctx.isCanceled()) {
        ctx.swarm.releaseAgent(child_id);
        return r.errResult(call, "canceled");
    }

    const post_slot = ctx.swarm.getSlot(child_id) orelse return r.errResult(call, "agent slot vanished");
    const is_err = post_slot.state.load(.acquire) == .failed;
    const text = prv.tool.extractChildResult(ctx.swarm, child_id);
    const owned = ctx.alloc.dupe(u8, text) catch {
        ctx.swarm.releaseAgent(child_id);
        return r.errResult(call, "oom");
    };

    ctx.swarm.releaseAgent(child_id);

    {
        const g = ctx.agent().bg_agents.lock(ctx.io);
        defer g.unlock();
        for (g.ptr.list.items, 0..) |bg, i| {
            if (bg.agent_id.index == child_id.index and bg.agent_id.generation == child_id.generation) {
                _ = g.ptr.list.swapRemove(i);
                break;
            }
        }
    }

    return .{
        .call_id = call.id,
        .name = call.name,
        .content = owned,
        .is_error = is_err,
    };
}

pub const CancelAgent = prv.tool.Tool{
    .def = .{
        .name = "cancel_agent",
        .description = "Cancel a running agent",
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "agent_id":{"type":"number","description":"packed AgentId (u32)"}
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
        ctx.swarm.releaseAgent(child_id);
    }

    {
        const g = ctx.agent().bg_agents.lock(ctx.io);
        defer g.unlock();
        for (g.ptr.list.items, 0..) |bg, i| {
            if (bg.agent_id.index == child_id.index and bg.agent_id.generation == child_id.generation) {
                _ = g.ptr.list.swapRemove(i);
                break;
            }
        }
    }

    return r.okResult(call, "agent canceled");
}
