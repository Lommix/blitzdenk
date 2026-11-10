const std = @import("std");
const tui = @import("tui/root.zig");
const permissions = @import("permissions");
const text_utils = tui.text_utils;

const MAX_QUESTIONS = permissions.MAX_QUESTIONS;
const MAX_OPTIONS = permissions.MAX_OPTIONS;
const MAX_QUESTIONS_RULE = std.fmt.comptimePrint("too many questions (max {d})", .{MAX_QUESTIONS});
const MAX_OPTIONS_RULE = std.fmt.comptimePrint("too many options (max {d})", .{MAX_OPTIONS});
const Question = permissions.Question;
const Answer = permissions.Answer;
const Answers = permissions.Answers;
const optionBit = permissions.optionBit;

/// A failed request rule, with the 0-based location that broke it.
pub const Violation = struct {
    rule: [:0]const u8,
    question: ?usize = null,
    option: ?usize = null,
};

pub fn validate(questions: []const Question) ?Violation {
    if (questions.len == 0) return .{ .rule = "questions must contain at least one entry" };
    if (questions.len > MAX_QUESTIONS) return .{ .rule = MAX_QUESTIONS_RULE };
    for (questions, 0..) |q, i| {
        if (q.header.len == 0) return .{ .rule = "each question needs a non-empty header", .question = i };
        if (q.question.len == 0) return .{ .rule = "each question needs a non-empty question text", .question = i };
        if (q.options.len == 0) return .{ .rule = "each question needs at least one option", .question = i };
        if (q.options.len > MAX_OPTIONS) return .{ .rule = MAX_OPTIONS_RULE, .question = i };
        for (q.options, 0..) |opt, j| {
            if (opt.label.len == 0) return .{ .rule = "each option needs a label", .question = i, .option = j };
        }
        if (q.multi_select and q.options.len < 2) return .{ .rule = "multi_select questions need at least two options", .question = i };
    }
    return null;
}

/// Model-facing rule text with a 1-based location prefix, NUL-terminated for Lua errors.
pub fn formatViolation(alloc: std.mem.Allocator, violation: Violation) ![:0]const u8 {
    const question = violation.question orelse return violation.rule;
    if (violation.option) |option| {
        return std.fmt.allocPrintSentinel(alloc, "question {d}, option {d}: {s}", .{ question + 1, option + 1, violation.rule }, 0);
    }
    return std.fmt.allocPrintSentinel(alloc, "question {d}: {s}", .{ question + 1, violation.rule }, 0);
}

/// Picked labels joined with ", " in display order, or the custom message.
fn writeAnswer(w: *std.Io.Writer, q: Question, answer: Answer) !void {
    if (answer.message.len > 0) return w.writeAll(answer.message);
    var first = true;
    for (q.options, 0..) |opt, i| {
        if (answer.mask & optionBit(i) == 0) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.writeAll(opt.label);
    }
}

/// Model-facing result text: one numbered line per question in request order,
/// `1. [Header] Question? -> Answer`.
pub fn formatResult(alloc: std.mem.Allocator, questions: []const Question, answers: []const Answer) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    for (questions, answers, 0..) |q, answer, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{d}. [{s}] {s} -> ", .{ i + 1, q.header, q.question });
        try writeAnswer(&w.writer, q, answer);
    }
    return w.toOwnedSlice();
}

pub const Outcome = enum { none, open_message, advance, submitted };

