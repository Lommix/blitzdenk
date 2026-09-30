const std = @import("std");
const widgets = @import("widgets.zig");
const cell = @import("cell.zig");

const Line = widgets.Line;
const Span = widgets.Span;
const Style = cell.Style;
const Row = widgets.WrapRow;

pub const Pos = struct { row: usize = 0, col: usize = 0 };

pub const Layout = struct {
    text: []const u8,
    rows: std.ArrayList(Line) = .empty,
    ranges: std.ArrayList(Row) = .empty,
    cursor: Pos = .{},

    pub fn deinit(self: *Layout, alloc: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
        self.ranges.deinit(alloc);
    }
};

const Caret = struct { row: usize, on_codepoint: bool };

fn findCaret(ranges: []const Row, pos: usize) Caret {
    for (ranges, 0..) |r, i| {
        if (pos < r.start) continue;
        if (pos < r.end) return .{ .row = i, .on_codepoint = true };
        if (i + 1 < ranges.len and ranges[i + 1].start <= pos) continue;
        if (i + 1 < ranges.len and pos > r.end) return .{ .row = i + 1, .on_codepoint = true };
        return .{ .row = i, .on_codepoint = false };
    }
    return .{ .row = ranges.len - 1, .on_codepoint = false };
}

const displayCols = widgets.displayCols;

fn colInRow(text: []const u8, row: Row, pos: usize) usize {
    if (pos <= row.start) return 0;
    if (pos >= row.end) return row.cols;
    return displayCols(text[row.start..pos]);
}

fn freeSpan(alloc: std.mem.Allocator, span: Span) void {
    if (span.owned) alloc.free(span.content);
}

fn spanRow(alloc: std.mem.Allocator, row: *Line, mask: ?u8) !void {
    if (mask == null) return;
    var next: std.ArrayList(Span) = .empty;
    errdefer {
        for (next.items) |span| freeSpan(alloc, span);
        next.deinit(alloc);
    }
    for (row.spans.items) |span| {
        const masked = try alloc.alloc(u8, displayCols(span.content));
        @memset(masked, mask.?);
        try next.append(alloc, .{ .content = masked, .style = span.style, .owned = true });
    }
    row.deinit(alloc);
    row.spans = next;
}

fn styleCursor(alloc: std.mem.Allocator, row: *Line, index: usize, at: usize, cp_len: usize, style: Style) !void {
    var next: std.ArrayList(Span) = .empty;
    errdefer {
        for (next.items) |span| freeSpan(alloc, span);
        next.deinit(alloc);
    }
    for (row.spans.items, 0..) |span, i| {
        if (i != index) {
            try next.append(alloc, .{ .content = try alloc.dupe(u8, span.content), .style = span.style, .owned = true });
            continue;
        }
        if (at > 0) try next.append(alloc, .{ .content = try alloc.dupe(u8, span.content[0..at]), .style = span.style, .owned = true });
        try next.append(alloc, .{ .content = try alloc.dupe(u8, span.content[at .. at + cp_len]), .style = style, .owned = true });
        if (at + cp_len < span.content.len) {
            try next.append(alloc, .{ .content = try alloc.dupe(u8, span.content[at + cp_len ..]), .style = span.style, .owned = true });
        }
    }
    row.deinit(alloc);
    row.spans = next;
}

fn codepointOffset(content: []const u8, col: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < content.len and seen < col) {
        i += widgets.codepointLen(content, i);
        seen += 1;
    }
    return i;
}

fn styleCaretCodepoint(alloc: std.mem.Allocator, row: *Line, col: usize, style: Style) !void {
    var total: usize = 0;
    for (row.spans.items) |span| total += displayCols(span.content);
    if (total == 0) return;
    const want = @min(col, total - 1);

    var seen: usize = 0;
    for (row.spans.items, 0..) |span, i| {
        const n = displayCols(span.content);
        if (want >= seen + n) {
            seen += n;
            continue;
        }
        const at = codepointOffset(span.content, want - seen);
        const len = widgets.codepointLen(span.content, at);
        if (len > 0) try styleCursor(alloc, row, i, at, len, style);
        return;
    }
}

