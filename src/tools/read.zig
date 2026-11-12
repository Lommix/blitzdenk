const r = @import("root.zig");
const std = @import("std");

const MAX_IMAGE_BYTES = r.MAX_IMAGE_BYTES;

pub const ReadTool = r.Tool{
    .def = .{
        .name = "read",
        .description = "Read the contents of a file. Output includes line numbers. Supports text files and images (png, jpeg, gif, webp). For text files, output is truncated to " ++ r.DISPLAY_CAP_TEXT ++
            \\ (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete."
        ,
        .prompt_snippet = "Read file contents and images",
        .prompt_guidelines = "Prefer the read tool over bash cat/sed for file contents",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "file_path": {"type": "string", "description": "Path to the file to read (relative or absolute), or an HTTP(S) URL to load an image"},
        \\      "offset": {"type": "number", "description": "Line number to start reading from (1-indexed)"},
        \\      "limit": {"type": "number", "description": "Maximum number of lines to read"}
        \\  },
        \\  "required": ["file_path"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct {
        file_path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"file_path\": \"...\"}");

    if (args.file_path.len == 0) return r.errResult(call, "path is empty");

    var buf: [r.STATUS_BUF]u8 = undefined;
    const cwd = ctx.base.cwd;
    const rel_path = if (cwd.len > 0)
        r.replaceAll(args.file_path, cwd, ".", &buf)
    else
        args.file_path;

    const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.base.cwd, args.file_path }) catch
        return r.errResult(call, "failed to resolve path");

    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var status_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&status_buf);
    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "read ");
    if (args.limit) |l| {
        if (args.offset) |o|
            w.styledPrint(.{ .fg = app.theme.muted }, "{s} offset: {d} limit: {d}", .{ rel_path, o, l })
        else
            w.styledPrint(.{ .fg = app.theme.muted }, "{s} limit: {d}", .{ rel_path, l });
    } else if (args.offset) |o| {
        w.styledPrint(.{ .fg = app.theme.muted }, "{s} offset: {d}", .{ rel_path, o });
    } else {
        w.styled(.{ .fg = app.theme.muted }, rel_path);
    }
    r.setToolStatus(ctx, call, w.finish()) catch {};

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    const is_url = std.mem.startsWith(u8, args.file_path, "http://") or
        std.mem.startsWith(u8, args.file_path, "https://");
    if (is_url) {
        if (!ctx.agent().flags.vision)
            return r.errResult(call, "URL reads load images, but this model has no vision; use bash with curl to fetch the content");
        return viewImage(ctx, call, args.file_path, true, resolved);
    }
    if (sniffImageType(ctx.io, resolved)) |media_type| {
        if (!ctx.agent().flags.vision)
            return nonVisionResult(ctx, call, media_type);
        return viewImage(ctx, call, args.file_path, false, resolved);
    }

    const start_line: u64 = if (args.offset) |o| (if (o > 0) o else 1) else 1;
    const max_lines: u64 = if (args.limit) |l| l else r.MAX_DISPLAY_LINES;
    const out = switch (readSection(ctx.alloc, ctx.io, resolved, start_line, max_lines) catch |err|
        return r.errResult(call, r.fsFailure(ctx, "failed to read", resolved, err))) {
        .text => |text| text,
        .missing => return r.errResult(call, r.pathFailure(ctx, "file not found", args.file_path)),
        .not_file => return r.errResult(call, r.pathFailure(ctx, "not a regular file", args.file_path)),
        .not_readable => return r.errResult(call, r.pathFailure(ctx, "file is not readable", args.file_path)),
        .empty => return r.okResult(call, "(empty file)"),
        .too_large => return r.errResult(call, "requested section exceeds the 4MB read limit; retry with offset and limit"),
        .past_end => |total| return r.errResult(call, std.fmt.allocPrint(
            ctx.alloc,
            "offset {d} is past the end of file ({d} lines)",
            .{ start_line, total },
        ) catch "offset past end of file"),
    };
    if (looksBinary(out)) {
        ctx.alloc.free(out);
        return r.errResult(call, "binary file (NUL byte or invalid UTF-8); use bash with xxd/strings/base64 to inspect");
    }
    const truncated = r.truncateOutputToOwned(ctx.alloc, out, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES);
    if (truncated.ptr != out.ptr) ctx.alloc.free(out);
    return r.okResult(call, truncated);
}

