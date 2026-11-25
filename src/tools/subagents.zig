const std = @import("std");
const r = @import("root.zig");
const inject = r.r.inject;
const App = r.r.app.App;

const MAX_SPAWNER_DEPTH = 1;
const DEFAULT_AGENT_TYPE = @tagName(r.r.ContextFactory.AgentType.general);

pub const SET_SUBAGENTS = [_][]const u8{
    AgentTool.def.name,
    MessageAgentTool.def.name,
    CancelAgentTool.def.name,
    IdleTool.def.name,
};

pub const AgentTool = r.Tool{
    .def = .{
        .name = "agent",
        .description =
        \\Launch a new background agent to handle a task autonomously. The tool returns immediately.
        \\When the agent finishes, its answer is injected into your context; oversized answers spill to a file. Subagents will wake you up.
        \\
        ,
        .prompt_snippet = "launch a new agent with a task",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "description": {"type": "string", "description": "A short (3-5 word) description of the task"},
        \\      "prompt": {"type": "string", "description": "The task for the agent to perform"},
        \\      "agent_type": {"type": "string", "description": "The type of specialized agent to use for this task. One name from the available agents catalogue. Defaults to general"},
        \\      "cwd": {"type": "string", "description": "The working directory of the agent. Defaults to current"}
        \\  },
        \\  "required": ["description", "prompt"]
        \\}
        ,
    },
    .func = &runAgent,
};

pub const MessageAgentTool = r.Tool{
    .def = .{
        .name = "message_agent",
        .description = "send a message to another agent",
        .prompt_snippet = "message an agent",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "agent_id": {"type": "integer", "description": "the id from the agent tool result"},
        \\      "message": {"type": "string", "description": "the text to deliver"}
        \\  },
        \\  "required": ["agent_id", "message"]
        \\}
        ,
    },
    .func = &runMessageAgent,
};

pub const CancelAgentTool = r.Tool{
    .def = .{
        .name = "cancel_agent",
        .description = "abort a sub agent",
        .prompt_snippet = "cancel an agent",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "agent_id": {"type": "integer", "description": "the id from the agent tool result"}
        \\  },
        \\  "required": ["agent_id"]
        \\}
        ,
    },
    .func = &runCancelAgent,
};

pub const IdleTool = r.Tool{
    .def = .{
        .name = "idle",
        .description = "End your turn and wait until a subagent wakes you. Call it when only waiting for subagent results remains; do not poll, sleep, or re-check agents that have not reported yet.",
        .prompt_snippet = "Wait for your sub agents",
        .parameters_schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .func = &runIdle,
};

fn runAgent(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const Args = struct {
        description: []const u8,
        prompt: []const u8,
        agent_type: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
    };
    const args = r.parseArgs(Args, ctx, call) orelse
        return r.errResult(call, "invalid arguments: expected {description, prompt, agent_type?, cwd?}");

    if (ctx.agent().depth > MAX_SPAWNER_DEPTH) return r.errResult(call, "max agent depth reached");

    const app = appOf(ctx);
    const type_name = args.agent_type orelse DEFAULT_AGENT_TYPE;
    const agent_type = findAgentType(app, type_name) orelse
        return failure(ctx, call, "unknown agent type: {s}", .{type_name});

    const id = spawn(ctx, app, .{
        .agent_type = agent_type,
        .description = args.description,
        .prompt = args.prompt,
        .cwd = args.cwd orelse "",
        .clean = false,
    }) catch |err| return switch (err) {
        error.NoAgentSlots => r.errResult(call, "No agent slots left"),
        else => failure(ctx, call, "failed to start agent: {s}", .{@errorName(err)}),
    };

    r.addToolChild(ctx, call, id);
    setSpawnStatus(ctx, call, app.theme, type_name, args.description);
    return success(ctx, call, "Agent started in background. agent_id: {d}", .{id.pack()});
}

const SpawnRequest = struct {
    agent_type: r.r.ContextFactory.AgentType,
    description: []const u8,
    prompt: []const u8,
    cwd: []const u8,
    clean: bool,
};

fn spawn(ctx: r.ToolContext, app: *App, request: SpawnRequest) !r.r.AgentId {
    const prompt = try std.fmt.allocPrint(ctx.alloc, "# Task: \"{s}\"\n\n{s}", .{ request.description, request.prompt });
    const cwd = if (request.cwd.len > 0)
        try std.fs.path.resolve(ctx.alloc, &.{ ctx.base.cwd, request.cwd })
    else
        "";

    const id = ctx.base.registry.reserve(ctx.base.self_id) orelse return error.NoAgentSlots;
    errdefer ctx.base.registry.releaseReservation(id);
    try app.cmd_queue.append(ctx.io, .{ .spawn_agent = .{
        .parent_id = ctx.base.self_id,
        .agent_id = id,
        .prompt = &.{.{ .text = prompt }},
        .agent_type = @backingInt(request.agent_type),
        .cwd = cwd,
        .background = true,
        .task = request.description,
        .clean = request.clean,
    } });
    return id;
}

fn findAgentType(app: *App, name: []const u8) ?r.r.ContextFactory.AgentType {
    app.lua_vm.vm_mu.lockUncancelable(app.io);
    defer app.lua_vm.vm_mu.unlock(app.io);
    return app.context_factory.findAgentType(name);
}

fn runMessageAgent(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const Args = struct { agent_id: u32, message: []const u8 };
    const args = r.parseArgs(Args, ctx, call) orelse
        return r.errResult(call, "invalid arguments: expected {agent_id, message}");

    const app = appOf(ctx);
    const id = r.r.AgentId.unpack(args.agent_id);
    if (ctx.base.registry.state(id) == null) return failure(ctx, call, "unknown agent: {d}", .{args.agent_id});

    app.cmd_queue.append(ctx.io, .{ .queue_agent_message = .{
        .agent_id = id,
        .parts = &.{.{ .text = args.message }},
    } }) catch |err| return failure(ctx, call, "failed to message agent: {s}", .{@errorName(err)});

    setMessageStatus(ctx, call, app.theme, args.agent_id, args.message);
    return r.okResult(call, "send");
}

fn runCancelAgent(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const Args = struct { agent_id: u32 };
    const args = r.parseArgs(Args, ctx, call) orelse
        return r.errResult(call, "invalid arguments: expected {agent_id}");

    const id = r.r.AgentId.unpack(args.agent_id);
    if (ctx.base.registry.state(id) == null) return failure(ctx, call, "unknown agent: {d}", .{args.agent_id});

    appOf(ctx).cmd_queue.append(ctx.io, .{ .cancel_agent = id }) catch |err|
        return failure(ctx, call, "failed to cancel agent: {s}", .{@errorName(err)});

    r.setToolStatusPrint(ctx, call, "Cancel agent({d})", .{args.agent_id});
    return r.okResult(call, "canceled");
}

fn runIdle(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    r.setToolStatusPrint(ctx, call, "Waiting for something to happen", .{});
    return .{ .content = "", .exit_loop = true };
}

fn setSpawnStatus(ctx: r.ToolContext, call: r.ToolCall, theme: r.r.app.Theme, type_name: []const u8, description: []const u8) void {
    var buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&buf);
    w.styled(.{ .modifier = .{ .bold = true }, .fg = theme.info }, type_name);
    w.styled(.{ .fg = theme.text }, " -> ");
    w.styled(.{ .modifier = .{ .bold = true }, .fg = theme.text_hl }, description);
    r.setToolStatus(ctx, call, w.finish()) catch {};
}

