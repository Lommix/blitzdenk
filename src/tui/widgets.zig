const std = @import("std");
const rect = @import("rect.zig");
const cell = @import("cell.zig");
const buffer = @import("buffer.zig");
const icon = @import("icon.zig");

pub const Rect = rect.Rect;
pub const Buffer = buffer.Buffer;
pub const Style = cell.Style;
pub const Cell = cell.Cell;

pub const TAB_WIDTH: u16 = 4;

// ── Block ──

pub const Borders = packed struct {
    top: bool = true,
    right: bool = true,
    bottom: bool = true,
    left: bool = true,

    pub const all: Borders = .{};
};

fn decodeCp(comptime s: []const u8) u21 {
    return std.unicode.utf8Decode(s) catch unreachable;
}

pub const BorderSet = struct {
    tl: u21,
    tr: u21,
    bl: u21,
    br: u21,
    h: u21,
    v: u21,

    pub const single: BorderSet = .{
        .tl = decodeCp(icon.box_tl_round),
        .tr = decodeCp(icon.box_tr_round),
        .bl = decodeCp(icon.box_bl_round),
        .br = decodeCp(icon.box_br_round),
        .h = decodeCp(icon.box_h),
        .v = decodeCp(icon.box_v),
    };
};

pub const Block = struct {
    style: Style = .{},
    border_style: Style = .{},
    borders: Borders = .all,
    border_set: BorderSet = .single,

    pub fn innerArea(self: *const Block, area: Rect) Rect {
        const top: u16 = if (self.borders.top) 1 else 0;
        const bottom: u16 = if (self.borders.bottom) 1 else 0;
        const left: u16 = if (self.borders.left) 1 else 0;
        const right: u16 = if (self.borders.right) 1 else 0;
        return area.inner(top, right, bottom, left);
    }

    pub fn render(self: *const Block, area: Rect, buf: *Buffer) void {
        // Fill background
        buf.fill(area, .{ .style = self.style });

        // if (area.width < 2 or area.height < 2) return;

        const bs = self.border_style;
        const set = self.border_set;

        // Top border
        if (self.borders.top) {
            var x = area.x +| 1;
            while (x < area.x +| area.width -| 1) : (x += 1) {
                buf.set(x, area.y, .{ .char = set.h, .style = bs });
            }
        }

        // Bottom border
        if (self.borders.bottom) {
            const bottom_y = area.y +| area.height -| 1;
            var x = area.x +| 1;
            while (x < area.x +| area.width -| 1) : (x += 1) {
                buf.set(x, bottom_y, .{ .char = set.h, .style = bs });
            }
        }

        // Left border
        if (self.borders.left) {
            var y = area.y +| 1;
            while (y < area.y +| area.height -| 1) : (y += 1) {
                buf.set(area.x, y, .{ .char = set.v, .style = bs });
            }
        }

        // Right border
        if (self.borders.right) {
            const right_x = area.x +| area.width -| 1;
            var y = area.y +| 1;
            while (y < area.y +| area.height -| 1) : (y += 1) {
                buf.set(right_x, y, .{ .char = set.v, .style = bs });
            }
        }

        // Corners
        if (self.borders.top and self.borders.left)
            buf.set(area.x, area.y, .{ .char = set.tl, .style = bs });
        if (self.borders.top and self.borders.right)
            buf.set(area.x +| area.width -| 1, area.y, .{ .char = set.tr, .style = bs });
        if (self.borders.bottom and self.borders.left)
            buf.set(area.x, area.y +| area.height -| 1, .{ .char = set.bl, .style = bs });
        if (self.borders.bottom and self.borders.right)
            buf.set(area.x +| area.width -| 1, area.y +| area.height -| 1, .{ .char = set.br, .style = bs });
    }
};

// ── Text ──

pub const Span = struct {
    pub const Kind = enum { text, table_row, table_separator, heading_h1, heading_h2, horizontal_rule };

    content: []const u8,
    style: Style = .{},
    kind: Kind = .text,
    owned: bool = false,

    pub fn widthCols(self: Span) usize {
        return std.unicode.utf8CountCodepoints(self.content) catch self.content.len;
    }
};

/// A horizontal line composed of styled spans.
pub const Line = struct {
    spans: std.ArrayList(Span) = .empty,
    style: Style = .{},

    pub fn new(alloc: std.mem.Allocator, comptime txt: []const u8, args: anytype, style: Style) !Line {
        var l = Line{};
        errdefer l.deinit(alloc);
        try l.pushSpanPrint(alloc, txt, args, style);
        return l;
    }

    pub fn deinit(self: *Line, alloc: std.mem.Allocator) void {
        for (self.spans.items) |span| {
            if (span.owned) alloc.free(span.content);
        }
        self.spans.deinit(alloc);
    }
    /// Appends a span. Span's `content` must outlive the Line (not copied).
    pub fn pushSpanPrint(self: *Line, alloc: std.mem.Allocator, comptime txt: []const u8, args: anytype, style: Style) !void {
        const content = try std.fmt.allocPrint(alloc, txt, args);
        errdefer alloc.free(content);
        try self.spans.append(alloc, .{
            .content = content,
            .style = style,
            .owned = true,
        });
    }

    /// Appends a span. Span's `content` must outlive the Line (not copied).
    pub fn pushSpan(self: *Line, alloc: std.mem.Allocator, span: Span) !void {
        const content = try alloc.dupe(u8, span.content);
        errdefer alloc.free(content);
        try self.spans.append(alloc, .{
            .content = content,
            .style = span.style,
            .kind = span.kind,
            .owned = true,
        });
    }

    /// Convenience: append a styled text chunk.
    pub fn pushText(self: *Line, alloc: std.mem.Allocator, text: []const u8, style: Style) !void {
        try self.spans.append(alloc, .{ .content = text, .style = style });
    }

    /// Column width (codepoint count across all spans).
    pub fn widthCols(self: *const Line) usize {
        var w: usize = 0;
        for (self.spans.items) |span| w += span.widthCols();
        return w;
    }

    /// Render at (x, y) clipping to max_width columns.
    pub fn render(self: *const Line, x: u16, y: u16, max_width: u16, buf: *Buffer) void {
        var col: u16 = 0;
        for (self.spans.items) |span| {
            if (col >= max_width) break;
            const span_style = if (span.style.fg != .reset or span.style.bg != .reset or
                !span.style.modifier.eql(.{}))
                span.style
            else
                self.style;
            var i: usize = 0;
            while (i < span.content.len) {
                if (col >= max_width) break;
                const len = std.unicode.utf8ByteSequenceLength(span.content[i]) catch break;
                if (i + len > span.content.len) break;
                const cp = std.unicode.utf8Decode(span.content[i..][0..len]) catch break;
                i += len;
                if (cp == '\t') {
                    var k: u16 = 0;
                    while (k < TAB_WIDTH and col < max_width) : (k += 1) {
                        buf.set(x +| col, y, .{ .char = ' ', .style = span_style });
                        col +|= 1;
                    }
                    continue;
                }
                if (cp < 0x20 or cp == 0x7F) continue;
                buf.set(x +| col, y, .{ .char = cp, .style = span_style });
                col +|= 1;
            }
        }
    }
};