/// Interactive edit state for one ask request: active tab, per-question
/// cursors and toggles, and resolved answers. Borrows `questions`.
pub const Session = struct {
    questions: []const Question,
    active: u8 = 0,
    cursors: [MAX_QUESTIONS]u8 = @splat(0),
    toggles: [MAX_QUESTIONS]u8 = @splat(0),
    resolved: [MAX_QUESTIONS]?Answer = @splat(null),

    pub fn init(questions: []const Question) Session {
        return .{ .questions = questions };
    }

    /// Free custom-message text not handed out by `takeAnswers`.
    pub fn deinit(self: *Session) void {
        for (self.resolved) |slot| if (slot) |answer| answer.deinit();
        self.resolved = @splat(null);
    }

    pub fn cursor(self: *const Session) u8 {
        return self.cursors[self.active];
    }

    pub fn moveCursor(self: *Session, delta: i32) void {
        const max: i32 = @as(i32, rowCount(self.questions[self.active])) - 1;
        const next = std.math.clamp(@as(i32, self.cursor()) + delta, 0, max);
        self.cursors[self.active] = @intCast(next);
    }

    pub fn isChecked(self: *const Session, qi: usize, opt: usize) bool {
        return self.toggles[qi] & optionBit(opt) != 0;
    }

    pub fn isResolved(self: *const Session, qi: usize) bool {
        return self.resolved[qi] != null;
    }

    /// Toggle the highlighted option of a multi-select question.
    pub fn toggle(self: *Session) void {
        const q = self.questions[self.active];
        const c = self.cursor();
        if (q.multi_select and c < q.options.len) self.toggles[self.active] ^= optionBit(c);
    }

    pub fn prevTab(self: *Session) void {
        if (self.active > 0) self.active -= 1;
    }

    /// Forward only when the current question is resolved.
    pub fn nextTab(self: *Session) void {
        if (!self.isResolved(self.active)) return;
        if (self.active + 1 < self.questions.len) self.active += 1;
    }

    /// Enter on the active question. Single-select resolves the highlighted
    /// option, or asks for the message field on the message row. Multi-select
    /// toggles option rows and commits a non-empty set from the submit row.
    pub fn enter(self: *Session) Outcome {
        const q = self.questions[self.active];
        const c = self.cursor();
        if (c < q.options.len) {
            if (!q.multi_select) return self.resolve(.{ .mask = optionBit(c) });
            self.toggle();
            return .none;
        }
        if (!q.multi_select) return .open_message;
        const mask = self.toggles[self.active];
        if (mask == 0) return .none;
        return self.resolve(.{ .mask = mask });
    }

    /// Resolve the active question with a typed custom message. Ignored for
    /// empty text and questions without a message row.
    pub fn message(self: *Session, text: []const u8) Outcome {
        if (text.len == 0 or !self.questions[self.active].hasMessageRow()) return .none;
        const owned = permissions.message_allocator.dupe(u8, text) catch return .none;
        return self.resolve(.{ .message = owned });
    }

    /// Store the answer, then activate the next unresolved question.
    fn resolve(self: *Session, answer: Answer) Outcome {
        const slot = &self.resolved[self.active];
        if (slot.*) |old| old.deinit();
        slot.* = answer;
        for (1..self.questions.len) |step| {
            const qi = (self.active + step) % self.questions.len;
            if (self.resolved[qi] == null) {
                self.active = @intCast(qi);
                return .advance;
            }
        }
        return .submitted;
    }

    /// Hand the answers and their message text to the caller. Null until
    /// every question is resolved.
    pub fn takeAnswers(self: *Session) ?Answers {
        var answers: Answers = .{ .len = @intCast(self.questions.len) };
        for (self.resolved[0..self.questions.len], 0..) |slot, i| answers.items[i] = slot orelse return null;
        self.resolved = @splat(null);
        return answers;
    }
};

/// Option rows plus the trailing message or submit row.
fn rowCount(q: Question) u8 {
    return @intCast(q.options.len + @intFromBool(q.multi_select or q.allow_message));
}

const LINE_MAX = 1024;

/// Format into `buf`, truncating at a codepoint boundary instead of failing.
fn lineText(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print(fmt, args) catch {};
    const out = w.buffered();
    var lead = out.len;
    while (lead > 0 and out[lead - 1] & 0xC0 == 0x80) lead -= 1;
    if (lead == 0) return out;
    const len = std.unicode.utf8ByteSequenceLength(out[lead - 1]) catch 1;
    return if (lead - 1 + len > out.len) out[0 .. lead - 1] else out;
}

fn headerLine(buf: []u8, q: Question) []const u8 {
    return lineText(buf, "[{s}] {s}", .{ q.header, q.question });
}

fn rowLine(buf: []u8, q: Question, row: usize, selected: bool, checked: bool) []const u8 {
    const prefix: []const u8 = if (selected) "> " else "  ";
    if (row >= q.options.len) {
        return lineText(buf, "{s}{s}", .{ prefix, if (q.multi_select) "submit" else "enter message" });
    }
    const opt = q.options[row];
    const mark: []const u8 = if (!q.multi_select) "" else if (checked) "[x] " else "[ ] ";
    const sep: []const u8 = if (opt.description.len > 0) " — " else "";
    return lineText(buf, "{s}{s}{s}{s}{s}", .{ prefix, mark, opt.label, sep, opt.description });
}

