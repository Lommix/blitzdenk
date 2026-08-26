const std = @import("std");

pub const CONFIG_DIR = ".config/blitzdenk/";
pub const SKILL_DIR = CONFIG_DIR ++ "skills/";

const LUA_DEFAULT_FILE = @embedFile("blitz_default.lua");
const LUA_META_FILE = @embedFile("blitz_defs.lua");
const LUA_SKILL_FILE = @embedFile("skills/blitzdenk-lua.md");
const LUARC_CONTENT =
    \\{
    \\  "workspace": {
    \\    "library": [
    \\      "meta.lua"
    \\    ]
    \\  }
    \\}
;

const DefaultFile = struct {
    rel_path: []const u8,
    contents: []const u8,
    force: bool = false,
};

const default_files = [_]DefaultFile{
    .{ .rel_path = CONFIG_DIR ++ "meta.lua", .contents = LUA_META_FILE, .force = true },
    .{ .rel_path = CONFIG_DIR ++ ".luarc.json", .contents = LUARC_CONTENT, .force = true },
    .{ .rel_path = CONFIG_DIR ++ "blitz.lua", .contents = LUA_DEFAULT_FILE },
    .{ .rel_path = SKILL_DIR ++ "blitzdenk-lua.md", .contents = LUA_SKILL_FILE, .force = true },
};

pub fn ensure(io: std.Io, home_dir: std.Io.Dir) void {
    for (default_files) |f| {
        const exists = fileExists(io, home_dir, f.rel_path);
        if (exists and (!f.force or fileContentsEqual(io, home_dir, f.rel_path, f.contents))) continue;
        if (std.fs.path.dirname(f.rel_path)) |parent| {
            if (home_dir.statFile(io, parent, .{}) == error.FileNotFound) {
                home_dir.createDirPath(io, parent) catch |err| {
                    std.log.scoped(.defaults).err("createDirPath({s}): {any}", .{ parent, err });
                    continue;
                };
            }
        }
        writeDefault(io, home_dir, f) catch |err| {
            std.log.scoped(.defaults).err("write {s}: {any}", .{ f.rel_path, err });
        };
    }
}

fn fileExists(io: std.Io, home_dir: std.Io.Dir, rel_path: []const u8) bool {
    _ = home_dir.statFile(io, rel_path, .{}) catch return false;
    return true;
}

fn fileContentsEqual(io: std.Io, home_dir: std.Io.Dir, rel_path: []const u8, expected: []const u8) bool {
    const stat = home_dir.statFile(io, rel_path, .{}) catch return false;
    if (stat.size != expected.len) return false;

    const file = home_dir.openFile(io, rel_path, .{}) catch return false;
    defer file.close(io);
    var reader_buf: [1024]u8 = undefined;
    var chunk: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var offset: usize = 0;
    while (offset < expected.len) {
        const len = @min(chunk.len, expected.len - offset);
        reader.interface.readSliceAll(chunk[0..len]) catch return false;
        if (!std.mem.eql(u8, chunk[0..len], expected[offset..][0..len])) return false;
        offset += len;
    }
    return true;
}

fn writeDefault(io: std.Io, home_dir: std.Io.Dir, f: DefaultFile) !void {
    const file = try home_dir.createFile(io, f.rel_path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(f.contents);
    try w.interface.flush();
}

test "ensure writes missing files and skips existing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        const stat = try tmp.dir.statFile(std.testing.io, f.rel_path, .{});
        if (stat.size != f.contents.len) return error.WrongSize;
    }

    const blitz_path = CONFIG_DIR ++ "blitz.lua";
    const file = try tmp.dir.createFile(std.testing.io, blitz_path, .{ .truncate = true });
    file.close(std.testing.io);

    ensure(std.testing.io, tmp.dir);

    const stat = try tmp.dir.statFile(std.testing.io, blitz_path, .{});
    if (stat.size != 0) return error.ModifiedExisting;
}

test "ensure rewrites forced files even when they exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        if (!f.force) continue;
        const file = try tmp.dir.createFile(std.testing.io, f.rel_path, .{ .truncate = true });
        file.close(std.testing.io);
    }

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        if (!f.force) continue;
        const stat = try tmp.dir.statFile(std.testing.io, f.rel_path, .{});
        if (stat.size != f.contents.len) return error.NotRewritten;
    }
}

test "ensure leaves current forced files untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        if (!f.force) continue;
        try tmp.dir.setTimestamps(std.testing.io, f.rel_path, .{ .modify_timestamp = .{ .new = .zero } });
    }

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        if (!f.force) continue;
        const stat = try tmp.dir.statFile(std.testing.io, f.rel_path, .{});
        try std.testing.expectEqual(@as(i96, 0), stat.mtime.nanoseconds);
    }
}

test "ensure works when config dir is a symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "real", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".config", .default_dir);
    try tmp.dir.symLink(std.testing.io, "../real", ".config/blitzdenk", .{});

    ensure(std.testing.io, tmp.dir);

    for (default_files) |f| {
        const stat = try tmp.dir.statFile(std.testing.io, f.rel_path, .{});
        if (stat.size != f.contents.len) return error.WrongSize;
    }
}
