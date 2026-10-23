const std = @import("std");
const builtin = @import("builtin");

pub const flag = "--blitz-exec-shim";

pub fn enter(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return;
    if (!std.mem.eql(u8, mode, flag)) return;
    const parent = std.fmt.parseInt(std.posix.pid_t, args.next() orelse std.process.exit(126), 10) catch std.process.exit(126);
    if (parent <= 0) std.process.exit(126);
    _ = std.posix.prctl(.SET_PDEATHSIG, .{ @backingInt(std.posix.SIG.KILL), 0, 0, 0 }) catch std.process.exit(126);
    if (std.posix.getppid() != parent) std.process.exit(126);
    if (std.c.setsid() < 0) std.process.exit(126);
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 4) std.process.exit(126);
    const err = std.process.replace(init.io, .{ .argv = argv[3..], .expand_arg0 = .expand });
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "exec {s}: {s}\n", .{ argv[3], @errorName(err) }) catch "exec failed\n";
    std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
    std.process.exit(127);
}

pub fn main(init: std.process.Init) !void {
    try enter(init);
    std.process.exit(126);
}
