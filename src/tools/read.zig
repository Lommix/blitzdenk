const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

/// Bad models always read to little or cut at bad lines. Padding the read scope helps
const READ_PADDING = 5;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

pub const ReadTool = prv.tool.Tool{
    .def = .{
        .name = "read",
        .description = "Read the contents of a file. Output is truncated to" ++ std.fmt.comptimePrint("{d} lines or {d} KB", .{ r.MAX_DISPLAY_LINES, @divTrunc(r.MAX_DISPLAY_BYTES, 1024) }) ++
            \\(whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.\n" ++
            \\OUTPUT FORMAT: each line is prefixed with `<right-aligned line number><TAB>`, e.g. `   42\\tcode`. The number+tab is display only and is NOT part of the file. " ++
            \\When using oldText for the edit tool, strip the prefix and use the raw line content exactly (preserve original tabs/spaces verbatim, no line numbers)."
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "Path to the file to read (relative to cwd or absolute)"},
        \\      "offset": {"type": "number", "description": "Line number to start reading from (1-indexed)"},
        \\      "limit": {"type": "number", "description": "Maximum number of lines to read"}
        \\  },
        \\  "required": ["path"]
        \\}
        ,
    },
    .func = &run,
};

pub const ViewImageTool = prv.tool.Tool{
    .def = .{
        .name = "view_image",
        .description = "Load an image from a local path or HTTP(S) URL into the model context. Supports PNG, JPEG, GIF, and WebP images up to 4 MB.",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "Local image path (relative to cwd or absolute) or HTTP(S) URL"}
        \\  },
        \\  "required": ["path"]
        \\}
        ,
    },
    .func = &viewImage,
};

pub const Stat = prv.agent.FileStat;
pub const FileStats = prv.agent.FileStats;

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };

    var args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");

    if (args.offset) |off| {
        args.offset = off -| READ_PADDING;
    }

    if (args.limit) |off| {
        args.limit = off + READ_PADDING;
    }

    if (args.path.len == 0) return r.errResult(call, "path is empty");

    var buf: [512]u8 = undefined;
    const rel_path = if (ctx.cwd.len > 0)
        r.replaceAll(args.path, ctx.cwd, ".", &buf)
    else
        args.path;

    const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, args.path }) catch
        return r.errResult(call, "failed to resolve path");

    const full_read = args.offset == null and args.limit == null;

    const app = ctx.swarm.context.cast(@import("../app.zig").App);
    var read_info: []const u8 = rel_path;

    if (args.limit) |l| {
        if (args.offset) |o| {
            read_info = std.fmt.allocPrint(app.sessionAlloc(), "{s} offset: {d} limit: {d}", .{ rel_path, o, l }) catch "";
        } else {
            read_info = std.fmt.allocPrint(app.sessionAlloc(), "{s} limit: {d}", .{ rel_path, l }) catch "";
        }
    } else if (args.offset) |o| {
        read_info = std.fmt.allocPrint(app.sessionAlloc(), "{s} offset: {d}", .{ rel_path, o }) catch "";
    }

    r.setToolStatusSpans(ctx, call, &.{
        .{ .content = "read ", .style = .{ .modifier = .{ .bold = true } } },
        .{ .content = read_info, .style = .{ .fg = app.theme.muted } },
    }) catch {};

    // Stat for mtime first so we can short-circuit unchanged re-reads.
    const stat_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "stat", "-c", "%Y", resolved } }) catch
        return r.errResult(call, "failed to stat file");
    defer ctx.swarm.exec.alloc.free(stat_res.stdout);
    defer ctx.swarm.exec.alloc.free(stat_res.stderr);

    if (stat_res.ty != .success) {
        const msg = if (stat_res.stderr.len > 0)
            ctx.alloc.dupe(u8, stat_res.stderr) catch "stat failed"
        else
            "stat failed";
        return r.errResult(call, msg);
    }

    const trimmed = std.mem.trim(u8, stat_res.stdout, " \t\r\n");
    const mtime = std.fmt.parseInt(i64, trimmed, 10) catch return r.errResult(call, "failed to parse mtime stat");

    {
        const g = ctx.agent().file_stats.lock(ctx.io);
        defer g.unlock();
        const look = g.ptr.getOrPut(ctx.alloc, resolved) catch return r.errResult(call, "oom");
        if (look.found_existing and full_read and mtime <= look.value_ptr.last_read) {
            return r.okResult(call, "File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.");
        }
        if (!look.found_existing) {
            look.value_ptr.* = .{ .last_read = mtime, .last_write = 0 };
        } else {
            look.value_ptr.last_read = mtime;
        }
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    // Read with cat -n for line numbering, sliced by offset/limit.
    const start_line: u64 = if (args.offset) |o| (if (o > 0) o else 1) else 1;
    const max_lines: u64 = if (args.limit) |l| l else r.MAX_DISPLAY_LINES;
    const command = std.fmt.allocPrint(ctx.alloc, "cat -n '{s}' | tail -n +{d} | head -n {d}", .{
        resolved, start_line, max_lines,
    }) catch return r.errResult(call, "out of memory");

    const read_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "/bin/sh", "-c", command } }) catch
        return r.errResult(call, "failed to read file");
    defer ctx.swarm.exec.alloc.free(read_res.stdout);
    defer ctx.swarm.exec.alloc.free(read_res.stderr);

    const out = read_res.toOwned(ctx.alloc) catch return r.errResult(call, "oom");
    return r.okResult(call, r.truncateOutputToOwned(ctx.alloc, out, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES));
}