/// Wrapped rows of every option row of `q`; continuation rows indent by 2.
fn optionRows(q: Question, width: u16) u16 {
    var line_buf: [LINE_MAX]u8 = undefined;
    var rows: u16 = 0;
    for (0..rowCount(q)) |row| {
        rows +|= text_utils.wrappedRowCount(rowLine(&line_buf, q, row, false, false), width -| 2);
    }
    return rows;
}

/// Input-area height for the ask widget, borders included. Sized for the
/// tallest question so switching tabs does not resize the widget; reserves
/// the tab headline row only for multi-question requests. `field_rows` grows
/// the message row while the caller's message field is open.
pub fn widgetHeight(questions: []const Question, area_width: u16, area_height: u16, field_rows: ?u16) u16 {
    const width = area_width -| 7;
    var line_buf: [LINE_MAX]u8 = undefined;
    var rows: u16 = 0;
    for (questions) |q| {
        rows = @max(rows, text_utils.wrappedRowCount(headerLine(&line_buf, q), width) +| optionRows(q, width));
    }
    rows +|= @intFromBool(questions.len > 1);
    rows +|= (field_rows orelse 1) -| 1;
    return @min(rows +| 6, area_height -| 1);
}

pub const Colors = struct {
    accent: tui.Color,
    muted: tui.Color,
    text: tui.Color,
};

/// Draw the active question. With `field_rows` set, the message row is left
/// blank for the caller's message field and its area is returned.
pub fn render(session: *const Session, colors: Colors, inner: tui.Rect, field_rows: ?u16, buf: *tui.Buffer) ?tui.Rect {
    const x = inner.x + 1;
    const width = inner.width -| 1;
    if (width == 0 or inner.height == 0) return null;
    const bottom = inner.y +| inner.height;

    var y = inner.y;
    if (session.questions.len > 1) {
        renderTabs(session, colors, x, y, width, buf);
        y +|= 1;
    }

    const q = session.questions[session.active];
    var line_buf: [LINE_MAX]u8 = undefined;
    const max_q_rows = bottom -| y -| optionRows(q, width) -| ((field_rows orelse 1) -| 1) -| 1;
    const q_rows = text_utils.renderWrappedText(buf, headerLine(&line_buf, q), x, y, width, max_q_rows, 0, .{ .fg = colors.accent });

    y = y +| 1 +| q_rows;
    for (0..rowCount(q)) |row| {
        if (y >= bottom) break;
        if (field_rows != null and row >= q.options.len and q.hasMessageRow()) {
            return .{ .x = x, .y = y, .width = width, .height = @min(field_rows.?, bottom -| y) };
        }
        const selected = session.cursor() == row;
        const style: tui.Style = .{ .fg = colors.text, .modifier = .{ .reverse = selected } };
        const line = rowLine(&line_buf, q, row, selected, session.isChecked(session.active, row));
        const used = text_utils.renderWrappedText(buf, line, x, y, width, bottom -| y, 2, style);
        if (used == 0) break;
        y +|= used;
    }
    return null;
}