fn buildRows(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: usize,
    style: Style,
    out: ?*std.ArrayList(Line),
    ranges: ?*std.ArrayList(Row),
) !usize {
    if (width == 0) return 0;
    var total: usize = 0;
    var base: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line: Line = .{ .style = style };
        defer line.deinit(alloc);
        try line.pushText(alloc, raw, style);

        var wrapped: std.ArrayList(Line) = .empty;
        defer wrapped.deinit(alloc);
        var local: std.ArrayList(Row) = .empty;
        defer local.deinit(alloc);
        const keep = out != null;
        const n = if (keep) try widgets.wrapLineTracked(alloc, &line, width, &wrapped, &local) else widgets.wrapLineCount(&line, width, width);
        if (keep) {
            if (n == 0) {
                try wrapped.append(alloc, .{ .style = style });
                try local.append(alloc, .{ .start = 0, .end = raw.len, .cols = 0 });
            }
            for (wrapped.items) |row| try out.?.append(alloc, row);
            for (local.items) |r| try ranges.?.append(alloc, .{
                .start = r.start + base,
                .end = r.end + base,
                .cols = r.cols,
            });
        }
        total += @max(1, n);
        base += raw.len + 1;
    }
    return total;
}

pub fn layout(
    alloc: std.mem.Allocator,
    text: []const u8,
    cursor: usize,
    width: usize,
    text_style: Style,
    cursor_style: Style,
    mask: ?u8,
) !Layout {
    var out: Layout = .{ .text = text };
    errdefer out.deinit(alloc);
    if (width == 0) return out;

    const caret: usize = @min(cursor, text.len);
    _ = try buildRows(alloc, text, width, text_style, &out.rows, &out.ranges);

    const at = findCaret(out.ranges.items, caret);
    for (out.rows.items, 0..) |*row, i| {
        try spanRow(alloc, row, mask);
        if (at.row != i) continue;
        if (at.on_codepoint) {
            try styleCaretCodepoint(alloc, row, colInRow(text, out.ranges.items[i], caret), cursor_style);
        } else {
            try row.pushSpan(alloc, .{ .content = " ", .style = cursor_style });
        }
    }
    out.cursor = posAt(&out, at, caret);
    return out;
}

fn posAt(l: *const Layout, at: Caret, pos: usize) Pos {
    if (at.on_codepoint) return .{ .row = at.row, .col = colInRow(l.text, l.ranges.items[at.row], pos) };
    return .{ .row = at.row, .col = l.ranges.items[at.row].cols };
}

pub fn visualPos(l: *const Layout, pos: usize) Pos {
    return posAt(l, findCaret(l.ranges.items, pos), pos);
}

pub fn rowCount(alloc: std.mem.Allocator, text: []const u8, width: usize) !usize {
    return buildRows(alloc, text, width, .{}, null, null);
}

pub fn verticalTarget(l: *const Layout, delta: i32, desired_col: usize) ?usize {
    if (l.ranges.items.len == 0) return null;
    const from = l.cursor.row;
    if (delta < 0 and from == 0) return null;
    const target = if (delta < 0) from - 1 else from + 1;
    if (target >= l.ranges.items.len) return null;

    const row = l.ranges.items[target];
    const wanted = @min(desired_col, row.cols);
    var pos = row.start;
    var cols: usize = 0;
    while (pos < row.end and cols < wanted) {
        pos = @min(pos + widgets.codepointLen(l.text, pos), row.end);
        cols += 1;
    }
    if (pos == row.end and pos > row.start and target + 1 < l.ranges.items.len and
        l.ranges.items[target + 1].start == pos)
    {
        pos -= 1;
        while (pos > row.start and (l.text[pos] & 0xC0) == 0x80) pos -= 1;
    }
    return pos;
}

fn expectRowText(alloc: std.mem.Allocator, row: *const Line, want: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (row.spans.items) |span| try buf.appendSlice(alloc, span.content);
    try std.testing.expectEqualStrings(want, buf.items);
}

fn expectCursorAt(row: *const Line, col: usize, style: Style) !void {
    var seen: usize = 0;
    for (row.spans.items) |span| {
        const n = displayCols(span.content);
        if (col < seen + n) {
            try std.testing.expect(style.eql(span.style));
            try std.testing.expectEqual(@as(usize, 1), n);
            return;
        }
        seen += n;
    }
    try std.testing.expect(false);
}

test "layout keeps a word whole when the cursor sits on it" {
    const alloc = std.testing.allocator;
    const text = "alpha beta gamma";
    var l = try layout(alloc, text, 0, 12, .{}, .{}, null);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), l.rows.items.len);
    try expectRowText(alloc, &l.rows.items[0], "alpha beta ");
    try expectRowText(alloc, &l.rows.items[1], "gamma");
    try std.testing.expectEqual(@as(usize, 0), l.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), l.cursor.col);

    var at_cursor = try layout(alloc, text, 6, 12, .{}, .{ .modifier = .{ .reverse = true } }, null);
    defer at_cursor.deinit(alloc);
    try std.testing.expectEqual(l.rows.items.len, at_cursor.rows.items.len);
    try expectRowText(alloc, &at_cursor.rows.items[0], "alpha beta ");
}

