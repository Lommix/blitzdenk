const std = @import("std");
const exec = @import("exec");
const util = @import("util.zig");

pub const TOKEN = "[Image]";

pub const PREFIX = "file://" ++ util.TMP_DIR ++ "/paste_";

const MAX_CLIP_IMAGE_BYTES = 4 * 1024 * 1024;

pub const ImageData = struct {
    data: []u8,
    ext: []const u8,
};

pub const PasteRange = struct {
    start: usize,
    end: usize,
};

pub fn findPasteAt(buffer: []const u8, pos: usize) ?PasteRange {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, buffer, i, PREFIX)) |start| {
        const end = urlEnd(buffer, start);
        if (pos > start and pos <= end) return .{ .start = start, .end = end };
        i = start + PREFIX.len;
    }
    return null;
}

pub const Display = struct {
    text: []const u8,
    cursor: usize,
};

pub fn toDisplay(alloc: std.mem.Allocator, buffer: []const u8, cursor: usize) !Display {
    var out: std.ArrayList(u8) = .empty;
    var display_cursor: usize = 0;
    var cursor_resolved = false;
    var i: usize = 0;
    while (i < buffer.len) {
        if (std.mem.indexOfPos(u8, buffer, i, PREFIX)) |start| {
            if (start > i) {
                if (!cursor_resolved and cursor < start) {
                    display_cursor = out.items.len + (cursor - i);
                    cursor_resolved = true;
                }
                try out.appendSlice(alloc, buffer[i..start]);
                i = start;
            }
            const end = urlEnd(buffer, start);
            if (!cursor_resolved) {
                if (cursor <= start) {
                    display_cursor = out.items.len;
                    cursor_resolved = true;
                } else if (cursor <= end) {
                    display_cursor = out.items.len + TOKEN.len;
                    cursor_resolved = true;
                }
            }
            try out.appendSlice(alloc, TOKEN);
            i = end;
            continue;
        }
        if (!cursor_resolved) {
            display_cursor = out.items.len + (cursor - i);
            cursor_resolved = true;
        }
        try out.appendSlice(alloc, buffer[i..]);
        return .{ .text = out.items, .cursor = display_cursor };
    }
    if (!cursor_resolved) display_cursor = out.items.len;
    return .{ .text = out.items, .cursor = display_cursor };
}

fn urlEnd(buffer: []const u8, start: usize) usize {
    var i = start + PREFIX.len;
    while (i < buffer.len and
        (std.ascii.isAlphanumeric(buffer[i]) or buffer[i] == '.' or buffer[i] == '_' or buffer[i] == '-'))
    {
        i += 1;
    }
    return i;
}

fn readMime(alloc: std.mem.Allocator, pool: *exec.CmdPool, argv: []const []const u8, ext: []const u8) !?ImageData {
    const res = pool.runAndWaitTimeout(.{ .argv = argv, .force_local = true }, 1500) catch return null;
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);
    if (res.ty == .success and res.stdout.len > 0 and res.stdout.len <= MAX_CLIP_IMAGE_BYTES) {
        return .{ .data = try alloc.dupe(u8, res.stdout), .ext = ext };
    }
    return null;
}

pub fn readImage(alloc: std.mem.Allocator, pool: *exec.CmdPool) !?ImageData {
    const env = pool.env;

    const attempts = [_]struct { mime: []const u8, ext: []const u8 }{
        .{ .mime = "image/png", .ext = ".png" },
        .{ .mime = "image/jpeg", .ext = ".jpg" },
    };

    if (env.get("WAYLAND_DISPLAY") != null) {
        for (attempts) |a| {
            if (try readMime(alloc, pool, &.{ "wl-paste", "--no-newline", "-t", a.mime }, a.ext)) |img| return img;
        }
        return null;
    }
    if (env.get("DISPLAY") != null) {
        for (attempts) |a| {
            if (try readMime(alloc, pool, &.{ "xclip", "-selection", "clipboard", "-t", a.mime, "-o" }, a.ext)) |img| return img;
        }
    }
    return null;
}

pub fn saveImage(io: std.Io, alloc: std.mem.Allocator, data: []const u8, ext: []const u8) ![]const u8 {
    std.Io.Dir.createDirAbsolute(io, util.TMP_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, util.TMP_DIR, .{});
    defer tmp_dir.close(io);
    const ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const name = try std.fmt.allocPrint(alloc, "paste_{d}{s}", .{ ns, ext });
    defer alloc.free(name);
    try tmp_dir.writeFile(io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrint(alloc, "file://{s}/{s}", .{ util.TMP_DIR, name });
}

test "saveImage writes bytes and returns file URL" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const png = "fake-png-bytes";
    const url = try saveImage(io, alloc, png, ".png");
    defer alloc.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "file:///tmp/blitz/"));

    const path = url["file://".len..];
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, util.TMP_DIR, .{});
    defer tmp_dir.close(io);
    const read = try tmp_dir.readFileAlloc(io, path[util.TMP_DIR.len + 1 ..], alloc, .limited(1024));
    defer alloc.free(read);
    try std.testing.expectEqualStrings(png, read);
}

test "findPasteAt hits inside and at the end of a pasted URL" {
    const buffer = "hi " ++ PREFIX ++ "123.png bye";
    const start: usize = 3;
    const end = start + PREFIX.len + 7;

    try std.testing.expectEqual(@as(usize, start), findPasteAt(buffer, start + 1).?.start);
    try std.testing.expectEqual(@as(usize, end), findPasteAt(buffer, end).?.end);
    try std.testing.expect(findPasteAt(buffer, start) == null);
    try std.testing.expect(findPasteAt(buffer, end + 1) == null);
    try std.testing.expect(findPasteAt("no image here", 3) == null);
}

test "toDisplay masks urls and remaps cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = PREFIX ++ "123.png";
    const buffer = "ab " ++ url ++ " cd";

    {
        const d = try toDisplay(a, buffer, 3 + url.len);
        try std.testing.expectEqualStrings("ab [Image] cd", d.text);
        try std.testing.expectEqual(@as(usize, 3 + TOKEN.len), d.cursor);
    }
    {
        const d = try toDisplay(a, buffer, 3 + 5);
        try std.testing.expectEqual(@as(usize, 3 + TOKEN.len), d.cursor);
    }
    {
        const d = try toDisplay(a, buffer, 3);
        try std.testing.expectEqualStrings("ab [Image] cd", d.text);
        try std.testing.expectEqual(@as(usize, 3), d.cursor);
    }
    {
        const d = try toDisplay(a, buffer, buffer.len);
        try std.testing.expectEqual(@as(usize, buffer.len - url.len + TOKEN.len), d.cursor);
    }
}

test "toDisplay masks multiple urls and cursor shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url1 = PREFIX ++ "111.png";
    const url2 = PREFIX ++ "222.png";
    const buffer = url1 ++ " mid " ++ url2;
    const d = try toDisplay(a, buffer, buffer.len);
    try std.testing.expectEqualStrings("[Image] mid [Image]", d.text);
    try std.testing.expectEqual(@as(usize, TOKEN.len + 5 + TOKEN.len), d.cursor);
}
