const std = @import("std");
const permissions = @import("permissions");

pub const Selection = struct {
    ask: permissions.AskPayload,
    func_ref: c_int,
    arena: std.heap.ArenaAllocator,

    pub fn create(
        parent: std.mem.Allocator,
        ask: permissions.AskPayload,
        func_ref: c_int,
    ) !*Selection {
        const self = try parent.create(Selection);
        errdefer parent.destroy(self);
        self.* = .{ .ask = undefined, .func_ref = func_ref, .arena = .init(parent) };
        errdefer self.arena.deinit();

        const alloc = self.arena.allocator();
        const options = try alloc.alloc([]const u8, ask.options.len);
        for (ask.options, 0..) |opt, i| options[i] = try alloc.dupe(u8, opt);
        self.ask = .{
            .header = try alloc.dupe(u8, ask.header),
            .question = try alloc.dupe(u8, ask.question),
            .options = options,
            .allow_message = ask.allow_message,
        };
        return self;
    }

    pub fn destroy(self: *Selection) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self);
    }
};