test "layout styles the cursor codepoint after wrapping" {
    const alloc = std.testing.allocator;
    const text = "alpha beta";
    var l = try layout(alloc, text, 8, 12, .{ .fg = .white }, .{ .fg = .red }, null);
    defer l.deinit(alloc);

    try expectRowText(alloc, &l.rows.items[0], text);
    try std.testing.expectEqual(@as(usize, 8), l.cursor.col);
    try expectCursorAt(&l.rows.items[0], 8, .{ .fg = .red });
}

test "layout puts the caret on a space when the cursor has no codepoint" {
    const alloc = std.testing.allocator;
    var l = try layout(alloc, "hi", 2, 12, .{}, .{ .bg = .red }, null);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), l.rows.items.len);
    try expectRowText(alloc, &l.rows.items[0], "hi ");
    try std.testing.expectEqual(@as(usize, 2), l.cursor.col);
}

test "layout masks every row and keeps the cursor column" {
    const alloc = std.testing.allocator;
    var l = try layout(alloc, "secret", 3, 12, .{}, .{ .fg = .red }, '*');
    defer l.deinit(alloc);

    try expectRowText(alloc, &l.rows.items[0], "******");
    try std.testing.expectEqual(@as(usize, 3), l.cursor.col);
}

test "layout styles one whole cursor codepoint of multi-byte text" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, mask: ?u8, row: []const u8 }{
        .{ .text = "日本語", .mask = null, .row = "日本語" },
        .{ .text = "日本語", .mask = '*', .row = "***" },
        .{ .text = "a 👩‍👩‍👦 b", .mask = null, .row = "a 👩‍👩‍👦 b" },
    };
    const cursor_style: Style = .{ .fg = .red };
    for (cases) |case| {
        var col: usize = 0;
        var pos: usize = 0;
        while (pos < case.text.len) {
            var l = try layout(alloc, case.text, pos, 40, .{}, cursor_style, case.mask);
            defer l.deinit(alloc);
            try expectRowText(alloc, &l.rows.items[0], case.row);
            try std.testing.expectEqual(col, l.cursor.col);
            try expectCursorAt(&l.rows.items[0], col, cursor_style);
            pos += std.unicode.utf8ByteSequenceLength(case.text[pos]) catch 1;
            col += 1;
        }
    }
}

test "layout finds the caret inside a space run dropped at a wrap break" {
    const alloc = std.testing.allocator;
    var l = try layout(alloc, "hello     world", 9, 7, .{}, .{ .fg = .red }, null);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), l.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), l.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), l.cursor.col);
    try expectCursorAt(&l.rows.items[1], 0, .{ .fg = .red });
}

test "layout snaps a caret in a dropped space run to the next row" {
    const alloc = std.testing.allocator;
    const cursor_style: Style = .{ .fg = .red };
    var l = try layout(alloc, "aaa     bbb     ccc", 5, 3, .{}, cursor_style, null);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), l.rows.items.len);
    try expectRowText(alloc, &l.rows.items[1], "bbb");
    try std.testing.expectEqual(@as(usize, 1), l.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), l.cursor.col);
    try expectCursorAt(&l.rows.items[1], 0, cursor_style);
}

test "layout caret row never jumps ahead of the row the cursor text is on" {
    const alloc = std.testing.allocator;
    const text = "aaa     bbb     ccc";
    var prev: usize = 0;
    for (0..text.len + 1) |pos| {
        var l = try layout(alloc, text, pos, 3, .{}, .{ .fg = .red }, null);
        defer l.deinit(alloc);

        var limit: usize = l.ranges.items.len - 1;
        for (l.ranges.items, 0..) |r, i| {
            if (r.start > pos) {
                limit = i;
                break;
            }
        }
        try std.testing.expect(l.cursor.row <= limit);
        try std.testing.expect(l.cursor.row >= prev);
        prev = l.cursor.row;
    }
}

const wrap_cases = [_]struct { text: []const u8, width: usize }{
    .{ .text = "alpha beta", .width = 20 },
    .{ .text = "alpha beta", .width = 6 },
    .{ .text = "alpha", .width = 0 },
    .{ .text = "aaaa bbbb cccc dddd", .width = 9 },
    .{ .text = "aaaaaaaa bbb", .width = 4 },
    .{ .text = "ab   cd", .width = 5 },
    .{ .text = "héllo wörld foo", .width = 4 },
    .{ .text = "   ", .width = 3 },
    .{ .text = "a b c d e f g", .width = 1 },
    .{ .text = "⠋⠙⠹\xe2", .width = 3 },
    .{ .text = "bad \x80\x81 bytes \xff end", .width = 8 },
    .{ .text = "one\ntwo\nthree", .width = 4 },
    .{ .text = "a\n\nb", .width = 4 },
};

