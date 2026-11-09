const std = @import("std");
const tui = @import("tui/root.zig");
const permissions = @import("permissions");
const text_utils = tui.text_utils;

pub const MAX_QUESTIONS = permissions.MAX_QUESTIONS;
pub const MAX_OPTIONS = permissions.MAX_OPTIONS;

/// Tool argument shape: one option as the model sends it.
pub const ArgOption = struct {
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Tool argument shape: one question as the model sends it.
pub const ArgQuestion = struct {
    header: ?[]const u8 = null,
    question: ?[]const u8 = null,
    options: ?[]const ArgOption = null,
    multi_select: ?bool = null,
};

pub const Args = struct {
    questions: ?[]const ArgQuestion = null,
};

pub fn argHeader(q: ArgQuestion) []const u8 {
    return q.header orelse "";
}

pub fn argQuestion(q: ArgQuestion) []const u8 {
    return q.question orelse "";
}

pub fn argOptions(q: ArgQuestion) []const ArgOption {
    return q.options orelse &.{};
}

pub fn argMultiSelect(q: ArgQuestion) bool {
    return q.multi_select orelse false;
}

pub const Question = permissions.Question;
pub const Pick = permissions.Pick;
pub const Answer = permissions.Answer;
pub const Answers = permissions.Answers;
pub const isRecommended = permissions.isRecommended;
pub const writeRecommendedAnswer = permissions.writeRecommendedAnswer;
pub const AnswerBuilder = permissions.AnswerBuilder;

pub const ResolveOutcome = enum { advance, submitted, blocked };

/// Enter-key result: multi-select option rows report `.toggle`, commits and
/// single-select picks map the resolve outcomes.
pub const EnterOutcome = enum { toggle, advance, submitted, blocked };

pub fn optionRow(alloc: std.mem.Allocator, opt: ArgOption) ?[]const u8 {
    const label = opt.label orelse "";
    const desc = opt.description orelse "";
    if (label.len == 0 and desc.len == 0) return null;
    if (label.len == 0) return desc;
    if (desc.len == 0) return label;
    return std.fmt.allocPrint(alloc, "{s} — {s}", .{ label, desc }) catch null;
}

/// Build the display question list from tool arguments. Returns null when a
/// display row cannot be built; run validateArgs first to name the real rule.
pub fn payloadQuestions(alloc: std.mem.Allocator, args: Args) ?[]Question {
    const questions = alloc.alloc(Question, argQuestionList(args).len) catch return null;
    for (argQuestionList(args), 0..) |q, i| {
        const src = argOptions(q);
        const rows = alloc.alloc([]const u8, src.len) catch return null;
        for (src, 0..) |opt, j| {
            rows[j] = optionRow(alloc, opt) orelse return null;
        }
        questions[i] = .{
            .header = argHeader(q),
            .question = argQuestion(q),
            .options = rows,
            .multi_select = argMultiSelect(q),
        };
    }
    return questions;
}

pub fn argQuestionList(args: Args) []const ArgQuestion {
    return args.questions orelse &.{};
}

/// A failed argument rule, with the 0-based location that broke it.
pub const Violation = struct {
    rule: [:0]const u8,
    question: ?usize = null,
    option: ?usize = null,
};

pub fn validateArgs(args: Args) ?Violation {
    const questions = argQuestionList(args);
    if (questions.len == 0) return .{ .rule = "questions must contain at least one entry" };
    if (questions.len > MAX_QUESTIONS) return .{ .rule = "too many questions (max 4)" };
    for (questions, 0..) |q, i| {
        if (argHeader(q).len == 0) return .{ .rule = "each question needs a non-empty header", .question = i };
        if (argQuestion(q).len == 0) return .{ .rule = "each question needs a non-empty question text", .question = i };
        const options = argOptions(q);
        if (options.len == 0) return .{ .rule = "each question needs at least one option", .question = i };
        if (options.len > MAX_OPTIONS) return .{ .rule = "too many options (max 8)", .question = i };
        for (options, 0..) |opt, j| {
            const label: []const u8 = opt.label orelse "";
            if (label.len == 0) return .{ .rule = "each option needs a label", .question = i, .option = j };
        }
        if (argMultiSelect(q) and options.len < 2) return .{ .rule = "multi_select questions need at least two options", .question = i };
    }
    return null;
}

/// Model-facing rule text with a 1-based location prefix, NUL-terminated for Lua errors.
pub fn formatViolation(alloc: std.mem.Allocator, violation: Violation) ?[:0]const u8 {
    const question = violation.question orelse return violation.rule;
    if (violation.option) |option| {
        return std.fmt.allocPrintSentinel(
            alloc,
            "question {d}, option {d}: {s}",
            .{ question + 1, option + 1, violation.rule },
            0,
        ) catch null;
    }
    return std.fmt.allocPrintSentinel(
        alloc,
        "question {d}: {s}",
        .{ question + 1, violation.rule },
        0,
    ) catch null;
}

fn rowContains(buf: *const tui.Buffer, y: u16, needle: []const u8) bool {
    var text_buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&text_buf);
    var x: u16 = 0;
    while (x < buf.rect.width) : (x += 1) {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(buf.get(x, y).char, &utf8_buf) catch continue;
        w.writeAll(utf8_buf[0..len]) catch return false;
    }
    return std.mem.indexOf(u8, w.buffered(), needle) != null;
}

