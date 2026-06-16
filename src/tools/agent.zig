const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");
const prompts = @import("../prompts.zig");

pub const AgentTool = prv.tool.Tool{
    .def = .{
        .name = "spawn_agent",
        .description =
        \\Spawns a sub-agent in the background and returns immediately with an agent id.
        \\Use await_agent with the returned id to wait for completion and retrieve the result.
        \\Use cancel_agent to cancel a running sub-agent.
        \\Each tool call spawns exactly one sub-agent. To run multiple sub-agents in parallel, emit multiple Agent tool calls in the same response.
        \\
        \\## When to fork
        \\
        \\Fork yourself when the intermediate tool output isn't worth keeping in your context.
        \\The criterion is qualitative — "will I need this output again" — not task size.
        \\
        \\- **Research**: fork open-ended questions. If research can be broken into independent questions, launch parallel forks in one message. A fork beats a fresh subagent for this — it inherits context and shares your cache.
        \\- **Implementation**: prefer to fork implementation work that requires more than a couple of edits. Do research before jumping to implementation.
        \\
        \\Forks are cheap because they share your prompt cache
        \\**Writing a fork prompt.** Since the fork inherits your context, the prompt is a _directive_ — what to do, not what the situation is. Be specific about scope: what's in, what's out, what another agent is handling. Don't re-explain background.
        \\
        \\## Writing the prompt
        \\
        \\When spawning a fresh agent it starts with zero context. Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.
        \\
        \\- Explain what you're trying to accomplish and why.
        \\- Describe what you've already learned or ruled out.
        \\- Give enough context about the surrounding problem that the agent can make judgment calls rather than just following a narrow instruction.
        \\- If you need a short response, say so ("report in under 200 words").
        \\- Lookups: hand over the exact command. Investigations: hand over the question — prescribed steps become dead weight when the premise is wrong.
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "description": {"type": "string", "description": "A short (3-5 word) description of the task"},
        \\      "prompt": {"type": "string", "description": "The task for the agent to perform"},
        \\      "budget": {"type": "number", "description": "The amount of allowed tool calls before stopping. For most tasks between 10 - 30 depending on complexity is a good amount"},
        \\      "effort": {"type": "string", "enum": ["min", "mid", "max"], "description": "Effort level deciding which model the child agent uses"},
        \\      "type": {"type": "string", "enum": ["fork", "fresh"], "description": "forked agents inherit chat history, fresh start with an empty history"},
        \\      "allow_write": {"type": "boolean", "default": false, "description": "allow write"}
        \\  },
        \\  "required": ["description","prompt","budget","effort","type"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().depth != 0) {
        return r.errResult(call, "Subagents are not allowed to spawn more subagents");
    }

    const swarm = ctx.swarm;
    const self_id = ctx.self_id;

    const Args = struct {
        description: []const u8,
        prompt: []const u8,
        budget: u32,
        effort: []const u8,
        type: []const u8,
        allow_write: bool = false,
    };

    const parsed = std.json.parseFromSlice(
        Args,
        ctx.alloc,
        call.arguments,
        .{ .ignore_unknown_fields = true },
    ) catch return r.errResult(call, "invalid arguments");
    const args = parsed.value;
    const is_fork = std.mem.eql(u8, args.type, "fork");

    if (is_fork) {
        const slot = swarm.getSlot(self_id).?;
        if (slot.agent.depth > 0) {
            return r.errResult(call, "Forks are not allowed to fork again");
        }
    }

    const child_id = ctx.swarm.reserveFreeSlot() orelse
        return r.errResult(call, "No agent slots left");

    const effort: prv.config.EffortLevel = elk: {
        if (std.mem.eql(u8, "max", args.effort)) break :elk .max;
        if (std.mem.eql(u8, "mid", args.effort)) break :elk .mid;
        break :elk .min;
    };

    const prompt = std.fmt.allocPrint(ctx.alloc,
        \\Your Task: {s}
        \\
        \\{s}
    , .{ args.description, args.prompt }) catch return r.errResult(call, "out of memory");

    const parts = ctx.alloc.alloc(prv.adapter.ContentPart, 1) catch
        return r.errResult(call, "oom");

    parts[0] = .{ .text = prompt };

    const app = ctx.swarm.context.cast(@import("../app.zig").App);
    app.cmd_queue.append(ctx.io, .{ .spawn_agent = .{
        .agent_id = child_id,
        .parent_id = ctx.self_id,
        .tool_budget = args.budget,
        .prompt = parts,
        .fork = is_fork,
        .effort = effort,
        .level = .read,
    } }) catch return r.errResult(call, "command queue is full, inform user");

    ctx.setToolChild(call, child_id);

    if (is_fork) {
        ctx.updateToolStatus(call, "(New Fork) {s} ({d})", .{ args.description, args.budget });
    } else {
        ctx.updateToolStatus(call, "(New {s} Agent) {s} ({d})", .{ args.effort, args.description, args.budget });
    }

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

    ctx.updateToolStatus(call, "(Sending Message) - to {d}", .{args.agent_id});
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

    ctx.updateToolStatus(call, "(Awaiting Agent) - {d}", .{args.agent_id});

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
