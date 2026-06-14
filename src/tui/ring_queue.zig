pub fn RingQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, item: T) void {
            if (self.len == capacity) return;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }
    };
}
