const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");
const prompts = @import("../prompts.zig");

pub const AgentTool = prv.tool.Tool{
    .def = .{
        .name = "Agent",
        .description =
        \\Spawns a single sub-agent to research, explore, or execute a multi-step task.
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

    const app = ctx.interface.cast(@import("../app.zig").App);
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

    // Wait for the child slot to terminate. The swarm's tickAll on the UI
    // thread sets slot.event when state transitions to .complete/.failed.
    const slot = swarm.getSlot(child_id).?;
    slot.event.wait(ctx.io) catch {
        swarm.releaseAgent(child_id);
        return r.errResult(call, "canceled");
    };

    if (ctx.isCanceled()) {
        swarm.releaseAgent(child_id);
        return r.errResult(call, "canceled");
    }

    const post_slot = swarm.getSlot(child_id) orelse return r.errResult(call, "child slot vanished");
    const is_err = post_slot.state.load(.acquire) == .failed;
    const text = prv.tool.extractChildResult(swarm, child_id);
    // Dupe before releaseAgent — `text` aliases the child arena.
    const owned = ctx.alloc.dupe(u8, text) catch {
        swarm.releaseAgent(child_id);
        return r.errResult(call, "oom");
    };
    swarm.releaseAgent(child_id);

    return .{
        .call_id = call.id,
        .name = call.name,
        .content = owned,
        .is_error = is_err,
    };
}