fn basicColor(n: u8) cell.Color {
    return switch (n) {
        0 => .black,
        1 => .red,
        2 => .green,
        3 => .yellow,
        4 => .blue,
        5 => .magenta,
        6 => .cyan,
        7 => .white,
        8 => .bright_black,
        9 => .bright_red,
        10 => .bright_green,
        11 => .bright_yellow,
        12 => .bright_blue,
        13 => .bright_magenta,
        14 => .bright_cyan,
        15 => .bright_white,
        else => .reset,
    };
}

fn applySgr(style: *Style, params: []const u8) void {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (p.len == 0) {
            style.* = .{};
            continue;
        }
        const code = std.fmt.parseInt(u16, p, 10) catch continue;
        switch (code) {
            0 => style.* = .{},
            1 => style.modifier.bold = true,
            2 => style.modifier.dim = true,
            3 => style.modifier.italic = true,
            4 => style.modifier.underline = true,
            7 => style.modifier.reverse = true,
            9 => style.modifier.strikethrough = true,
            22 => {
                style.modifier.bold = false;
                style.modifier.dim = false;
            },
            23 => style.modifier.italic = false,
            24 => style.modifier.underline = false,
            27 => style.modifier.reverse = false,
            29 => style.modifier.strikethrough = false,
            39 => style.fg = .reset,
            49 => style.bg = .reset,
            30...37 => style.fg = basicColor(@intCast(code - 30)),
            40...47 => style.bg = basicColor(@intCast(code - 40)),
            90...97 => style.fg = basicColor(@intCast(code - 90 + 8)),
            100...107 => style.bg = basicColor(@intCast(code - 100 + 8)),
            38, 48 => {
                const is_fg = code == 38;
                const mode = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
                if (mode == 5) {
                    const n = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
                    if (is_fg) style.fg = .{ .indexed = n } else style.bg = .{ .indexed = n };
                } else if (mode == 2) {
                    const r = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
                    const g = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
                    const b = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
                    const rgb = cell.Color{ .rgb = .{ .r = r, .g = g, .b = b } };
                    if (is_fg) style.fg = rgb else style.bg = rgb;
                }
            },
            else => {},
        }
    }
}

/// A block of styled lines. Mutable builder.
pub const Text = struct {
    lines: std.ArrayList(Line) = .empty,

    /// Parse ANSI SGR escapes and newlines into styled lines. Style carries across newlines. Content is copied.
    pub fn fromAnsi(alloc: std.mem.Allocator, text: []const u8) !Text {
        var out = Text{};
        var line = Line{};
        errdefer {
            line.deinit(alloc);
            out.deinit(alloc);
        }

        var style: Style = .{};
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\n') {
                if (line.spans.items.len > 0) {
                    try out.lines.append(alloc, line);
                    line = .{};
                }
                i += 1;
                continue;
            }
            if (c == 0x1b) {
                if (i + 1 < text.len and text[i + 1] == '[') {
                    const line_end = std.mem.indexOfAnyPos(u8, text, i + 2, "\x1b\n") orelse text.len;
                    const end = std.mem.indexOfScalarPos(u8, text, i + 2, 'm') orelse line_end;
                    if (end < line_end) {
                        applySgr(&style, text[i + 2 .. end]);
                        i = end + 1;
                        continue;
                    }
                    var j = i + 2;
                    while (j < line_end and text[j] >= 0x30 and text[j] <= 0x3f) : (j += 1) {}
                    if (j < line_end) j += 1;
                    i = j;
                    continue;
                }
                i += 1;
                continue;
            }
            const esc = std.mem.indexOfScalarPos(u8, text, i, 0x1b) orelse text.len;
            const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            const stop = @min(esc, nl);
            if (stop > i) {
                const content = try alloc.dupe(u8, text[i..stop]);
                errdefer alloc.free(content);
                try line.spans.append(alloc, .{ .content = content, .style = style, .owned = true });
            }
            i = stop;
        }

        if (line.spans.items.len > 0) {
            try out.lines.append(alloc, line);
        } else {
            line.deinit(alloc);
        }
        return out;
    }

    pub fn deinit(self: *Text, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(alloc);
        self.lines.deinit(alloc);
    }
};

pub const WrapRow = struct {
    start: usize,
    end: usize,
    cols: usize,
};

const Mark = struct { span: usize, pos: usize };

const Run = struct { end: Mark, cols: usize, bytes: usize };

fn markBefore(a: Mark, b: Mark) bool {
    return a.span < b.span or (a.span == b.span and a.pos < b.pos);
}

fn markPush(cur: *Line, alloc: std.mem.Allocator, spans: []const Span, from: Mark, to: Mark) !void {
    var m = from;
    while (markBefore(m, to)) {
        const content = spans[m.span].content;
        const stop = if (m.span == to.span) to.pos else content.len;
        if (m.pos < stop) try cur.pushSpan(alloc, .{ .content = content[m.pos..stop], .style = spans[m.span].style });
        m = .{ .span = m.span + 1, .pos = 0 };
    }
}

pub fn codepointLen(s: []const u8, i: usize) usize {
    return @min(std.unicode.utf8ByteSequenceLength(s[i]) catch 1, s.len - i);
}

pub fn displayCols(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += codepointLen(s, i);
        cols += 1;
    }
    return cols;
}

fn markScan(spans: []const Span, from: Mark, stop: ?Mark, max_cols: usize, space: ?bool) Run {
    var m = from;
    var take: Run = .{ .end = from, .cols = 0, .bytes = 0 };
    while (take.cols < max_cols and (stop == null or markBefore(m, stop.?))) {
        const content = spans[m.span].content;
        const limit = if (stop) |s| (if (m.span == s.span) s.pos else content.len) else content.len;
        while (m.pos < limit and take.cols < max_cols) {
            const cp = @min(codepointLen(content, m.pos), limit - m.pos);
            const len: usize = if (space) |sp| (if ((content[m.pos] == ' ') == sp) cp else 0) else cp;
            if (len == 0) break;
            m.pos += len;
            take.bytes += len;
            take.cols += 1;
        }
        if (m.pos < limit or m.span + 1 >= spans.len) break;
        take.bytes += content.len - m.pos;
        m = .{ .span = m.span + 1, .pos = 0 };
    }
    take.end = m;
    return take;
}

const WrapState = struct {
    alloc: ?std.mem.Allocator,
    out: ?*std.ArrayList(Line),
    rows: ?*std.ArrayList(WrapRow),
    cur: Line,
    first_width: usize,
    cont_width: usize,
    col: usize = 0,
    row_start: usize = 0,
    src: usize = 0,
    row_count: usize = 0,
    has_content: bool = false,

    fn width(self: *const WrapState) usize {
        return if (self.row_count == 0) self.first_width else self.cont_width;
    }

    fn push(self: *WrapState, spans: []const Span, from: Mark, to: Mark) !void {
        self.has_content = true;
        if (self.out != null) try markPush(&self.cur, self.alloc.?, spans, from, to);
    }

    fn flush(self: *WrapState) !void {
        if (self.out) |out| {
            try out.append(self.alloc.?, self.cur);
            self.cur = .{ .style = self.cur.style };
        }
        if (self.rows) |rows| {
            try rows.append(self.alloc.?, .{ .start = self.row_start, .end = self.src, .cols = self.col });
        }
        self.row_start = self.src;
        self.col = 0;
        self.row_count += 1;
        self.has_content = false;
    }
};

