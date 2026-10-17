const std = @import("std");
const util = @import("util.zig");
const exec = @import("exec");

const MAX_NAME_BYTES = 128;
const MAX_FILE_BYTES = MAX_NAME_BYTES + 32;
const MAX_ATTEMPTS = 8;

pub fn write(pool: *exec.CmdPool, alloc: std.mem.Allocator, name: []const u8, content: []const u8) ![]const u8 {
    const io = pool.io;
    std.Io.Dir.createDirAbsolute(io, util.TMP_DIR, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, util.TMP_DIR, .{ .follow_symlinks = false });
    defer tmp_dir.close(io);

    var pid_buf: [16]u8 = undefined;
    const pid_name = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()});
    tmp_dir.createDir(io, pid_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try tmp_dir.openDir(io, pid_name, .{ .follow_symlinks = false });
    defer dir.close(io);

    var name_buf: [MAX_NAME_BYTES]u8 = undefined;
    const stem = sanitizeName(name, &name_buf);
    const ext = fileExtension(stem);
    const base = stem[0 .. stem.len - ext.len];

    var attempt: usize = 0;
    while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
        var random: [8]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var file_buf: [MAX_FILE_BYTES]u8 = undefined;
        const file_name = if (ext.len == 0)
            std.fmt.bufPrint(&file_buf, "{s}-{s}.txt", .{ base, hex }) catch return error.NameTooLong
        else
            std.fmt.bufPrint(&file_buf, "{s}-{s}{s}", .{ base, hex, ext }) catch return error.NameTooLong;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ util.TMP_DIR, pid_name, file_name });
        errdefer alloc.free(path);
        const file = dir.createFile(io, file_name, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        file.writeStreamingAll(io, content) catch |err| {
            file.close(io);
            dir.deleteFile(io, file_name) catch {};
            return err;
        };
        file.close(io);
        return path;
    }
    return error.PathAlreadyExists;
}

fn fileExtension(stem: []const u8) []const u8 {
    const ext = std.fs.path.extension(stem);
    if (ext.len < 2) return stem[stem.len..];
    return ext;
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

fn initPool(env: *std.process.Environ.Map) exec.CmdPool {
    return exec.CmdPool.init(std.testing.allocator, std.testing.io, env);
}

test "artifact writes into the process session directory" {
    const testing = std.testing;
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = initPool(&env);
    defer pool.deinit();

    const path = try write(&pool, testing.allocator, "test/a.txt", "artifact data\n");
    defer testing.allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, testing.allocator, .limited64(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("artifact data\n", content);
    const base = std.fs.path.basename(path);
    try testing.expect(std.mem.startsWith(u8, base, "test_a-"));
    try testing.expect(std.mem.endsWith(u8, base, ".txt"));

    const py = try write(&pool, testing.allocator, "x.py", "py\n");
    defer testing.allocator.free(py);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, py) catch {};
    const py_base = std.fs.path.basename(py);
    try testing.expect(std.mem.startsWith(u8, py_base, "x-"));
    try testing.expect(std.mem.endsWith(u8, py_base, ".py"));
}

test "artifact writes distinct private files into a private directory" {
    const testing = std.testing;
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = initPool(&env);
    defer pool.deinit();

    const first = try write(&pool, testing.allocator, "dup.txt", "first\n");
    defer testing.allocator.free(first);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, first) catch {};
    const second = try write(&pool, testing.allocator, "dup.txt", "second\n");
    defer testing.allocator.free(second);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, second) catch {};

    try testing.expect(!std.mem.eql(u8, first, second));
    const first_stat = try std.Io.Dir.cwd().statFile(std.testing.io, first, .{});
    const second_stat = try std.Io.Dir.cwd().statFile(std.testing.io, second, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), first_stat.permissions.toMode() & 0o777);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), second_stat.permissions.toMode() & 0o777);

    var dir_buf: [64]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/{d}", .{ util.TMP_DIR, std.c.getpid() });
    const dir_stat = try std.Io.Dir.cwd().statFile(std.testing.io, dir_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
}
