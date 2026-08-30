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
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    completion_next,
    completion_prev,
    completion_accept,
    paste_image,
    undo,
    lua: c_int,
};

pub const KeyBind = struct { key: tui.Key, action: Action, description: []const u8 = "" };
pub const KeyMap = struct {
    custom: std.ArrayList(KeyBind) = .empty,

    pub const defaults: []const KeyBind = &.{
        KeyBind{ .key = .{ .code = .tab }, .action = .completion_next },
        KeyBind{ .key = .{ .code = .arrow_left }, .action = .cursor_left },
        KeyBind{ .key = .{ .code = .arrow_right }, .action = .cursor_right },
        KeyBind{ .key = .{ .code = .arrow_up }, .action = .cursor_up },
        KeyBind{ .key = .{ .code = .arrow_down }, .action = .cursor_down },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'u' } }, .action = .scroll_up },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'd' } }, .action = .scroll_down },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'c' } }, .action = .exit },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'r' } }, .action = .retry },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'n' } }, .action = .completion_next },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'p' } }, .action = .completion_prev },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'y' } }, .action = .completion_accept },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'x' } }, .action = .clear_session },
        KeyBind{ .key = .{ .code = .esc }, .action = .cancel },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'v' } }, .action = .paste_image },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'z' } }, .action = .undo },
    };

    pub fn parse(self: *const KeyMap, key: tui.Key) ?Action {
        for (self.custom.items) |bind| if (bind.key.eql(key)) return bind.action;
        for (KeyMap.defaults) |bind| if (bind.key.eql(key)) return bind.action;
        return null;
    }
};

pub fn formatKey(key: tui.Key, buf: []u8) []const u8 {
    var len: usize = 0;
    if (key.mods.ctrl) len += put(buf[len..], "c+");
    if (key.mods.alt) len += put(buf[len..], "m+");
    if (key.mods.shift) len += put(buf[len..], "s+");
    switch (key.code) {
        .char => |c| {
            if (c == ' ') {
                len += put(buf[len..], "space");
            } else {
                buf[len] = c;
                len += 1;
            }
        },
        .enter => len += put(buf[len..], "cr"),
        .backspace => len += put(buf[len..], "bs"),
        .tab => len += put(buf[len..], "tab"),
        .esc => len += put(buf[len..], "esc"),
        .arrow_up => len += put(buf[len..], "↑"),
        .arrow_down => len += put(buf[len..], "↓"),
        .arrow_left => len += put(buf[len..], "←"),
        .arrow_right => len += put(buf[len..], "→"),
        .home => len += put(buf[len..], "home"),
        .end => len += put(buf[len..], "end"),
        .page_up => len += put(buf[len..], "pgup"),
        .page_down => len += put(buf[len..], "pgdn"),
        .insert => len += put(buf[len..], "ins"),
        .delete => len += put(buf[len..], "del"),
        .f1 => len += put(buf[len..], "f1"),
        .f2 => len += put(buf[len..], "f2"),
        .f3 => len += put(buf[len..], "f3"),
        .f4 => len += put(buf[len..], "f4"),
        .f5 => len += put(buf[len..], "f5"),
        .f6 => len += put(buf[len..], "f6"),
        .f7 => len += put(buf[len..], "f7"),
        .f8 => len += put(buf[len..], "f8"),
        .f9 => len += put(buf[len..], "f9"),
        .f10 => len += put(buf[len..], "f10"),
        .f11 => len += put(buf[len..], "f11"),
        .f12 => len += put(buf[len..], "f12"),
    }
    return buf[0..len];
}

pub fn actionName(action: Action) []const u8 {
    return switch (action) {
        .noop => "noop",
        .exit => "quit",
        .scroll_up => "scroll up",
        .scroll_down => "scroll down",
        .clear_session => "clear",
        .retry => "retry",
        .cancel => "cancel",
        .cursor_left => "left",
        .cursor_right => "right",
        .cursor_up => "up",
        .cursor_down => "down",
        .completion_next => "cmp next",
        .completion_prev => "cmp prev",
        .completion_accept => "cmp accept",
        .paste_image => "paste img",
        .undo => "undo",
        .lua => "custom",
    };
}

fn put(buf: []u8, s: []const u8) usize {
    @memcpy(buf[0..s.len], s);
    return s.len;
}

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

test "KeyMap defaults bind ctrl-z to undo" {
    var map = KeyMap{};
    try std.testing.expectEqual(Action.undo, map.parse(.{ .mods = .{ .ctrl = true }, .code = .{ .char = 'z' } }).?);
}

test "KeyMap defaults bind completion actions" {
    var map = KeyMap{};
    try std.testing.expectEqual(Action.completion_next, map.parse(.{ .code = .tab }).?);
    try std.testing.expectEqual(Action.completion_next, map.parse(.{ .mods = .{ .ctrl = true }, .code = .{ .char = 'n' } }).?);
    try std.testing.expectEqual(Action.completion_prev, map.parse(.{ .mods = .{ .ctrl = true }, .code = .{ .char = 'p' } }).?);
    try std.testing.expectEqual(Action.completion_accept, map.parse(.{ .mods = .{ .ctrl = true }, .code = .{ .char = 'y' } }).?);
}

test "formatKey ctrl char" {
    var buf: [16]u8 = undefined;
    const k = parseKeyString("<C-c>").?;
    try std.testing.expectEqualStrings("c+c", formatKey(k, &buf));
}

test "formatKey multi mods" {
    var buf: [16]u8 = undefined;
    const k = parseKeyString("<M-S-a>").?;
    try std.testing.expectEqualStrings("m+s+a", formatKey(k, &buf));
}

test "formatKey named keys" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("esc", formatKey(parseKeyString("<Esc>").?, &buf));
    try std.testing.expectEqualStrings("↑", formatKey(parseKeyString("<Up>").?, &buf));
    try std.testing.expectEqualStrings("f12", formatKey(parseKeyString("<F12>").?, &buf));
    try std.testing.expectEqualStrings("space", formatKey(parseKeyString("<Space>").?, &buf));
    try std.testing.expectEqualStrings("s+tab", formatKey(parseKeyString("<S-Tab>").?, &buf));
}

test "actionName short names" {
    try std.testing.expectEqualStrings("quit", actionName(.exit));
    try std.testing.expectEqualStrings("scroll up", actionName(.scroll_up));
    try std.testing.expectEqualStrings("cmp accept", actionName(.completion_accept));
    try std.testing.expectEqualStrings("custom", actionName(.{ .lua = 3 }));
}
