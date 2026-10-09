const std = @import("std");
const AgentId = @import("agent-id").AgentId;

pub const ToolDiff = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
};

pub const ToolCallPayload = struct {
    description: []const u8,
};

pub const AskPayload = struct {
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
    allow_message: bool = true,
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

pub const AgentInfo = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    task: []const u8 = "",
    cwd: []const u8 = "",
};

pub const Request = struct {
    agent_id: AgentId,
    call_id: ?[]const u8 = null,
    tool_name: []const u8 = "",
    tool_input: []const u8 = "",
    agent: AgentInfo = .{},
    state: State = .pending,
    stage: Stage = .pending,
    payload: Payload,
    event: std.Io.Event = .unset,
    ticket: u64 = 0,
};

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    request: ?*const fn (?*anyopaque, *Request) void = null,

    pub fn send(self: Handler, value: *Request) void {
        if (self.request) |request| request(self.ctx, value);
    }
};

pub const Stage = enum(u8) { pending, in_lua, in_tui };

pub const ApprovalMode = enum(u2) { strict, default, yolo };

pub fn parseApprovalMode(value: []const u8) ?ApprovalMode {
    return std.meta.stringToEnum(ApprovalMode, value);
}

pub fn shouldAutoApprove(mode: ApprovalMode, is_ask: bool, ssh_active: bool) bool {
    if (is_ask) return false;
    return switch (mode) {
        .strict => false,
        .default => !ssh_active,
        .yolo => true,
    };
}

/// The answer the interactive picker gives when a question is "approved"
/// rather than answered: the first option marked "(recommended)", else the
/// first option. Mirrored by the headless resolver in main.zig.
pub fn recommendedChoice(options: []const []const u8) State {
    for (options, 0..) |opt, i| {
        if (std.mem.indexOf(u8, opt, "(recommended)") != null or
            std.mem.indexOf(u8, opt, "(Recommended)") != null) return .{ .choice = @intCast(i) };
    }
    return .{ .choice = 0 };
}