fn wrapRows(
    alloc: ?std.mem.Allocator,
    src: *const Line,
    first_width: usize,
    cont_width: usize,
    out: ?*std.ArrayList(Line),
    rows_out: ?*std.ArrayList(WrapRow),
) !usize {
    if (first_width == 0 and cont_width == 0) return 0;

    var st: WrapState = .{
        .alloc = alloc,
        .out = out,
        .rows = rows_out,
        .cur = .{ .style = src.style },
        .first_width = first_width,
        .cont_width = cont_width,
    };
    errdefer if (st.alloc) |a| st.cur.deinit(a);

    const spans = src.spans.items;
    var si: usize = 0;
    var pos: usize = 0;

    while (si < spans.len) {
        if (pos >= spans[si].content.len) {
            si += 1;
            pos = 0;
            continue;
        }
        const space = spans[si].content[pos] == ' ';
        const from: Mark = .{ .span = si, .pos = pos };
        const run = markScan(spans, from, null, std.math.maxInt(usize), space);
        si = run.end.span;
        pos = run.end.pos;

        const row_width = st.width();
        const fits = run.cols <= row_width -| st.col;
        const placeable = (st.col > 0 or run.cols <= row_width) and (space or run.cols <= row_width);
        if (placeable and st.col > 0 and !fits) {
            try st.flush();
            if (space) {
                st.src += run.bytes;
                st.row_start = st.src;
                continue;
            }
        }
        if (placeable) {
            try st.push(spans, from, run.end);
            st.col += run.cols;
            st.src += run.bytes;
            continue;
        }

        var m = from;
        while (markBefore(m, run.end)) {
            const take = markScan(spans, m, run.end, st.width() -| st.col, null);
            try st.push(spans, m, take.end);
            st.col += take.cols;
            st.src += take.bytes;
            m = take.end;
            if (markBefore(m, run.end)) try st.flush();
        }
    }

    if (st.has_content or spans.len == 0) {
        try st.flush();
    } else if (st.alloc) |a| {
        st.cur.deinit(a);
    }
    return st.row_count;
}

/// Wrap a span-sequence into lines of <= width columns.
/// Word boundaries are spaces. Words longer than width are hard-split.
/// Styles are preserved per sub-span. Caller owns output and must deinit each Line.
pub fn wrapLine(alloc: std.mem.Allocator, src: *const Line, width: usize, out: *std.ArrayList(Line)) !void {
    _ = try wrapRows(alloc, src, width, width, out, null);
}

/// Like wrapLine but the first emitted row uses `first_width` columns; subsequent
/// rows use `cont_width`. Pass equal values for uniform wrapping.
pub fn wrapLineEx(
    alloc: std.mem.Allocator,
    src: *const Line,
    first_width: usize,
    cont_width: usize,
    out: *std.ArrayList(Line),
) !void {
    _ = try wrapRows(alloc, src, first_width, cont_width, out, null);
}

pub fn wrapLineTracked(
    alloc: std.mem.Allocator,
    src: *const Line,
    width: usize,
    out: *std.ArrayList(Line),
    rows: *std.ArrayList(WrapRow),
) !usize {
    return wrapRows(alloc, src, width, width, out, rows);
}

pub fn wrapLineCount(src: *const Line, first_width: usize, cont_width: usize) usize {
    return wrapRows(null, src, first_width, cont_width, null, null) catch 0;
}

fn prependIndent(alloc: std.mem.Allocator, row: *Line, indent: usize) !void {
    const spaces = try alloc.alloc(u8, indent);
    @memset(spaces, ' ');
    errdefer alloc.free(spaces);
    try row.spans.insert(alloc, 0, .{ .content = spaces, .style = row.style, .owned = true });
}

pub fn wrapLineIndented(
    alloc: std.mem.Allocator,
    src: *const Line,
    width: usize,
    indent: usize,
    out: *std.ArrayList(Line),
) !void {
    if (indent == 0 or indent >= width) return wrapLine(alloc, src, width, out);

    var tmp: std.ArrayList(Line) = .empty;
    defer tmp.deinit(alloc);
    try wrapLineEx(alloc, src, width, width - indent, &tmp);
    for (tmp.items, 0..) |*row, idx| {
        if (idx > 0) try prependIndent(alloc, row, indent);
        try out.append(alloc, row.*);
    }
}

test "wrapLine basic word wrap" {
    const alloc = std.testing.allocator;
    var src: Line = .{};
    defer src.deinit(alloc);
    try src.pushText(alloc, "hello world foo bar baz", .{});

    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try wrapLine(alloc, &src, 11, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // "hello world" — 11 cols exactly
    // "foo bar baz"
}

test "Text.fromAnsi parses SGR escapes" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "\x1b[1mread \x1b[0m\x1b[2mpath\x1b[0m");
    defer text.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), text.lines.items.len);
    const spans = text.lines.items[0].spans.items;
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("read ", spans[0].content);
    try std.testing.expect(spans[0].style.modifier.bold);
    try std.testing.expectEqualStrings("path", spans[1].content);
    try std.testing.expect(spans[1].style.modifier.dim);
}

test "Text.fromAnsi parses truecolor and drops unknown codes" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "\x1b[38;2;255;0;128mhi\x1b[99m\x1b[1m!");
    defer text.deinit(alloc);
    const spans = text.lines.items[0].spans.items;
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("hi", spans[0].content);
    try std.testing.expectEqualDeep(cell.Color{ .rgb = .{ .r = 255, .g = 0, .b = 128 } }, spans[0].style.fg);
    try std.testing.expectEqualStrings("!", spans[1].content);
    try std.testing.expect(spans[1].style.modifier.bold);
    try std.testing.expect(!spans[1].style.modifier.dim);
}

test "Text.fromAnsi carries style across newlines" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "\x1b[31mred\nstill red");
    defer text.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), text.lines.items.len);
    try std.testing.expectEqualStrings("red", text.lines.items[0].spans.items[0].content);
    try std.testing.expectEqualDeep(cell.Color.red, text.lines.items[0].spans.items[0].style.fg);
    try std.testing.expectEqualStrings("still red", text.lines.items[1].spans.items[0].content);
    try std.testing.expectEqualDeep(cell.Color.red, text.lines.items[1].spans.items[0].style.fg);
}

test "Text.fromAnsi resets on bare ESC[m and skips lone ESC" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "\x1b[1mbold\x1b[mplain\x1b");
    defer text.deinit(alloc);
    const spans = text.lines.items[0].spans.items;
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("bold", spans[0].content);
    try std.testing.expect(spans[0].style.modifier.bold);
    try std.testing.expectEqualStrings("plain", spans[1].content);
    try std.testing.expect(!spans[1].style.modifier.bold);
}

test "Text.fromAnsi skips truncated escape and does not consume the next escape" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "\x1b[3\n\x1b[31mTimeout reached!");
    defer text.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), text.lines.items.len);
    const spans = text.lines.items[0].spans.items;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("Timeout reached!", spans[0].content);
    try std.testing.expectEqualDeep(cell.Color.red, spans[0].style.fg);
}

test "Text.fromAnsi drops truncated escape at end of text" {
    const alloc = std.testing.allocator;
    var text = try Text.fromAnsi(alloc, "abc\x1b[31");
    defer text.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), text.lines.items.len);
    const spans = text.lines.items[0].spans.items;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("abc", spans[0].content);
}