/// Recommended answers for a whole request, allocated from `alloc`.
pub fn recommendedAnswers(alloc: std.mem.Allocator, questions: []const Question) ?Answers {
    var builder = AnswerBuilder.init(questions);
    const answers = alloc.alloc(Answer, questions.len) catch return null;
    for (0..questions.len) |i| {
        answers[i] = alloc.dupe(Pick, builder.answer(i)) catch return null;
    }
    return answers;
}

fn answerText(alloc: std.mem.Allocator, q: ArgQuestion, answer: Answer) ?[]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    const options = argOptions(q);
    for (answer, 0..) |pick, i| {
        if (i > 0) w.writer.writeAll(", ") catch return null;
        if (pick.index) |idx| {
            if (idx >= options.len) return null;
            w.writer.writeAll(options[idx].label orelse "") catch return null;
        } else {
            w.writer.writeAll(pick.message) catch return null;
        }
    }
    return alloc.dupe(u8, w.written()) catch null;
}

/// Model-facing result text: one numbered line per question in request order,
/// `1. [Header] Question? -> Answer`, multi-select labels joined with ", ".
pub fn formatResult(alloc: std.mem.Allocator, args: Args, answers: Answers) ?[]const u8 {
    const questions = argQuestionList(args);
    if (questions.len != answers.len) return null;
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    for (questions, 0..) |q, i| {
        if (i > 0) w.writer.writeAll("\n") catch return null;
        const text = answerText(alloc, q, answers[i]) orelse return null;
        w.writer.print("{d}. [{s}] {s} -> {s}", .{ i + 1, argHeader(q), argQuestion(q), text }) catch return null;
    }
    return alloc.dupe(u8, w.written()) catch null;
}

