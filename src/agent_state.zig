const std = @import("std");
const AgentId = @import("agent-id").AgentId;

pub fn Guard(comptime T: type) type {
    return struct {
        ptr: *T,
        mutex: *std.Io.Mutex,
        io: std.Io,

        pub fn unlock(self: @This()) void {
            self.mutex.unlock(self.io);
        }
    };
}

pub fn Locked(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T = if (@hasDecl(T, "empty")) .empty else .{},
        mutex: std.Io.Mutex = .init,

        pub fn lock(self: *Self, io: std.Io) Guard(T) {
            self.mutex.lockUncancelable(io);
            return .{ .ptr = &self.value, .mutex = &self.mutex, .io = io };
        }

        pub fn tryLock(self: *Self, io: std.Io) ?Guard(T) {
            if (!self.mutex.tryLock()) return null;
            return .{ .ptr = &self.value, .mutex = &self.mutex, .io = io };
        }
    };
}

pub const ToolDisplay = struct {
    content: []const u8,
    child: ?AgentId = null,
};