test "wrapLine preserves per-span styles" {
    const alloc = std.testing.allocator;
    var src: Line = .{};
    defer src.deinit(alloc);
    try src.pushText(alloc, "normal ", .{});
    try src.pushText(alloc, "bold", .{ .modifier = .{ .bold = true } });
    try src.pushText(alloc, " tail", .{});

    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try wrapLine(alloc, &src, 80, &out);
    try std.testing.expect(out.items.len >= 1);
    // bold span must retain its style
    var found_bold = false;
    for (out.items) |*l| for (l.spans.items) |s| {
        if (s.style.modifier.bold) found_bold = true;
    };
    try std.testing.expect(found_bold);
}

test "wrapLine preserves leading indentation" {
    const alloc = std.testing.allocator;
    var src: Line = .{};
    defer src.deinit(alloc);
    try src.pushText(alloc, "    indented line", .{}); // 4 spaces lead

    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try wrapLine(alloc, &src, 80, &out);
    // first line's first span should start with 4 spaces
    try std.testing.expect(out.items.len >= 1);
    const first_spans = out.items[0].spans.items;
    try std.testing.expect(first_spans.len >= 1);
    try std.testing.expectEqualStrings("    ", first_spans[0].content);
}

test "wrapLine hard-splits long word" {
    const alloc = std.testing.allocator;
    var src: Line = .{};
    defer src.deinit(alloc);
    try src.pushText(alloc, "aaaaaaaaaaaaaaa", .{}); // 15 chars, width 5

    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try wrapLine(alloc, &src, 5, &out);
    // 15/5 = 3 lines
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
}

test "wrapLine terminates on truncated and invalid utf8" {
    const alloc = std.testing.allocator;
    const exact = [_]struct { text: []const u8, width: usize, rows: []const []const u8 }{
        .{ .text = "⠋⠙⠹\xe2", .width = 3, .rows = &.{ "⠋⠙⠹", "\xe2" } },
        .{ .text = "\xf0\x9f", .width = 3, .rows = &.{"\xf0\x9f"} },
        .{ .text = "\x80\x81\x80", .width = 3, .rows = &.{"\x80\x81\x80"} },
    };
    for (exact) |case| {
        var src: Line = .{};
        defer src.deinit(alloc);
        try src.pushText(alloc, case.text, .{});

        var out: std.ArrayList(Line) = .empty;
        defer {
            for (out.items) |*l| l.deinit(alloc);
            out.deinit(alloc);
        }

        try wrapLine(alloc, &src, case.width, &out);
        try std.testing.expectEqual(case.rows.len, out.items.len);
        for (case.rows, out.items) |want, got| {
            const text = try lineText(alloc, &got);
            defer alloc.free(text);
            try std.testing.expectEqualStrings(want, text);
        }
    }
}

test "wrapLine adds no phantom row after a trailing space run" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, width: usize, rows: []const []const u8 }{
        .{ .text = "ab    ", .width = 3, .rows = &.{"ab"} },
        .{ .text = "ab   ", .width = 3, .rows = &.{"ab"} },
        .{ .text = "abc    ", .width = 3, .rows = &.{"abc"} },
        .{ .text = "日x         ", .width = 9, .rows = &.{"日x"} },
        .{ .text = "b   日 é   a日 ", .width = 2, .rows = &.{ "b", "日 ", "é", "a日" } },
        .{ .text = "a b ", .width = 2, .rows = &.{ "a ", "b " } },
        .{ .text = "   ", .width = 3, .rows = &.{"   "} },
        .{ .text = "", .width = 3, .rows = &.{} },
        .{ .text = "hello world", .width = 4, .rows = &.{ "hell", "o wo", "rld" } },
        .{ .text = "aaaaaaaaaa", .width = 4, .rows = &.{ "aaaa", "aaaa", "aa" } },
        .{ .text = "日本語 テスト end", .width = 8, .rows = &.{ "日本語 テスト ", "end" } },
        .{ .text = "██████╗ ██╗", .width = 11, .rows = &.{"██████╗ ██╗"} },
        .{ .text = "██████╗ ██╗ ███████╗███╗   ██╗", .width = 100, .rows = &.{"██████╗ ██╗ ███████╗███╗   ██╗"} },
    };
    for (cases) |case| {
        var src: Line = .{};
        defer src.deinit(alloc);
        try src.pushText(alloc, case.text, .{});

        var out: std.ArrayList(Line) = .empty;
        defer {
            for (out.items) |*l| l.deinit(alloc);
            out.deinit(alloc);
        }

        try wrapLine(alloc, &src, case.width, &out);
        try std.testing.expectEqual(case.rows.len, out.items.len);
        try std.testing.expectEqual(case.rows.len, wrapLineCount(&src, case.width, case.width));
        for (case.rows, out.items) |want, got| {
            const text = try lineText(alloc, &got);
            defer alloc.free(text);
            try std.testing.expectEqualStrings(want, text);
        }
    }

    var empty: Line = .{};
    defer empty.deinit(alloc);
    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }
    try wrapLine(alloc, &empty, 3, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "wrapLineIndented indents wrapped list continuation rows" {
    const alloc = std.testing.allocator;
    var src: Line = .{};
    defer src.deinit(alloc);
    try src.pushText(alloc, "• ", .{ .fg = .cyan });
    try src.pushText(alloc, "hello world foo bar baz", .{});

    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try wrapLineIndented(alloc, &src, 11, 2, &out);
    try std.testing.expect(out.items.len > 1);
    try std.testing.expectEqualStrings("•", out.items[0].spans.items[0].content);
    try std.testing.expectEqualStrings("  ", out.items[1].spans.items[0].content);
    try std.testing.expectEqual(@as(usize, out.items.len), wrapLineCount(&src, 11, 9));
}

test "buildParagraphRows indents wrapped list continuation rows" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.pushText(alloc, "• ", .{ .fg = .cyan });
    try line.pushText(alloc, "hello world foo bar baz", .{});

    var lines = [_]Line{line};
    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try buildParagraphRows(alloc, &lines, 11, &out);
    try std.testing.expectEqual(@as(usize, countParagraphRows(&lines, 11)), out.items.len);
    try std.testing.expect(out.items.len > 1);
    try std.testing.expectEqualStrings("  ", out.items[1].spans.items[0].content);
}

test "buildParagraphRows indents wrapped nested list rows" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.pushText(alloc, "  ", .{});
    try line.pushText(alloc, "• ", .{ .fg = .cyan });
    try line.pushText(alloc, "hello world foo bar baz", .{});

    var lines = [_]Line{line};
    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try buildParagraphRows(alloc, &lines, 11, &out);
    try std.testing.expectEqual(@as(usize, countParagraphRows(&lines, 11)), out.items.len);
    try std.testing.expect(out.items.len > 1);
    try std.testing.expectEqualStrings("    ", out.items[1].spans.items[0].content);
}

test "buildParagraphRows indents wrapped blockquote rows" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.pushText(alloc, "  │ ", .{ .fg = .bright_cyan, .modifier = .{ .italic = true } });
    try line.pushText(alloc, "hello world foo bar baz", .{});

    var lines = [_]Line{line};
    var out: std.ArrayList(Line) = .empty;
    defer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }

    try buildParagraphRows(alloc, &lines, 11, &out);
    try std.testing.expectEqual(@as(usize, countParagraphRows(&lines, 11)), out.items.len);
    try std.testing.expect(out.items.len > 1);
    try std.testing.expectEqualStrings("    ", out.items[1].spans.items[0].content);
}