fn looksBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data);
}

const READ_SECTION_CAP = 4 * 1024 * 1024;

const Section = union(enum) {
    text: []u8,
    missing,
    not_file,
    not_readable,
    empty,
    past_end: u64,
    too_large,
};

/// Lines `start..start+max` of `path` in `cat -n` format (`%6d\t<line>`).
fn readSection(alloc: std.mem.Allocator, io: std.Io, path: []const u8, start: u64, max: u64) !Section {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => err,
    };
    if (st.kind != .file) return .not_file;
    if (st.size == 0) return .empty;
    const file = cwd.openFile(io, path, .{}) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .not_readable,
        else => err,
    };
    defer file.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var line: u64 = 1;
    var line_open = false;
    const stop = start +| max;
    while (line < stop) {
        const n = try file.readPositional(io, &.{&chunk}, offset);
        if (n == 0) {
            const total = if (line_open) line else line - 1;
            if (total == 0) return .empty;
            if (total < start) return .{ .past_end = total };
            break;
        }
        offset += n;
        var rest = chunk[0..n];
        while (rest.len > 0 and line < stop) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const seg = if (nl) |i| rest[0 .. i + 1] else rest;
            if (line >= start) {
                if (!line_open) try out.print(alloc, "{d:>6}\t", .{line});
                try out.appendSlice(alloc, seg);
                if (out.items.len > READ_SECTION_CAP) {
                    out.deinit(alloc);
                    return .too_large;
                }
            }
            rest = rest[seg.len..];
            line_open = nl == null;
            if (!line_open) line += 1;
        }
    }
    return .{ .text = try out.toOwnedSlice(alloc) };
}

fn sniffImageType(io: std.Io, path: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    const file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var head: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return null;
    return detectImageMediaType(head[0..n]);
}

const NON_VISION_NOTE = "[Current model does not support images. The image will be omitted from this request.]";

fn nonVisionResult(ctx: r.ToolContext, call: r.r.sdk.ToolCall, media_type: ?[]const u8) r.r.sdk.ToolOutput {
    const msg = if (media_type) |mt|
        std.fmt.allocPrint(ctx.alloc, "Read image file [{s}]\n" ++ NON_VISION_NOTE, .{mt}) catch
            return r.errResult(call, "out of memory")
    else
        NON_VISION_NOTE;
    return r.okResult(call, msg);
}

const ScaledImage = struct {
    bytes: []u8,
    width: u32,
    height: u32,
};

