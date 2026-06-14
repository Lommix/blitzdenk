const std = @import("std");
const tui = @import("tui/root.zig");

pub const Action = union(enum) {
    noop,
    exit,
    scroll_down,
    scroll_up,
    clear_session,
    retry,
    cancel,
    open_cmd,
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    toggle_skip,
    lua: c_int,
};

pub const KeyBind = struct { key: tui.Key, action: Action };
pub const KeyMap = struct {
    custom: std.ArrayList(KeyBind) = .empty,

    pub const defaults: []const KeyBind = &.{
        KeyBind{ .key = .{ .code = .arrow_left }, .action = .cursor_left },
        KeyBind{ .key = .{ .code = .arrow_right }, .action = .cursor_right },
        KeyBind{ .key = .{ .code = .arrow_up }, .action = .scroll_up },
        KeyBind{ .key = .{ .code = .arrow_down }, .action = .scroll_down },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'c' } }, .action = .exit },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'r' } }, .action = .retry },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'n' } }, .action = .clear_session },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'z' } }, .action = .open_cmd },
        KeyBind{ .key = .{ .code = .esc }, .action = .cancel },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'g' } }, .action = .toggle_skip },
    };

    pub fn parse(self: *const KeyMap, key: tui.Key) ?Action {
        for (self.custom.items) |bind| if (bind.key.eql(key)) return bind.action;
        for (KeyMap.defaults) |bind| if (bind.key.eql(key)) return bind.action;
        return null;
    }
};

// vim style key bind parsing
// <C-c> <M-S-a> <Esc> <Up> <F1> ...
pub fn parseKeyString(key_str: []const u8) ?tui.Key {
    if (key_str.len == 0) return null;

    // bare single char outside angle brackets
    if (key_str[0] != '<') {
        if (key_str.len != 1) return null;
        const c = key_str[0];
        if (c < 0x20 or c > 0x7E) return null;
        return tui.Key{ .code = .{ .char = c } };
    }

    if (key_str[key_str.len - 1] != '>') return null;
    const inner = key_str[1 .. key_str.len - 1];
    if (inner.len == 0) return null;

    var mods: tui.Terminal.Modifiers = .{};
    var rest = inner;

    // parse modifier prefixes: C-, S-, M-, A-
    while (rest.len >= 2 and rest[1] == '-') {
        switch (rest[0]) {
            'C', 'c' => mods.ctrl = true,
            'S', 's' => mods.shift = true,
            'M', 'm', 'A', 'a' => mods.alt = true,
            else => break,
        }
        rest = rest[2..];
    }

    if (rest.len == 0) return null;

    const code = parseKeyName(rest) orelse return null;

    // ctrl+letter normalize to lowercase (terminal emits lowercase for ctrl-a..z)
    var final_code = code;
    if (mods.ctrl) switch (final_code) {
        .char => |*ch| {
            if (ch.* >= 'A' and ch.* <= 'Z') ch.* = ch.* + ('a' - 'A');
        },
        else => {},
    };

    return tui.Key{ .code = final_code, .mods = mods };
}

fn parseKeyName(name: []const u8) ?tui.Terminal.KeyCode {
    if (name.len == 1) {
        const c = name[0];
        if (c < 0x20 or c > 0x7E) return null;
        return .{ .char = c };
    }

    if (eqlIgnoreCase(name, "esc") or eqlIgnoreCase(name, "escape")) return .esc;
    if (eqlIgnoreCase(name, "enter") or eqlIgnoreCase(name, "return") or eqlIgnoreCase(name, "cr")) return .enter;
    if (eqlIgnoreCase(name, "tab")) return .tab;
    if (eqlIgnoreCase(name, "bs") or eqlIgnoreCase(name, "backspace")) return .backspace;
    if (eqlIgnoreCase(name, "space")) return .{ .char = ' ' };
    if (eqlIgnoreCase(name, "up")) return .arrow_up;
    if (eqlIgnoreCase(name, "down")) return .arrow_down;
    if (eqlIgnoreCase(name, "left")) return .arrow_left;
    if (eqlIgnoreCase(name, "right")) return .arrow_right;
    if (eqlIgnoreCase(name, "home")) return .home;
    if (eqlIgnoreCase(name, "end")) return .end;
    if (eqlIgnoreCase(name, "pageup") or eqlIgnoreCase(name, "pgup")) return .page_up;
    if (eqlIgnoreCase(name, "pagedown") or eqlIgnoreCase(name, "pgdn")) return .page_down;
    if (eqlIgnoreCase(name, "insert") or eqlIgnoreCase(name, "ins")) return .insert;
    if (eqlIgnoreCase(name, "delete") or eqlIgnoreCase(name, "del")) return .delete;
    if (eqlIgnoreCase(name, "lt")) return .{ .char = '<' };
    if (eqlIgnoreCase(name, "gt")) return .{ .char = '>' };

    if ((name[0] == 'F' or name[0] == 'f') and name.len <= 3) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        return switch (n) {
            1 => .f1,
            2 => .f2,
            3 => .f3,
            4 => .f4,
            5 => .f5,
            6 => .f6,
            7 => .f7,
            8 => .f8,
            9 => .f9,
            10 => .f10,
            11 => .f11,
            12 => .f12,
            else => null,
        };
    }

    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + ('a' - 'A') else x;
        const yl = if (y >= 'A' and y <= 'Z') y + ('a' - 'A') else y;
        if (xl != yl) return false;
    }
    return true;
}