/// Interactive edit state for one ask request. Owns every decision: active
/// tab, per-question cursors and toggles, and resolved answers.
pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    questions: []const Question,
    active: u8 = 0,
    cursors: [MAX_QUESTIONS]u8 = @splat(0),
    toggles: [MAX_QUESTIONS]u8 = @splat(0),
    resolved: [MAX_QUESTIONS]?Answer = @splat(null),

    pub fn init(parent: std.mem.Allocator, questions: []const Question) !Session {
        var arena = std.heap.ArenaAllocator.init(parent);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const copy = try alloc.alloc(Question, questions.len);
        for (questions, 0..) |q, i| {
            const rows = try alloc.alloc([]const u8, q.options.len);
            for (q.options, 0..) |opt, j| rows[j] = try alloc.dupe(u8, opt);
            copy[i] = .{
                .header = try alloc.dupe(u8, q.header),
                .question = try alloc.dupe(u8, q.question),
                .options = rows,
                .multi_select = q.multi_select,
            };
        }
        return .{ .arena = arena, .questions = copy };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    pub fn rowCount(self: *const Session, qi: usize) u8 {
        const q = self.questions[qi];
        const opts: u8 = @intCast(@min(q.options.len, MAX_OPTIONS));
        // Single-select trails with the custom-message row, multi-select
        // with the fixed submit row.
        return opts + 1;
    }

    pub fn activeRowCount(self: *const Session) u8 {
        return self.rowCount(self.active);
    }

    pub fn cursor(self: *const Session) u8 {
        return self.cursors[self.active];
    }

    pub fn moveCursor(self: *Session, delta: i32) void {
        if (self.questions.len == 0) return;
        const max: i32 = @as(i32, self.activeRowCount()) - 1;
        var next: i32 = @as(i32, self.cursor()) + delta;
        next = @min(@max(next, 0), max);
        self.cursors[self.active] = @intCast(next);
    }

    pub fn isChecked(self: *const Session, qi: usize, opt: usize) bool {
        if (opt >= MAX_OPTIONS) return false;
        return self.toggles[qi] & (@as(u8, 1) << @intCast(opt)) != 0;
    }

    /// True when the cursor of `qi` sits on the custom-message row. Only
    /// single-select questions have that row.
    pub fn messageRowActive(self: *const Session, qi: usize) bool {
        const q = self.questions[qi];
        return !q.multi_select and self.cursors[qi] >= q.options.len;
    }

    /// True when the cursor of `qi` sits on the fixed submit row. Only
    /// multi-select questions have that row.
    pub fn submitRowActive(self: *const Session, qi: usize) bool {
        const q = self.questions[qi];
        return q.multi_select and self.cursors[qi] >= q.options.len;
    }

    pub fn toggleCurrent(self: *Session) void {
        const qi = self.active;
        const q = self.questions[qi];
        if (!q.multi_select) return;
        const c = self.cursor();
        if (c >= q.options.len) return;
        self.toggles[qi] ^= @as(u8, 1) << @intCast(c);
    }

    pub fn prevTab(self: *Session) void {
        if (self.active > 0) self.active -= 1;
    }

    /// Forward only when the current question is resolved.
    pub fn nextTab(self: *Session) void {
        if (self.resolved[self.active] == null) return;
        if (self.active + 1 < self.questions.len) self.active += 1;
    }

    pub fn isResolved(self: *const Session, qi: usize) bool {
        return self.resolved[qi] != null;
    }

    pub fn allResolved(self: *const Session) bool {
        for (self.resolved[0..self.questions.len]) |a| {
            if (a == null) return false;
        }
        return true;
    }

    /// Resolve the active question: the highlighted option for single-select,
    /// the committed toggle set for multi-select (at least one toggle,
    /// entered from the submit row). The last resolution returns `.submitted`.
    pub fn resolveCurrent(self: *Session) ResolveOutcome {
        const qi = self.active;
        const q = self.questions[qi];
        if (q.multi_select) {
            if (self.toggles[qi] == 0) return .blocked;
            const alloc = self.arena.allocator();
            var picks: [MAX_OPTIONS]Pick = @splat(.{});
            var n: usize = 0;
            for (q.options, 0..) |_, oi| {
                if (self.isChecked(qi, oi)) {
                    picks[n] = .{ .index = @intCast(oi) };
                    n += 1;
                }
            }
            self.resolved[qi] = alloc.dupe(Pick, picks[0..n]) catch return .blocked;
            return self.finishResolve();
        }
        const c = self.cursor();
        if (c >= q.options.len) return .blocked;
        const alloc = self.arena.allocator();
        self.resolved[qi] = alloc.dupe(Pick, &.{.{ .index = c }}) catch return .blocked;
        return self.finishResolve();
    }

    /// Enter on the active question. Multi-select option rows toggle the
    /// highlighted option; the submit row commits the toggled set.
    /// Single-select picks the highlighted option.
    pub fn enterCurrent(self: *Session) EnterOutcome {
        if (self.submitRowActive(self.active)) {
            return switch (self.resolveCurrent()) {
                .advance => .advance,
                .submitted => .submitted,
                .blocked => .blocked,
            };
        }
        if (self.questions[self.active].multi_select) {
            self.toggleCurrent();
            return .toggle;
        }
        return switch (self.resolveCurrent()) {
            .advance => .advance,
            .submitted => .submitted,
            .blocked => .blocked,
        };
    }

    /// Resolve the active question with a typed custom message. Multi-select
    /// questions never take a custom message; the call is blocked instead.
    pub fn resolveMessage(self: *Session, text: []const u8) ResolveOutcome {
        const qi = self.active;
        if (self.questions[qi].multi_select) return .blocked;
        const alloc = self.arena.allocator();
        const msg = alloc.dupe(u8, text) catch return .blocked;
        self.resolved[qi] = alloc.dupe(Pick, &.{.{ .index = null, .message = msg }}) catch return .blocked;
        return self.finishResolve();
    }

    fn finishResolve(self: *Session) ResolveOutcome {
        if (self.allResolved()) return .submitted;
        var step: usize = 1;
        while (step < self.questions.len) : (step += 1) {
            const qi = (self.active + step) % self.questions.len;
            if (self.resolved[qi] == null) {
                self.active = @intCast(qi);
                return .advance;
            }
        }
        return .submitted;
    }

    /// Copy the resolved answers into `alloc` so the result outlives this
    /// session. Null until every question is resolved.
    pub fn answersOwned(self: *const Session, alloc: std.mem.Allocator) ?Answers {
        var total: usize = 0;
        for (self.resolved[0..self.questions.len]) |a| total += (a orelse return null).len;
        const picks = alloc.alloc(Pick, total) catch return null;
        const lists = alloc.alloc(Answer, self.questions.len) catch {
            alloc.free(picks);
            return null;
        };
        var off: usize = 0;
        for (self.resolved[0..self.questions.len], 0..) |a, i| {
            const src = a.?;
            @memcpy(picks[off..][0..src.len], src);
            lists[i] = picks[off..][0..src.len];
            off += src.len;
        }
        return lists;
    }

    /// Borrowed view of the resolved answers, the pick slices still owned by
    /// this session. Null until every question is resolved. The view is only
    /// valid while the session lives.
    pub fn answersView(self: *const Session, out: []Answer) ?Answers {
        if (!self.allResolved()) return null;
        if (out.len < self.questions.len) return null;
        for (self.resolved[0..self.questions.len], 0..) |a, i| out[i] = a.?;
        return out[0..self.questions.len];
    }
};

