const std = @import("std");
const cell = @import("cell.zig");

pub const Style = cell.Style;

pub const AnsiWriter = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) AnsiWriter {
        return .{ .buf = buf };
    }

    pub fn writeAll(self: *AnsiWriter, text: []const u8) void {
        self.write(text);
    }

    pub fn print(self: *AnsiWriter, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += text.len;
    }

    pub fn styled(self: *AnsiWriter, style: Style, text: []const u8) void {
        var style_buf: [128]u8 = undefined;
        const style_ansi = formatStyle(&style_buf, style);
        if (self.len + style_ansi.len + text.len > self.buf.len) return;
        self.write(style_ansi);
        self.write(text);
    }

    pub fn styledPrint(self: *AnsiWriter, style: Style, comptime fmt: []const u8, args: anytype) void {
        var style_buf: [128]u8 = undefined;
        const style_ansi = formatStyle(&style_buf, style);
        if (self.len + style_ansi.len > self.buf.len) return;
        const text = std.fmt.bufPrint(self.buf[self.len + style_ansi.len ..], fmt, args) catch return;
        self.write(style_ansi);
        self.len += text.len;
    }

    pub fn finish(self: *AnsiWriter) []const u8 {
        self.write("\x1b[0m");
        return self.buf[0..self.len];
    }

    fn write(self: *AnsiWriter, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

fn formatStyle(buf: []u8, style: Style) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    style.writeAnsi(&w) catch return "";
    return w.buffered();
}
