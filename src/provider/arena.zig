const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const ThreadSafeArena = struct {
    inner: std.heap.ArenaAllocator,
    mu: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(child: Allocator, io: std.Io) ThreadSafeArena {
        return .{ .inner = std.heap.ArenaAllocator.init(child), .io = io };
    }

    pub fn deinit(self: ThreadSafeArena) void {
        self.inner.deinit();
    }

    pub fn reset(self: *ThreadSafeArena, mode: std.heap.ArenaAllocator.ResetMode) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.inner.reset(mode);
    }

    pub fn allocator(self: *ThreadSafeArena) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: Allocator.VTable = .{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeArena = @ptrCast(@alignCast(ctx));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const inner = self.inner.allocator();
        return inner.vtable.alloc(inner.ptr, len, alignment, ret_addr);
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeArena = @ptrCast(@alignCast(ctx));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const inner = self.inner.allocator();
        return inner.vtable.resize(inner.ptr, memory, alignment, new_len, ret_addr);
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeArena = @ptrCast(@alignCast(ctx));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const inner = self.inner.allocator();
        return inner.vtable.remap(inner.ptr, memory, alignment, new_len, ret_addr);
    }

    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ThreadSafeArena = @ptrCast(@alignCast(ctx));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const inner = self.inner.allocator();
        inner.vtable.free(inner.ptr, memory, alignment, ret_addr);
    }
};