pub const Colors = struct {
    accent: tui.Color,
    muted: tui.Color,
};

fn displayWidth(text: []const u8) u16 {
    var width: u16 = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |_| width += 1;
    return width;
}

/// Input-area height for the ask widget, borders included. Reserves the tab
/// headline row only for multi-question requests.
pub fn widgetHeight(questions: []const Question, active: usize, area_width: u16, area_height: u16) u16 {
    if (questions.len == 0) return 0;
    const q = questions[@min(active, questions.len - 1)];
    const width = area_width -| 7;
    var rows: u16 = @intFromBool(questions.len > 1);
    var header_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&header_buf, "[{s}] {s}", .{ q.header, q.question }) catch q.question;
    rows +|= text_utils.wrappedRowCount(header_line, width);
    rows +|= 1; // "enter message" or "submit"
    for (q.options) |opt| {
        var opt_buf: [512]u8 = undefined;
        const opt_line = std.fmt.bufPrint(&opt_buf, "  {s}", .{opt}) catch opt;
        rows +|= text_utils.wrappedRowCount(opt_line, width -| 2);
    }
    return @min(rows +| 6, area_height -| 1);
}

pub fn renderSession(session: *const Session, colors: Colors, inner: tui.Rect, buf: *tui.Buffer) void {
    if (inner.width == 0 or inner.height == 0) return;
    const x = inner.x + 1;
    const width = inner.width -| 1;
    if (width == 0) return;

    var y = inner.y;
    if (session.questions.len > 1) {
        renderTabs(session, colors, x, y, width, buf);
        y +|= 1;
    }

    const q = session.questions[session.active];
    var header_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&header_buf, "[{s}] {s}", .{ q.header, q.question }) catch q.question;

    var opts_rows: u16 = 1; // "enter message" or "submit"
    for (q.options) |opt| {
        var opt_buf: [512]u8 = undefined;
        const opt_line = std.fmt.bufPrint(&opt_buf, "  {s}", .{opt}) catch opt;
        opts_rows +|= text_utils.wrappedRowCount(opt_line, width -| 2);
    }

    const used_height = y -| inner.y;
    const max_q_rows = inner.height -| used_height -| opts_rows -| 1;
    const q_rows = text_utils.renderWrappedText(buf, header_line, x, y, width, max_q_rows, 0, .{ .fg = colors.accent });

    y = y +| 1 +| q_rows;
    const total_rows: usize = @as(usize, q.options.len) + 1;
    var row: usize = 0;
    while (row < total_rows and y < inner.y +| inner.height) : (row += 1) {
        const selected = session.cursor() == @as(u8, @intCast(row));
        const style: tui.Style = if (selected) .{ .modifier = .{ .reverse = true } } else .{};
        const prefix: []const u8 = if (selected) "> " else "  ";
        var line_buf: [512]u8 = undefined;
        const line: []const u8 = blk: {
            if (row >= q.options.len) {
                const tail: []const u8 = if (q.multi_select) "submit" else "enter message";
                break :blk std.fmt.bufPrint(&line_buf, "{s}{s}", .{ prefix, tail }) catch tail;
            }
            if (q.multi_select) {
                const mark: []const u8 = if (session.isChecked(session.active, row)) "x" else " ";
                break :blk std.fmt.bufPrint(&line_buf, "{s}[{s}] {s}", .{ prefix, mark, q.options[row] }) catch q.options[row];
            }
            break :blk std.fmt.bufPrint(&line_buf, "{s}{s}", .{ prefix, q.options[row] }) catch q.options[row];
        };
        const used = text_utils.renderWrappedText(buf, line, x, y, width, inner.y +| inner.height -| y, 2, style);
        if (used == 0) break;
        y +|= used;
    }
}

