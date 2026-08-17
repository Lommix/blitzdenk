const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    table: Table,
};

pub const Table = struct {
    array: std.ArrayListUnmanaged(Value) = .empty,
    map: std.StringHashMapUnmanaged(Value) = .{},
};

pub const Store = struct {
    map: std.StringHashMapUnmanaged(Value) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn set(self: *Store, io: std.Io, gpa: Allocator, key: []const u8, value: ?Value) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (value) |v| {
            const key_copy = try gpa.dupe(u8, key);
            errdefer gpa.free(key_copy);
            const gop = try self.map.getOrPut(gpa, key_copy);
            if (gop.found_existing) {
                const old_key = gop.key_ptr.*;
                const old_value = gop.value_ptr.*;
                gop.key_ptr.* = key_copy;
                gop.value_ptr.* = v;
                gpa.free(old_key);
                freeValue(gpa, old_value);
            } else {
                gop.key_ptr.* = key_copy;
                gop.value_ptr.* = v;
            }
        } else if (self.map.fetchRemove(key)) |kv| {
            freeValue(gpa, kv.value);
            gpa.free(kv.key);
        }
    }

    pub fn get(self: *Store, alloc: Allocator, io: std.Io, key: []const u8) !?Value {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const value = self.map.get(key) orelse return null;
        return try cloneValue(alloc, value);
    }

    pub fn reset(self: *Store, io: std.Io, gpa: Allocator) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        freeAll(self, gpa);
        self.map.clearRetainingCapacity();
    }

    pub fn deinit(self: *Store, gpa: Allocator) void {
        freeAll(self, gpa);
        self.map.deinit(gpa);
    }

    fn freeAll(self: *Store, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            freeValue(gpa, entry.value_ptr.*);
            gpa.free(entry.key_ptr.*);
        }
    }
};

pub fn mapPut(alloc: Allocator, map: *std.StringHashMapUnmanaged(Value), key: []const u8, value: Value) !void {
    const key_copy = try alloc.dupe(u8, key);
    map.put(alloc, key_copy, value) catch |err| {
        alloc.free(key_copy);
        freeValue(alloc, value);
        return err;
    };
}

pub fn cloneValue(alloc: Allocator, value: Value) anyerror!Value {
    return switch (value) {
        .boolean, .integer, .number => value,
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .table => |t| .{ .table = try cloneTable(alloc, t) },
    };
}

pub fn freeValue(gpa: Allocator, value: Value) void {
    switch (value) {
        .string => |s| gpa.free(s),
        .table => |t| {
            var table = t;
            freeTable(gpa, &table);
        },
        else => {},
    }
}

fn cloneTable(alloc: Allocator, table: Table) anyerror!Table {
    var out: Table = .{};
    errdefer freeTable(alloc, &out);

    try out.array.ensureTotalCapacity(alloc, table.array.items.len);
    for (table.array.items) |item| {
        out.array.appendAssumeCapacity(try cloneValue(alloc, item));
    }

    var it = table.map.iterator();
    while (it.next()) |entry| {
        try mapPut(alloc, &out.map, entry.key_ptr.*, try cloneValue(alloc, entry.value_ptr.*));
    }
    return out;
}

fn freeTable(gpa: Allocator, table: *Table) void {
    for (table.array.items) |item| freeValue(gpa, item);
    table.array.deinit(gpa);
    var it = table.map.iterator();
    while (it.next()) |entry| {
        freeValue(gpa, entry.value_ptr.*);
        gpa.free(entry.key_ptr.*);
    }
    table.map.deinit(gpa);
}

test "cloneValue and freeValue round-trip" {
    const a = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(a);

    try store.set(std.testing.io, a, "count", .{ .integer = 42 });
    try store.set(std.testing.io, a, "name", .{ .string = try a.dupe(u8, "hello") });
    var nested: Table = .{};
    try nested.array.append(a, .{ .integer = 1 });
    try nested.array.append(a, .{ .string = try a.dupe(u8, "two") });
    try nested.map.put(a, try a.dupe(u8, "key"), .{ .boolean = true });
    try store.set(std.testing.io, a, "nested", .{ .table = nested });

    const got = (try store.get(a, std.testing.io, "nested")).?;
    defer freeValue(a, got);
    try std.testing.expectEqual(@as(usize, 2), got.table.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), got.table.array.items[0].integer);
    try std.testing.expectEqualStrings("two", got.table.array.items[1].string);
    try std.testing.expect(got.table.map.get("key").?.boolean);

    try store.set(std.testing.io, a, "count", null);
    try std.testing.expect(try store.get(a, std.testing.io, "count") == null);

    store.reset(std.testing.io, a);
    try std.testing.expect(try store.get(a, std.testing.io, "nested") == null);
}