fn viewImage(ctx: r.ToolContext, call: r.r.sdk.ToolCall, file_path: []const u8, is_url: bool, resolved: []const u8) r.r.sdk.ToolOutput {
    const raw = if (is_url)
        loadUrlImage(ctx, file_path) catch |err| return r.errResult(call, imageLoadError(err, true))
    else
        loadLocalImage(ctx, resolved) catch |err| return r.errResult(call, imageLoadError(err, false));
    defer ctx.base.exec_pool.alloc.free(raw);

    const source_media_type = detectImageMediaType(raw) orelse
        return r.errResult(call, "unsupported image format; expected PNG, JPEG, GIF, or WebP");
    var output_media_type = source_media_type;
    const source_size = r.r.image.dimensions(raw);

    var encoded_raw: []const u8 = raw;
    var scaled: ?ScaledImage = null;
    var scale_error: ?anyerror = null;
    defer if (scaled) |value| ctx.alloc.free(value.bytes);

    if (source_size) |size| {
        const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
        const max = app.readImageMax();
        if (exceedsReadImageMax(size, max)) {
            if (scaleImageToPng(ctx, raw, size, max)) |value| {
                scaled = value;
                encoded_raw = value.bytes;
                output_media_type = "image/png";
            } else |err| {
                scale_error = err;
            }
        }
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(encoded_raw.len);
    const encoded = ctx.alloc.alloc(u8, encoded_len) catch return r.errResult(call, "out of memory");
    defer ctx.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, encoded_raw);

    const note = if (scaled) |value|
        std.fmt.allocPrint(
            ctx.alloc,
            "Read image file [image/png] ({s} {d}x{d} scaled to {d}x{d})",
            .{ source_media_type, source_size.?.width, source_size.?.height, value.width, value.height },
        ) catch return r.errResult(call, "out of memory")
    else if (scale_error) |err|
        std.fmt.allocPrint(ctx.alloc, "Read image file [{s}] (not scaled: {s})", .{ source_media_type, imageScaleError(err) }) catch
            return r.errResult(call, "out of memory")
    else
        std.fmt.allocPrint(ctx.alloc, "Read image file [{s}]", .{source_media_type}) catch
            return r.errResult(call, "out of memory");

    return .{ .content = note, .image = .{
        .url = std.fmt.allocPrint(ctx.alloc, "data:{s};base64,{s}", .{ output_media_type, encoded }) catch return r.errResult(call, "out of memory"),
        .media_type = output_media_type,
    } };
}

fn exceedsReadImageMax(size: r.r.image.Size, max: r.r.image.Size) bool {
    return (max.width != 0 and size.width > max.width) or (max.height != 0 and size.height > max.height);
}

fn scaleImageToPng(ctx: r.ToolContext, raw: []const u8, size: r.r.image.Size, max: r.r.image.Size) !ScaledImage {
    var box_width = if (max.width == 0) size.width else max.width;
    var box_height = if (max.height == 0) size.height else max.height;
    while (true) {
        var img = try r.r.image.decode(ctx.alloc, raw);
        const scaled = r.r.image.scaleToFit(ctx.alloc, img, box_width, box_height) catch |err| {
            img.deinit(ctx.alloc);
            return err;
        };
        defer scaled.deinit(ctx.alloc);
        const png = try r.r.image.encodePng(ctx.alloc, scaled);
        if (png.len <= MAX_IMAGE_BYTES or (box_width == 1 and box_height == 1)) {
            return .{ .bytes = png, .width = scaled.width, .height = scaled.height };
        }
        ctx.alloc.free(png);
        box_width = @max(1, box_width -| box_width / 4);
        box_height = @max(1, box_height -| box_height / 4);
    }
}

fn imageScaleError(err: anyerror) []const u8 {
    return switch (err) {
        error.Unsupported => "format cannot be scaled",
        error.TooLarge => "image is too large to decode",
        error.Corrupt => "image could not be decoded",
        error.OutOfMemory => "out of memory",
        else => "scaling failed",
    };
}

const ImageLoadError = error{
    EmptyImage,
    ImageTooLarge,
    ReadFailed,
    DownloadFailed,
    DownloadTimedOut,
};

fn imageLoadError(err: anyerror, is_url: bool) []const u8 {
    return switch (err) {
        error.EmptyImage => "image is empty",
        error.ImageTooLarge => "image exceeds the 4 MB limit",
        error.DownloadTimedOut => "image download timed out",
        error.DownloadFailed => "failed to download image",
        error.ReadFailed => if (is_url) "failed to download image" else "failed to read image",
        else => if (is_url) "failed to download image" else "failed to read image",
    };
}