fn renderTabs(session: *const Session, colors: Colors, x: u16, y: u16, width: u16, buf: *tui.Buffer) void {
    var cx = x;
    for (session.questions, 0..) |_, i| {
        var tab_buf: [8]u8 = undefined;
        const text = if (session.isResolved(i))
            std.fmt.bufPrint(&tab_buf, "✓{d}", .{i + 1}) catch "?"
        else
            std.fmt.bufPrint(&tab_buf, "{d}", .{i + 1}) catch "?";
        const style: tui.Style = if (i == session.active)
            .{ .fg = colors.accent, .modifier = .{ .reverse = true } }
        else if (session.isResolved(i))
            .{ .fg = colors.accent }
        else
            .{ .fg = colors.muted };
        buf.setStringMax(cx, y, text, style, width -| (cx -| x));
        cx +|= displayWidth(text) + 1;
    }
}

fn expectMessage(alloc: std.mem.Allocator, expected: []const u8, violation: ?Violation) !void {
    const found = violation orelse return error.ExpectedViolation;
    const text = formatViolation(alloc, found) orelse return error.OutOfMemory;
    try std.testing.expectEqualStrings(expected, text);
}

test "validateArgs names each failing rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ok = Args{ .questions = &.{
        .{ .header = "Auth", .question = "Which method?", .options = &.{.{ .label = "OAuth" }} },
        .{ .header = "Scope", .question = "What scope?", .options = &.{
            .{ .label = "read" },
            .{ .label = "write" },
        }, .multi_select = true },
    } };
    try std.testing.expect(validateArgs(ok) == null);

    try expectMessage(
        alloc,
        "questions must contain at least one entry",
        validateArgs(.{ .questions = &.{} }),
    );
    try expectMessage(
        alloc,
        "too many questions (max 4)",
        validateArgs(.{ .questions = &.{ ok.questions.?[0], ok.questions.?[0], ok.questions.?[0], ok.questions.?[0], ok.questions.?[0] } }),
    );
    try expectMessage(
        alloc,
        "question 1: each question needs a non-empty header",
        validateArgs(.{ .questions = &.{.{ .header = "", .question = "q?", .options = &.{.{ .label = "a" }} }} }),
    );
    try expectMessage(
        alloc,
        "question 1: each question needs a non-empty question text",
        validateArgs(.{ .questions = &.{.{ .header = "h", .question = "", .options = &.{.{ .label = "a" }} }} }),
    );
    try expectMessage(
        alloc,
        "question 1: each question needs at least one option",
        validateArgs(.{ .questions = &.{.{ .header = "h", .question = "q?", .options = &.{} }} }),
    );
    try expectMessage(
        alloc,
        "question 1, option 1: each option needs a label",
        validateArgs(.{ .questions = &.{.{ .header = "h", .question = "q?", .options = &.{.{ .description = "only desc" }} }} }),
    );
    try expectMessage(
        alloc,
        "question 1: multi_select questions need at least two options",
        validateArgs(.{ .questions = &.{.{ .header = "h", .question = "q?", .options = &.{.{ .label = "a" }}, .multi_select = true }} }),
    );

    const too_many = Args{ .questions = &.{.{ .header = "h", .question = "q?", .options = &.{
        .{ .label = "1" }, .{ .label = "2" }, .{ .label = "3" }, .{ .label = "4" },
        .{ .label = "5" }, .{ .label = "6" }, .{ .label = "7" }, .{ .label = "8" },
        .{ .label = "9" },
    } }} };
    try expectMessage(alloc, "question 1: too many options (max 8)", validateArgs(too_many));
}

