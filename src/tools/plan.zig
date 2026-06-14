const prv = @import("provider");
const std = @import("std");
const r = @import("root.zig");
const prompts = @import("../prompts.zig");

// @DEPRICATED
// plan mode and agents are expensive and not worth it. They produce bad plans that need
// constant baby sitting (even top tier models and other coding tuis). I rather reaseach ideas, collect collisions and make decisions on code myself. The agents
// may then follow my plan.

pub const PlanTool = prv.tool.Tool{
    .def = .{
        .name = "exit_plan_mode",
        .description =
        \\You are not in plan mode. This tool is only for exiting plan mode after writing a plan. If your plan was already approved, continue with implementation.\
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "the path to the plan.md file"}
        \\  },
        \\  "required": ["path"]
        \\}
        ,
    },
    .func = &propose_plan,
};

pub const PlanAgentTool = prv.tool.Tool{
    .def = .{
        .name = "plan_agent",
        .description =
        \\Software architect agent for designing implementation plans. Use this when you need to plan the implementation strategy for a task.
        \\Returns step-by-step plans, identifies critical files, and considers architectural trade-offs.
        \\- Explain what you're trying to accomplish and why.
        \\- Describe what you've already learned or ruled out.
        \\- Give enough context about the surrounding problem that the agent can make judgment calls rather than just following a narrow instruction.
        \\- If you need a short response, say so ("report in under 200 words").
        \\- Lookups: hand over the exact command. Investigations: hand over the question — prescribed steps become dead weight when the premise is wrong.
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "task": {"type": "string", "description": "a description about the task"},
        \\      "context": {"type": "string", "description": "A report about your findings related to the task"}
        \\  },
        \\  "required": ["task", "context"]
        \\}
        ,
    },
    .func = &plan_agent,
};

fn propose_plan(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().permission_level != .write) {
        return r.errResult(call, "Subagents must not write/edit/plan. Instead write a report back to the user");
    }

    const Args = struct { path: []const u8 };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");

    ctx.updateToolStatus(call, "(Review) `{s}`", .{args.path});

    const plan_res = ctx.swarm.exec.runAndWait(.{ .cwd = ctx.cwd, .argv = &.{ "cat", args.path } }) catch
        return r.errResult(call, "failed to read plan");
    defer ctx.swarm.exec.alloc.free(plan_res.stderr);
    // plan_res.stdout transferred into ctx.alloc-owned content below.

    const plan_content = ctx.alloc.dupe(u8, plan_res.stdout) catch {
        ctx.swarm.exec.alloc.free(plan_res.stdout);
        return r.errResult(call, "oom");
    };
    ctx.swarm.exec.alloc.free(plan_res.stdout);

    if (plan_res.ty != .success) return r.errResult(call, plan_content);

    const decision = ctx.requestPerm(call.id, .always_check, .{ .plan = .{
        .path = args.path,
        .plan_text = plan_content,
    } });
    return switch (decision) {
        .approved => r.okResult(call, "plan approved"),
        .denied => r.errResult(call, "User declined plan"),
        .message => |txt| blk: {
            const wrapped = std.fmt.allocPrint(
                ctx.alloc,
                "User declined the plan and left feedback: {s}",
                .{txt},
            ) catch txt;
            break :blk r.errResult(call, wrapped);
        },
        else => r.errResult(call, "permission unresolved"),
    };
}

fn plan_agent(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().permission_level != .write) {
        return r.errResult(call, "Subagents must not write/edit/plan. Instead write a report back to the user");
    }

    const swarm = ctx.swarm;
    const self_id = ctx.self_id;

    const parent_slot = swarm.getSlot(self_id).?;
    if (parent_slot.agent.depth > 0) {
        return r.errResult(call, "Subagents are not allowed to spawn the plan agent. Report your findings instead");
    }

    const Args = struct { task: []const u8, context: []const u8 };
    const parsed = std.json.parseFromSlice(
        Args,
        ctx.alloc,
        call.arguments,
        .{ .ignore_unknown_fields = true },
    ) catch return r.errResult(call, "invalid arguments");
    const args = parsed.value;

    const child_id = swarm.reserveFreeSlot() orelse
        return r.errResult(call, "No agent slots left");

    const parts = ctx.alloc.alloc(prv.adapter.ContentPart, 1) catch
        return r.errResult(call, "oom");
    parts[0] = .{ .text = args.task };

    const app = ctx.interface.cast(@import("../app.zig").App);
    app.cmd_queue.append(ctx.io, .{ .spawn_agent = .{
        .agent_id = child_id,
        .parent_id = self_id,
        .agent_type = @intFromEnum(r.reg.AgentType.sub),
        .tool_budget = ctx.agent().max_allowed_tool_calls,
        .prompt = parts,
        .fork = false,
        .effort = .max,
        .level = .read,
    } }) catch return r.errResult(call, "command queue is full, inform user");

    ctx.updateToolStatus(call, "(Plan) Enslaving higher intelligence .. ", .{});
    ctx.setToolChild(call, child_id);

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
