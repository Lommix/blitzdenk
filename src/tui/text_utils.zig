const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");

pub const Buffer = buffer_mod.Buffer;
pub const Style = cell_mod.Style;
const Color = cell_mod.Color;

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
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            byte_end += @min(cp_len, remaining.len - byte_end);
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
    while (iter.next() != null) count +|= 1;
    return count;
}

pub fn spinnerDots(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return frames[(frame_count / 6) % frames.len];
}

pub fn spinnerBar(frame_count: usize) []const u8 {
    const frames = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▁" };
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
