const std = @import("std");
const permissions = @import("permissions");
const ask_session = @import("ask_session.zig");

/// A queued cmd.select request. Owns its questions and the widget session,
/// so progress survives while a permission takes the screen.
pub const Selection = struct {
    session: ask_session.Session,
    func_ref: c_int,
    arena: std.heap.ArenaAllocator,

    pub fn create(
        parent: std.mem.Allocator,
        questions: []const permissions.Question,
        func_ref: c_int,
    ) !*Selection {
        const self = try parent.create(Selection);
        errdefer parent.destroy(self);
        self.* = .{ .session = undefined, .func_ref = func_ref, .arena = .init(parent) };
        errdefer self.arena.deinit();
        self.session = .init(try permissions.dupQuestions(self.arena.allocator(), questions));
        return self;
    }

    pub fn destroy(self: *Selection) void {
        const parent = self.arena.child_allocator;
        self.session.deinit();
        self.arena.deinit();
        parent.destroy(self);
    }
};
