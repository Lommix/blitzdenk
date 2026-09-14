const std = @import("std");

pub fn Field(comptime max: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = max;

        buf: [max]u8 = undefined,
        len: usize = 0,
        cursor: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn set(self: *Self, text: []const u8) void {
            const n = @min(text.len, capacity);
            @memcpy(self.buf[0..n], text[0..n]);
            self.len = n;
            self.cursor = n;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.cursor = 0;
        }

        pub fn wipe(self: *Self) void {
            @memset(&self.buf, 0);
            self.clear();
        }

        pub fn insert(self: *Self, bytes: []const u8) void {
            if (self.cursor > self.len) self.cursor = self.len;
            const n = @min(bytes.len, capacity - self.len);
            const tail = self.len - self.cursor;
            std.mem.copyBackwards(u8, self.buf[self.cursor + n ..][0..tail], self.buf[self.cursor..][0..tail]);
            @memcpy(self.buf[self.cursor..][0..n], bytes[0..n]);
            self.len += n;
            self.cursor += n;
        }

        pub fn deleteRange(self: *Self, start: usize, stop_in: usize) void {
            const stop = @min(stop_in, self.len);
            if (start >= stop) return;
            const removed = stop - start;
            const tail = self.len - stop;
            std.mem.copyForwards(u8, self.buf[start..][0..tail], self.buf[stop..][0..tail]);
            self.len -= removed;
            if (self.cursor > stop) {
                self.cursor -= removed;
            } else if (self.cursor > start) {
                self.cursor = start;
            }
        }

        pub fn backspace(self: *Self) void {
            if (self.cursor == 0) return;
            var start = self.cursor - 1;
            while (start > 0 and (self.buf[start] & 0xC0) == 0x80) start -= 1;
            self.deleteRange(start, self.cursor);
        }

        pub fn deleteForward(self: *Self) void {
            if (self.cursor >= self.len) return;
            var stop = self.cursor + 1;
            while (stop < self.len and (self.buf[stop] & 0xC0) == 0x80) stop += 1;
            self.deleteRange(self.cursor, stop);
        }

        pub fn left(self: *Self) void {
            if (self.cursor == 0) return;
            var i = self.cursor - 1;
            while (i > 0 and (self.buf[i] & 0xC0) == 0x80) i -= 1;
            self.cursor = i;
        }

        pub fn right(self: *Self) void {
            if (self.cursor >= self.len) return;
            var i = self.cursor + 1;
            while (i < self.len and (self.buf[i] & 0xC0) == 0x80) i += 1;
            self.cursor = i;
        }

        pub fn home(self: *Self) void {
            var i = self.cursor;
            while (i > 0 and self.buf[i - 1] != '\n') i -= 1;
            self.cursor = i;
        }

        pub fn end(self: *Self) void {
            var i = self.cursor;
            while (i < self.len and self.buf[i] != '\n') i += 1;
            self.cursor = i;
        }
    };
}

test "insert at cursor shifts tail" {
    var f: Field(64) = .{};
    f.set("ac");
    f.cursor = 1;
    f.insert("b");
    try std.testing.expectEqualStrings("abc", f.slice());
    try std.testing.expectEqual(@as(usize, 2), f.cursor);

    f.insert("xy");
    try std.testing.expectEqualStrings("abxyc", f.slice());
    try std.testing.expectEqual(@as(usize, 4), f.cursor);
}

test "insert clamps at capacity" {
    var f: Field(8) = .{};
    const big = "a" ** (Field(8).capacity + 10);
    f.insert(big);
    try std.testing.expectEqual(Field(8).capacity, f.len);
    f.insert("more");
    try std.testing.expectEqual(Field(8).capacity, f.len);
}

test "backspace removes full codepoint" {
    var f: Field(64) = .{};
    f.set("héllo");
    f.cursor = "hé".len;
    f.backspace();
    try std.testing.expectEqualStrings("hllo", f.slice());
    try std.testing.expectEqual(@as(usize, 1), f.cursor);

    f.cursor = 0;
    f.backspace();
    try std.testing.expectEqualStrings("hllo", f.slice());
}

test "deleteForward removes full codepoint" {
    var f: Field(64) = .{};
    f.set("héllo");
    f.cursor = 1;
    f.deleteForward();
    try std.testing.expectEqualStrings("hllo", f.slice());
    try std.testing.expectEqual(@as(usize, 1), f.cursor);

    f.cursor = f.len;
    f.deleteForward();
    try std.testing.expectEqualStrings("hllo", f.slice());
}

test "left and right step over whole codepoints" {
    var f: Field(64) = .{};
    f.set("aéz");
    f.end();
    try std.testing.expectEqual(f.len, f.cursor);
    f.left();
    try std.testing.expectEqual(@as(usize, 3), f.cursor);
    f.left();
    try std.testing.expectEqual(@as(usize, 1), f.cursor);
    f.right();
    try std.testing.expectEqual(@as(usize, 3), f.cursor);
    f.left();
    f.left();
    f.left();
    try std.testing.expectEqual(@as(usize, 0), f.cursor);
    f.right();
    f.right();
    f.right();
    try std.testing.expectEqual(f.len, f.cursor);
}

test "home and end stay on the current line" {
    var f: Field(64) = .{};
    f.set("ab\ncdé\nfg");
    f.cursor = "ab\nc".len;
    f.home();
    try std.testing.expectEqual(@as(usize, 3), f.cursor);
    f.end();
    try std.testing.expectEqual(@as(usize, 7), f.cursor);

    f.cursor = 2;
    f.end();
    try std.testing.expectEqual(@as(usize, 2), f.cursor);
}

test "deleteRange moves cursor into the hole" {
    var f: Field(64) = .{};
    f.set("hello");
    f.cursor = 5;
    f.deleteRange(1, 3);
    try std.testing.expectEqualStrings("hlo", f.slice());
    try std.testing.expectEqual(@as(usize, 3), f.cursor);

    f.set("hello");
    f.cursor = 4;
    f.deleteRange(1, 3);
    try std.testing.expectEqual(@as(usize, 2), f.cursor);

    f.set("hello");
    f.cursor = 0;
    f.deleteRange(1, 3);
    try std.testing.expectEqual(@as(usize, 0), f.cursor);
}

test "wipe zeroes the whole buffer including deleted tail" {
    var f: Field(64) = .{};
    f.set("hunter2");
    f.backspace();
    f.backspace();
    try std.testing.expectEqualStrings("hunte", f.slice());
    f.wipe();
    try std.testing.expect(f.isEmpty());
    for (&f.buf) |ch| try std.testing.expectEqual(@as(u8, 0), ch);
}

test "set truncates and parks cursor at end" {
    var f: Field(64) = .{};
    f.set("abc");
    f.cursor = 0;
    f.set("abcdef");
    try std.testing.expectEqual(@as(usize, 6), f.cursor);
}
