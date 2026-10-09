const std = @import("std");

fn clampUtf8(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var n = limit;
    while (n > 0 and (bytes[n] & 0xC0) == 0x80) n -= 1;
    const len = std.unicode.utf8ByteSequenceLength(bytes[n]) catch 1;
    if (n + len > limit) return n;
    return limit;
}

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
            const n = clampUtf8(text, @min(text.len, capacity));
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
            const n = clampUtf8(bytes, @min(bytes.len, capacity - self.len));
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
