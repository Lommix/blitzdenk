const std = @import("std");

pub const context = @import("context.zig");
pub const Tool = context.Definition;
pub const ToolContext = context.Context;
pub const ToolCall = r.sdk.ToolCall;
pub const ToolResult = r.sdk.ToolOutput;
pub const bash = @import("bash.zig");
pub const read = @import("read.zig");
pub const ask = @import("ask.zig");
pub const agent = @import("agent.zig");
pub const edit = @import("edit.zig");
pub const write = @import("write.zig");
pub const reg = @import("../context_factory.zig");
pub const patch = @import("patch.zig");
pub const r = @import("../root.zig");
pub const tui = r.tui;
pub const search = @import("search.zig");
pub const start = @import("start.zig");
pub const skill = @import("skill.zig");

pub const MAX_DISPLAY_BYTES = 32 * 1024;
pub const MAX_DISPLAY_LINES = 2000;
pub const DISPLAY_CAP_TEXT = std.fmt.comptimePrint("{d} lines or {d}KB", .{ MAX_DISPLAY_LINES, @divTrunc(MAX_DISPLAY_BYTES, 1024) });
pub const STATUS_BUF: usize = 512;

pub fn setToolStatusPrint(ctx: ToolContext, call: ToolCall, comptime fmt: []const u8, args: anytype) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var buf: [STATUS_BUF]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    app.setToolStatus(ctx.base.self_id, call.id, w.buffered()) catch return;
}

pub fn setToolStatus(ctx: ToolContext, call: ToolCall, text: []const u8) !void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    try app.setToolStatus(ctx.base.self_id, call.id, text);
}

pub fn setToolChild(ctx: ToolContext, call: ToolCall, child_id: r.AgentId) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    app.setToolChild(ctx.base.self_id, call.id, child_id) catch {};
}

pub fn markConfigTouched(ctx: ToolContext, resolved: []const u8) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    if (app.lua_config_abs) |abs| {
        if (std.mem.eql(u8, resolved, abs)) {
            app.requestLuaReload();
            ctx.agent().markToolsDirty();
            return;
        }
    }
    if (app.lua_config_dir) |dir| {
        if (std.mem.startsWith(u8, resolved, dir)) {
            app.requestLuaReload();
            ctx.agent().markToolsDirty();
        }
    }
}

pub fn errResult(_: ToolCall, msg: []const u8) ToolResult {
    return .{
        .content = msg,
        .is_error = true,
    };
}

pub fn okResult(_: ToolCall, content: []const u8) ToolResult {
    return .{
        .content = content,
    };
}

pub fn parseArgs(comptime T: type, alloc: std.mem.Allocator, call: ToolCall) ?T {
    const parsed = std.json.parseFromSlice(T, alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.value;
}

pub fn replaceAll(input: []const u8, needle: []const u8, replacement: []const u8, buffer: []u8) []const u8 {
    if (needle.len == 0) return input;
    const out_len = std.mem.replacementSize(u8, input, needle, replacement);
    if (out_len > buffer.len) return input;
    _ = std.mem.replace(u8, input, needle, replacement, buffer[0..out_len]);
    return buffer[0..out_len];
}

pub fn truncateOutputToOwned(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
) []const u8 {
    return truncateOutputToOwnedSpill(alloc, output, max_bytes, max_lines, null);
}

/// Truncate `output` to its tail (last `max_lines` lines, last `max_bytes`
/// bytes — whichever binds first), with an optional spill locator embedded in
/// the notice. `spill_locator` points at a file (or null) holding the full output.
pub fn truncateOutputToOwnedSpill(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
    spill_locator: ?[]const u8,
) []const u8 {
    const total_lines = countLines(output);
    if (output.len <= max_bytes and total_lines <= max_lines) return ensureValidUtf8(alloc, output);

    const tail = output[collectLinesBack(output, max_bytes, max_lines)..];
    const kept = countLines(tail);

    const notice = if (spill_locator) |path|
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({d}KB cap). Full result saved at: {s} — call read with offset/limit to page through it.]",
            .{ kept, total_lines, @divTrunc(max_bytes, 1024), path },
        ) catch return output
    else
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({d}KB cap)]",
            .{ kept, total_lines, @divTrunc(max_bytes, 1024) },
        ) catch return output;
    defer alloc.free(notice);

    const raw = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ tail, notice }) catch
        return output;
    return ensureValidUtf8(alloc, raw);
}

/// True when `output` would be truncated by the given caps (matches
/// truncateOutputToOwnedSpill's entry condition). Callers gate spill-file
/// writes on this.
pub fn isOversized(output: []const u8, max_bytes: usize, max_lines: usize) bool {
    return output.len > max_bytes or countLines(output) > max_lines;
}

const MAX_SPILL_BYTES: usize = 64 * 1024 * 1024;

/// Write `content` to a best-effort OS-temp spill file, capped at MAX_SPILL_BYTES.
/// Returns an owned path on success, or null on any failure. Never propagates errors to the caller.
pub fn writeSpillFile(app_ctx: ?*anyopaque, io: std.Io, alloc: std.mem.Allocator, call_id: []const u8, content: []const u8) ?[]const u8 {
    const base = tmpDir(alloc, app_ctx) orelse return null;
    defer alloc.free(base);
    const safe_id = sanitizeCallId(alloc, call_id) orelse return null;
    defer alloc.free(safe_id);
    const basename = std.fmt.allocPrint(alloc, "blitz-spill-{s}.txt", .{safe_id}) catch return null;
    defer alloc.free(basename);
    const path = std.fs.path.join(alloc, &.{ base, basename }) catch return null;
    errdefer alloc.free(path);

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
    defer file.close(io);
    var cut = content.len -| MAX_SPILL_BYTES;
    while (cut < content.len and (content[cut] & 0xC0) == 0x80) cut += 1;
    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(content[cut..]) catch return null;
    writer.interface.flush() catch return null;
    return path;
}

