const std = @import("std");

pub const EMPTY_PROMPT_LABEL = "<no prompt saved>";

pub const Row = struct {
    id: []const u8,
    date: []const u8,
    prompt: []const u8,
};

pub const new_session = Row{ .id = "", .date = "", .prompt = "New session" };

pub fn isNewSession(row: Row) bool {
    return row.id.len == 0;
}

pub const Picker = struct {
    rows: []const Row = &.{},
    selected: usize = 0,
    scroll: usize = 0,

    pub fn move(self: *Picker, delta: i8) void {
        if (self.rows.len == 0) return;
        const moved = @as(i64, @intCast(self.selected)) + delta;
        self.selected = @intCast(@min(@max(moved, 0), @as(i64, @intCast(self.rows.len - 1))));
    }

    pub fn syncScroll(self: *Picker, visible: usize) void {
        if (visible == 0 or self.rows.len <= visible) {
            self.scroll = 0;
            return;
        }
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected + 1 - visible;
    }

    pub fn pick(self: Picker) ?Row {
        if (self.rows.len == 0) return null;
        return self.rows[self.selected];
    }
};

test "picker move clamps into row bounds" {
    var empty = Picker{};
    empty.move(1);
    try std.testing.expectEqual(@as(usize, 0), empty.selected);

    const rows = [_]Row{
        .{ .id = "a", .date = "d1", .prompt = "p1" },
        .{ .id = "b", .date = "d2", .prompt = "p2" },
    };
    var picker = Picker{ .rows = &rows };
    picker.move(5);
    try std.testing.expectEqual(@as(usize, 1), picker.selected);
    picker.move(-9);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
}

test "picker pick returns the selected row" {
    const rows = [_]Row{
        .{ .id = "a", .date = "d1", .prompt = "p1" },
        .{ .id = "b", .date = "d2", .prompt = "p2" },
    };
    var picker = Picker{ .rows = &rows };
    try std.testing.expectEqualStrings("a", picker.pick().?.id);
    picker.selected = 1;
    try std.testing.expectEqualStrings("b", picker.pick().?.id);
}

test "syncScroll keeps the selection inside the window" {
    const rows = [_]Row{.{ .id = "", .date = "", .prompt = "" }} ** 10;
    var picker = Picker{ .rows = &rows };

    picker.syncScroll(0);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);

    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    picker.move(4);
    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    picker.move(1);
    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 1), picker.scroll);
    picker.move(5);
    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 5), picker.scroll);
    try std.testing.expectEqual(@as(usize, 9), picker.selected);

    picker.move(-9);
    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
}

test "syncScroll resets when every row fits" {
    const rows = [_]Row{
        .{ .id = "a", .date = "", .prompt = "" },
        .{ .id = "b", .date = "", .prompt = "" },
    };
    var picker = Picker{ .rows = &rows, .scroll = 2 };
    picker.syncScroll(5);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
}