fn testQuestions() [3]Question {
    return .{
        .{ .header = "Auth", .question = "Which method?", .options = &.{ "OAuth", "API key" } },
        .{ .header = "Scope", .question = "What scope?", .options = &.{ "read (recommended)", "write" }, .multi_select = false },
        .{ .header = "Regions", .question = "Which regions?", .options = &.{ "eu", "us", "apac" }, .multi_select = true },
    };
}

test "session resolves questions one by one and submits at the end" {
    var session = try Session.init(std.testing.allocator, &testQuestions());
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(u8, 0), session.active);
    try std.testing.expect(!session.isResolved(0));

    session.moveCursor(1);
    try std.testing.expectEqual(@as(u8, 1), session.cursor());
    try std.testing.expectEqual(ResolveOutcome.advance, session.resolveCurrent());
    try std.testing.expect(session.isResolved(0));
    try std.testing.expectEqual(@as(u8, 1), session.active);
    try std.testing.expect(!session.allResolved());

    try std.testing.expectEqual(ResolveOutcome.advance, session.resolveCurrent());
    try std.testing.expectEqual(@as(u8, 2), session.active);

    try std.testing.expectEqual(ResolveOutcome.blocked, session.resolveCurrent());
    try std.testing.expect(!session.isResolved(2));

    session.toggleCurrent();
    session.moveCursor(1);
    session.toggleCurrent();
    try std.testing.expect(session.isChecked(2, 0));
    try std.testing.expect(session.isChecked(2, 1));
    session.toggleCurrent();
    try std.testing.expect(!session.isChecked(2, 1));
    session.toggleCurrent();

    try std.testing.expectEqual(ResolveOutcome.submitted, session.resolveCurrent());
    try std.testing.expect(session.allResolved());
    try std.testing.expect(session.answersOwned(arena.allocator()) != null);
}

test "session tab navigation honors resolution state" {
    var session = try Session.init(std.testing.allocator, &testQuestions());
    defer session.deinit();

    session.nextTab();
    try std.testing.expectEqual(@as(u8, 0), session.active);

    _ = session.resolveCurrent();
    try std.testing.expectEqual(@as(u8, 1), session.active);
    session.nextTab();
    try std.testing.expectEqual(@as(u8, 1), session.active);
    _ = session.resolveCurrent();
    try std.testing.expectEqual(@as(u8, 2), session.active);
    session.prevTab();
    session.prevTab();
    try std.testing.expectEqual(@as(u8, 0), session.active);

    // Reopen keeps picks and the stored cursor, re-resolve overwrites.
    session.moveCursor(1);
    _ = session.resolveCurrent();
    try std.testing.expectEqual(@as(?u8, 1), session.resolved[0].?[0].index);
}

test "session resolves a custom message without an index" {
    const questions = [_]Question{
        .{ .header = "Auth", .question = "Which method?", .options = &.{ "OAuth", "API key" } },
    };
    var session = try Session.init(std.testing.allocator, &questions);
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect(!session.messageRowActive(0));
    session.moveCursor(2);
    try std.testing.expect(session.messageRowActive(0));
    try std.testing.expectEqual(ResolveOutcome.blocked, session.resolveCurrent());

    try std.testing.expectEqual(ResolveOutcome.submitted, session.resolveMessage("something else"));
    const answers = session.answersOwned(arena.allocator()).?;
    try std.testing.expect(answers[0][0].index == null);
    try std.testing.expectEqualStrings("something else", answers[0][0].message);
}