test "Paragraph renders markdown table full width" {
    const alloc = std.testing.allocator;
    var p: Paragraph = .{};
    defer p.deinit(alloc);

    var header: Line = .{};
    try header.pushSpan(alloc, .{ .content = "| Name | Value |", .kind = .table_row });
    try p.lines.append(alloc, header);

    var sep: Line = .{};
    try sep.pushSpan(alloc, .{ .content = "| --- | ---: |", .kind = .table_separator });
    try p.lines.append(alloc, sep);

    var body: Line = .{};
    try body.pushSpan(alloc, .{ .content = "| a | 1 |", .kind = .table_row });
    try p.lines.append(alloc, body);

    try std.testing.expectEqual(@as(u16, 3), p.totalHeight(20));

    var buf = try Buffer.init(alloc, .{ .x = 0, .y = 0, .width = 20, .height = 3 });
    defer buf.deinit();
    p.renderSimple(alloc, .{ .x = 0, .y = 0, .width = 20, .height = 3 }, &buf);

    try std.testing.expectEqual(@as(u21, '│'), buf.get(0, 0).char);
    try std.testing.expectEqual(@as(u21, '│'), buf.get(19, 0).char);
    try std.testing.expectEqual(@as(u21, '─'), buf.get(0, 1).char);
    try std.testing.expectEqual(@as(u21, '─'), buf.get(19, 1).char);
    try std.testing.expectEqual(@as(u21, '│'), buf.get(0, 2).char);
    try std.testing.expectEqual(@as(u21, '│'), buf.get(19, 2).char);
}

test "Paragraph table wraps cells and measures expanded rows" {
    const alloc = std.testing.allocator;
    var p: Paragraph = .{};
    defer p.deinit(alloc);
    const texts = [_][]const u8{
        "| Long heading | B |",
        "| --- | --- |",
        "| alpha beta gamma | ééééééééééé |",
        "| tail | |",
    };
    for (texts, 0..) |text, i| {
        var line: Line = .{};
        try line.pushSpan(alloc, .{ .content = text, .kind = if (i == 1) .table_separator else .table_row });
        try p.lines.append(alloc, line);
    }
    for ([_]u16{ 17, 20, 40 }) |width| {
        var rows: std.ArrayList(Line) = .empty;
        defer {
            for (rows.items) |*row| row.deinit(alloc);
            rows.deinit(alloc);
        }
        try buildParagraphRows(alloc, p.lines.items, width, &rows);
        try std.testing.expectEqual(rows.items.len, p.totalHeightLong(width));
        for (rows.items) |*row| try std.testing.expectEqual(@as(usize, width), row.widthCols());
        if (width == 17) {
            const expected = [_][]const u8{
                "│ Long  │ B     │",
                "│ headi │       │",
                "│ ng    │       │",
                "─────────────────",
                "│ alpha │ ééééé │",
                "│ beta  │ ééééé │",
                "│ gamma │ é     │",
                "│ tail  │       │",
            };
            try std.testing.expectEqual(expected.len, rows.items.len);
            for (rows.items, expected) |*row, want| {
                const text = try lineText(alloc, row);
                defer alloc.free(text);
                try std.testing.expectEqualStrings(want, text);
            }
            try std.testing.expect(rows.items[1].spans.items[2].style.modifier.bold);
        }
    }
}

test "Paragraph prewrap leaves the paragraph intact when the inner width is zero" {
    const alloc = std.testing.allocator;
    var p: Paragraph = .{};
    defer p.deinit(alloc);
    try p.appendText(alloc, "a\nb", .{});
    const lines_ptr = p.lines.items.ptr;
    const lines_len = p.lines.items.len;

    try std.testing.expect(!p.prewrap(alloc, 0));
    try std.testing.expect(p.wrap);
    try std.testing.expect(p.lines.items.ptr == lines_ptr);
    try std.testing.expectEqual(lines_len, p.lines.items.len);
}

test "Paragraph reverse scroll_offset skips bottom rows" {
    const alloc = std.testing.allocator;
    var p: Paragraph = .{ .reverse = true, .scroll_offset = 1 };
    defer p.deinit(alloc);
    try p.appendText(alloc, "a\nb\nc", .{});

    var buf = try Buffer.init(alloc, .{ .width = 4, .height = 2 });
    defer buf.deinit();
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    p.renderSimple(scratch.allocator(), .{ .width = 4, .height = 2 }, &buf);

    try std.testing.expectEqual(@as(u21, 'a'), buf.get(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'b'), buf.get(0, 1).char);
}

// ── Diff ──

pub const DiffLineKind = enum { context, addition, deletion, header };

pub const DiffLine = struct {
    kind: DiffLineKind,
    line_number: ?u32 = null,
    content: []const u8,
};

pub const Padding = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(val: u16) Padding {
        return Padding{ .left = val, .right = val, .top = val, .bottom = val };
    }
};

