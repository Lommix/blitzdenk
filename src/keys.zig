const std = @import("std");
const tui = @import("tui/root.zig");

pub const Action = union(enum) {
    exit,
    scroll_down,
    scroll_up,
    retry,
    cancel,
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    history_prev,
    history_next,
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
        KeyBind{ .key = .{ .mods = .{ .shift = true }, .code = .arrow_up }, .action = .history_prev },
        KeyBind{ .key = .{ .mods = .{ .shift = true }, .code = .arrow_down }, .action = .history_next },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'u' } }, .action = .scroll_up },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'd' } }, .action = .scroll_down },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'c' } }, .action = .exit },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'r' } }, .action = .retry },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'n' } }, .action = .completion_next },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'p' } }, .action = .completion_prev },
        KeyBind{ .key = .{ .mods = .{ .ctrl = true }, .code = .{ .char = 'y' } }, .action = .completion_accept },
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
        .exit => "quit",
        .scroll_up => "scroll up",
        .scroll_down => "scroll down",
        .retry => "retry",
        .cancel => "cancel",
        .cursor_left => "left",
        .cursor_right => "right",
        .cursor_up => "up",
        .cursor_down => "down",
        .history_prev => "hist prev",
        .history_next => "hist next",
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
