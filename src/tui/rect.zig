const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn area(self: Rect) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }

    pub fn pad(self: Rect, val: u16) Rect {
        return .{
            .x = self.x +| val,
            .y = self.y +| val,
            .width = self.width -| (val *| 2),
            .height = self.height -| (val *| 2),
        };
    }

    pub fn padX(self: Rect, val: u16) Rect {
        return .{
            .x = self.x +| val,
            .y = self.y,
            .width = self.width -| (val *| 2),
            .height = self.height,
        };
    }

    pub fn padY(self: Rect, val: u16) Rect {
        return .{
            .x = self.x,
            .y = self.y +| val,
            .width = self.width,
            .height = self.height -| (val *| 2),
        };
    }

    pub fn inner(self: Rect, top: u16, right: u16, bottom: u16, left: u16) Rect {
        return .{
            .x = self.x +| left,
            .y = self.y +| top,
            .width = self.width -| (left +| right),
            .height = self.height -| (top +| bottom),
        };
    }

    pub fn center(self: Rect, w: u16, h: u16) Rect {
        const x = self.x + (self.width -| w) / 2;
        const y = self.y + (self.height -| h) / 2;
        return .{
            .x = x,
            .y = y,
            .width = w,
            .height = h,
        };
    }

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and y >= self.y and
            x < self.x +| self.width and y < self.y +| self.height;
    }
};

pub const Constraint = union(enum) {
    fixed: u16,
    percent: u8,
    fill,

    pub fn eval(self: Constraint, max: u16) u16 {
        return switch (self) {
            .fixed => |v| @min(v, max),
            .percent => |p| @as(u16, @intCast((@as(u32, max) * @as(u32, p)) / 100)),
            .fill => max,
        };
    }
};

/// Split a rect horizontally (left to right).
pub fn splitRow(rect: Rect, buf: []Rect, constraints: []const Constraint) []Rect {
    std.debug.assert(buf.len >= constraints.len);

    var total_fixed: u16 = 0;
    var fill_count: u16 = 0;

    for (constraints) |c| {
        switch (c) {
            .fixed => |v| total_fixed +|= v,
            .percent => |p| total_fixed +|= @as(u16, @intCast((@as(u32, rect.width) * @as(u32, p)) / 100)),
            .fill => fill_count += 1,
        }
    }

    const remaining = rect.width -| total_fixed;
    const fill_width: u16 = if (fill_count > 0) remaining / fill_count else 0;

    var current_x = rect.x;

    for (constraints, 0..) |c, i| {
        const w: u16 = switch (c) {
            .fixed => |v| @min(v, rect.width),
            .percent => |p| @as(u16, @intCast((@as(u32, rect.width) * @as(u32, p)) / 100)),
            .fill => fill_width,
        };

        buf[i] = .{
            .x = current_x,
            .y = rect.y,
            .width = w,
            .height = rect.height,
        };

        current_x +|= w;
    }

    return buf[0..constraints.len];
}

/// Split a rect vertically (top to bottom, Y-down).
pub fn splitCol(rect: Rect, buf: []Rect, constraints: []const Constraint) []Rect {
    std.debug.assert(buf.len >= constraints.len);

    var total_fixed: u16 = 0;
    var fill_count: u16 = 0;

    for (constraints) |c| {
        switch (c) {
            .fixed => |v| total_fixed +|= v,
            .percent => |p| total_fixed +|= @as(u16, @intCast((@as(u32, rect.height) * @as(u32, p)) / 100)),
            .fill => fill_count += 1,
        }
    }

    const remaining = rect.height -| total_fixed;
    const fill_height: u16 = if (fill_count > 0) remaining / fill_count else 0;

    var current_y = rect.y;

    for (constraints, 0..) |c, i| {
        const h: u16 = switch (c) {
            .fixed => |v| @min(v, rect.height),
            .percent => |p| @as(u16, @intCast((@as(u32, rect.height) * @as(u32, p)) / 100)),
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

// -- Comptime sugar --
pub fn Row(rect: Rect, constraints: anytype) [constraints.len]Rect {
    var out: [constraints.len]Rect = undefined;
    _ = splitRow(rect, &out, &constraints);
    return out;
}

pub fn Col(rect: Rect, constraints: anytype) [constraints.len]Rect {
    var out: [constraints.len]Rect = undefined;
    _ = splitCol(rect, &out, &constraints);
    return out;
}

pub fn Pad(rect: Rect, comptime left: Constraint, comptime right: Constraint, comptime top: Constraint, comptime bottom: Constraint) Rect {
    const row = Row(rect, .{ left, .fill, right });
    const col = Col(row[1], .{ top, .fill, bottom });
    return col[1];
}

pub fn Centered(rect: Rect, comptime width: Constraint, comptime height: Constraint) Rect {
    const row = Row(rect, .{ .fill, width, .fill });
    const col = Col(row[1], .{ .fill, height, .fill });
    return col[1];
}

// -- Tests --

test "constraint eval" {
    const c_fixed: Constraint = .{ .fixed = 10 };
    try std.testing.expectEqual(@as(u16, 10), c_fixed.eval(100));
    try std.testing.expectEqual(@as(u16, 5), c_fixed.eval(5));

    const c_pct: Constraint = .{ .percent = 50 };
    try std.testing.expectEqual(@as(u16, 50), c_pct.eval(100));

    const c_fill: Constraint = .fill;
    try std.testing.expectEqual(@as(u16, 80), c_fill.eval(80));
}

test "splitRow basic" {
    const rect = Rect{ .x = 0, .y = 0, .width = 100, .height = 50 };
    var buf: [3]Rect = undefined;
    const result = splitRow(rect, &buf, &.{ .{ .fixed = 20 }, .fill, .{ .fixed = 30 } });

    try std.testing.expectEqual(@as(u16, 0), result[0].x);
    try std.testing.expectEqual(@as(u16, 20), result[0].width);
    try std.testing.expectEqual(@as(u16, 20), result[1].x);
    try std.testing.expectEqual(@as(u16, 50), result[1].width);
    try std.testing.expectEqual(@as(u16, 70), result[2].x);
    try std.testing.expectEqual(@as(u16, 30), result[2].width);
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

test "Rect pad" {
    const r = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const p = r.pad(2);
    try std.testing.expectEqual(@as(u16, 2), p.x);
    try std.testing.expectEqual(@as(u16, 2), p.y);
    try std.testing.expectEqual(@as(u16, 76), p.width);
    try std.testing.expectEqual(@as(u16, 20), p.height);
}

test "Rect contains" {
    const r = Rect{ .x = 10, .y = 10, .width = 20, .height = 10 };
    try std.testing.expect(r.contains(10, 10));
    try std.testing.expect(r.contains(29, 19));
    try std.testing.expect(!r.contains(30, 10));
    try std.testing.expect(!r.contains(9, 10));
}
