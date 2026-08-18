const std = @import("std");
const AgentId = @import("agent-id").AgentId;

pub const ToolDiff = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
};

pub const ToolCallPayload = struct {
    tool_name: []const u8,
    tool_arguments: []const u8,
};

pub const AskPayload = struct {
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
};

pub const PlanApprovalPayload = struct {
    path: []const u8,
    plan_text: []const u8,
};

pub const Payload = union(enum) {
    call: ToolCallPayload,
    diff: ToolDiff,
    ask: AskPayload,
    plan: PlanApprovalPayload,
};

pub const State = union(enum) {
    pending,
    approved,
    denied,
    choice: u8,
    message: []const u8,
};

pub const Request = struct {
    agent_id: AgentId,
    call_id: ?[]const u8 = null,
    state: State = .pending,
    payload: Payload,
    event: std.Io.Event = .unset,
};

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    request: ?*const fn (?*anyopaque, *Request) void = null,

    pub fn send(self: Handler, value: *Request) void {
        if (self.request) |request| request(self.ctx, value);
    }
};