fn setMessageStatus(ctx: r.ToolContext, call: r.ToolCall, theme: r.r.app.Theme, agent_id: u32, message: []const u8) void {
    const buf = ctx.alloc.alloc(u8, message.len + r.STATUS_BUF) catch return;
    var w = r.tui.AnsiWriter.init(buf);
    w.print("To agent({d}) :\n> ", .{agent_id});
    w.styled(.{ .fg = theme.muted }, message);
    r.setToolStatus(ctx, call, w.finish()) catch {};
}

pub fn injectCatalog(w: *std.Io.Writer, app: *App, agent: *r.r.agent.Agent) !void {
    if (!agent.hasTool(AgentTool.def.name)) {
        agent.agent_catalog_digest = null;
        return;
    }

    var rows = std.Io.Writer.Allocating.init(agent.step_arena.allocator());
    const count = blk: {
        app.lua_vm.vm_mu.lockUncancelable(app.io);
        defer app.lua_vm.vm_mu.unlock(app.io);
        break :blk try writeCatalogRows(&rows.writer, app.context_factory);
    };
    try inject.emitCatalog(w, "available_agents", count, rows.written(), &agent.agent_catalog_digest, "");
}

fn writeCatalogRows(w: *std.Io.Writer, factory: *const r.r.ContextFactory) !usize {
    var count: usize = 0;
    for (0..factory.agentSlotCount()) |index| {
        const def = factory.agentTypeAt(@intCast(index)) orelse continue;
        if (!def.in_agent_tool) continue;
        try w.print("- `{s}`: ", .{def.name});
        try inject.writeCatalogField(w, std.mem.trim(u8, def.description, " \t\r\n"));
        try w.writeByte('\n');
        count += 1;
    }
    return count;
}

fn appOf(ctx: r.ToolContext) *App {
    return @ptrCast(@alignCast(ctx.base.display.ctx.?));
}

fn success(ctx: r.ToolContext, call: r.ToolCall, comptime fmt: []const u8, args: anytype) r.ToolResult {
    const text = std.fmt.allocPrint(ctx.alloc, fmt, args) catch return r.errResult(call, "out of memory");
    return r.okResult(call, text);
}

fn failure(ctx: r.ToolContext, call: r.ToolCall, comptime fmt: []const u8, args: anytype) r.ToolResult {
    const text = std.fmt.allocPrint(ctx.alloc, fmt, args) catch "out of memory";
    return r.errResult(call, text);
}
