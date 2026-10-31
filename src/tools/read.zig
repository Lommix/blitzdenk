const r = @import("root.zig");
const std = @import("std");

const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

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
    const cwd = ctx.base.routeCwd();
    const rel_path = if (cwd.len > 0)
        r.replaceAll(args.file_path, cwd, ".", &buf)
    else
        args.file_path;

    const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.base.routeCwd(), args.file_path }) catch
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
    const harness_path = !is_url and r.isHarnessPath(resolved);

    const sniffed_type = if (is_url)
        null
    else
        sniffImageType(ctx, resolved, harness_path);
    if (is_url) {
        if (!ctx.agent().flags.vision)
            return r.errResult(call, "URL reads load images, but this model has no vision; use bash with curl to fetch the content");
        return viewImage(ctx, call, args.file_path, true, resolved, harness_path);
    }
    if (sniffed_type) |_| {
        if (!ctx.agent().flags.vision)
            return nonVisionResult(ctx, call, sniffed_type);
        return viewImage(ctx, call, args.file_path, false, resolved, harness_path);
    }

    const start_line: u64 = if (args.offset) |o| (if (o > 0) o else 1) else 1;
    const max_lines: u64 = if (args.limit) |l| l else r.MAX_DISPLAY_LINES;
    var start_buf: [24]u8 = undefined;
    var max_buf: [24]u8 = undefined;
    const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{start_line}) catch return r.errResult(call, "out of memory");
    const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{max_lines}) catch return r.errResult(call, "out of memory");

    var read_res = runRead(ctx, resolved, start_str, max_str, false) catch |err|
        return r.errResult(call, r.execFailure(ctx, "failed to read", resolved, @errorName(err)));
    if (harness_path and ctx.base.routeIsRemote() and isMissingResult(read_res)) {
        ctx.base.exec_pool.alloc.free(read_res.stdout);
        ctx.base.exec_pool.alloc.free(read_res.stderr);
        read_res = runRead(ctx, resolved, start_str, max_str, true) catch |err|
            return r.errResult(call, r.execFailure(ctx, "failed to read", resolved, @errorName(err)));
    }
    defer ctx.base.exec_pool.alloc.free(read_res.stdout);
    defer ctx.base.exec_pool.alloc.free(read_res.stderr);

    if (read_res.ty != .success) return r.errResult(call, r.execFailure(ctx, "failed to read", resolved, read_res.stderr));
    if (read_res.stdout_truncated or read_res.stderr_truncated) return r.errResult(call, "requested section exceeds the 4MB read limit; retry with offset and limit");
    const out = read_res.toOwned(ctx.alloc) catch return r.errResult(call, "oom");
    if (std.mem.startsWith(u8, out, "MISS:")) {
        ctx.alloc.free(out);
        return r.errResult(call, r.pathFailure(ctx, "file not found", args.file_path));
    }
    if (std.mem.startsWith(u8, out, "NOTFILE:")) {
        ctx.alloc.free(out);
        return r.errResult(call, r.pathFailure(ctx, "not a regular file", args.file_path));
    }
    if (std.mem.startsWith(u8, out, "NOREAD:")) {
        ctx.alloc.free(out);
        return r.errResult(call, r.pathFailure(ctx, "file is not readable", args.file_path));
    }
    if (std.mem.startsWith(u8, out, "EMPTY:")) {
        ctx.alloc.free(out);
        return r.okResult(call, "(empty file)");
    }
    if (std.mem.startsWith(u8, out, "OFFSET:")) {
        const total = std.mem.trim(u8, out["OFFSET:".len..], " \t\r\n");
        const msg = std.fmt.allocPrint(
            ctx.alloc,
            "offset {d} is past the end of file ({s} lines)",
            .{ start_line, total },
        ) catch "offset past end of file";
        ctx.alloc.free(out);
        return r.errResult(call, msg);
    }
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

const SNIFF_BYTES = "4100";

