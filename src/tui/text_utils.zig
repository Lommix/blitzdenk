const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");

pub const Buffer = buffer_mod.Buffer;
pub const Style = cell_mod.Style;
const Color = cell_mod.Color;

pub const WrappedTextIter = struct {
    const Self = @This();
    wit: WordIterator,
    word: ?[]const u8 = null,
    line_width: u16 = 0,
    i: u32 = 0,
    width: u16,

    pub fn new(text: []const u8, width: u16) Self {
        return Self{
            .wit = WordIterator{ .text = text },
            .width = width,
        };
    }

    pub fn next(self: *Self) ?u21 {
        if (self.width == 0) return null;
        const word = self.word orelse blk: {
            const next_word = self.wit.next() orelse return null;
            self.word = next_word;

            if (next_word.len == 1 and next_word[0] == '\n') {
                self.word = null;
                self.line_width = 0;
                return '\n';
            }

            const word_cols = std.unicode.utf8CountCodepoints(next_word) catch next_word.len;
            const is_overflow = self.line_width > 0 and self.line_width + word_cols > self.width;
            if (is_overflow) {
                self.line_width = 0;
                return '\n';
            }

            break :blk next_word;
        };

        if (word.len <= self.i) {
            self.i = 0;
            self.word = null;
            return self.next();
        }

        if (self.line_width >= self.width) {
            self.line_width = 0;
            return '\n';
        }

        const remaining = word[self.i..];
        const cp_len = std.unicode.utf8ByteSequenceLength(remaining[0]) catch {
            self.i += 1;
            return self.next();
        };
        if (remaining.len < cp_len) {
            self.i = @intCast(word.len);
            return self.next();
        }
        const cp = std.unicode.utf8Decode(remaining[0..cp_len]) catch {
            self.i += 1;
            return self.next();
        };
        self.i += @intCast(cp_len);
        self.line_width += 1;

        return cp;
    }
};

// ── Word Iterator ──
pub const WordIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordIterator) ?[]const u8 {
        // skip leading spaces
        while (self.pos < self.text.len and self.text[self.pos] == ' ') {
            self.pos += 1;
        }
        if (self.pos >= self.text.len) return null;

        if (self.text[self.pos] == '\n') {
            self.pos += 1;
            return "\n";
        }

        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != ' ' and self.text[self.pos] != '\n') {
            self.pos += 1;
        }
        // include trailing space as part of word so widths account for gaps
        if (self.pos < self.text.len and self.text[self.pos] == ' ') {
            self.pos += 1;
        }
        return self.text[start..self.pos];
    }
};

// ── Line Iterator ──
pub const LineIterator = struct {
    text: []const u8,
    width: usize,
    pos: usize = 0,
    peeked: ?[]const u8 = null,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.peeked) |p| {
            self.peeked = null;
            return p;
        }
        return self.advance();
    }

    pub fn peek(self: *LineIterator) ?[]const u8 {
        if (self.peeked != null) return self.peeked;
        const result = self.advance();
        self.peeked = result;
        return result;
    }

    fn advance(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const remaining = self.text[self.pos..];

        // Walk codepoints up to self.width columns
        var byte_end: usize = 0;
        var col: usize = 0;
        var last_space_byte: ?usize = null;
        var explicit_break = false;
        while (byte_end < remaining.len and col < self.width) {
            const b = remaining[byte_end];
            if (b == '\n') {
                explicit_break = true;
                break;
            }
            if (b == ' ') last_space_byte = byte_end;
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch break;
            if (byte_end + cp_len > remaining.len) break;
            byte_end += cp_len;
            col += 1;
        }

        var end = byte_end;
        if (byte_end < remaining.len and !explicit_break) {
            // Line exceeds width — break at last space if possible
            if (last_space_byte) |sp| {
                if (sp > 0) end = sp;
            }
        }
        const slice = remaining[0..end];
        self.pos += end;
        if (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\n')) self.pos += 1;
        return slice;
    }
};

// ── Render Helpers ──

/// Render word-wrapped text into the buffer. Continuation rows are indented by
/// `cont_indent` columns. Returns number of rows consumed.
pub fn renderWrappedText(buf: *Buffer, text: []const u8, x: u16, y: u16, width: u16, max_rows: u16, cont_indent: u16, style: Style) u16 {
    if (text.len == 0 or width == 0 or max_rows == 0) return 0;
    var iter = LineIterator{ .text = text, .width = width -| cont_indent };
    var row: u16 = 0;
    while (row < max_rows) : (row += 1) {
        const slice = iter.next() orelse break;
        const ix = if (row == 0) x else x +| cont_indent;
        buf.setStringMax(ix, y +| row, slice, style, width -| cont_indent);
    }
    return row;
}

pub fn wrappedRowCount(text: []const u8, width: usize) u16 {
    if (width == 0) return 0;
    var iter = LineIterator{ .text = text, .width = width };
    var count: u16 = 0;
    while (iter.next() != null) count += 1;
    return count;
}

test "wrapped rows honor newlines" {
    try std.testing.expectEqual(@as(u16, 3), wrappedRowCount("first\nsecond line", 6));
    try std.testing.expectEqual(@as(u16, 3), wrappedRowCount("first\n\nlast", 20));
    try std.testing.expectEqual(@as(u16, 2), wrappedRowCount("first line\nlast", 20));
}

fn expectRowEqual(idx: *usize, expected: []const []const u8, got: []const u8) !void {
    if (idx.* >= expected.len) return error.TooManyRows;
    try std.testing.expectEqualStrings(expected[idx.*], got);
    idx.* += 1;
}

