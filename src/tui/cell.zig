const std = @import("std");

pub const Color = union(enum) {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    rgb: struct { r: u8, g: u8, b: u8 },
    indexed: u8,

    /// '#232323' ...
    pub fn parseStrHex(str: []const u8) !Color {
        const hex = if (str.len > 0 and str[0] == '#') str[1..] else str;
        if (hex.len != 6) return error.InvalidHexLength;
        const n = try std.fmt.parseInt(u24, hex, 16);
        return .{ .rgb = .{
            .r = @intCast((n >> 16) & 0xFF),
            .g = @intCast((n >> 8) & 0xFF),
            .b = @intCast(n & 0xFF),
        } };
    }

    pub fn ansiFg(self: Color, writer: anytype) !void {
        switch (self) {
            .reset => try writer.writeAll("\x1b[39m"),
            .black => try writer.writeAll("\x1b[30m"),
            .red => try writer.writeAll("\x1b[31m"),
            .green => try writer.writeAll("\x1b[32m"),
            .yellow => try writer.writeAll("\x1b[33m"),
            .blue => try writer.writeAll("\x1b[34m"),
            .magenta => try writer.writeAll("\x1b[35m"),
            .cyan => try writer.writeAll("\x1b[36m"),
            .white => try writer.writeAll("\x1b[37m"),
            .bright_black => try writer.writeAll("\x1b[90m"),
            .bright_red => try writer.writeAll("\x1b[91m"),
            .bright_green => try writer.writeAll("\x1b[92m"),
            .bright_yellow => try writer.writeAll("\x1b[93m"),
            .bright_blue => try writer.writeAll("\x1b[94m"),
            .bright_magenta => try writer.writeAll("\x1b[95m"),
            .bright_cyan => try writer.writeAll("\x1b[96m"),
            .bright_white => try writer.writeAll("\x1b[97m"),
            .rgb => |c| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
            .indexed => |i| try writer.print("\x1b[38;5;{d}m", .{i}),
        }
    }

    pub fn ansiBg(self: Color, writer: anytype) !void {
        switch (self) {
            .reset => try writer.writeAll("\x1b[49m"),
            .black => try writer.writeAll("\x1b[40m"),
            .red => try writer.writeAll("\x1b[41m"),
            .green => try writer.writeAll("\x1b[42m"),
            .yellow => try writer.writeAll("\x1b[43m"),
            .blue => try writer.writeAll("\x1b[44m"),
            .magenta => try writer.writeAll("\x1b[45m"),
            .cyan => try writer.writeAll("\x1b[46m"),
            .white => try writer.writeAll("\x1b[47m"),
            .bright_black => try writer.writeAll("\x1b[100m"),
            .bright_red => try writer.writeAll("\x1b[101m"),
            .bright_green => try writer.writeAll("\x1b[102m"),
            .bright_yellow => try writer.writeAll("\x1b[103m"),
            .bright_blue => try writer.writeAll("\x1b[104m"),
            .bright_magenta => try writer.writeAll("\x1b[105m"),
            .bright_cyan => try writer.writeAll("\x1b[106m"),
            .bright_white => try writer.writeAll("\x1b[107m"),
            .rgb => |c| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
            .indexed => |i| try writer.print("\x1b[48;5;{d}m", .{i}),
        }
    }

    pub fn eql(self: Color, other: Color) bool {
        const Tag = @typeInfo(Color).@"union".tag_type.?;
        const self_tag: Tag = self;
        const other_tag: Tag = other;
        if (self_tag != other_tag) return false;
        return switch (self) {
            .rgb => |a| {
                const b = other.rgb;
                return a.r == b.r and a.g == b.g and a.b == b.b;
            },
            .indexed => |a| a == other.indexed,
            else => true,
        };
    }

    pub fn toHexStr(self: Color) [7]u8 {
        const Rgb = @FieldType(Color, "rgb");
        const rgb: Rgb = switch (self) {
            .rgb => |c| c,
            .reset => Rgb{ .r = 0, .g = 0, .b = 0 },
            .black => Rgb{ .r = 0, .g = 0, .b = 0 },
            .red => Rgb{ .r = 0x80, .g = 0, .b = 0 },
            .green => Rgb{ .r = 0, .g = 0x80, .b = 0 },
            .yellow => Rgb{ .r = 0x80, .g = 0x80, .b = 0 },
            .blue => Rgb{ .r = 0, .g = 0, .b = 0x80 },
            .magenta => Rgb{ .r = 0x80, .g = 0, .b = 0x80 },
            .cyan => Rgb{ .r = 0, .g = 0x80, .b = 0x80 },
            .white => Rgb{ .r = 0xC0, .g = 0xC0, .b = 0xC0 },
            .bright_black => Rgb{ .r = 0x80, .g = 0x80, .b = 0x80 },
            .bright_red => Rgb{ .r = 0xFF, .g = 0, .b = 0 },
            .bright_green => Rgb{ .r = 0, .g = 0xFF, .b = 0 },
            .bright_yellow => Rgb{ .r = 0xFF, .g = 0xFF, .b = 0 },
            .bright_blue => Rgb{ .r = 0, .g = 0, .b = 0xFF },
            .bright_magenta => Rgb{ .r = 0xFF, .g = 0, .b = 0xFF },
            .bright_cyan => Rgb{ .r = 0, .g = 0xFF, .b = 0xFF },
            .bright_white => Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
            .indexed => |i| Rgb{ .r = i, .g = i, .b = i },
        };
        return .{
            '#',
            hexDigit(rgb.r >> 4),
            hexDigit(rgb.r & 0xF),
            hexDigit(rgb.g >> 4),
            hexDigit(rgb.g & 0xF),
            hexDigit(rgb.b >> 4),
            hexDigit(rgb.b & 0xF),
        };
    }

    fn hexDigit(n: u8) u8 {
        return if (n < 10) '0' + n else 'a' + (n - 10);
    }
};

pub const Modifier = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    _pad: u2 = 0,

    pub fn eql(self: Modifier, other: Modifier) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }

    pub fn writeAnsi(self: Modifier, writer: anytype) !void {
        if (self.bold) try writer.writeAll("\x1b[1m");
        if (self.dim) try writer.writeAll("\x1b[2m");
        if (self.italic) try writer.writeAll("\x1b[3m");
        if (self.underline) try writer.writeAll("\x1b[4m");
        if (self.reverse) try writer.writeAll("\x1b[7m");
        if (self.strikethrough) try writer.writeAll("\x1b[9m");
    }
};

pub const Style = struct {
    fg: Color = .reset,
    bg: Color = .reset,
    modifier: Modifier = .{},

    pub fn writeAnsi(self: Style, writer: anytype) !void {
        try writer.writeAll("\x1b[0m");
        if (self.fg != .reset) try self.fg.ansiFg(writer);
        if (self.bg != .reset) try self.bg.ansiBg(writer);
        try self.modifier.writeAnsi(writer);
    }

    pub fn eql(self: Style, other: Style) bool {
        return self.fg.eql(other.fg) and self.bg.eql(other.bg) and self.modifier.eql(other.modifier);
    }
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and self.style.eql(other.style);
    }

    pub fn reset(self: *Cell) void {
        self.* = .{};
    }
};
