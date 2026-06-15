const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");

pub const Buffer = buffer_mod.Buffer;
pub const Style = cell_mod.Style;

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

    pub fn peek(self: *Self) ?u21 {
        var s = self.*;
        return s.next();
    }

    pub fn next(self: *Self) ?u21 {
        const word = self.word orelse blk: {
            const next_word = self.wit.next() orelse return null;
            self.word = next_word;

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

        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != ' ') {
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
        while (byte_end < remaining.len and col < self.width) {
            const b = remaining[byte_end];
            if (b == ' ') last_space_byte = byte_end;
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch break;
            if (byte_end + cp_len > remaining.len) break;
            byte_end += cp_len;
            col += 1;
        }

        var end = byte_end;
        if (byte_end < remaining.len) {
            // Line exceeds width — break at last space if possible
            if (last_space_byte) |sp| {
                if (sp > 0) end = sp;
            }
        }
        const slice = remaining[0..end];
        self.pos += end;
        if (self.pos < self.text.len and self.text[self.pos] == ' ') self.pos += 1;
        return slice;
    }
};

// ── Render Helpers ──

/// Render word-wrapped text into the buffer. Returns number of rows consumed.
pub fn renderWrappedText(buf: *Buffer, text: []const u8, x: u16, y: u16, width: u16, max_rows: u16, style: Style) u16 {
    if (text.len == 0 or width == 0 or max_rows == 0) return 0;
    var iter = LineIterator{ .text = text, .width = width };
    var row: u16 = 0;
    while (row < max_rows) : (row += 1) {
        const slice = iter.next() orelse break;
        buf.setStringMax(x, y +| row, slice, style, width);
    }
    return row;
}

pub fn renderError(buf: *Buffer, last_error: ?anyerror, detail: ?[]const u8, x: u16, y: u16, width: u16, height: u16) void {
    const err_text: []const u8 = if (last_error) |err| @errorName(err) else "unknown error";
    var err_buf: [128]u8 = undefined;
    const display = std.fmt.bufPrint(&err_buf, "Error: {s}", .{err_text}) catch "Error";
    const rows = renderWrappedText(buf, display, x, y, width, @min(height, 2), .{ .fg = .red });
    if (detail) |body| {
        if (body.len > 0 and height > rows + 1) {
            _ = renderWrappedText(buf, body, x, y +| rows +| 1, width, height - rows - 1, .{ .fg = .red });
        }
    }
}

pub fn spinnerDots(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return frames[(frame_count / 6) % frames.len];
}

pub fn spinnerBar(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "▁", "▂ ", "▃ ", "▄ ", "▅ ", "▆ ", "▇ ", "█ ", "▇ ", "▆ ", "▅ ", "▄ ", "▃ ", "▁" };
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
