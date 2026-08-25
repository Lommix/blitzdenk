const std = @import("std");
const exec = @import("exec");
const util = @import("util.zig");

const MAX_NAME_BYTES = 128;
const WRITE_TIMEOUT_MS = 30_000;

pub fn write(pool: *exec.CmdPool, alloc: std.mem.Allocator, name: []const u8, content: []const u8) ![]const u8 {
    var name_buf: [MAX_NAME_BYTES]u8 = undefined;
    const safe_name = sanitizeName(name, &name_buf);
    const path = try std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ util.TMP_DIR, std.c.getpid(), safe_name });
    errdefer alloc.free(path);

    var dir_buf: [64]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/{d}", .{ util.TMP_DIR, std.c.getpid() });
    const result = try pool.runAndWaitTimeout(.{
        .argv = &.{ "/bin/sh", "-c", "umask 077; mkdir -p \"$1\" && cat > \"$2\"", "blitz-artifact", dir_path, path },
        .stdin_data = content,
    }, WRITE_TIMEOUT_MS);
    defer pool.alloc.free(result.stdout);
    defer pool.alloc.free(result.stderr);
    if (result.ty != .success) return error.WriteFailed;
    return path;
}

pub fn cleanup(pool: *exec.CmdPool) void {
    var dir_buf: [64]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{d}", .{ util.TMP_DIR, std.c.getpid() }) catch return;
    remove(pool, dir_path, false);
    if (pool.ssh_active and pool.ssh_target != null) remove(pool, dir_path, true);
}

fn remove(pool: *exec.CmdPool, dir_path: []const u8, force_local: bool) void {
    const result = pool.runAndWaitTimeout(.{
        .argv = &.{ "rm", "-rf", "--", dir_path },
        .force_local = force_local,
    }, WRITE_TIMEOUT_MS) catch return;
    pool.alloc.free(result.stdout);
    pool.alloc.free(result.stderr);
}

fn sanitizeName(name: []const u8, buf: *[MAX_NAME_BYTES]u8) []const u8 {
    var len: usize = 0;
    for (name) |byte| {
        if (len == buf.len) break;
        buf[len] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') byte else '_';
        len += 1;
    }
    const out = if (len == 0) "artifact" else buf[0..len];
    if (std.mem.eql(u8, out, ".") or std.mem.eql(u8, out, "..")) return "artifact";
    return out;
}

test "artifact writes into the process session directory" {
    const testing = std.testing;
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = exec.CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const path = try write(&pool, testing.allocator, "test/a.txt", "artifact data\n");
    defer testing.allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited64(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("artifact data\n", content);
    try testing.expectEqualStrings("test_a.txt", std.fs.path.basename(path));

    cleanup(&pool);
    if (std.Io.Dir.cwd().statFile(testing.io, path, .{})) |_| return error.TestUnexpectedResult else |_| {}
}
