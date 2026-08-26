const r = @import("root.zig");
const std = @import("std");

const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

pub const ReadTool = r.Tool{
    .def = .{
        .name = "read",
        .description = "Read the contents of a file. For text files, output is truncated to " ++ r.DISPLAY_CAP_TEXT ++
            \\ (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete."
        ,
        .prompt_snippet = "Read file contents",
        .prompt_guidelines = "Use read to examine files instead of cat or sed. You can read many files in parallel",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "file_path": {"type": "string", "description": "Path to the file to read (relative or absolute)"},
        \\      "offset": {"type": "number", "description": "Line number to start reading from (1-indexed)"},
        \\      "limit": {"type": "number", "description": "Maximum number of lines to read"}
        \\  },
        \\  "required": ["file_path"]
        \\}
        ,
    },
    .func = &run,
};

pub const ViewImageTool = r.Tool{
    .def = .{
        .name = "view_image",
        .description = "Load an image from a local path or HTTP(S) URL into the context (PNG, JPEG, GIF, WebP)",
        .prompt_snippet = "Load an image into the context",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "file_path": {"type": "string", "description": "Local image path (relative to cwd or absolute) or HTTP(S) URL"}
        \\  },
        \\  "required": ["file_path"]
        \\}
        ,
    },
    .func = &viewImage,
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
    const rel_path = if (ctx.base.cwd.len > 0)
        r.replaceAll(args.file_path, ctx.base.cwd, ".", &buf)
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

    // Read with cat -n for line numbering, sliced by offset/limit.
    const start_line: u64 = if (args.offset) |o| (if (o > 0) o else 1) else 1;
    const max_lines: u64 = if (args.limit) |l| l else r.MAX_DISPLAY_LINES;
    const command = std.fmt.allocPrint(ctx.alloc, "cat -n '{s}' | tail -n +{d} | head -n {d}", .{
        resolved, start_line, max_lines,
    }) catch return r.errResult(call, "out of memory");

    const read_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "/bin/sh", "-c", command } }) catch
        return r.errResult(call, "failed to read file");
    defer ctx.base.exec_pool.alloc.free(read_res.stdout);
    defer ctx.base.exec_pool.alloc.free(read_res.stderr);

    const out = read_res.toOwned(ctx.alloc) catch return r.errResult(call, "oom");
    if (looksBinary(out)) {
        ctx.alloc.free(out);
        return r.errResult(call, "binary file (NUL byte or invalid UTF-8); use view_image for images, or bash with xxd/strings/base64 to inspect");
    }
    const truncated = r.truncateOutputToOwned(ctx.alloc, out, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES);
    if (truncated.ptr != out.ptr) ctx.alloc.free(out);
    return r.okResult(call, truncated);
}

fn looksBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data);
}

fn viewImage(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct { file_path: []const u8 };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"file_path\": \"...\"}");

    if (args.file_path.len == 0) return r.errResult(call, "path is empty");

    const is_url = std.mem.startsWith(u8, args.file_path, "http://") or
        std.mem.startsWith(u8, args.file_path, "https://");

    var display_buf: [r.STATUS_BUF]u8 = undefined;
    const display_path = if (!is_url and ctx.base.cwd.len > 0)
        r.replaceAll(args.file_path, ctx.base.cwd, ".", &display_buf)
    else
        args.file_path;

    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var status_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&status_buf);
    w.styled(.{ .modifier = .{ .bold = true } }, "view image ");
    w.styled(.{ .fg = app.theme.muted }, display_path);
    r.setToolStatus(ctx, call, w.finish()) catch {};

    const raw = if (is_url)
        loadRemoteImage(ctx, args.file_path) catch |err| return r.errResult(call, imageLoadError(err, true))
    else blk: {
        const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.base.cwd, args.file_path }) catch
            return r.errResult(call, "failed to resolve image path");
        break :blk loadLocalImage(ctx, resolved) catch |err| return r.errResult(call, imageLoadError(err, false));
    };
    defer ctx.base.exec_pool.alloc.free(raw);

    const media_type = detectImageMediaType(raw) orelse
        return r.errResult(call, "unsupported image format; expected PNG, JPEG, GIF, or WebP");

    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = ctx.alloc.alloc(u8, encoded_len) catch return r.errResult(call, "out of memory");
    _ = std.base64.standard.Encoder.encode(encoded, raw);

    return .{ .content = "Loaded image", .image = .{
        .url = std.fmt.allocPrint(ctx.alloc, "data:{s};base64,{s}", .{ media_type, encoded }) catch return r.errResult(call, "out of memory"),
        .media_type = media_type,
    } };
}