test "layout keeps the word that follows a break whole for every caret" {
    const alloc = std.testing.allocator;
    const text = "a aaaaaaaaa";
    for (0..text.len + 1) |pos| {
        var l = try layout(alloc, text, pos, 10, .{}, .{ .fg = .red }, null);
        defer l.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), l.rows.items.len);
        try expectRowText(alloc, &l.rows.items[0], "a ");
        try expectRowText(alloc, &l.rows.items[1], if (pos == text.len) "aaaaaaaaa " else "aaaaaaaaa");
    }
}

test "layout keeps a caret at a row end on that row" {
    const alloc = std.testing.allocator;
    const text = "aaa     bbb     ccc";
    const cases = [_]struct { pos: usize, row: usize, col: usize }{
        .{ .pos = 3, .row = 0, .col = 3 },
        .{ .pos = 11, .row = 1, .col = 3 },
    };
    for (cases) |case| {
        var l = try layout(alloc, text, case.pos, 3, .{}, .{ .fg = .red }, null);
        defer l.deinit(alloc);
        try std.testing.expectEqual(case.row, l.cursor.row);
        try std.testing.expectEqual(case.col, l.cursor.col);
        try expectCursorAt(&l.rows.items[case.row], case.col, .{ .fg = .red });
    }
}

test "verticalTarget moves up from the last row of a dropped space run" {
    const alloc = std.testing.allocator;
    const text = "aaa     bbb     ccc";
    var l = try layout(alloc, text, 19, 3, .{}, .{}, null);
    defer l.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), l.cursor.row);

    const up = verticalTarget(&l, -1, 3) orelse 99;
    try std.testing.expectEqual(@as(usize, 11), up);

    var moved = try layout(alloc, text, up, 3, .{}, .{}, null);
    defer moved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), moved.cursor.row);
    try std.testing.expectEqual(@as(usize, 3), moved.cursor.col);
}

test "layout charges a column for every byte that starts a codepoint" {
    const alloc = std.testing.allocator;
    const text = "bad \x80\x81 bytes \xff end";
    var l = try layout(alloc, text, 0, 4, .{}, .{}, null);
    defer l.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 6), displayCols(text[0..6]));
    for (l.rows.items, l.ranges.items) |*row, r| {
        try expectRowText(alloc, row, text[r.start..r.end]);
        try std.testing.expectEqual(displayCols(text[r.start..r.end]), r.cols);
    }
}

test "layout keeps the caret column inside its own row" {
    const alloc = std.testing.allocator;
    for (wrap_cases) |case| {
        for (0..case.text.len + 1) |pos| {
            var l = try layout(alloc, case.text, pos, case.width, .{}, .{ .fg = .red }, null);
            defer l.deinit(alloc);
            if (l.ranges.items.len == 0) continue;
            try std.testing.expect(l.cursor.col <= l.ranges.items[l.cursor.row].cols);
        }
    }

    const text = "\xe2\xe2\xe2";
    var l = try layout(alloc, text, 2, 1, .{}, .{ .fg = .red }, null);
    defer l.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), l.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), l.cursor.col);
    try std.testing.expectEqual(@as(usize, 1), l.ranges.items[0].cols);
}

test "verticalTarget walks wrapped rows and keeps the desired column" {
    const alloc = std.testing.allocator;
    const text = "alpha beta gamma";
    var l = try layout(alloc, text, 2, 12, .{}, .{}, null);
    defer l.deinit(alloc);

    try std.testing.expect(verticalTarget(&l, -1, 2) == null);
    const down = verticalTarget(&l, 1, 2) orelse 99;
    try std.testing.expectEqual(@as(usize, 13), down);

    var moved = try layout(alloc, text, down, 12, .{}, .{}, null);
    defer moved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), moved.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), moved.cursor.col);
    try std.testing.expectEqual(@as(usize, 2), verticalTarget(&moved, -1, 2) orelse 99);
}

test "verticalTarget maps to byte offsets in the source" {
    const alloc = std.testing.allocator;
    var l = try layout(alloc, "abc\ndé\nfgh", 1, 80, .{}, .{}, null);
    defer l.deinit(alloc);

    const down = verticalTarget(&l, 1, 0) orelse 99;
    try std.testing.expectEqual(@as(usize, 4), down);
    try std.testing.expect(verticalTarget(&l, -1, 0) == null);

    var moved = try layout(alloc, "abc\ndé\nfgh", down, 80, .{}, .{}, null);
    defer moved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), moved.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), verticalTarget(&moved, -1, 0) orelse 99);
}
