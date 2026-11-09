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
        const questions = try alloc.alloc(permissions.Question, ask.questions.len);
        for (ask.questions, 0..) |q, i| {
            const options = try alloc.alloc([]const u8, q.options.len);
            for (q.options, 0..) |opt, j| options[j] = try alloc.dupe(u8, opt);
            questions[i] = .{
                .header = try alloc.dupe(u8, q.header),
                .question = try alloc.dupe(u8, q.question),
                .options = options,
                .multi_select = q.multi_select,
            };
        }
        self.ask = .{ .questions = questions };
        return self;
    }

    pub fn destroy(self: *Selection) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self);
    }
};
