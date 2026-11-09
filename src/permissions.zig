const std = @import("std");
const AgentId = @import("agent-id").AgentId;

pub const MAX_QUESTIONS = 4;
pub const MAX_OPTIONS = 8;

pub const ToolDiff = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
};

pub const ToolCallPayload = struct {
    description: []const u8,
};

/// One question of an ask request as the widget, hooks, and headless runs
/// see it. Options are pre-joined display strings.
pub const Question = struct {
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
    multi_select: bool = false,
};

/// One chosen entry of an answer. `index` is the 0-based option index; it is
/// null when the user typed a custom message, which then lives in `message`.
pub const Pick = struct {
    index: ?u8 = null,
    message: []const u8 = "",
};

pub const Answer = []const Pick;
pub const Answers = []const Answer;

/// One ask request: up to four questions.
pub const AskPayload = struct {
    questions: []const Question,
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
    /// Deny reason for non-ask decisions.
    message: []const u8,
    /// One pick list per ask question, in request order.
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

    /// In-request storage for ask answers set by hooks, the headless
    /// resolver, or `setAskAnswers`. `state.answers` points here, so the
    /// answer outlives the decider without extra allocations. Custom
    /// message text is page-allocated; message answers are rare enough
    /// for that.
    ask_picks: [MAX_QUESTIONS][MAX_OPTIONS]Pick = @splat(@splat(.{})),
    ask_answer: [MAX_QUESTIONS][]const Pick = @splat(&.{}),
};

pub fn isRecommended(option: []const u8) bool {
    return std.mem.indexOf(u8, option, "(recommended)") != null or
        std.mem.indexOf(u8, option, "(Recommended)") != null;
}

/// Write the recommended picks of one question into `picks` and return their
/// count. Single-select picks the first marked option or option one.
/// Multi-select picks every marked option in display order, or option one
/// only when none is marked.
pub fn writeRecommendedAnswer(question: Question, picks: []Pick) usize {
    if (question.multi_select) {
        var n: usize = 0;
        for (question.options, 0..) |opt, i| {
            if (n >= picks.len) break;
            if (isRecommended(opt)) {
                picks[n] = .{ .index = @intCast(i) };
                n += 1;
            }
        }
        if (n > 0) return n;
    }
    for (question.options, 0..) |opt, i| {
        if (isRecommended(opt)) {
            picks[0] = .{ .index = @intCast(i) };
            return 1;
        }
    }
    picks[0] = .{ .index = 0 };
    return 1;
}

/// Stack-held builder for hook and headless answers. Starts from the
/// recommended picks; callers replace or append per question.
pub const AnswerBuilder = struct {
    questions: []const Question,
    picks: [MAX_QUESTIONS][MAX_OPTIONS]Pick = @splat(@splat(.{})),
    lens: [MAX_QUESTIONS]usize = @splat(0),
    slices: [MAX_QUESTIONS][]const Pick = @splat(&.{}),

    pub fn init(questions: []const Question) AnswerBuilder {
        var self = AnswerBuilder{ .questions = questions };
        for (questions, 0..) |q, i| self.lens[i] = writeRecommendedAnswer(q, &self.picks[i]);
        return self;
    }

    pub fn clear(self: *AnswerBuilder, qi: usize) void {
        self.lens[qi] = 0;
    }

    pub fn add(self: *AnswerBuilder, qi: usize, pick: Pick) bool {
        if (qi >= self.questions.len) return false;
        if (self.lens[qi] >= MAX_OPTIONS) return false;
        self.picks[qi][self.lens[qi]] = pick;
        self.lens[qi] += 1;
        return true;
    }

    pub fn answer(self: *const AnswerBuilder, qi: usize) Answer {
        return self.picks[qi][0..self.lens[qi]];
    }

    pub fn bake(self: *AnswerBuilder) Answers {
        for (0..self.questions.len) |i| self.slices[i] = self.answer(i);
        return self.slices[0..self.questions.len];
    }
};

/// Copy `answers` into the request storage and settle the request with them.
/// Returns false when the answer does not fit the storage limits.
pub fn setAskAnswers(req: *Request, answers: Answers) bool {
    if (answers.len > MAX_QUESTIONS) return false;
    for (answers, 0..) |answer, qi| {
        if (answer.len > MAX_OPTIONS) return false;
        for (answer, 0..) |pick, pi| {
            var stored = pick;
            if (pick.index == null and pick.message.len > 0) {
                stored.message = std.heap.page_allocator.dupe(u8, pick.message) catch return false;
            }
            req.ask_picks[qi][pi] = stored;
        }
        req.ask_answer[qi] = req.ask_picks[qi][0..answer.len];
    }
    req.state = .{ .answers = req.ask_answer[0..answers.len] };
    return true;
}

/// Settle an ask request with the recommended pick for every question.
/// Used by hooks that approve without explicit answers and by headless runs.
pub fn setAskRecommended(req: *Request) void {
    var builder = AnswerBuilder.init(req.payload.ask.questions);
    if (!setAskAnswers(req, builder.bake())) req.state = .denied;
}

/// Deep copy of an answer set: the outer list, every pick list, and custom
/// message text. Answer slices produced by settlers point into request
/// frames that die before the caller reads the returned state; consumers
/// copy through this.
pub fn dupAnswers(alloc: std.mem.Allocator, answers: Answers) ?Answers {
    var total: usize = 0;
    for (answers) |answer| total += answer.len;
    const picks = alloc.alloc(Pick, total) catch return null;
    const lists = alloc.alloc(Answer, answers.len) catch {
        alloc.free(picks);
        return null;
    };
    var off: usize = 0;
    for (answers, 0..) |answer, i| {
        for (answer, 0..) |pick, j| {
            var copy = pick;
            if (pick.index == null and pick.message.len > 0) {
                copy.message = alloc.dupe(u8, pick.message) catch return null;
            }
            picks[off + j] = copy;
        }
        lists[i] = picks[off..][0..answer.len];
        off += answer.len;
    }
    return lists;
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

test "dupAnswers deep-copies picks and messages into caller memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var msg_buf = [_]u8{ 'n', 'o', 't', 'e' };
    var src_picks = [_]Pick{ .{ .index = 0 }, .{ .index = null, .message = &msg_buf } };
    var src_lists = [_]Answer{ src_picks[0..1], src_picks[1..2] };
    const copy = dupAnswers(alloc, src_lists[0..2]).?;

    try std.testing.expectEqual(@as(usize, 2), copy.len);
    try std.testing.expectEqual(@as(?u8, 0), copy[0][0].index);
    try std.testing.expect(copy[1][0].index == null);
    try std.testing.expectEqualStrings("note", copy[1][0].message);

    // The copy stays valid after the source storage is rewritten, like a
    // request frame dying under the returned state.
    src_picks[0].index = 5;
    msg_buf[0] = 'x';
    try std.testing.expectEqual(@as(?u8, 0), copy[0][0].index);
    try std.testing.expectEqualStrings("note", copy[1][0].message);
}
