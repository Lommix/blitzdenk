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