const READ_SCRIPT =
    \\if [ ! -e "$1" ]; then echo "MISS:$1"; exit 0; fi
    \\if [ ! -f "$1" ]; then echo "NOTFILE:$1"; exit 0; fi
    \\if [ ! -r "$1" ]; then echo "NOREAD:$1"; exit 0; fi
    \\total=$(wc -l < "$1")
    \\[ -n "$(tail -c 1 "$1")" ] && total=$((total + 1))
    \\if [ "$total" -eq 0 ]; then echo "EMPTY:"; exit 0; fi
    \\if [ "$total" -lt "$2" ]; then echo "OFFSET:$total"; exit 0; fi
    \\cat -n -- "$1" | tail -n +"$2" | head -n "$3"
;

fn runRead(ctx: r.ToolContext, resolved: []const u8, start_str: []const u8, max_str: []const u8, force_local: bool) !r.r.exec.CmdResult {
    return ctx.base.exec_pool.runAndWait(.{
        .argv = &.{ "/bin/sh", "-c", READ_SCRIPT, "read", resolved, start_str, max_str },
        .max_output = 4 * 1024 * 1024,
        .force_local = force_local,
    });
}

fn isMissingResult(res: r.r.exec.CmdResult) bool {
    return res.ty == .success and std.mem.startsWith(u8, res.stdout, "MISS:");
}

fn sniffImageType(ctx: r.ToolContext, resolved: []const u8, harness_path: bool) ?[]const u8 {
    if (sniffImageAt(ctx, resolved, false)) |media_type| return media_type;
    if (harness_path and ctx.base.routeIsRemote()) return sniffImageAt(ctx, resolved, true);
    return null;
}

fn sniffImageAt(ctx: r.ToolContext, resolved: []const u8, force_local: bool) ?[]const u8 {
    const res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "head", "-c", SNIFF_BYTES, "--", resolved }, .force_local = force_local }) catch
        return null;
    defer ctx.base.exec_pool.alloc.free(res.stdout);
    defer ctx.base.exec_pool.alloc.free(res.stderr);
    if (res.ty != .success) return null;
    return detectImageMediaType(res.stdout);
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

fn viewImage(ctx: r.ToolContext, call: r.r.sdk.ToolCall, file_path: []const u8, is_url: bool, resolved: []const u8, harness_path: bool) r.r.sdk.ToolOutput {
    const raw = if (is_url)
        loadUrlImage(ctx, file_path) catch |err| return r.errResult(call, imageLoadError(err, true))
    else
        loadLocalImage(ctx, resolved, harness_path) catch |err| return r.errResult(call, imageLoadError(err, false));
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

fn loadLocalImage(ctx: r.ToolContext, resolved: []const u8, harness_path: bool) ImageLoadError![]const u8 {
    if (loadImageAt(ctx, resolved, false)) |raw| return raw else |err| {
        if (harness_path and ctx.base.routeIsRemote()) return loadImageAt(ctx, resolved, true);
        return err;
    }
}

fn loadImageAt(ctx: r.ToolContext, resolved: []const u8, force_local: bool) ImageLoadError![]const u8 {
    const size_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "stat", "-c", "%s", resolved }, .force_local = force_local }) catch
        return error.ReadFailed;
    defer ctx.base.exec_pool.alloc.free(size_res.stdout);
    defer ctx.base.exec_pool.alloc.free(size_res.stderr);
    if (size_res.ty != .success) return error.ReadFailed;

    const size_text = std.mem.trim(u8, size_res.stdout, " \t\r\n");
    const size = std.fmt.parseInt(usize, size_text, 10) catch return error.ReadFailed;
    if (size == 0) return error.EmptyImage;
    if (size > MAX_IMAGE_BYTES) return error.ImageTooLarge;

    const read_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "cat", "--", resolved }, .max_output = MAX_IMAGE_BYTES, .force_local = force_local }) catch
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
    if (read_res.stdout_truncated or read_res.stdout.len > MAX_IMAGE_BYTES) {
        ctx.base.exec_pool.alloc.free(read_res.stdout);
        return error.ImageTooLarge;
    }
    return read_res.stdout;
}

fn loadUrlImage(ctx: r.ToolContext, url: []const u8) ImageLoadError![]const u8 {
    const result = ctx.base.exec_pool.runAndWaitTimeout(.{ .argv = &.{
        "curl",
        "-fsSL",
        "--max-filesize",
        "4194304",
        "--",
        url,
    }, .max_output = MAX_IMAGE_BYTES, .force_local = true }, 30_000) catch return error.DownloadFailed;
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