const ImageLoadError = error{
    EmptyImage,
    ImageTooLarge,
    ReadFailed,
    DownloadFailed,
    DownloadTimedOut,
};

fn imageLoadError(err: anyerror, remote: bool) []const u8 {
    return switch (err) {
        error.EmptyImage => "image is empty",
        error.ImageTooLarge => "image exceeds the 4 MB limit",
        error.DownloadTimedOut => "image download timed out",
        error.DownloadFailed => "failed to download image",
        error.ReadFailed => if (remote) "failed to download image" else "failed to read image",
        else => if (remote) "failed to download image" else "failed to read image",
    };
}

fn loadLocalImage(ctx: r.ToolContext, resolved: []const u8) ImageLoadError![]const u8 {
    const size_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "stat", "-c", "%s", resolved } }) catch
        return error.ReadFailed;
    defer ctx.base.exec_pool.alloc.free(size_res.stdout);
    defer ctx.base.exec_pool.alloc.free(size_res.stderr);
    if (size_res.ty != .success) return error.ReadFailed;

    const size_text = std.mem.trim(u8, size_res.stdout, " \t\r\n");
    const size = std.fmt.parseInt(usize, size_text, 10) catch return error.ReadFailed;
    if (size == 0) return error.EmptyImage;
    if (size > MAX_IMAGE_BYTES) return error.ImageTooLarge;

    const read_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "cat", "--", resolved } }) catch
        return error.ReadFailed;
    defer ctx.base.exec_pool.alloc.free(read_res.stderr);
    if (read_res.ty != .success) {
        ctx.base.exec_pool.alloc.free(read_res.stdout);
        return error.ReadFailed;
    }
    if (read_res.stdout.len == 0) {
        ctx.base.exec_pool.alloc.free(read_res.stdout);
        return error.EmptyImage;
    }
    if (read_res.stdout.len > MAX_IMAGE_BYTES) {
        ctx.base.exec_pool.alloc.free(read_res.stdout);
        return error.ImageTooLarge;
    }
    return read_res.stdout;
}

fn loadRemoteImage(ctx: r.ToolContext, url: []const u8) ImageLoadError![]const u8 {
    const result = ctx.base.exec_pool.runAndWaitTimeout(.{ .argv = &.{
        "curl",
        "-fsSL",
        "--max-filesize",
        "4194304",
        "--",
        url,
    } }, 30_000) catch return error.DownloadFailed;
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
    if (result.stdout.len > MAX_IMAGE_BYTES) {
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

test "detect image media type from magic bytes" {
    try std.testing.expectEqualStrings("image/png", detectImageMediaType("\x89PNG\r\n\x1a\nrest").?);
    try std.testing.expectEqualStrings("image/jpeg", detectImageMediaType("\xff\xd8\xffrest").?);
    try std.testing.expectEqualStrings("image/gif", detectImageMediaType("GIF89arest").?);
    try std.testing.expectEqualStrings("image/webp", detectImageMediaType("RIFFxxxxWEBPrest").?);
    try std.testing.expect(detectImageMediaType("not an image") == null);
}

test "looksBinary rejects NUL byte anywhere" {
    var data: [8208]u8 = @splat('a');
    data[data.len - 1] = 0;
    try std.testing.expect(looksBinary(&data));
    try std.testing.expect(looksBinary("a\x00b"));
}

test "looksBinary rejects invalid utf8 beyond sample window" {
    const data = "plain text prefix" ++ ("\xff" ** 4) ++ "\n";
    try std.testing.expect(looksBinary(data));
}

test "looksBinary accepts valid text" {
    try std.testing.expect(!looksBinary("line one\nline two\n"));
    try std.testing.expect(!looksBinary(""));
    try std.testing.expect(!looksBinary("héllo wörld ✓\n"));
}