pub const BorderKind = enum { none, single };
pub const Paragraph = struct {
    /// Per-side toggle. Effective only when `border != .none`.
    pub const Sides = packed struct {
        top: bool = true,
        right: bool = true,
        bottom: bool = true,
        left: bool = true,

        pub const all: Sides = .{};
        pub const off: Sides = .{ .top = false, .right = false, .bottom = false, .left = false };
        pub const left_only: Sides = .{ .top = false, .right = false, .bottom = false, .left = true };
    };

    border: BorderKind = .none,
    sides: Sides = .all,
    /// `style.fg` colors the border glyphs. `style.bg` fills the whole
    /// Paragraph footprint (intersected with clip) and is also used as the
    /// background for content cells whose own span bg is `.reset`
    /// (transparent). Modifier applies to border glyphs only.
    style: Style = .{},
    /// If true, lay out content bottom-up: bottom border at area bottom,
    /// content rows above it, top border on top. Rows that would land above
    /// `area.y` are clipped. In reverse mode, `scroll_offset` skips rows from
    /// the paragraph bottom.
    reverse: bool = false,
    /// Inner spacer between border (or area edge when borderless) and content.
    /// Subtracts from the content area on every side; size calculations
    /// (`innerWidth`, `totalHeight`) include it.
    padding: Padding = .{},
    lines: std.ArrayList(Line) = .empty,
    wrap: bool = true,
    scroll_offset: usize = 0,

    pub fn deinit(self: *Paragraph, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*l| l.deinit(alloc);
        self.lines.deinit(alloc);
    }

    pub fn appendText(self: *Paragraph, alloc: std.mem.Allocator, text: []const u8, style: Style) !void {
        var it = std.mem.splitAny(u8, text, "\n");
        while (it.next()) |line| {
            var l = Line{};
            try l.pushText(alloc, line, style);
            try self.lines.append(alloc, l);
        }
    }

    pub fn appendLineSpan(self: *Paragraph, alloc: std.mem.Allocator, spans: []const Span) !void {
        var line = Line{};
        for (spans) |span| {
            try line.pushSpan(alloc, span);
        }
        try self.lines.append(alloc, line);
    }

    fn borderSet(self: *const Paragraph) ?BorderSet {
        return switch (self.border) {
            .none => null,
            .single => BorderSet.single,
        };
    }

    pub fn inner(self: *const Paragraph, area: Rect) Rect {
        var a = area;
        a.x += self.padding.left;
        a.y += self.padding.top;
        a.width -= (self.padding.right + self.padding.left);
        a.height -= (self.padding.top + self.padding.bottom);
        return a;
    }

    /// Effective sides (off entirely when border kind is .none).
    fn effectiveSides(self: *const Paragraph) Sides {
        return if (self.border == .none) Sides.off else self.sides;
    }

    fn innerWidth(self: *const Paragraph, width: u16) u16 {
        const s = self.effectiveSides();
        var sub: u16 = 0;
        if (s.left) sub += 1;
        if (s.right) sub += 1;
        sub +|= self.padding.left;
        sub +|= self.padding.right;
        return width -| sub;
    }

    fn topRows(self: *const Paragraph) u16 {
        const border: u16 = if (self.effectiveSides().top) 1 else 0;
        return border +| self.padding.top;
    }

    fn bottomRows(self: *const Paragraph) u16 {
        const border: u16 = if (self.effectiveSides().bottom) 1 else 0;
        return border +| self.padding.bottom;
    }

    /// Total visual height after wrapping, including border rows. Caller uses
    /// this to size the area before render.
    pub fn totalHeightLong(self: *const Paragraph, width: u16) usize {
        const border_rows: u16 = self.topRows() + self.bottomRows();
        if (!self.wrap) return @as(usize, border_rows) + self.lines.items.len;
        const inner_w = self.innerWidth(width);
        if (inner_w == 0) return border_rows;

        const rows = countParagraphRows(self.lines.items, inner_w);
        return @as(usize, border_rows) + rows;
    }

    pub fn totalHeight(self: *const Paragraph, width: u16) u16 {
        return @intCast(@min(self.totalHeightLong(width), std.math.maxInt(u16)));
    }

    pub fn prewrap(self: *Paragraph, alloc: std.mem.Allocator, width: u16) bool {
        if (!self.wrap) return true;
        const inner_w = self.innerWidth(width);
        if (inner_w == 0) return false;
        var wrapped: std.ArrayList(Line) = .empty;
        buildParagraphRows(alloc, self.lines.items, inner_w, &wrapped) catch return false;
        self.wrap = false;
        self.lines = wrapped;
        return true;
    }

    /// Convenience: render with clip = area. Use `render` directly for cases
    /// where the paragraph footprint extends outside the visible region.
    pub fn renderSimple(self: *const Paragraph, scratch: std.mem.Allocator, area: Rect, buf: *Buffer) void {
        self.render(scratch, area, area, buf);
    }

    /// Render the paragraph at `area`. Writes are restricted to `clip` —
    /// useful when the logical footprint extends outside the visible region
    /// (e.g. reverse-mode bottom-up stacking with timeline scroll offset).
    pub fn render(
        self: *const Paragraph,
        scratch: std.mem.Allocator,
        area: Rect,
        clip: Rect,
        buf: *Buffer,
    ) void {
        if (area.width == 0 or area.height == 0) return;

        const inner_w = self.innerWidth(area.width);

        // Wrap all source lines into a flat list of visual rows.
        var wrapped: std.ArrayList(Line) = .empty;
        defer {
            if (self.wrap) {
                for (wrapped.items) |*row| row.deinit(scratch);
                wrapped.deinit(scratch);
            }
        }
        const rows: []const Line = if (self.wrap) blk: {
            if (inner_w > 0) buildParagraphRows(scratch, self.lines.items, inner_w, &wrapped) catch {};
            break :blk wrapped.items;
        } else self.lines.items;

        // Background fill across the area-clip intersection. `.reset` bg
        // means transparent — skip the fill so the terminal default shows.
        if (self.style.bg != .reset) {
            fillBg(buf, area, clip, .{ .bg = self.style.bg });
        }

        const set_opt = self.borderSet();
        const sides = self.effectiveSides();
        const para_bg = self.style.bg;

        // Use signed math because reverse mode may produce negative
        // intermediate values when sub_top < area.y.
        const ax: i32 = @intCast(area.x);
        const ay: i32 = @intCast(area.y);
        const aw: i32 = @intCast(area.width);
        const ah: i32 = @intCast(area.height);
        const left_x: i32 = ax;
        const right_x: i32 = ax + aw - 1;
        const border_left: i32 = if (sides.left) 1 else 0;
        const border_top_h: i32 = if (sides.top) 1 else 0;
        const border_bottom_h: i32 = if (sides.bottom) 1 else 0;
        const pad_left: i32 = @intCast(self.padding.left);
        const pad_top: i32 = @intCast(self.padding.top);
        const pad_bottom: i32 = @intCast(self.padding.bottom);
        const content_x: i32 = ax + border_left + pad_left;
        const top_y: i32 = ay;
        const bottom_y: i32 = ay + ah - 1;
        const content_top: i32 = ay + border_top_h + pad_top;
        const content_bottom: i32 = bottom_y - border_bottom_h - pad_bottom; // last content row y

        if (set_opt) |set| {
            const bs: Style = .{ .fg = self.style.fg, .bg = self.style.bg, .modifier = self.style.modifier };
            // Horizontal edges first; corners are stamped after so they
            // overwrite the H glyph at intersections.
            if (sides.top) {
                var x: i32 = if (sides.left) ax + 1 else ax;
                const x_end: i32 = if (sides.right) right_x else right_x + 1;
                while (x < x_end) : (x += 1) {
                    setClipped(buf, clip, x, top_y, .{ .char = set.h, .style = bs });
                }
            }
            if (sides.bottom) {
                var x: i32 = if (sides.left) ax + 1 else ax;
                const x_end: i32 = if (sides.right) right_x else right_x + 1;
                while (x < x_end) : (x += 1) {
                    setClipped(buf, clip, x, bottom_y, .{ .char = set.h, .style = bs });
                }
            }
            // Corners
            if (sides.top and sides.left) setClipped(buf, clip, left_x, top_y, .{ .char = set.tl, .style = bs });
            if (sides.top and sides.right and aw >= 2) setClipped(buf, clip, right_x, top_y, .{ .char = set.tr, .style = bs });
            if (sides.bottom and sides.left) setClipped(buf, clip, left_x, bottom_y, .{ .char = set.bl, .style = bs });
            if (sides.bottom and sides.right and aw >= 2) setClipped(buf, clip, right_x, bottom_y, .{ .char = set.br, .style = bs });

            // Vertical edges across the full inter-border span (covers padding
            // rows).
            {
                const v_top: i32 = ay + border_top_h;
                const v_end: i32 = bottom_y - border_bottom_h + 1;
                var vy: i32 = v_top;
                while (vy < v_end) : (vy += 1) {
                    if (sides.left) setClipped(buf, clip, left_x, vy, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, vy, .{ .char = set.v, .style = bs });
                }
            }

            // Vertical edges + content rows. Layout is reverse or forward.
            if (self.reverse) {
                const rows_count: i32 = @intCast(rows.len);
                const skip: i32 = @intCast(@min(self.scroll_offset, rows.len));
                var i: i32 = rows_count - 1 - skip;
                var y: i32 = content_bottom;
                while (i >= 0 and y >= content_top) : ({
                    i -= 1;
                    y -= 1;
                }) {
                    const row = &rows[@intCast(i)];
                    if (sides.left) setClipped(buf, clip, left_x, y, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, y, .{ .char = set.v, .style = bs });
                    renderRowClipped(row, content_x, y, inner_w, buf, clip, para_bg);
                }
                // Vertical glyphs above where rows ran out (pad up to content_top).
                while (y >= content_top) : (y -= 1) {
                    if (sides.left) setClipped(buf, clip, left_x, y, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, y, .{ .char = set.v, .style = bs });
                }
            } else {
                const skip: usize = self.scroll_offset;
                const start = @min(skip, rows.len);
                const visible = rows[start..];
                var y: i32 = content_top;
                const y_end: i32 = content_bottom + 1;
                for (visible) |*row| {
                    if (y >= y_end) break;
                    if (sides.left) setClipped(buf, clip, left_x, y, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, y, .{ .char = set.v, .style = bs });
                    renderRowClipped(row, content_x, y, inner_w, buf, clip, para_bg);
                    y += 1;
                }
                // Pad remaining content rows with vertical edges only.
                while (y < y_end) : (y += 1) {
                    if (sides.left) setClipped(buf, clip, left_x, y, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, y, .{ .char = set.v, .style = bs });
                }
            }
            return;
        }

        // No border kind: just lay out rows.
        if (self.reverse) {
            const rows_count: i32 = @intCast(rows.len);
            const skip: i32 = @intCast(@min(self.scroll_offset, rows.len));
            var i: i32 = rows_count - 1 - skip;
            var y: i32 = content_bottom;
            while (i >= 0 and y >= content_top) : ({
                i -= 1;
                y -= 1;
            }) {
                renderRowClipped(&rows[@intCast(i)], content_x, y, inner_w, buf, clip, para_bg);
            }
        } else {
            const skip: usize = self.scroll_offset;
            const start = @min(skip, rows.len);
            const visible = rows[start..];
            var y: i32 = content_top;
            const y_end: i32 = content_bottom + 1;
            for (visible) |*row| {
                if (y >= y_end) break;
                renderRowClipped(row, content_x, y, area.width, buf, clip, para_bg);
                y += 1;
            }
        }
    }
};