/// Keep only filename-safe characters so a hostile call id cannot escape the
/// temp dir. Never returns empty.
fn sanitizeCallId(alloc: std.mem.Allocator, call_id: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (call_id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        out.append(alloc, if (ok) c else '_') catch return null;
    }
    if (out.items.len == 0) out.appendSlice(alloc, "id") catch return null;
    return alloc.dupe(u8, out.items) catch null;
}

fn tmpDir(alloc: std.mem.Allocator, app_ctx: ?*anyopaque) ?[]const u8 {
    if (app_ctx) |ptr| {
        const self: *r.app.App = @ptrCast(@alignCast(ptr));
        if (self.exec_pool.env.get("TMPDIR")) |dir| return alloc.dupe(u8, dir) catch null;
    }
    return alloc.dupe(u8, "/tmp") catch null;
}

/// Collect trailing lines from the end of `output`: the last `max_lines`
/// lines (matching `countLines` semantics), byte-clamped to `max_bytes` from
/// the end. Returns the codepoint-floor boundary of the tail start.
fn collectLinesBack(output: []const u8, max_bytes: usize, max_lines: usize) usize {
    const total = countLines(output);
    var line_start: usize = 0;
    if (total > max_lines) {
        const target_line = total - max_lines; // 0-based index of first kept line
        var line_idx: usize = 0;
        var i: usize = 0;
        while (i < output.len and line_idx < target_line) : (i += 1) {
            if (output[i] == '\n') {
                line_idx += 1;
                line_start = i + 1;
            }
        }
    }
    if (output.len - line_start > max_bytes)
        return utf8Floor(output, output.len - max_bytes);
    return line_start;
}

/// Walk end back so it never splits a multi-byte UTF-8 sequence.
fn utf8Floor(s: []const u8, end: usize) usize {
    var i = @min(end, s.len);
    if (i == s.len) return i;
    while (i > 0 and (s[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Return `raw` if already valid UTF-8; otherwise owned lossy copy (U+FFFD).
fn ensureValidUtf8(alloc: std.mem.Allocator, raw: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    return std.fmt.allocPrint(alloc, "{f}", .{std.unicode.fmtUtf8(raw)}) catch
        "(binary output; failed to sanitize utf-8)";
}

pub fn countLines(output: []const u8) usize {
    var lines: usize = 0;
    var pos: usize = 0;
    while (pos < output.len) {
        lines += 1;
        if (std.mem.indexOfScalar(u8, output[pos..], '\n')) |nl| {
            pos += nl + 1;
        } else {
            break;
        }
    }
    return lines;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "truncateOutputToOwned keeps valid utf8 as string payload" {
    const testing = std.testing;
    const in = "hello\nworld";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    try testing.expectEqualStrings(in, out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "truncateOutputToOwned sanitizes invalid utf8" {
    const testing = std.testing;
    // 0xFF is never valid UTF-8 lead/cont — classic binary command output.
    const in = "ok\xffnope";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    // Must serialize as a JSON string, never a byte array.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(out, .{}, &w);
    const json = w.buffered();
    try testing.expect(json.len >= 2 and json[0] == '"');
    try testing.expect(json[json.len - 1] == '"');
}

test "truncateOutputToOwned keeps the tail for oversized output" {
    const testing = std.testing;
    // 100 lines of "line N\n"; a small budget forces a tail-only cut.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "line{d}\n", .{i});
        defer testing.allocator.free(line);
        try buf.appendSlice(testing.allocator, line);
    }
    const out = truncateOutputToOwned(testing.allocator, buf.items, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    defer if (out.ptr != buf.items.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    // The final line "line99" must survive as the tail.
    try testing.expect(std.mem.indexOf(u8, out, "line99") != null);
}

test "truncateOutputToOwned drops the head and keeps the tail on line cap" {
    const testing = std.testing;
    const in = "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\n";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, 2);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "EEEE\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "AAAA") == null);
}

test "collectLinesBack is codepoint-safe at the byte boundary" {
    const testing = std.testing;
    // "é" is c3 a9; cutting at a byte count that lands mid-sequence must floor.
    const in = "ab\xc3\xa9cd\nef\xc3\xa9gh\n";
    const tail_start = collectLinesBack(in, 4, 100);
    try testing.expect(std.unicode.utf8ValidateSlice(in[tail_start..]));
}

test "truncateOutputToOwned does not split multi-byte utf8" {
    const testing = std.testing;
    // "é" is c3 a9 — cut max_bytes inside the sequence.
    const in = "ab\xc3\xa9cd";
    const out = truncateOutputToOwned(testing.allocator, in, 3, MAX_DISPLAY_LINES);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "writeSpillFile persists a small payload and sanitizes the call id" {
    const testing = std.testing;
    const payload = "hello spill\n";
    const path = writeSpillFile(null, testing.io, testing.allocator, "b.a/d/1", payload).?;
    defer testing.allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited64(1024)) catch
        return error.TestUnexpectedResult;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(payload, content);

    // The hostile call id must not escape into the basename (slashes/dots are
    // replaced), so the filename only ever lands under the temp dir.
    const base = std.fs.path.basename(path);
    try testing.expect(std.mem.indexOf(u8, base, "/") == null);
    try testing.expect(std.mem.eql(u8, base, "blitz-spill-b_a_d_1.txt"));
}
