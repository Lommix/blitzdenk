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
    tool_name: []const u8 = "",
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

pub const ApprovalMode = enum(u2) { strict, default, yolo, smart };

pub fn parseApprovalMode(value: []const u8) ?ApprovalMode {
    return std.meta.stringToEnum(ApprovalMode, value);
}

pub fn shouldAutoApprove(mode: ApprovalMode, is_ask: bool, ssh_active: bool) bool {
    if (is_ask) return false;
    return switch (mode) {
        .strict => false,
        .smart, .default => !ssh_active,
        .yolo => true,
    };
}

/// The answer the interactive picker gives when a question is "approved"
/// rather than answered: the first option marked "(recommended)", else the
/// first option. Mirrored by the headless resolver in main.zig.
pub fn recommendedChoice(options: []const []const u8) State {
    for (options, 0..) |opt, i| {
        if (std.mem.indexOf(u8, opt, "(recommended)") != null) return .{ .choice = @intCast(i) };
    }
    return .{ .choice = 0 };
}

test "shouldAutoApprove decision table" {
    const Case = struct { mode: ApprovalMode, is_ask: bool, ssh: bool, want: bool };
    const cases = [_]Case{
        .{ .mode = .strict, .is_ask = false, .ssh = false, .want = false },
        .{ .mode = .strict, .is_ask = false, .ssh = true, .want = false },
        .{ .mode = .strict, .is_ask = true, .ssh = false, .want = false },
        .{ .mode = .strict, .is_ask = true, .ssh = true, .want = false },
        .{ .mode = .default, .is_ask = false, .ssh = false, .want = true },
        .{ .mode = .default, .is_ask = false, .ssh = true, .want = false },
        .{ .mode = .default, .is_ask = true, .ssh = false, .want = false },
        .{ .mode = .default, .is_ask = true, .ssh = true, .want = false },
        .{ .mode = .smart, .is_ask = false, .ssh = false, .want = true },
        .{ .mode = .smart, .is_ask = false, .ssh = true, .want = false },
        .{ .mode = .smart, .is_ask = true, .ssh = false, .want = false },
        .{ .mode = .smart, .is_ask = true, .ssh = true, .want = false },
        .{ .mode = .yolo, .is_ask = false, .ssh = false, .want = true },
        .{ .mode = .yolo, .is_ask = false, .ssh = true, .want = true },
        .{ .mode = .yolo, .is_ask = true, .ssh = false, .want = false },
        .{ .mode = .yolo, .is_ask = true, .ssh = true, .want = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.want, shouldAutoApprove(case.mode, case.is_ask, case.ssh));
    }
}

test "parseApprovalMode" {
    try std.testing.expectEqual(ApprovalMode.strict, parseApprovalMode("strict").?);
    try std.testing.expectEqual(ApprovalMode.yolo, parseApprovalMode("yolo").?);
    try std.testing.expectEqual(@as(?ApprovalMode, null), parseApprovalMode("YOLO"));
    try std.testing.expectEqual(@as(?ApprovalMode, null), parseApprovalMode("nope"));
}