pub const TableLineKind = enum { row, separator };

pub fn tableLineKind(line: *const Line) ?TableLineKind {
    for (line.spans.items) |span| switch (span.kind) {
        .table_row => return .row,
        .table_separator => return .separator,
        .text, .heading_h1, .heading_h2, .horizontal_rule => {},
    };
    return null;
}

pub fn listMarkerIndent(line: *const Line) ?usize {
    const spans = line.spans.items;
    if (spans.len == 0) return null;

    var idx: usize = 0;
    var lead: usize = 0;
    if (isAllSpaces(spans[0].content)) {
        lead = std.unicode.utf8CountCodepoints(spans[0].content) catch spans[0].content.len;
        idx += 1;
        if (idx >= spans.len) return null;
    }

    const marker = spans[idx].content;
    if (std.mem.eql(u8, marker, "• ")) {
        return lead + (std.unicode.utf8CountCodepoints(marker) catch marker.len);
    }

    if (marker.len < 3) return null;
    if (marker[marker.len - 2] != '.' or marker[marker.len - 1] != ' ') return null;
    var i: usize = 0;
    while (i < marker.len - 2) : (i += 1) {
        if (!std.ascii.isDigit(marker[i])) return null;
    }
    if (i == 0) return null;
    return lead + marker.len;
}

pub fn blockquoteIndent(line: *const Line) ?usize {
    const spans = line.spans.items;
    if (spans.len == 0) return null;
    const first = spans[0].content;
    if (std.mem.eql(u8, first, "  │ ")) {
        return std.unicode.utf8CountCodepoints(first) catch first.len;
    }
    return null;
}

fn isAllSpaces(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c != ' ') return false;
    return true;
}

fn buildParagraphRows(alloc: std.mem.Allocator, lines: []Line, width: u16, out: *std.ArrayList(Line)) !void {
    var i: usize = 0;
    while (i < lines.len) {
        if (tableLineKind(&lines[i]) == .row and i + 1 < lines.len and tableLineKind(&lines[i + 1]) == .separator) {
            const start = i;
            i += 2;
            while (i < lines.len and tableLineKind(&lines[i]) == .row) : (i += 1) {}
            try appendTableRows(alloc, lines[start..i], width, out);
            continue;
        }

        var tmp: std.ArrayList(Line) = .empty;
        defer tmp.deinit(alloc);
        const indent = listMarkerIndent(&lines[i]) orelse blockquoteIndent(&lines[i]) orelse 0;
        const use_indent = indent > 0 and @as(usize, width) > indent;
        const wrapped = if (use_indent)
            wrapLineIndented(alloc, &lines[i], width, indent, &tmp)
        else
            wrapLine(alloc, &lines[i], width, &tmp);
        wrapped catch {
            try out.append(alloc, .{ .style = lines[i].style });
            i += 1;
            continue;
        };
        if (tmp.items.len == 0) {
            try out.append(alloc, .{ .style = lines[i].style });
        } else {
            for (tmp.items) |row| try out.append(alloc, row);
        }
        i += 1;
    }
}

fn countParagraphRows(lines: []Line, width: u16) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        if (tableLineKind(&lines[i]) == .row and i + 1 < lines.len and tableLineKind(&lines[i + 1]) == .separator) {
            const start = i;
            i += 2;
            while (i < lines.len and tableLineKind(&lines[i]) == .row) : (i += 1) {}
            var scratch = std.heap.stackFallback(4096, std.heap.page_allocator);
            count += layoutTableRows(scratch.get(), lines[start..i], width, null) catch 0;
            continue;
        }

        const indent = listMarkerIndent(&lines[i]) orelse blockquoteIndent(&lines[i]) orelse 0;
        const wrapped = if (indent > 0 and @as(usize, width) > indent)
            wrapLineCount(&lines[i], width, width - indent)
        else
            wrapLineCount(&lines[i], width, width);
        count += if (wrapped == 0) 1 else wrapped;
        i += 1;
    }
    return count;
}

pub fn appendTableRows(alloc: std.mem.Allocator, lines: []Line, width: u16, out: *std.ArrayList(Line)) !void {
    _ = try layoutTableRows(alloc, lines, width, out);
}

fn layoutTableRows(alloc: std.mem.Allocator, lines: []Line, width: u16, out: ?*std.ArrayList(Line)) !usize {
    if (width == 0 or lines.len < 2) return 0;

    const max_cols = 16;
    var col_count: usize = 0;
    for (lines) |*line| {
        if (tableLineKind(line) != .row) continue;
        const text = try lineText(alloc, line);
        defer alloc.free(text);
        col_count = @max(col_count, countTableCells(text));
        col_count = @min(col_count, max_cols);
    }
    if (col_count == 0) return 0;

    var col_widths_buf: [max_cols]usize = undefined;
    const col_widths = col_widths_buf[0..col_count];
    computeTableWidths(width, col_widths);

    var row_index: usize = 0;
    var height: usize = 0;
    for (lines) |*line| {
        const kind = tableLineKind(line) orelse continue;
        switch (kind) {
            .separator => {},
            .row => {
                const text = try lineText(alloc, line);
                defer alloc.free(text);
                const is_header = row_index == 0;
                if (out) |rows| {
                    const start = rows.items.len;
                    try appendFormattedTableRow(alloc, text, col_widths, is_header, rows);
                    if (is_header) try appendTableRule(alloc, width, rows);
                    height += rows.items.len - start;
                } else {
                    var cells = splitTableCells(text);
                    var row_height: usize = 1;
                    for (col_widths) |col_w| {
                        var spans = [_]Span{.{ .content = std.mem.trim(u8, cells.next() orelse "", " \t\r") }};
                        const cell_line: Line = .{ .spans = .{ .items = &spans, .capacity = spans.len } };
                        row_height = @max(row_height, wrapLineCount(&cell_line, col_w, col_w));
                    }
                    height += row_height + @as(usize, if (is_header) 1 else 0);
                }
                row_index += 1;
            },
        }
    }
    return height;
}