fn renderTabs(session: *const Session, colors: Colors, x: u16, y: u16, width: u16, buf: *tui.Buffer) void {
    var cx = x;
    for (session.questions, 0..) |_, i| {
        const resolved = session.isResolved(i);
        var tab_buf: [8]u8 = undefined;
        const text = lineText(&tab_buf, "{s}{d}", .{ if (resolved) "✓" else "", i + 1 });
        const style: tui.Style = if (i == session.active)
            .{ .fg = colors.accent, .modifier = .{ .reverse = true } }
        else if (resolved)
            .{ .fg = colors.accent }
        else
            .{ .fg = colors.muted };
        buf.setStringMax(cx, y, text, style, width -| (cx -| x));
        cx +|= @as(u16, if (resolved) 3 else 2);
    }
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

fn expectMessage(alloc: std.mem.Allocator, expected: []const u8, violation: ?Violation) !void {
    const found = violation orelse return error.ExpectedViolation;
    try std.testing.expectEqualStrings(expected, try formatViolation(alloc, found));
}

test "validate names each failing rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const one: Question = .{ .header = "Auth", .question = "Which method?", .options = &.{.{ .label = "OAuth" }} };
    const ok = [_]Question{
        one,
        .{ .header = "Scope", .question = "What scope?", .options = &.{ .{ .label = "read" }, .{ .label = "write" } }, .multi_select = true },
    };
    try std.testing.expect(validate(&ok) == null);

    try expectMessage(alloc, "questions must contain at least one entry", validate(&.{}));
    const too_many: [MAX_QUESTIONS + 1]Question = @splat(one);
    try expectMessage(alloc, "too many questions (max 8)", validate(&too_many));
    try expectMessage(alloc, "question 1: each question needs a non-empty header", validate(&.{.{ .question = "q?", .options = &.{.{ .label = "a" }} }}));
    try expectMessage(alloc, "question 1: each question needs a non-empty question text", validate(&.{.{ .header = "h", .options = &.{.{ .label = "a" }} }}));
    try expectMessage(alloc, "question 1: each question needs at least one option", validate(&.{.{ .header = "h", .question = "q?" }}));
    try expectMessage(alloc, "question 1, option 1: each option needs a label", validate(&.{.{ .header = "h", .question = "q?", .options = &.{.{ .description = "only desc" }} }}));
    try expectMessage(alloc, "question 1: multi_select questions need at least two options", validate(&.{.{ .header = "h", .question = "q?", .options = &.{.{ .label = "a" }}, .multi_select = true }}));

    const nine: [9]permissions.Option = @splat(.{ .label = "x" });
    try expectMessage(alloc, "question 1: too many options (max 8)", validate(&.{.{ .header = "h", .question = "q?", .options = &nine }}));
}

const test_questions = [_]Question{
    .{ .header = "Auth", .question = "Which method?", .options = &.{ .{ .label = "OAuth" }, .{ .label = "API key" } } },
    .{ .header = "Scope", .question = "What scope?", .options = &.{ .{ .label = "read (recommended)" }, .{ .label = "write" } } },
    .{ .header = "Regions", .question = "Which regions?", .options = &.{ .{ .label = "eu" }, .{ .label = "us" }, .{ .label = "apac" } }, .multi_select = true },
};

test "session resolves questions one by one and submits at the end" {
    var session = Session.init(&test_questions);
    defer session.deinit();

    session.moveCursor(1);
    try std.testing.expectEqual(Outcome.advance, session.enter());
    try std.testing.expect(session.isResolved(0));
    try std.testing.expectEqual(@as(u8, 1), session.active);
    try std.testing.expect(session.takeAnswers() == null);

    try std.testing.expectEqual(Outcome.advance, session.enter());
    try std.testing.expectEqual(@as(u8, 2), session.active);

    session.toggle();
    session.moveCursor(1);
    session.toggle();
    try std.testing.expect(session.isChecked(2, 0) and session.isChecked(2, 1));
    session.toggle();
    try std.testing.expect(!session.isChecked(2, 1));
    session.moveCursor(1);
    session.toggle();

    session.moveCursor(1);
    try std.testing.expectEqual(Outcome.submitted, session.enter());
    const answers = session.takeAnswers().?;
    try std.testing.expectEqual(@as(u8, 0b10), answers.items[0].mask);
    try std.testing.expectEqual(@as(u8, 0b01), answers.items[1].mask);
    try std.testing.expectEqual(@as(u8, 0b101), answers.items[2].mask);
}

test "session tab navigation honors resolution state" {
    var session = Session.init(&test_questions);
    defer session.deinit();

    session.nextTab();
    try std.testing.expectEqual(@as(u8, 0), session.active);

    _ = session.enter();
    try std.testing.expectEqual(@as(u8, 1), session.active);
    session.nextTab();
    try std.testing.expectEqual(@as(u8, 1), session.active);
    _ = session.enter();
    try std.testing.expectEqual(@as(u8, 2), session.active);
    session.prevTab();
    session.prevTab();
    try std.testing.expectEqual(@as(u8, 0), session.active);

    // Reopen keeps the stored cursor, re-resolve overwrites and jumps to the
    // next unresolved question.
    session.moveCursor(1);
    try std.testing.expectEqual(Outcome.advance, session.enter());
    try std.testing.expectEqual(@as(u8, 0b10), session.resolved[0].?.mask);
    try std.testing.expectEqual(@as(u8, 2), session.active);
}

