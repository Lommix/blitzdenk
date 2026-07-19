const std = @import("std");

pub const prv = @import("provider");
pub const bash = @import("bash.zig");
pub const read = @import("read.zig");
pub const todos = @import("todo.zig");
pub const ask = @import("ask.zig");
pub const ssh = @import("ssh.zig");
pub const agent = @import("agent.zig");
pub const edit = @import("edit.zig");
pub const write = @import("write.zig");
pub const parse = @import("htmlparser.zig");
pub const reg = @import("../context_factory.zig");
pub const patch = @import("patch.zig");
pub const r = @import("../root.zig");
pub const tui = r.tui;
pub const rg = @import("rg.zig");
pub const skill = @import("skill.zig");
pub const start = @import("start.zig");

pub const MAX_DISPLAY_BYTES = 32 * 1024;
pub const MAX_DISPLAY_LINES = 1000;

pub fn fmtSpan(ctx: *r.prv.tool.ToolContext, comptime fmt: []const u8, args: anytype, style: tui.Style) r.tui.Span {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.swarm.context.ptr));
    return .{
        .content = std.fmt.allocPrint(app.sessionAlloc(), fmt, args) catch "",
        .style = style,
    };
}

pub fn setToolStatusPrint(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall, comptime fmt: []const u8, args: anytype) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.swarm.context.ptr));
    const alloc = app.sessionAlloc();

    const txt = std.fmt.allocPrint(alloc, fmt, args) catch return;
    const count = std.mem.count(u8, txt, "\n") + 1;

    // TODO: this does not need to be allocated
    const spans = alloc.alloc(r.tui.Span, count) catch return;
    const lines = alloc.alloc(r.app.ToolStatusLineInput, count) catch return;

    var it = std.mem.splitScalar(u8, txt, '\n');
    var i: usize = 0;
    while (it.next()) |text| : (i += 1) {
        spans[i] = .{ .content = text };
        lines[i] = .{ .spans = spans[i .. i + 1] };
    }
    app.setToolStatus(ctx.self_id, call.id, lines) catch return;
}

pub fn setToolStatusSpan(
    ctx: r.prv.tool.ToolContext,
    call: r.prv.adapter.ToolCall,
    span: r.tui.Span,
) !void {
    try setToolStatusParagraph(ctx, call, &.{&.{span}});
}

pub fn setToolStatusSpans(
    ctx: r.prv.tool.ToolContext,
    call: r.prv.adapter.ToolCall,
    spans: []const r.tui.Span,
) !void {
    try setToolStatusParagraph(ctx, call, &.{spans});
}

pub fn setToolStatusLine(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall, line: r.tui.Line) !void {
    try setToolStatusLines(ctx, call, &.{line});
}

pub fn setToolStatusLines(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall, lines: []const r.tui.Line) !void {
    const inputs = try ctx.alloc.alloc(r.app.ToolStatusLineInput, lines.len);
    for (lines, 0..) |line, i| inputs[i] = .{ .spans = line.spans.items, .style = line.style };
    const app = ctx.swarm.context.cast(r.app.App);
    try app.setToolStatus(ctx.self_id, call.id, inputs);
}

pub fn setToolStatusParagraph(
    ctx: r.prv.tool.ToolContext,
    call: r.prv.adapter.ToolCall,
    lines: []const []const r.tui.Span,
) !void {
    const inputs = try ctx.alloc.alloc(r.app.ToolStatusLineInput, lines.len);
    for (lines, 0..) |spans, i| inputs[i] = .{ .spans = spans };
    const app = ctx.swarm.context.cast(r.app.App);
    try app.setToolStatus(ctx.self_id, call.id, inputs);
}

pub fn setToolChild(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall, child_id: r.prv.Swarm.AgentId) void {
    const app = ctx.swarm.context.cast(r.app.App);
    app.setToolChild(ctx.self_id, call.id, child_id) catch {};
}

pub fn errResult(call: prv.adapter.ToolCall, msg: []const u8) prv.adapter.ToolResult {
    return .{
        .call_id = call.id,
        .name = call.name,
        .content = msg,
        .is_error = true,
    };
}

pub fn okResult(call: prv.adapter.ToolCall, content: []const u8) prv.adapter.ToolResult {
    return .{
        .call_id = call.id,
        .name = call.name,
        .content = content,
    };
}

pub fn parseArgs(comptime T: type, alloc: std.mem.Allocator, call: prv.adapter.ToolCall) ?T {
    const parsed = std.json.parseFromSlice(T, alloc, call.arguments, .{
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
    if (output.len == 0) return output;

    const total_lines = countLines(output);
    var end_byte: usize = 0;
    var lines_collected: usize = 0;
    var pos: usize = 0;

    while (pos < output.len and lines_collected < max_lines and end_byte < max_bytes) {
        const next_line_end = if (std.mem.indexOfScalar(u8, output[pos..], '\n')) |nl|
            pos + nl + 1
        else
            output.len;
        const remaining_bytes = max_bytes - end_byte;
        if (next_line_end - pos > remaining_bytes) {
            end_byte += remaining_bytes;
            if (remaining_bytes > 0) lines_collected += 1;
            break;
        }
        end_byte = next_line_end;
        lines_collected += 1;
        pos = next_line_end;
    }

    // Mid-sequence cut makes valid UTF-8 invalid; floor to codepoint boundary.
    end_byte = utf8Floor(output, end_byte);

    const raw: []const u8 = if (end_byte >= output.len)
        output
    else blk: {
        const slice = output[0..end_byte];
        break :blk std.fmt.allocPrint(
            alloc,
            "<result>\n{s}\n</result>\n..<stats>showing {d} of {d} bytes, {d} of {d} lines</stats>",
            .{ slice, end_byte, output.len, lines_collected, total_lines },
        ) catch slice;
    };

    // std.json.Stringify emits invalid UTF-8 []const u8 as a JSON number array
    // (bytes), not a string. Provider APIs reject that on the next request.
    // fmtUtf8(...).data is a no-op wrapper; format through {f} to replace.
    return ensureValidUtf8(alloc, raw);
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

fn countLines(output: []const u8) usize {
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

test "truncateOutputToOwned does not split multi-byte utf8" {
    const testing = std.testing;
    // "é" is c3 a9 — cut max_bytes inside the sequence.
    const in = "ab\xc3\xa9cd";
    const out = truncateOutputToOwned(testing.allocator, in, 3, MAX_DISPLAY_LINES);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}