/// Allocated with the exec pool allocator, like `loadUrlImage`, so `viewImage` frees both alike.
fn loadLocalImage(ctx: r.ToolContext, resolved: []const u8) ImageLoadError![]const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.base.exec_pool.alloc, .limited(MAX_IMAGE_BYTES + 1)) catch |err| return switch (err) {
        error.StreamTooLong => error.ImageTooLarge,
        else => error.ReadFailed,
    };
    if (raw.len == 0) {
        ctx.base.exec_pool.alloc.free(raw);
        return error.EmptyImage;
    }
    return raw;
}

fn loadUrlImage(ctx: r.ToolContext, url: []const u8) ImageLoadError![]const u8 {
    const result = ctx.base.exec_pool.runAndWaitTimeout(.{ .argv = &.{
        "curl",
        "-fsSL",
        "--max-filesize",
        "4194304",
        "--",
        url,
    }, .max_output = MAX_IMAGE_BYTES }, 30_000) catch return error.DownloadFailed;
    defer ctx.base.exec_pool.alloc.free(result.stderr);
    if (result.ty == .timeout) {
        ctx.base.exec_pool.alloc.free(result.stdout);
        return error.DownloadTimedOut;
    }
    if (result.ty != .success) {
        ctx.base.exec_pool.alloc.free(result.stdout);
        if (result.exit_code == 63) return error.ImageTooLarge;
        return error.DownloadFailed;
    }
    if (result.stdout.len == 0) {
        ctx.base.exec_pool.alloc.free(result.stdout);
        return error.EmptyImage;
    }
    if (result.stdout_truncated or result.stdout.len > MAX_IMAGE_BYTES) {
        ctx.base.exec_pool.alloc.free(result.stdout);
        return error.ImageTooLarge;
    }
    return result.stdout;
}

fn detectImageMediaType(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "\xff\xd8\xff")) return "image/jpeg";
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return "image/gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    return null;
}

test "readSection matches cat -n and reports edge cases" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nl.txt", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    try tmp.dir.createDir(io, "sub", .default_dir);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf, "{s}/a.txt", .{root});
    {
        const s = try readSection(testing.allocator, io, a, 1, 2000);
        defer testing.allocator.free(s.text);
        try testing.expectEqualStrings("     1\tone\n     2\ttwo\n     3\tthree", s.text);
    }
    {
        const s = try readSection(testing.allocator, io, a, 2, 1);
        defer testing.allocator.free(s.text);
        try testing.expectEqualStrings("     2\ttwo\n", s.text);
    }
    try testing.expectEqual(@as(u64, 3), (try readSection(testing.allocator, io, a, 4, 10)).past_end);

    var nl_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nl = try std.fmt.bufPrint(&nl_buf, "{s}/nl.txt", .{root});
    try testing.expectEqual(@as(u64, 1), (try readSection(testing.allocator, io, nl, 2, 10)).past_end);

    var other: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(try readSection(testing.allocator, io, try std.fmt.bufPrint(&other, "{s}/empty.txt", .{root}), 1, 10) == .empty);
    try testing.expect(try readSection(testing.allocator, io, try std.fmt.bufPrint(&other, "{s}/sub", .{root}), 1, 10) == .not_file);
    try testing.expect(try readSection(testing.allocator, io, try std.fmt.bufPrint(&other, "{s}/missing", .{root}), 1, 10) == .missing);
}

test "readSection stops past the section cap" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, READ_SECTION_CAP + 1);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = data });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/big.txt", .{root});
    try testing.expect(try readSection(testing.allocator, io, path, 1, 10) == .too_large);
}

test "sniffImageType reads the magic bytes" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.png", .data = "\x89PNG\r\n\x1a\n rest" });
    try tmp.dir.writeFile(io, .{ .sub_path = "t.txt", .data = "hello" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("image/png", sniffImageType(io, try std.fmt.bufPrint(&buf, "{s}/p.png", .{root})).?);
    try testing.expect(sniffImageType(io, try std.fmt.bufPrint(&buf, "{s}/t.txt", .{root})) == null);
    try testing.expect(sniffImageType(io, root) == null);
}