test "session resolves a custom message from the message row" {
    var session = Session.init(test_questions[0..1]);
    defer session.deinit();

    session.moveCursor(2);
    try std.testing.expectEqual(Outcome.open_message, session.enter());
    try std.testing.expectEqual(Outcome.none, session.message(""));
    try std.testing.expectEqual(Outcome.submitted, session.message("something else"));
    const answers = session.takeAnswers().?;
    defer answers.deinit();
    try std.testing.expectEqual(@as(u8, 0), answers.items[0].mask);
    try std.testing.expectEqualStrings("something else", answers.items[0].message);
}

test "message rows only exist where allowed" {
    var multi = Session.init(test_questions[2..3]);
    defer multi.deinit();
    try std.testing.expectEqual(Outcome.none, multi.message("nope"));
    try std.testing.expect(!multi.isResolved(0));

    const closed = [_]Question{.{ .header = "Effort", .question = "Which?", .options = &.{ .{ .label = "low" }, .{ .label = "high" } }, .allow_message = false }};
    var session = Session.init(&closed);
    defer session.deinit();
    session.moveCursor(5);
    try std.testing.expectEqual(@as(u8, 1), session.cursor());
    try std.testing.expectEqual(Outcome.none, session.message("free text"));
    try std.testing.expectEqual(Outcome.submitted, session.enter());
}

test "enter toggles multi-select options and commits from the submit row" {
    var session = Session.init(test_questions[2..3]);
    defer session.deinit();

    try std.testing.expectEqual(Outcome.none, session.enter());
    try std.testing.expect(session.isChecked(0, 0));
    session.moveCursor(2);
    _ = session.enter();
    try std.testing.expect(session.isChecked(0, 2));
    try std.testing.expect(!session.isResolved(0));

    session.moveCursor(1);
    try std.testing.expectEqual(Outcome.submitted, session.enter());
    try std.testing.expectEqual(@as(u8, 0b101), session.resolved[0].?.mask);

    var empty = Session.init(test_questions[2..3]);
    defer empty.deinit();
    empty.moveCursor(3);
    try std.testing.expectEqual(Outcome.none, empty.enter());
    try std.testing.expect(!empty.isResolved(0));
}

test "formatResult echoes questions and answers in request order" {
    const alloc = std.testing.allocator;
    const questions = [_]Question{ test_questions[0], test_questions[2] };
    const answers = [_]Answer{ .{ .message = "none of these" }, .{ .mask = 0b101 } };

    const text = try formatResult(alloc, &questions, &answers);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("1. [Auth] Which method? -> none of these\n2. [Regions] Which regions? -> eu, apac", text);

    const one = try formatResult(alloc, questions[0..1], answers[0..1]);
    defer alloc.free(one);
    try std.testing.expectEqualStrings("1. [Auth] Which method? -> none of these", one);
}

test "render draws tab headline, checkboxes, and the active row" {
    var session = Session.init(&test_questions);
    defer session.deinit();

    var buf = try tui.Buffer.init(std.testing.allocator, .{ .width = 60, .height = 24 });
    defer buf.deinit();
    const inner = tui.Rect{ .x = 0, .y = 0, .width = 58, .height = 22 };
    const colors = Colors{ .accent = .{ .rgb = .{ .r = 122, .g = 162, .b = 247 } }, .muted = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } }, .text = .{ .rgb = .{ .r = 192, .g = 202, .b = 245 } } };

    _ = render(&session, colors, inner, null, &buf);

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
    try std.testing.expect(rowContains(&buf, 5, "enter message"));

    // Resolve tabs 1 and 2, toggle row 0 of the multi-select tab.
    _ = session.enter();
    _ = session.enter();
    try std.testing.expectEqual(@as(u8, 2), session.active);
    session.toggle();

    buf.clear();
    _ = render(&session, colors, inner, null, &buf);

    try std.testing.expectEqual(@as(u21, '✓'), buf.get(1, 0).char);
    try std.testing.expectEqual(@as(u21, '1'), buf.get(2, 0).char);
    try std.testing.expect(buf.get(7, 0).style.modifier.reverse);
    try std.testing.expectEqual(@as(u21, '['), buf.get(3, 3).char);
    try std.testing.expectEqual(@as(u21, 'x'), buf.get(4, 3).char);
    try std.testing.expectEqual(@as(u21, ']'), buf.get(5, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(4, 4).char);
    try std.testing.expect(rowContains(&buf, 6, "submit"));
    var y: u16 = 2;
    while (y < 12) : (y += 1) try std.testing.expect(!rowContains(&buf, y, "enter message"));
}

