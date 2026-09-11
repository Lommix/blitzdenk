const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn inner(self: Rect, top: u16, right: u16, bottom: u16, left: u16) Rect {
        return .{
            .x = self.x +| left,
            .y = self.y +| top,
            .width = self.width -| (left +| right),
            .height = self.height -| (top +| bottom),
        };
    }

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and y >= self.y and
            x < self.x +| self.width and y < self.y +| self.height;
    }
};

pub const Constraint = union(enum) {
    fixed: u16,
    fill,
};

/// Split a rect vertically (top to bottom, Y-down).
pub fn splitCol(rect: Rect, buf: []Rect, constraints: []const Constraint) []Rect {
    std.debug.assert(buf.len >= constraints.len);

    var total_fixed: u16 = 0;
    var fill_count: u16 = 0;

    for (constraints) |c| {
        switch (c) {
            .fixed => |v| total_fixed +|= v,
            .fill => fill_count += 1,
        }
    }

    const remaining = rect.height -| total_fixed;
    const fill_height: u16 = if (fill_count > 0) remaining / fill_count else 0;

    var current_y = rect.y;

    for (constraints, 0..) |c, i| {
        const h: u16 = switch (c) {
            .fixed => |v| @min(v, rect.height),
            .fill => fill_height,
        };

        buf[i] = .{
            .x = rect.x,
            .y = current_y,
            .width = rect.width,
            .height = h,
        };

        current_y +|= h;
    }

    return buf[0..constraints.len];
}

pub fn Col(rect: Rect, constraints: anytype) [constraints.len]Rect {
    var out: [constraints.len]Rect = undefined;
    _ = splitCol(rect, &out, &constraints);
    return out;
}

test "splitCol top-to-bottom" {
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    var buf: [2]Rect = undefined;
    const result = splitCol(rect, &buf, &.{ .{ .fixed = 3 }, .fill });

    try std.testing.expectEqual(@as(u16, 0), result[0].y);
    try std.testing.expectEqual(@as(u16, 3), result[0].height);
    try std.testing.expectEqual(@as(u16, 3), result[1].y);
    try std.testing.expectEqual(@as(u16, 21), result[1].height);
}

test "Rect contains" {
    const r = Rect{ .x = 10, .y = 10, .width = 20, .height = 10 };
    try std.testing.expect(r.contains(10, 10));
    try std.testing.expect(r.contains(29, 19));
    try std.testing.expect(!r.contains(30, 10));
    try std.testing.expect(!r.contains(9, 10));
}
