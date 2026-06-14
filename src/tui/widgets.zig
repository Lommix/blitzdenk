const std = @import("std");
const rect = @import("rect.zig");
const cell = @import("cell.zig");
const buffer = @import("buffer.zig");
const util = @import("text_utils.zig");
const icon = @import("icon.zig");

pub const Rect = rect.Rect;
pub const Buffer = buffer.Buffer;
pub const Style = cell.Style;
pub const Cell = cell.Cell;

pub const TAB_WIDTH: u16 = 4;

// ── Type-erased Widget (dynamic dispatch) ──

pub const Widget = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *const anyopaque, area: Rect, buf: *Buffer) void,
        height: *const fn (ptr: *const anyopaque, width: u16) u16,
    };

    pub fn render(self: Widget, area: Rect, buf: *Buffer) void {
        self.vtable.render(self.ptr, area, buf);
    }

    pub fn from(ptr: anytype) Widget {
        const Ptr = @TypeOf(ptr);
        const T = @typeInfo(Ptr).pointer.child;
        return .{
            .ptr = ptr,
            .vtable = &.{
                .render = &struct {
                    fn call(p: *const anyopaque, area: Rect, buf: *Buffer) void {
                        const self: *const T = @ptrCast(@alignCast(p));
                        self.render(area, buf);
                    }
                }.call,
            },
        };
    }
};

// ── Block ──

pub const Borders = packed struct {
    top: bool = true,
    right: bool = true,
    bottom: bool = true,
    left: bool = true,

    pub const all: Borders = .{};
    pub const none: Borders = .{ .top = false, .right = false, .bottom = false, .left = false };
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
    t_left: u21,
    t_right: u21,

    pub const single: BorderSet = .{
        .tl = decodeCp(icon.box_tl_round),
        .tr = decodeCp(icon.box_tr_round),
        .bl = decodeCp(icon.box_bl_round),
        .br = decodeCp(icon.box_br_round),
        .h = decodeCp(icon.box_h),
        .v = decodeCp(icon.box_v),
        .t_left = decodeCp(icon.box_t_right),
        .t_right = decodeCp(icon.box_t_left),
    };

    pub const double: BorderSet = .{
        .tl = decodeCp(icon.double_box_tl),
        .tr = decodeCp(icon.double_box_tr),
        .bl = decodeCp(icon.double_box_bl),
        .br = decodeCp(icon.double_box_br),
        .h = decodeCp(icon.double_box_h),
        .v = decodeCp(icon.double_box_v),
        .t_left = decodeCp(icon.double_box_t_right),
        .t_right = decodeCp(icon.double_box_t_left),
    };
};

pub const Block = struct {
    pub const TitleAlign = enum {
        left,
        right,
        center,
    };

    title: ?[]const u8 = null,
    title_style: ?Style = .{},
    title_align: TitleAlign = .center,
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

        // Title
        if (self.title) |title| {
            if (self.borders.top and title.len > 0) {
                const max_len = area.width -| 4; // leave room for borders + padding
                const title_len = @min(title.len, max_len);
                const start_x = switch (self.title_align) {
                    .left => area.x +| 2,
                    .right => area.x +| area.width -| 2 -| title_len,
                    .center => area.x +| ((area.width -| title_len) / 2),
                };
                buf.setStringMax(start_x, area.y, title, self.title_style orelse bs, max_len);
            }
        }
    }
};

// ── Text ──

