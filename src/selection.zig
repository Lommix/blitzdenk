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

test "create deep clones and destroy frees" {
    const alloc = std.testing.allocator;
    var header_buf = [_]u8{'h'} ** 4;
    var opt0_buf = [_]u8{'o'} ** 3;
    var opt1_buf = [_]u8{'p'} ** 4;
    const options = [_][]const u8{ &opt0_buf, &opt1_buf };

    const sel = try Selection.create(alloc, .{
        .header = &header_buf,
        .question = "pick one",
        .options = &options,
        .allow_message = false,
    }, 7);
    defer sel.destroy();

    try std.testing.expectEqual(@as(c_int, 7), sel.func_ref);
    try std.testing.expectEqualStrings("pick one", sel.ask.question);
    try std.testing.expectEqualStrings("h", sel.ask.header[3..4]);
    try std.testing.expect(!sel.ask.allow_message);

    header_buf[0] = 'x';
    opt0_buf[0] = 'x';
    try std.testing.expectEqualStrings("h", sel.ask.header[0..1]);
    try std.testing.expectEqualStrings("o", sel.ask.options[0][0..1]);
    try std.testing.expectEqualStrings("p", sel.ask.options[1][0..1]);
    try std.testing.expectEqual(options.len, sel.ask.options.len);
}