fn expectWrappedRows(text: []const u8, width: u16, expected: []const []const u8) !void {
    var it = WrappedTextIter.new(text, width);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    var idx: usize = 0;
    while (it.next()) |c| {
        if (c == '\n') {
            try expectRowEqual(&idx, expected, row.items);
            row.clearRetainingCapacity();
            continue;
        }
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &utf8) catch return error.InvalidCodepoint;
        try row.appendSlice(std.testing.allocator, utf8[0..n]);
    }
    try expectRowEqual(&idx, expected, row.items);
    try std.testing.expectEqual(expected.len, idx);
}

test "wrapped iter breaks at newlines not around them" {
    try expectWrappedRows("one\ntwo three", 10, &.{ "one", "two three" });
}

test "wrapped iter resets row width on newline" {
    try expectWrappedRows("hi\n0123456789abc", 10, &.{ "hi", "0123456789", "abc" });
}

test "wrapped iter emits single break for full row plus newline" {
    try expectWrappedRows("abcdef\nghij", 6, &.{ "abcdef", "ghij" });
}

test "wrapped iter with zero width yields nothing" {
    var it = WrappedTextIter.new("text", 0);
    try std.testing.expect(it.next() == null);
}

pub fn renderError(buf: *Buffer, last_error: ?anyerror, detail: ?[]const u8, x: u16, y: u16, width: u16, height: u16) void {
    const err_text: []const u8 = if (last_error) |err| @errorName(err) else "unknown error";
    var err_buf: [128]u8 = undefined;
    const display = std.fmt.bufPrint(&err_buf, "Error: {s}", .{err_text}) catch "Error";
    const rows = renderWrappedText(buf, display, x, y, width, @min(height, 2), 0, .{ .fg = .red });
    if (detail) |body| {
        if (body.len > 0 and height > rows + 1) {
            _ = renderWrappedText(buf, body, x, y +| rows +| 1, width, height - rows - 1, 0, .{ .fg = .red });
        }
    }
}

pub fn spinnerDots(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return frames[(frame_count / 6) % frames.len];
}

pub fn spinnerBar(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▁" };
    return frames[(frame_count / 6) % frames.len];
}

pub fn spinnerWave(frame_count: usize) []const u8 {
    const frames = [_][]const u8{
        "▁▂▄▆█▆▄▂▁▂",
        "▂▄▆█▆▄▂▁▂▄",
        "▄▆█▆▄▂▁▂▄▆",
        "▆█▆▄▂▁▂▄▆█",
        "█▆▄▂▁▂▄▆█▆",
        "▆▄▂▁▂▄▆█▆▄",
        "▄▂▁▂▄▆█▆▄▂",
        "▂▁▂▄▆█▆▄▂▁",
    };
    return frames[(frame_count / 6) % frames.len];
}

pub const GradientWaveChunk = struct {
    text: []const u8,
    color: Color,
};

pub const GradientWave = struct {
    text: []const u8,
    from_color: Color,
    to_color: Color,
    frame_count: usize,
    byte_index: usize = 0,
    column_index: usize = 0,

    pub fn next(self: *GradientWave) ?GradientWaveChunk {
        if (self.byte_index >= self.text.len) return null;
        const sequence_length = std.unicode.utf8ByteSequenceLength(self.text[self.byte_index]) catch {
            self.byte_index += 1;
            return self.next();
        };
        if (self.byte_index + sequence_length > self.text.len) return null;
        const slice = self.text[self.byte_index..][0..sequence_length];
        const color = mixColors(self.from_color, self.to_color, waveMix(self.column_index, self.frame_count));
        self.byte_index += sequence_length;
        self.column_index += 1;
        return .{ .text = slice, .color = color };
    }
};

pub fn gradientWave(text: []const u8, from_color: Color, to_color: Color, frame_count: usize) GradientWave {
    return .{
        .text = text,
        .from_color = from_color,
        .to_color = to_color,
        .frame_count = frame_count,
    };
}

fn waveMix(column_index: usize, frame_count: usize) u8 {
    const phase: u8 = @truncate(column_index *% 32 -% frame_count *% 8);
    if (phase < 128) return phase *% 2;
    return (255 - phase) *% 2;
}

fn mixColors(from_color: Color, to_color: Color, mix: u8) Color {
    const from_rgb = from_color.toRgb();
    const to_rgb = to_color.toRgb();
    return .{ .rgb = .{
        .r = mixChannel(from_rgb.r, to_rgb.r, mix),
        .g = mixChannel(from_rgb.g, to_rgb.g, mix),
        .b = mixChannel(from_rgb.b, to_rgb.b, mix),
    } };
}

fn mixChannel(from_value: u8, to_value: u8, mix: u8) u8 {
    const from_wide: u16 = from_value;
    const to_wide: u16 = to_value;
    const mix_wide: u16 = mix;
    return @intCast((from_wide * (255 - mix_wide) + to_wide * mix_wide) / 255);
}

test "gradient wave travels with frame" {
    const from_color = Color{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const to_color = Color{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    var wave_at_start = gradientWave("ab", from_color, to_color, 0);
    var wave_shifted = gradientWave("ab", from_color, to_color, 16);
    const start_color = wave_at_start.next().?.color.toRgb();
    const shifted_color = wave_shifted.next().?.color.toRgb();
    try std.testing.expect(start_color.r != shifted_color.r);
}