test "parseKeyString plain char" {
    const k = parseKeyString("a").?;
    try std.testing.expectEqual(@as(u8, 'a'), k.code.char);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(k.mods)));
}

test "parseKeyString uppercase plain" {
    const k = parseKeyString("A").?;
    try std.testing.expectEqual(@as(u8, 'A'), k.code.char);
}

test "parseKeyString ctrl-c" {
    const k = parseKeyString("<C-c>").?;
    try std.testing.expectEqual(@as(u8, 'c'), k.code.char);
    try std.testing.expect(k.mods.ctrl);
    try std.testing.expect(!k.mods.alt);
    try std.testing.expect(!k.mods.shift);
}

test "parseKeyString ctrl-uppercase normalized" {
    const k = parseKeyString("<C-C>").?;
    try std.testing.expectEqual(@as(u8, 'c'), k.code.char);
    try std.testing.expect(k.mods.ctrl);
}

test "parseKeyString multiple mods" {
    const k = parseKeyString("<M-S-a>").?;
    try std.testing.expectEqual(@as(u8, 'a'), k.code.char);
    try std.testing.expect(k.mods.alt);
    try std.testing.expect(k.mods.shift);
    try std.testing.expect(!k.mods.ctrl);
}

test "parseKeyString A- alias for alt" {
    const k = parseKeyString("<A-x>").?;
    try std.testing.expect(k.mods.alt);
    try std.testing.expectEqual(@as(u8, 'x'), k.code.char);
}

test "parseKeyString esc" {
    const k = parseKeyString("<Esc>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.esc, k.code);
}

test "parseKeyString case insensitive name" {
    const k = parseKeyString("<ESCAPE>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.esc, k.code);
}

test "parseKeyString arrow up" {
    const k = parseKeyString("<Up>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.arrow_up, k.code);
}

test "parseKeyString f1" {
    const k = parseKeyString("<F1>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.f1, k.code);
}

test "parseKeyString f12" {
    const k = parseKeyString("<F12>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.f12, k.code);
}

test "parseKeyString f13 invalid" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString("<F13>"));
}

test "parseKeyString space" {
    const k = parseKeyString("<Space>").?;
    try std.testing.expectEqual(@as(u8, ' '), k.code.char);
}

test "parseKeyString lt gt" {
    const lt = parseKeyString("<lt>").?;
    try std.testing.expectEqual(@as(u8, '<'), lt.code.char);
    const gt = parseKeyString("<gt>").?;
    try std.testing.expectEqual(@as(u8, '>'), gt.code.char);
}

test "parseKeyString cr/return" {
    const k1 = parseKeyString("<CR>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.enter, k1.code);
    const k2 = parseKeyString("<Return>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.enter, k2.code);
}

test "parseKeyString ctrl-shift-up" {
    const k = parseKeyString("<C-S-Up>").?;
    try std.testing.expectEqual(tui.Terminal.KeyCode.arrow_up, k.code);
    try std.testing.expect(k.mods.ctrl);
    try std.testing.expect(k.mods.shift);
}

test "parseKeyString empty" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString(""));
}

test "parseKeyString unterminated" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString("<C-c"));
}

test "parseKeyString empty inner" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString("<>"));
}

test "parseKeyString unknown name" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString("<Foo>"));
}

test "parseKeyString multichar plain rejected" {
    try std.testing.expectEqual(@as(?tui.Key, null), parseKeyString("ab"));
}

test "parseKeyString round-trip with KeyMap defaults" {
    const k = parseKeyString("<C-c>").?;
    var map = KeyMap{};
    try std.testing.expectEqual(Action.exit, map.parse(k).?);
}