test "multi-select questions reject custom messages" {
    const questions = [_]Question{
        .{ .header = "Regions", .question = "Which regions?", .options = &.{ "eu", "us" }, .multi_select = true },
    };
    var session = try Session.init(std.testing.allocator, &questions);
    defer session.deinit();

    try std.testing.expect(!session.messageRowActive(0));
    try std.testing.expectEqual(ResolveOutcome.blocked, session.resolveMessage("nope"));
    try std.testing.expect(!session.allResolved());
}

test "enter toggles multi-select options and commits from the submit row" {
    const questions = [_]Question{
        .{ .header = "Regions", .question = "Which regions?", .options = &.{ "eu", "us", "apac" }, .multi_select = true },
    };
    var session = try Session.init(std.testing.allocator, &questions);
    defer session.deinit();

    // Enter on option rows toggles; it never commits.
    try std.testing.expect(!session.submitRowActive(0));
    try std.testing.expectEqual(EnterOutcome.toggle, session.enterCurrent());
    try std.testing.expect(session.isChecked(0, 0));
    session.moveCursor(2);
    try std.testing.expectEqual(EnterOutcome.toggle, session.enterCurrent());
    try std.testing.expect(session.isChecked(0, 2));
    try std.testing.expect(!session.allResolved());

    // Enter on the submit row commits the toggled set.
    session.moveCursor(1);
    try std.testing.expect(session.submitRowActive(0));
    try std.testing.expectEqual(EnterOutcome.submitted, session.enterCurrent());
    try std.testing.expect(session.allResolved());
    const answers = session.resolved[0].?;
    try std.testing.expectEqual(@as(usize, 2), answers.len);
    try std.testing.expectEqual(@as(?u8, 0), answers[0].index);
    try std.testing.expectEqual(@as(?u8, 2), answers[1].index);

    // Enter on the submit row with no toggles stays blocked.
    var empty = try Session.init(std.testing.allocator, &questions);
    defer empty.deinit();
    empty.moveCursor(3);
    try std.testing.expectEqual(EnterOutcome.blocked, empty.enterCurrent());
    try std.testing.expect(!empty.allResolved());
}

test "formatResult echoes questions and answers in request order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = Args{ .questions = &.{
        .{ .header = "Auth", .question = "Which method?", .options = &.{
            .{ .label = "OAuth" },
            .{ .label = "API key" },
        } },
        .{ .header = "Regions", .question = "Which regions?", .options = &.{
            .{ .label = "eu" },
            .{ .label = "us" },
            .{ .label = "apac" },
        }, .multi_select = true },
    } };
    const answers = [_]Answer{
        &.{.{ .index = null, .message = "none of these" }},
        &.{ .{ .index = 0 }, .{ .index = 2 } },
    };

    const text = formatResult(alloc, args, &answers).?;
    try std.testing.expectEqualStrings(
        "1. [Auth] Which method? -> none of these\n2. [Regions] Which regions? -> eu, apac",
        text,
    );

    const single = Args{ .questions = args.questions.?[0..1] };
    const one = formatResult(alloc, single, answers[0..1]).?;
    try std.testing.expectEqualStrings("1. [Auth] Which method? -> none of these", one);
}

test "recommended answers follow the marker convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const single_marked = [_]Question{
        .{ .header = "h", .question = "q?", .options = &.{ "first", "second (recommended)", "third" } },
    };
    var answers = recommendedAnswers(alloc, &single_marked).?;
    try std.testing.expectEqual(@as(usize, 1), answers[0].len);
    try std.testing.expectEqual(@as(?u8, 1), answers[0][0].index);

    const single_unmarked = [_]Question{
        .{ .header = "h", .question = "q?", .options = &.{ "first", "second" } },
    };
    answers = recommendedAnswers(alloc, &single_unmarked).?;
    try std.testing.expectEqual(@as(?u8, 0), answers[0][0].index);

    const multi_marked = [_]Question{
        .{ .header = "h", .question = "q?", .options = &.{ "a (recommended)", "b", "c (Recommended)", "d" }, .multi_select = true },
    };
    answers = recommendedAnswers(alloc, &multi_marked).?;
    try std.testing.expectEqual(@as(usize, 2), answers[0].len);
    try std.testing.expectEqual(@as(?u8, 0), answers[0][0].index);
    try std.testing.expectEqual(@as(?u8, 2), answers[0][1].index);

    const multi_unmarked = [_]Question{
        .{ .header = "h", .question = "q?", .options = &.{ "a", "b" }, .multi_select = true },
    };
    answers = recommendedAnswers(alloc, &multi_unmarked).?;
    try std.testing.expectEqual(@as(usize, 1), answers[0].len);
    try std.testing.expectEqual(@as(?u8, 0), answers[0][0].index);
}

