// Clipboard image paste support: reads an image off the system clipboard
// (Wayland via wl-paste, X11 via xclip), writes it to a temp file under
// `/tmp/blitz` and returns a `file://` URL. Text pastes are untouched.
const std = @import("std");
const prv = @import("provider");
const util = @import("util.zig");

/// Display token that stands in for a pasted-image URL in the input buffer.
pub const TOKEN = "[Image]";
pub const TOKEN_LEN = TOKEN.len;

/// Fixed URL prefix every pasted image gets. The display masks anything
/// starting with this into `[Image]`, and backspace deletes it as one unit.
pub const PREFIX = "file://" ++ util.TMP_DIR ++ "/paste_";

const MAX_CLIP_IMAGE_BYTES = 4 * 1024 * 1024;

pub const ImageData = struct {
    data: []u8,
    ext: []const u8,
};

/// Byte range of a pasted-image URL in the input buffer.
pub const PasteRange = struct {
    start: usize,
    end: usize,
};

/// If the character left of `pos` is inside a pasted-image URL, returns its
/// byte range. Mirrors deleteChar's "remove the char before the cursor" rule.
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

/// Maps a raw input buffer to its rendered form: pasted-image URLs are masked
/// with `[Image]` and `cursor` is remapped to the display position. `text` is
/// allocated with `alloc`; the caller owns it.
pub fn toDisplay(alloc: std.mem.Allocator, buffer: []const u8, cursor: usize) !Display {
    var out: std.ArrayList(u8) = .empty;
    var display_cursor: usize = 0;
    var cursor_resolved = false;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < buffer.len) {
        if (std.mem.indexOfPos(u8, buffer, i, PREFIX)) |start| {
            if (start > i) {
                if (!cursor_resolved and cursor < start) {
                    display_cursor = out_len + (cursor - i);
                    cursor_resolved = true;
                }
                try out.appendSlice(alloc, buffer[i..start]);
                out_len += start - i;
                i = start;
            }
            const end = urlEnd(buffer, start);
            if (!cursor_resolved) {
                if (cursor <= start) {
                    display_cursor = out_len;
                    cursor_resolved = true;
                } else if (cursor <= end) {
                    display_cursor = out_len + TOKEN_LEN;
                    cursor_resolved = true;
                }
            }
            try out.appendSlice(alloc, TOKEN);
            out_len += TOKEN_LEN;
            i = end;
            continue;
        }
        if (!cursor_resolved) {
            display_cursor = out_len + (cursor - i);
            cursor_resolved = true;
        }
        try out.appendSlice(alloc, buffer[i..]);
        return .{ .text = out.items, .cursor = display_cursor };
    }
    if (!cursor_resolved) display_cursor = out_len;
    return .{ .text = out.items, .cursor = display_cursor };
}

/// End offset of the pasted-image URL starting at `start`. The tail is the
/// generated filename (`paste_<timestamp><ext>`), so consume filename chars.
fn urlEnd(buffer: []const u8, start: usize) usize {
    var i = start + PREFIX.len;
    while (i < buffer.len and
        (std.ascii.isAlphanumeric(buffer[i]) or buffer[i] == '.' or buffer[i] == '_' or buffer[i] == '-'))
    {
        i += 1;
    }
    return i;
}

fn readMime(alloc: std.mem.Allocator, pool: *prv.exec.CmdPool, argv: []const []const u8, ext: []const u8) !?ImageData {
    const res = pool.runAndWaitTimeout(.{ .argv = argv, .force_local = true }, 1500) catch return null;
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);
    if (res.ty == .success and res.stdout.len > 0 and res.stdout.len <= MAX_CLIP_IMAGE_BYTES) {
        return .{ .data = try alloc.dupe(u8, res.stdout), .ext = ext };
    }
    return null;
}

/// Reads the first supported image type found on the clipboard.
/// Returns `null` when the clipboard holds no image (or no tool is available).
/// Caller frees `data`.
pub fn readImage(alloc: std.mem.Allocator, pool: *prv.exec.CmdPool) !?ImageData {
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

/// Writes raw image bytes to `<TMP_DIR>/paste_<ts><ext>` and returns a `file://`
/// URL pointing at it. Caller frees the returned string. `/tmp` is cleared on
/// reboot, so pastes are low-value cache that cleans up on its own.
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
    const start: usize = 3; // past the "hi " prefix
    const end = start + PREFIX.len + 7; // "123.png"

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

    // cursor after the url (at its end)
    {
        const d = try toDisplay(a, buffer, 3 + url.len);
        try std.testing.expectEqualStrings("ab [Image] cd", d.text);
        try std.testing.expectEqual(@as(usize, 3 + TOKEN_LEN), d.cursor);
    }
    // cursor inside the url
    {
        const d = try toDisplay(a, buffer, 3 + 5);
        try std.testing.expectEqual(@as(usize, 3 + TOKEN_LEN), d.cursor);
    }
    // cursor before the url
    {
        const d = try toDisplay(a, buffer, 3);
        try std.testing.expectEqualStrings("ab [Image] cd", d.text);
        try std.testing.expectEqual(@as(usize, 3), d.cursor);
    }
    // cursor at end of buffer
    {
        const d = try toDisplay(a, buffer, buffer.len);
        try std.testing.expectEqual(@as(usize, buffer.len - url.len + TOKEN_LEN), d.cursor);
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
    try std.testing.expectEqual(@as(usize, TOKEN_LEN + 5 + TOKEN_LEN), d.cursor);
}
