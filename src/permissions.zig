const std = @import("std");
const AgentId = @import("agent-id").AgentId;

pub const MAX_QUESTIONS = 8;
pub const MAX_OPTIONS = 8;

pub const ToolDiff = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
};

pub const ToolCallPayload = struct {
    description: []const u8,
};

pub const Option = struct {
    label: []const u8 = "",
    description: []const u8 = "",
};

/// One question of an ask request. The defaults let the ask tool parse model
/// JSON straight into this type; validation names any missing field.
pub const Question = struct {
    header: []const u8 = "",
    question: []const u8 = "",
    options: []const Option = &.{},
    multi_select: bool = false,
    /// Show the custom-message row. Single-select questions only.
    allow_message: bool = true,

    pub fn hasMessageRow(self: Question) bool {
        return !self.multi_select and self.allow_message;
    }

    /// True when `answer` is a legal resolution of this question: exactly one
    /// option for single-select, at least one for multi-select, or a custom
    /// message where the message row exists.
    pub fn accepts(self: Question, answer: Answer) bool {
        if (answer.message.len > 0) return answer.mask == 0 and self.hasMessageRow();
        if (answer.mask == 0) return false;
        if (self.options.len < MAX_OPTIONS and answer.mask >> @intCast(self.options.len) != 0) return false;
        return self.multi_select or @popCount(answer.mask) == 1;
    }
};

/// One resolved question. Bit i of `mask` marks option i as picked, so
/// multi-select picks keep display order. A custom message leaves `mask`
/// zero; its text is allocated from `message_allocator`.
pub const Answer = struct {
    mask: u8 = 0,
    message: []const u8 = "",

    pub fn deinit(self: Answer) void {
        if (self.message.len > 0) message_allocator.free(self.message);
    }
};

/// One answer per ask question, in request order. Held by value, so a
/// settled request needs no storage beyond its custom-message text.
pub const Answers = struct {
    items: [MAX_QUESTIONS]Answer = @splat(.{}),
    len: u8 = 0,

    pub fn slice(self: *const Answers) []const Answer {
        return self.items[0..self.len];
    }

    /// Free the custom-message text. The requester calls this once it has
    /// read the answers.
    pub fn deinit(self: Answers) void {
        for (self.items[0..self.len]) |answer| answer.deinit();
    }
};

/// Thread-safe allocator for custom-message text: the main thread settles,
/// the requesting tool thread frees.
pub const message_allocator = std.heap.smp_allocator;

pub fn optionBit(index: usize) u8 {
    return @as(u8, 1) << @intCast(index);
}

/// One ask request: up to `MAX_QUESTIONS` questions.
pub const AskPayload = struct {
    questions: []const Question,
};

pub const Payload = union(enum) {
    call: ToolCallPayload,
    diff: ToolDiff,
    ask: AskPayload,
};

pub const State = union(enum) {
    pending,
    approved,
    denied,
    /// Deny reason for non-ask decisions.
    message: []const u8,
    /// One answer per ask question, in request order.
    answers: Answers,
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

fn isRecommended(label: []const u8) bool {
    return std.mem.indexOf(u8, label, "(recommended)") != null or
        std.mem.indexOf(u8, label, "(Recommended)") != null;
}

/// Single-select picks the first marked option, multi-select every marked
/// option; option one when none is marked.
pub fn recommendedAnswer(question: Question) Answer {
    var mask: u8 = 0;
    for (question.options, 0..) |opt, i| {
        if (!isRecommended(opt.label)) continue;
        mask |= optionBit(i);
        if (!question.multi_select) break;
    }
    return .{ .mask = if (mask == 0) 1 else mask };
}

/// Recommended answers for a whole request. Used by hooks that approve
/// without explicit answers and by headless runs.
pub fn recommendedAnswers(questions: []const Question) Answers {
    var answers: Answers = .{ .len = @intCast(questions.len) };
    for (questions, 0..) |q, i| answers.items[i] = recommendedAnswer(q);
    return answers;
}

/// Deep copy of a question list into `alloc`.
pub fn dupQuestions(alloc: std.mem.Allocator, questions: []const Question) ![]const Question {
    const copy = try alloc.alloc(Question, questions.len);
    for (questions, copy) |q, *dst| {
        const options = try alloc.alloc(Option, q.options.len);
        for (q.options, options) |opt, *o| o.* = .{
            .label = try alloc.dupe(u8, opt.label),
            .description = try alloc.dupe(u8, opt.description),
        };
        dst.* = q;
        dst.header = try alloc.dupe(u8, q.header);
        dst.question = try alloc.dupe(u8, q.question);
        dst.options = options;
    }
    return copy;
}

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

test "recommended answers follow the marker convention" {
    const marked = [_]Option{ .{ .label = "a" }, .{ .label = "b (recommended)" }, .{ .label = "c (Recommended)" } };
    const plain = [_]Option{ .{ .label = "a" }, .{ .label = "b" } };
    try std.testing.expectEqual(@as(u8, 0b010), recommendedAnswer(.{ .options = &marked }).mask);
    try std.testing.expectEqual(@as(u8, 0b110), recommendedAnswer(.{ .options = &marked, .multi_select = true }).mask);
    try std.testing.expectEqual(@as(u8, 0b001), recommendedAnswer(.{ .options = &plain }).mask);
    try std.testing.expectEqual(@as(u8, 0b001), recommendedAnswer(.{ .options = &plain, .multi_select = true }).mask);
}

test "question accepts only answers that fit its mode" {
    const options = [_]Option{ .{ .label = "a" }, .{ .label = "b" } };
    const single: Question = .{ .header = "h", .question = "q?", .options = &options };
    const multi: Question = .{ .header = "h", .question = "q?", .options = &options, .multi_select = true };
    const closed: Question = .{ .header = "h", .question = "q?", .options = &options, .allow_message = false };

    try std.testing.expect(single.accepts(.{ .mask = 0b10 }));
    try std.testing.expect(!single.accepts(.{ .mask = 0b11 }));
    try std.testing.expect(!single.accepts(.{}));
    try std.testing.expect(!single.accepts(.{ .mask = 0b100 }));
    try std.testing.expect(single.accepts(.{ .message = "x" }));
    try std.testing.expect(!closed.accepts(.{ .message = "x" }));
    try std.testing.expect(multi.accepts(.{ .mask = 0b11 }));
    try std.testing.expect(!multi.accepts(.{ .message = "x" }));
}