test "render draws tab headline, checkboxes, and the active row" {
    const questions = testQuestions();
    var session = try Session.init(std.testing.allocator, &questions);
    defer session.deinit();

    var buf = try tui.Buffer.init(std.testing.allocator, .{ .width = 60, .height = 24 });
    defer buf.deinit();
    const inner = tui.Rect{ .x = 0, .y = 0, .width = 58, .height = 22 };
    const colors = Colors{ .accent = .{ .rgb = .{ .r = 122, .g = 162, .b = 247 } }, .muted = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } } };

    renderSession(&session, colors, inner, &buf);

    // Tab headline: three numbers, tab 1 active (inverted).
    try std.testing.expectEqual(@as(u21, '1'), buf.get(1, 0).char);
    try std.testing.expect(buf.get(1, 0).style.modifier.reverse);
    try std.testing.expectEqual(@as(u21, '2'), buf.get(3, 0).char);
    try std.testing.expect(!buf.get(3, 0).style.modifier.reverse);

    // Question chip and text on the row below the headline.
    try std.testing.expectEqual(@as(u21, '['), buf.get(1, 1).char);
    try std.testing.expect(rowContains(&buf, 1, "Which method?"));

    // Single-select options with cursor prefix, one blank row below the question.
    try std.testing.expectEqual(@as(u21, '>'), buf.get(1, 3).char);
    try std.testing.expect(buf.get(1, 3).style.modifier.reverse);
    try std.testing.expect(rowContains(&buf, 3, "OAuth"));
    // Custom-message row exists on single-select questions.
    try std.testing.expect(rowContains(&buf, 5, "enter message"));

    // Resolve tab 1, move to the multi-select tab, toggle row 0.
    _ = session.resolveCurrent();
    try std.testing.expectEqual(@as(u8, 1), session.active);
    _ = session.resolveCurrent();
    try std.testing.expectEqual(@as(u8, 2), session.active);
    session.toggleCurrent();

    buf.clear();
    renderSession(&session, colors, inner, &buf);

    // Resolved tab shows the checkmark glyph.
    try std.testing.expectEqual(@as(u21, '✓'), buf.get(1, 0).char);
    try std.testing.expectEqual(@as(u21, '1'), buf.get(2, 0).char);
    // Active tab is now tab 3.
    try std.testing.expect(buf.get(7, 0).style.modifier.reverse);
    // Checkbox column on multi-select rows, row 0 checked.
    try std.testing.expectEqual(@as(u21, '['), buf.get(3, 3).char);
    try std.testing.expectEqual(@as(u21, 'x'), buf.get(4, 3).char);
    try std.testing.expectEqual(@as(u21, ']'), buf.get(5, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(4, 4).char);
    // The multi-select question ends in the fixed submit row, not the
    // custom-message row.
    try std.testing.expect(rowContains(&buf, 6, "submit"));
    var found_message = false;
    var y: u16 = 2;
    while (y < 12) : (y += 1) {
        if (rowContains(&buf, y, "enter message")) found_message = true;
    }
    try std.testing.expect(!found_message);
}

test "widgetHeight reserves the tab row only for multi-question requests" {
    const questions = testQuestions();
    const multi = widgetHeight(&questions, 0, 80, 40);
    const single_questions = questions[0..1];
    const single = widgetHeight(single_questions, 0, 80, 40);
    try std.testing.expect(multi == single + 1);
}

test "one-question request renders without a tab headline" {
    const questions = testQuestions()[0..1];
    var session = try Session.init(std.testing.allocator, questions);
    defer session.deinit();

    var buf = try tui.Buffer.init(std.testing.allocator, .{ .width = 60, .height = 24 });
    defer buf.deinit();
    renderSession(&session, .{ .accent = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .muted = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } }, .{ .x = 0, .y = 0, .width = 58, .height = 22 }, &buf);
    try std.testing.expectEqual(@as(u21, '['), buf.get(1, 0).char);
    try std.testing.expect(rowContains(&buf, 0, "Which method?"));
}