pub fn lineText(alloc: std.mem.Allocator, line: *const Line) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (line.spans.items) |span| try out.appendSlice(alloc, span.content);
    return out.toOwnedSlice(alloc);
}

fn countTableCells(text: []const u8) usize {
    var cells = splitTableCells(text);
    var n: usize = 0;
    while (cells.next()) |_| n += 1;
    return n;
}

fn computeTableWidths(width: u16, col_widths: []usize) void {
    const cols = col_widths.len;
    if (cols == 0) return;
    const fixed = cols + 1 + cols * 2;
    const available: usize = if (width > fixed) width - fixed else cols;
    const base = @max(@as(usize, 1), available / cols);
    var rem = available - base * cols;
    for (col_widths) |*w| {
        w.* = base;
        if (rem > 0) {
            w.* += 1;
            rem -= 1;
        }
    }
}

fn appendFormattedTableRow(alloc: std.mem.Allocator, text: []const u8, col_widths: []const usize, is_header: bool, out: *std.ArrayList(Line)) !void {
    const border_style: Style = .{ .fg = .bright_cyan };
    const cell_style: Style = if (is_header) .{ .modifier = .{ .bold = true } } else .{};
    var cells = splitTableCells(text);
    var wrapped: [16]std.ArrayList(Line) = @splat(.empty);
    defer for (&wrapped) |*rows| {
        for (rows.items) |*row| row.deinit(alloc);
        rows.deinit(alloc);
    };
    var height: usize = 1;
    for (col_widths, 0..) |col_w, col| {
        var spans = [_]Span{.{
            .content = std.mem.trim(u8, cells.next() orelse "", " \t\r"),
            .style = cell_style,
        }};
        const cell_line: Line = .{ .spans = .{ .items = &spans, .capacity = spans.len } };
        try wrapLine(alloc, &cell_line, col_w, &wrapped[col]);
        height = @max(height, wrapped[col].items.len);
    }
    for (0..height) |row| {
        var line: Line = .{};
        errdefer line.deinit(alloc);
        try line.pushText(alloc, "│", border_style);
        for (col_widths, 0..) |col_w, col| {
            try line.pushText(alloc, " ", cell_style);
            var used: usize = 0;
            if (row < wrapped[col].items.len) {
                const cell_line = &wrapped[col].items[row];
                for (cell_line.spans.items) |span| try line.pushSpan(alloc, span);
                used = cell_line.widthCols();
            }
            try pushTablePadding(&line, alloc, col_w -| used, cell_style);
            try line.pushText(alloc, " ", cell_style);
            try line.pushText(alloc, "│", border_style);
        }
        try out.append(alloc, line);
    }
}

fn appendTableRule(alloc: std.mem.Allocator, width: u16, out: *std.ArrayList(Line)) !void {
    var line: Line = .{};
    const glyph = "─";
    const rule = try alloc.alloc(u8, @as(usize, width) * glyph.len);
    defer alloc.free(rule);
    var i: usize = 0;
    while (i < width) : (i += 1) {
        @memcpy(rule[i * glyph.len ..][0..glyph.len], glyph);
    }
    try line.pushSpan(alloc, .{ .content = rule, .style = .{ .fg = .bright_cyan } });
    try out.append(alloc, line);
}

fn pushTablePadding(line: *Line, alloc: std.mem.Allocator, width: usize, style: Style) !void {
    if (width == 0) return;
    const pad = try alloc.alloc(u8, width);
    defer alloc.free(pad);
    @memset(pad, ' ');
    try line.pushSpan(alloc, .{ .content = pad, .style = style });
}

const TableCellIter = struct {
    text: []const u8,
    pos: usize,
    end: usize,

    fn next(self: *TableCellIter) ?[]const u8 {
        if (self.pos > self.end) return null;
        const start = self.pos;
        const next_bar = std.mem.indexOfScalarPos(u8, self.text, start, '|') orelse self.end;
        self.pos = next_bar + 1;
        return self.text[start..next_bar];
    }
};

fn splitTableCells(text: []const u8) TableCellIter {
    var start: usize = 0;
    var end: usize = text.len;
    while (start < end and (text[start] == ' ' or text[start] == '\t')) start += 1;
    if (start < end and text[start] == '|') start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;
    if (end > start and text[end - 1] == '|') end -= 1;
    return .{ .text = text, .pos = start, .end = end };
}

/// Write a cell only if (x, y) lies inside `clip`. Coordinates are signed so
/// callers can pass values that may fall outside the buffer/clip without
/// underflow.
fn setClipped(buf: *Buffer, clip: Rect, x: i32, y: i32, c: Cell) void {
    if (x < 0 or y < 0) return;
    if (x > std.math.maxInt(u16) or y > std.math.maxInt(u16)) return;
    const ux: u16 = @intCast(x);
    const uy: u16 = @intCast(y);
    if (!clip.contains(ux, uy)) return;
    buf.set(ux, uy, c);
}

/// Fill the intersection of `area` and `clip` with spaces styled `style`.
fn fillBg(buf: *Buffer, area: Rect, clip: Rect, style: Style) void {
    const x0 = @max(area.x, clip.x);
    const y0 = @max(area.y, clip.y);
    const x1 = @min(area.x +| area.width, clip.x +| clip.width);
    const y1 = @min(area.y +| area.height, clip.y +| clip.height);
    if (x0 >= x1 or y0 >= y1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            buf.set(x, y, .{ .char = ' ', .style = style });
        }
    }
}

/// Render a Line at signed (x, y), clipping to `clip` and to `max_width`
/// columns. Mirrors Line.render but routes every cell write through clip.
/// `para_bg` is the Paragraph background; cells whose effective style.bg is
/// `.reset` (transparent) inherit it so text rows pick up the surrounding
/// Paragraph fill instead of leaving the terminal default.
fn renderRowClipped(row: *const Line, x: i32, y: i32, max_width: u16, buf: *Buffer, clip: Rect, para_bg: cell.Color) void {
    if (y < 0 or y > std.math.maxInt(u16)) return;
    var col: u16 = 0;
    for (row.spans.items) |span| {
        if (col >= max_width) break;
        var span_style = if (span.style.fg != .reset or span.style.bg != .reset or
            !span.style.modifier.eql(.{}))
            span.style
        else
            row.style;
        if (span_style.bg == .reset) span_style.bg = para_bg;
        var i: usize = 0;
        while (i < span.content.len) {
            if (col >= max_width) break;
            const len = std.unicode.utf8ByteSequenceLength(span.content[i]) catch break;
            if (i + len > span.content.len) break;
            const cp = std.unicode.utf8Decode(span.content[i..][0..len]) catch break;
            i += len;
            if (cp == '\t') {
                var k: u16 = 0;
                while (k < TAB_WIDTH and col < max_width) : (k += 1) {
                    setClipped(buf, clip, x + @as(i32, col), y, .{ .char = ' ', .style = span_style });
                    col +|= 1;
                }
                continue;
            }
            if (cp < 0x20 or cp == 0x7F) continue;
            setClipped(buf, clip, x + @as(i32, col), y, .{ .char = cp, .style = span_style });
            col +|= 1;
        }
    }
}