test "render reserves the message row for an open field" {
    var session = Session.init(test_questions[0..1]);
    defer session.deinit();
    session.moveCursor(2);

    var buf = try tui.Buffer.init(std.testing.allocator, .{ .width = 60, .height = 24 });
    defer buf.deinit();
    const colors = Colors{ .accent = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .muted = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } }, .text = .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } } };
    const inner = tui.Rect{ .x = 0, .y = 0, .width = 58, .height = 22 };

    const field = render(&session, colors, inner, 3, &buf).?;
    try std.testing.expectEqual(tui.Rect{ .x = 1, .y = 4, .width = 57, .height = 3 }, field);
    try std.testing.expect(rowContains(&buf, 2, "OAuth"));
    try std.testing.expect(!rowContains(&buf, 4, "enter message"));

    // Multi-select questions have no message row to reserve.
    var multi = Session.init(test_questions[2..3]);
    defer multi.deinit();
    try std.testing.expect(render(&multi, colors, inner, 3, &buf) == null);
}

test "widgetHeight grows with the open field" {
    const q = test_questions[0];
    try std.testing.expectEqual(widgetHeight(&.{q}, 80, 40, null), widgetHeight(&.{q}, 80, 40, 1));
    try std.testing.expectEqual(widgetHeight(&.{q}, 80, 40, null) + 2, widgetHeight(&.{q}, 80, 40, 3));
}

test "widgetHeight reserves the tab row only for multi-question requests" {
    const q = test_questions[0];
    try std.testing.expectEqual(widgetHeight(&.{q}, 80, 40, null) + 1, widgetHeight(&.{ q, q }, 80, 40, null));
}

test "widgetHeight counts the checkbox width of multi-select rows" {
    // Each label fills the wrap width exactly without a checkbox; the
    // checkbox pushes every row onto a second line.
    const label_buf: [69]u8 = @splat('x');
    const label: []const u8 = &label_buf;
    const single = [_]Question{.{ .header = "h", .question = "q?", .options = &.{ .{ .label = label }, .{ .label = label } }, .allow_message = false }};
    const multi = [_]Question{.{ .header = "h", .question = "q?", .options = &.{ .{ .label = label }, .{ .label = label } }, .multi_select = true }};
    // multi: two doubled option rows plus the submit row, single: two rows.
    try std.testing.expectEqual(widgetHeight(&single, 80, 60, null) + 3, widgetHeight(&multi, 80, 60, null));
}

test "long lines keep their cursor prefix" {
    var line_buf: [LINE_MAX]u8 = undefined;
    const long: [1200]u8 = comptime blk: {
        var b: [1200]u8 = undefined;
        for (0..600) |i| b[2 * i ..][0..2].* = "ü".*;
        break :blk b;
    };
    const q: Question = .{ .header = "h", .question = "q?", .options = &.{.{ .label = &long }} };
    const line = rowLine(&line_buf, q, 0, true, false);
    try std.testing.expect(std.mem.startsWith(u8, line, "> ü"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
}

test "one-question request renders without a tab headline" {
    var session = Session.init(test_questions[0..1]);
    defer session.deinit();

    var buf = try tui.Buffer.init(std.testing.allocator, .{ .width = 60, .height = 24 });
    defer buf.deinit();
    _ = render(&session, .{ .accent = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .muted = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } }, .text = .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } } }, .{ .x = 0, .y = 0, .width = 58, .height = 22 }, null, &buf);
    try std.testing.expectEqual(@as(u21, '['), buf.get(1, 0).char);
    try std.testing.expect(rowContains(&buf, 0, "Which method?"));
}