fn viewImage(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct { path: []const u8 };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");

    if (args.path.len == 0) return r.errResult(call, "path is empty");

    const is_url = std.mem.startsWith(u8, args.path, "http://") or
        std.mem.startsWith(u8, args.path, "https://");

    var display_buf: [512]u8 = undefined;
    const display_path = if (!is_url and ctx.cwd.len > 0)
        r.replaceAll(args.path, ctx.cwd, ".", &display_buf)
    else
        args.path;

    const app = ctx.swarm.context.cast(@import("../app.zig").App);
    r.setToolStatusSpans(ctx, call, &.{
        .{ .content = "view image ", .style = .{ .modifier = .{ .bold = true } } },
        .{ .content = display_path, .style = .{ .fg = app.theme.muted } },
    }) catch {};

    const raw = if (is_url)
        loadRemoteImage(ctx, args.path) catch |err| return r.errResult(call, imageLoadError(err, true))
    else blk: {
        const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, args.path }) catch
            return r.errResult(call, "failed to resolve image path");
        break :blk loadLocalImage(ctx, resolved) catch |err| return r.errResult(call, imageLoadError(err, false));
    };
    defer ctx.swarm.exec.alloc.free(raw);

    const media_type = detectImageMediaType(raw) orelse
        return r.errResult(call, "unsupported image format; expected PNG, JPEG, GIF, or WebP");

    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = ctx.alloc.alloc(u8, encoded_len) catch return r.errResult(call, "out of memory");
    _ = std.base64.standard.Encoder.encode(encoded, raw);

    return .{
        .call_id = call.id,
        .name = call.name,
        .content = "Loaded image",
        .image = .{ .media_type = media_type, .data = encoded },
    };
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

fn loadLocalImage(ctx: prv.tool.ToolContext, resolved: []const u8) ImageLoadError![]const u8 {
    const size_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "stat", "-c", "%s", resolved } }) catch
        return error.ReadFailed;
    defer ctx.swarm.exec.alloc.free(size_res.stdout);
    defer ctx.swarm.exec.alloc.free(size_res.stderr);
    if (size_res.ty != .success) return error.ReadFailed;

    const size_text = std.mem.trim(u8, size_res.stdout, " \t\r\n");
    const size = std.fmt.parseInt(usize, size_text, 10) catch return error.ReadFailed;
    if (size == 0) return error.EmptyImage;
    if (size > MAX_IMAGE_BYTES) return error.ImageTooLarge;

    const read_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "cat", "--", resolved } }) catch
        return error.ReadFailed;
    defer ctx.swarm.exec.alloc.free(read_res.stderr);
    if (read_res.ty != .success) {
        ctx.swarm.exec.alloc.free(read_res.stdout);
        return error.ReadFailed;
    }
    if (read_res.stdout.len == 0) {
        ctx.swarm.exec.alloc.free(read_res.stdout);
        return error.EmptyImage;
    }
    if (read_res.stdout.len > MAX_IMAGE_BYTES) {
        ctx.swarm.exec.alloc.free(read_res.stdout);
        return error.ImageTooLarge;
    }
    return read_res.stdout;
}

fn loadRemoteImage(ctx: prv.tool.ToolContext, url: []const u8) ImageLoadError![]const u8 {
    const result = ctx.swarm.exec.runAndWaitTimeout(.{ .argv = &.{
        "curl",
        "-fsSL",
        "--max-filesize",
        "4194304",
        "--",
        url,
    } }, 30_000) catch return error.DownloadFailed;
    defer ctx.swarm.exec.alloc.free(result.stderr);
    if (result.ty == .timeout) {
        ctx.swarm.exec.alloc.free(result.stdout);
        return error.DownloadTimedOut;
    }
    if (result.ty != .success) {
        ctx.swarm.exec.alloc.free(result.stdout);
        if (result.exit_code == 63) return error.ImageTooLarge;
        return error.DownloadFailed;
    }
    if (result.stdout.len == 0) {
        ctx.swarm.exec.alloc.free(result.stdout);
        return error.EmptyImage;
    }
    if (result.stdout.len > MAX_IMAGE_BYTES) {
        ctx.swarm.exec.alloc.free(result.stdout);
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