pub const Span = struct {
    pub const Kind = enum { text, table_row, table_separator };

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

    pub fn deinit(self: *Line, alloc: std.mem.Allocator) void {
        for (self.spans.items) |span| {
            if (span.owned) alloc.free(span.content);
        }
        self.spans.deinit(alloc);
    }

    /// Appends a span. Span's `content` must outlive the Line (not copied).
    pub fn pushSpan(self: *Line, alloc: std.mem.Allocator, span: Span) !void {
        try self.spans.append(alloc, .{
            .content = try alloc.dupe(u8, span.content),
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

/// A block of styled lines. Mutable builder.
pub const Text = struct {
    lines: std.ArrayList(Line) = .empty,
    style: Style = .{},

    pub fn deinit(self: *Text, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(alloc);
        self.lines.deinit(alloc);
    }

    pub fn pushLine(self: *Text, alloc: std.mem.Allocator, line: Line) !void {
        try self.lines.append(alloc, line);
    }

    /// Append a span to the last line. Creates a new line if empty.
    pub fn pushSpan(self: *Text, alloc: std.mem.Allocator, span: Span) !void {
        if (self.lines.items.len == 0) try self.lines.append(alloc, .{});
        try self.lines.items[self.lines.items.len - 1].pushSpan(alloc, span);
    }

    pub fn render(self: *const Text, area: Rect, buf: *Buffer) void {
        var y = area.y;
        for (self.lines.items) |*line| {
            if (y >= area.y +| area.height) break;
            line.render(area.x, y, area.width, buf);
            y += 1;
        }
    }
};

/// Wrap a span-sequence into lines of <= width columns.
/// Word boundaries are spaces. Words longer than width are hard-split.
/// Styles are preserved per sub-span. Caller owns output and must deinit each Line.
pub fn wrapLine(alloc: std.mem.Allocator, src: *const Line, width: usize, out: *std.ArrayList(Line)) !void {
    return wrapLineEx(alloc, src, width, width, out);
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
    if (first_width == 0 and cont_width == 0) return;

    var cur: Line = .{ .style = src.style };
    errdefer cur.deinit(alloc);
    var col: usize = 0;
    var emitted: usize = 0;
    const startWidth = struct {
        fn f(em: usize, fw: usize, cw: usize) usize {
            return if (em == 0) fw else cw;
        }
    }.f;
    var width = startWidth(emitted, first_width, cont_width);

    for (src.spans.items) |span| {
        var pos: usize = 0;
        while (pos < span.content.len) {
            const is_space = span.content[pos] == ' ';
            var end = pos + 1;
            while (end < span.content.len and (span.content[end] == ' ') == is_space) end += 1;
            const run = span.content[pos..end];
            pos = end;

            const run_cols = std.unicode.utf8CountCodepoints(run) catch run.len;

            if (is_space) {
                if (col > 0 and col + run_cols > width) {
                    try out.append(alloc, cur);
                    cur = .{ .style = src.style };
                    col = 0;
                    emitted += 1;
                    width = startWidth(emitted, first_width, cont_width);
                    continue;
                }
                try cur.pushSpan(alloc, .{ .content = run, .style = span.style });
                col += run_cols;
                continue;
            }

            if (run_cols <= width) {
                if (col + run_cols > width) {
                    try out.append(alloc, cur);
                    cur = .{ .style = src.style };
                    col = 0;
                    emitted += 1;
                    width = startWidth(emitted, first_width, cont_width);
                }
                try cur.pushSpan(alloc, .{ .content = run, .style = span.style });
                col += run_cols;
            } else {
                var bi: usize = 0;
                while (bi < run.len) {
                    const remaining = width -| col;
                    var take_bytes: usize = 0;
                    var take_cols: usize = 0;
                    while (bi + take_bytes < run.len and take_cols < remaining) {
                        const len = std.unicode.utf8ByteSequenceLength(run[bi + take_bytes]) catch 1;
                        if (bi + take_bytes + len > run.len) break;
                        take_bytes += len;
                        take_cols += 1;
                    }
                    if (take_cols == 0) {
                        try out.append(alloc, cur);
                        cur = .{ .style = src.style };
                        col = 0;
                        emitted += 1;
                        width = startWidth(emitted, first_width, cont_width);
                        continue;
                    }
                    try cur.pushSpan(alloc, .{ .content = run[bi .. bi + take_bytes], .style = span.style });
                    col += take_cols;
                    bi += take_bytes;
                    if (col >= width and bi < run.len) {
                        try out.append(alloc, cur);
                        cur = .{ .style = src.style };
                        col = 0;
                        emitted += 1;
                        width = startWidth(emitted, first_width, cont_width);
                    }
                }
            }
        }
    }

    if (cur.spans.items.len > 0 or src.spans.items.len == 0) {
        try out.append(alloc, cur);
    } else {
        cur.deinit(alloc);
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

    try std.testing.expectEqual(@as(u16, 3), p.totalHeight(alloc, 20));

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

// ── Diff ──

pub const DiffLineKind = enum { context, addition, deletion, header };

pub const DiffLine = struct {
    kind: DiffLineKind,
    line_number: ?u32 = null,
    content: []const u8,
};

pub const Diff = struct {
    lines: []const DiffLine,
    scroll_offset: usize = 0,
    gutter_width: u16 = 5,

    pub fn render(self: *const Diff, area: Rect, buf: *Buffer) void {
        if (area.height == 0 or area.width == 0) return;

        const height: usize = area.height;
        var row: usize = 0;
        var idx = self.scroll_offset;

        while (idx < self.lines.len and row < height) : ({
            idx += 1;
            row += 1;
        }) {
            const line = self.lines[idx];
            const y = area.y +| @as(u16, @intCast(row));

            // Style based on line kind
            const style: Style = switch (line.kind) {
                .deletion => .{ .fg = .white, .bg = .{ .rgb = .{ .r = 0x3D, .g = 0x01, .b = 0x00 } } },
                .addition => .{ .fg = .white, .bg = .{ .rgb = .{ .r = 0x00, .g = 0x30, .b = 0x10 } } },
                .context => .{},
                .header => .{ .fg = .cyan, .modifier = .{ .bold = true } },
            };

            // Fill entire row background
            var fx = area.x;
            while (fx < area.x +| area.width) : (fx += 1) {
                buf.set(fx, y, .{ .char = ' ', .style = style });
            }

            var x = area.x;

            // Gutter: right-aligned line number
            if (line.line_number) |num| {
                var num_buf: [10]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch "";
                const gw: usize = self.gutter_width -| 1;
                if (num_str.len <= gw) {
                    const pad_x = x +| @as(u16, @intCast(gw - num_str.len));
                    const gutter_style: Style = .{ .fg = .bright_black, .bg = style.bg };
                    buf.setString(pad_x, y, num_str, gutter_style);
                }
            }
            x +|= self.gutter_width;

            // Prefix character
            const prefix: u21 = switch (line.kind) {
                .deletion => '-',
                .addition => '+',
                .context => ' ',
                .header => '@',
            };
            buf.set(x, y, .{ .char = prefix, .style = style });
            x +|= 1;

            // Space after prefix
            x +|= 1;

            // Content (truncated to area width)
            var ci: usize = 0;
            while (ci < line.content.len) {
                if (x >= area.x +| area.width) break;
                const len = std.unicode.utf8ByteSequenceLength(line.content[ci]) catch break;
                if (ci + len > line.content.len) break;
                const cp = std.unicode.utf8Decode(line.content[ci..][0..len]) catch break;
                buf.set(x, y, .{ .char = cp, .style = style });
                x +|= 1;
                ci += len;
            }
        }
    }
};

// ── List ──
pub const ListItem = struct {
    content: Line,
    style: Style = .{},
};

pub const List = struct {
    items: []const ListItem,
    style: Style = .{},
    highlight_style: Style = .{ .modifier = .{ .reverse = true } },
    highlight_symbol: []const u8 = "> ",
    selected: ?usize = null,

    pub fn render(self: *const List, area: Rect, buf: *Buffer) void {
        if (area.height == 0 or area.width == 0) return;

        // Calculate scroll offset to keep selected item visible
        const height: usize = area.height;
        var offset: usize = 0;
        if (self.selected) |sel| {
            if (sel >= height) {
                offset = sel - height + 1;
            }
        }

        var y = area.y;
        var i = offset;
        while (i < self.items.len and y < area.y +| area.height) : (i += 1) {
            const item = self.items[i];
            const is_selected = self.selected != null and self.selected.? == i;

            const base_style = if (is_selected) self.highlight_style else if (item.style.fg != .reset or item.style.bg != .reset) item.style else self.style;

            // Apply row background
            var fill_x = area.x;
            while (fill_x < area.x +| area.width) : (fill_x += 1) {
                buf.set(fill_x, y, .{ .char = ' ', .style = base_style });
            }

            var x = area.x;

            // Draw highlight symbol
            if (is_selected) {
                buf.setString(x, y, self.highlight_symbol, base_style);
                x +|= @as(u16, @intCast(self.highlight_symbol.len));
            } else {
                x +|= @as(u16, @intCast(self.highlight_symbol.len));
            }

            // Draw item content
            for (item.content.spans.items) |span| {
                const style = if (is_selected) base_style else if (span.style.fg != .reset or span.style.bg != .reset) span.style else base_style;

                var si: usize = 0;
                while (si < span.content.len) {
                    if (x >= area.x +| area.width) break;
                    const len = std.unicode.utf8ByteSequenceLength(span.content[si]) catch break;
                    if (si + len > span.content.len) break;
                    const cp = std.unicode.utf8Decode(span.content[si..][0..len]) catch break;
                    buf.set(x, y, .{ .char = cp, .style = style });
                    x +|= 1;
                    si += len;
                }
            }

            y += 1;
        }
    }
};

// ── Input ──

pub const Input = struct {
    text: []const u8,
    border_style: Style = .{},
    text_style: Style = .{},
    focused: bool = true,
    has_screenshot: bool = false,

    pub fn render(self: *const Input, area: Rect, buf: *Buffer) void {
        const block: Block = .{
            .border_style = self.border_style,
            .borders = .{ .bottom = true, .left = true, .right = true },
        };

        const prompt_area: Rect = .{ .x = area.x, .y = area.y, .height = 5, .width = area.width };

        block.render(prompt_area, buf);
        const inner = block.innerArea(prompt_area);

        const input_end = inner.x + inner.width;
        const input_start = inner.x + 2;

        buf.set(inner.x, inner.y, .{ .char = '❯' });

        // Screenshot indicator
        if (self.has_screenshot) {
            const tag = "[IMG]";
            const tag_x: u16 = if (input_end > tag.len + 1) input_end - @as(u16, tag.len + 1) else inner.x;
            for (tag, 0..) |ch, i| {
                buf.set(tag_x +| @as(u16, @intCast(i)), inner.y, .{ .char = ch, .style = .{ .fg = .green } });
            }
        }

        var cx = input_start;
        var cy = inner.y;

        var w_it = util.WrappedTextIter.new(self.text, inner.width - 2);
        while (w_it.next()) |c| {
            if (c == '\n') {
                cx = inner.x + 2;
                cy += 1;
                continue;
            }

            buf.set(cx, cy, .{ .char = c, .style = self.text_style });
            cx += 1;
        }

        if (cx >= input_end) {
            cx = input_start;
            cy += 1;
        }
        buf.set(cx, cy, .{ .char = '_', .style = self.border_style });
    }
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

pub const BorderKind = enum { none, single, double };
pub const Paragraph = struct {
    pub const empty = Paragraph{};

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

    /// If true, vertical-edge glyphs on rows with visible text use T-junctions
    /// (├/┤ for single, ╠/╣ for double); empty rows keep the plain vertical
    /// glyph. Applies to whichever vertical sides are enabled.
    dynamic_border: bool = false,
    border: BorderKind = .none,
    sides: Sides = .all,
    /// `style.fg` colors the border glyphs. `style.bg` fills the whole
    /// Paragraph footprint (intersected with clip) and is also used as the
    /// background for content cells whose own span bg is `.reset`
    /// (transparent). Modifier applies to border glyphs only.
    style: Style = .{},
    /// If true, lay out content bottom-up: bottom border at area bottom,
    /// content rows above it, top border on top. Rows that would land above
    /// `area.y` are clipped. `scroll_offset` is ignored in reverse mode.
    reverse: bool = false,
    /// Inner spacer between border (or area edge when borderless) and content.
    /// Subtracts from the content area on every side; size calculations
    /// (`innerWidth`, `totalHeight`) include it.
    padding: Padding = .{},
    lines: std.ArrayList(Line) = .empty,
    scroll_offset: u16 = 0,

    pub fn deinit(self: *Paragraph, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*l| l.deinit(alloc);
        self.lines.deinit(alloc);
    }

    pub fn appendText(self: *Paragraph, alloc: std.mem.Allocator, text: []const u8) !void {
        var it = std.mem.splitAny(u8, text, "\n");
        while (it.next()) |line| {
            var l = Line{};
            try l.pushText(alloc, line, .{});
            try self.lines.append(alloc, l);
        }
    }

    fn borderSet(self: *const Paragraph) ?BorderSet {
        return switch (self.border) {
            .none => null,
            .single => BorderSet.single,
            .double => BorderSet.double,
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
    pub fn totalHeight(self: *const Paragraph, scratch: std.mem.Allocator, width: u16) u16 {
        const border_rows: u16 = self.topRows() + self.bottomRows();
        const inner_w = self.innerWidth(width);
        if (inner_w == 0) return border_rows;

        var rows: std.ArrayList(Line) = .empty;
        defer {
            for (rows.items) |*row| row.deinit(scratch);
            rows.deinit(scratch);
        }
        buildParagraphRows(scratch, self.lines.items, inner_w, &rows) catch return border_rows;
        return border_rows +| @as(u16, @intCast(@min(rows.items.len, std.math.maxInt(u16))));
    }

    /// Convenience: render with clip = area. Use `render` directly for cases
    /// where the paragraph footprint extends outside the visible region.
    pub fn renderSimple(self: *const Paragraph, scratch: std.mem.Allocator, area: Rect, buf: *Buffer) void {
        self.render(scratch, area, area, buf);
    }

    /// Render the paragraph at `area`. Writes are restricted to `clip` —
    /// useful when the logical footprint extends outside the visible region
    /// (e.g. reverse-mode bottom-up stacking with chat scroll offset).
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
        var rows: std.ArrayList(Line) = .empty;
        defer {
            for (rows.items) |*row| row.deinit(scratch);
            rows.deinit(scratch);
        }
        if (inner_w > 0) {
            buildParagraphRows(scratch, self.lines.items, inner_w, &rows) catch {};
        }

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
            // rows). Content rows below may overdraw with T-junctions when
            // dynamic_border is on.
            {
                const v_top: i32 = ay + border_top_h;
                const v_end: i32 = bottom_y - border_bottom_h + 1;
                var vy: i32 = v_top;
                while (vy < v_end) : (vy += 1) {
                    if (sides.left) setClipped(buf, clip, left_x, vy, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, vy, .{ .char = set.v, .style = bs });
                }
            }

            // Vertical edges + content rows. Each content row is paired with
            // its left/right glyphs so dynamic_border can swap to T-junctions
            // on rows with visible text. Layout is reverse or forward.
            if (self.reverse) {
                const rows_count: i32 = @intCast(rows.items.len);
                var i: i32 = rows_count - 1;
                var y: i32 = content_bottom;
                while (i >= 0 and y >= content_top) : ({
                    i -= 1;
                    y -= 1;
                }) {
                    const row = &rows.items[@intCast(i)];
                    const content_visible = self.dynamic_border and rowHasVisibleContent(row);
                    if (sides.left) {
                        const g: u21 = if (content_visible) set.t_left else set.v;
                        setClipped(buf, clip, left_x, y, .{ .char = g, .style = bs });
                    }
                    if (sides.right and aw >= 2) {
                        const g: u21 = if (content_visible) set.t_right else set.v;
                        setClipped(buf, clip, right_x, y, .{ .char = g, .style = bs });
                    }
                    renderRowClipped(row, content_x, y, inner_w, buf, clip, para_bg);
                }
                // Vertical glyphs above where rows ran out (pad up to content_top).
                while (y >= content_top) : (y -= 1) {
                    if (sides.left) setClipped(buf, clip, left_x, y, .{ .char = set.v, .style = bs });
                    if (sides.right and aw >= 2) setClipped(buf, clip, right_x, y, .{ .char = set.v, .style = bs });
                }
            } else {
                const skip: usize = self.scroll_offset;
                const start = @min(skip, rows.items.len);
                const visible = rows.items[start..];
                var y: i32 = content_top;
                const y_end: i32 = content_bottom + 1;
                for (visible) |*row| {
                    if (y >= y_end) break;
                    const content_visible = self.dynamic_border and rowHasVisibleContent(row);
                    if (sides.left) {
                        const g: u21 = if (content_visible) set.t_left else set.v;
                        setClipped(buf, clip, left_x, y, .{ .char = g, .style = bs });
                    }
                    if (sides.right and aw >= 2) {
                        const g: u21 = if (content_visible) set.t_right else set.v;
                        setClipped(buf, clip, right_x, y, .{ .char = g, .style = bs });
                    }
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
            const rows_count: i32 = @intCast(rows.items.len);
            var i: i32 = rows_count - 1;
            var y: i32 = content_bottom;
            while (i >= 0 and y >= content_top) : ({
                i -= 1;
                y -= 1;
            }) {
                renderRowClipped(&rows.items[@intCast(i)], content_x, y, inner_w, buf, clip, para_bg);
            }
        } else {
            const skip: usize = self.scroll_offset;
            const start = @min(skip, rows.items.len);
            const visible = rows.items[start..];
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

const TableLineKind = enum { row, separator };

fn tableLineKind(line: *const Line) ?TableLineKind {
    for (line.spans.items) |span| switch (span.kind) {
        .table_row => return .row,
        .table_separator => return .separator,
        .text => {},
    };
    return null;
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
        wrapLine(alloc, &lines[i], width, &tmp) catch {
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

fn appendTableRows(alloc: std.mem.Allocator, lines: []Line, width: u16, out: *std.ArrayList(Line)) !void {
    if (width == 0 or lines.len < 2) return;

    const max_cols = 16;
    var col_count: usize = 0;
    for (lines) |*line| {
        if (tableLineKind(line) != .row) continue;
        const text = try lineText(alloc, line);
        defer alloc.free(text);
        col_count = @max(col_count, countTableCells(text));
        col_count = @min(col_count, max_cols);
    }
    if (col_count == 0) return;

    var col_widths_buf: [max_cols]usize = undefined;
    const col_widths = col_widths_buf[0..col_count];
    computeTableWidths(width, col_widths);

    var row_index: usize = 0;
    for (lines) |*line| {
        const kind = tableLineKind(line) orelse continue;
        switch (kind) {
            .separator => {},
            .row => {
                const text = try lineText(alloc, line);
                defer alloc.free(text);
                const is_header = row_index == 0;
                try appendFormattedTableRow(alloc, text, col_widths, is_header, out);
                if (is_header) try appendTableRule(alloc, width, out);
                row_index += 1;
            },
        }
    }
}

fn lineText(alloc: std.mem.Allocator, line: *const Line) ![]u8 {
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
    var line: Line = .{};
    const border_style: Style = .{ .fg = .bright_cyan };
    const cell_style: Style = if (is_header) .{ .modifier = .{ .bold = true } } else .{};
    var cells = splitTableCells(text);

    try line.pushText(alloc, "│", border_style);
    for (col_widths) |col_w| {
        const raw_cell = cells.next() orelse "";
        const cell_text = std.mem.trim(u8, raw_cell, " \t\r");
        try line.pushText(alloc, " ", cell_style);
        try pushPaddedCell(&line, alloc, cell_text, col_w, cell_style);
        try line.pushText(alloc, " ", cell_style);
        try line.pushText(alloc, "│", border_style);
    }
    try out.append(alloc, line);
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

fn pushPaddedCell(line: *Line, alloc: std.mem.Allocator, cell_text: []const u8, width: usize, style: Style) !void {
    var used: usize = 0;
    var end: usize = 0;
    while (end < cell_text.len and used < width) {
        const len = std.unicode.utf8ByteSequenceLength(cell_text[end]) catch break;
        if (end + len > cell_text.len) break;
        end += len;
        used += 1;
    }
    if (end > 0) try line.pushSpan(alloc, .{ .content = cell_text[0..end], .style = style });
    if (used < width) {
        const pad = try alloc.alloc(u8, width - used);
        defer alloc.free(pad);
        @memset(pad, ' ');
        try line.pushSpan(alloc, .{ .content = pad, .style = style });
    }
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

/// True if any span in `row` contains a printable codepoint (not space, tab,
/// or control char).
fn rowHasVisibleContent(row: *const Line) bool {
    for (row.spans.items) |span| {
        var i: usize = 0;
        while (i < span.content.len) {
            const len = std.unicode.utf8ByteSequenceLength(span.content[i]) catch return false;
            if (i + len > span.content.len) return false;
            const cp = std.unicode.utf8Decode(span.content[i..][0..len]) catch return false;
            i += len;
            if (cp == ' ' or cp == '\t') continue;
            if (cp < 0x20 or cp == 0x7F) continue;
            return true;
        }
    }
    return false;
}

/// Command pallet widget
/// ╭──────────── CMD ──────────────╮
/// │ <input field>                 │
/// ├───────────────────────────────┤
/// │ - option                      │
/// │ - option                      │
/// │ - option                      │
/// │ - option                      │
/// │ - option                      │
/// ╰───────────────────────────────╯
pub const CommandPallet = struct {
    input_value: []const u8,
    preview: []const []const u8,
    border: BorderKind = .none,
    style: Style = .{}, // fg = border & text
    padding: Padding = .{},

    fn innerWidth(self: *const CommandPallet, width: u16) u16 {
        const border: u16 = 2;
        const pad: u16 = self.padding.left +| self.padding.right;
        return width -| border -| pad;
    }

    pub fn height(self: *const CommandPallet, width: u16) u16 {
        _ = width;
        return 2 + self.padding.top +| self.padding.bottom +| @as(u16, @intCast(self.preview.len));
    }

    pub fn render(self: *const CommandPallet, area: Rect, buf: *Buffer) void {
        if (area.width == 0 or area.height == 0) return;

        const block: Block = .{
            .title = icon.box_t_left ++ "COMMAND" ++ icon.box_t_right,
            .style = self.style,
            .border_style = self.style,
            .borders = .all,
            .border_set = switch (self.border) {
                .none => BorderSet.single,
                .single => BorderSet.single,
                .double => BorderSet.double,
            },
        };

        block.render(area, buf);
        const inner = block.innerArea(area);
        if (inner.width == 0 or inner.height == 0) return;

        const content_x = inner.x +| self.padding.left;
        const content_w = self.innerWidth(inner.width);
        const content_y = inner.y +| self.padding.top;
        const content_bottom = inner.y +| inner.height -| self.padding.bottom;

        var y = content_y;
        if (y < content_bottom) {
            buf.setStringMax(content_x, y, self.input_value, self.style, content_w);
            y += 1;
        }

        if (y < content_bottom and self.preview.len > 0) {
            const sep_y = y;
            var x: u16 = content_x;
            while (x < content_x +| content_w) : (x += 1) {
                buf.set(x, sep_y, .{ .char = '─', .style = self.style });
            }
            y += 1;
        }

        var i: usize = 0;
        while (i < self.preview.len and y < content_bottom) : (i += 1) {
            buf.setStringMax(content_x + 2, y, self.preview[i], self.style, content_w -| 2);
            buf.set(content_x, y, .{ .char = '-', .style = self.style });
            buf.set(content_x + 1, y, .{ .char = ' ', .style = self.style });
            y += 1;
        }
    }
};

/// Password popup
/// ╭───────── PASSWORD ────────────╮
/// │          ********             │
/// ╰───────────────────────────────╯
pub const PasswordInput = struct {
    input_value: []const u8,
    paragraph: Paragraph = .{
        .border = .single,
    },
};
