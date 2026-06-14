const std = @import("std");

///Mostly clones `T`. passthrough for function ptr and anything opaque.
pub fn deepClone(comptime T: type, value: T, alloc: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .void, .null, .undefined, .error_set => value,
        .optional => |opt| if (value) |v| try deepClone(opt.child, v, alloc) else null,
        .array => |arr| blk: {
            var out: T = undefined;
            for (value, 0..) |item, i| out[i] = try deepClone(arr.child, item, alloc);
            break :blk out;
        },
        .@"struct" => |s| blk: {
            var out: T = undefined;
            inline for (s.fields) |f| {
                @field(out, f.name) = try deepClone(f.type, @field(value, f.name), alloc);
            }
            break :blk out;
        },
        .@"union" => |u| blk: {
            const Tag = u.tag_type orelse @compileError("deepClone requires tagged union: " ++ @typeName(T));
            switch (@as(Tag, value)) {
                inline else => |tag| {
                    const F = @FieldType(T, @tagName(tag));
                    const cloned = try deepClone(F, @field(value, @tagName(tag)), alloc);
                    break :blk @unionInit(T, @tagName(tag), cloned);
                },
            }
        },
        .pointer => |p| switch (p.size) {
            .one => blk: {
                if (p.child == anyopaque) break :blk value;
                if (@typeInfo(p.child) == .@"fn") break :blk value;
                const dst = try alloc.create(p.child);
                dst.* = try deepClone(p.child, value.*, alloc);
                break :blk dst;
            },
            .slice => blk: {
                const dst = try alloc.alloc(p.child, value.len);
                for (value, 0..) |item, i| dst[i] = try deepClone(p.child, item, alloc);
                break :blk dst;
            },
            else => @compileError("deepClone unsupported pointer size: " ++ @typeName(T)),
        },

        else => @compileError("deepClone unsupported type: " ++ @typeName(T)),
    };
}

test "deepClone primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(@as(u32, 42), try deepClone(u32, 42, a));
    try std.testing.expectEqual(true, try deepClone(bool, true, a));
    try std.testing.expectEqual(@as(?u8, null), try deepClone(?u8, null, a));
    try std.testing.expectEqual(@as(?u8, 7), try deepClone(?u8, 7, a));
}

test "deepClone slice independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src: []const u8 = "hello";
    const dst = try deepClone([]const u8, src, a);
    try std.testing.expectEqualStrings("hello", dst);
    try std.testing.expect(src.ptr != dst.ptr);
}

test "deepClone nested struct with slices" {
    const Inner = struct { name: []const u8, n: u32 };
    const Outer = struct { items: []const Inner, tag: []const u8 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]Inner{ .{ .name = "a", .n = 1 }, .{ .name = "b", .n = 2 } };
    const src = Outer{ .items = &items, .tag = "x" };
    const dst = try deepClone(Outer, src, a);

    try std.testing.expectEqualStrings("x", dst.tag);
    try std.testing.expectEqual(@as(usize, 2), dst.items.len);
    try std.testing.expectEqualStrings("a", dst.items[0].name);
    try std.testing.expect(dst.items.ptr != src.items.ptr);
    try std.testing.expect(dst.items[0].name.ptr != src.items[0].name.ptr);
}

test "deepClone tagged union" {
    const U = union(enum) { num: u32, text: []const u8 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const a1 = try deepClone(U, U{ .num = 5 }, a);
    try std.testing.expectEqual(@as(u32, 5), a1.num);

    const a2 = try deepClone(U, U{ .text = "hi" }, a);
    try std.testing.expectEqualStrings("hi", a2.text);
}
