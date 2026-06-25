const std = @import("std");

pub const prv = @import("provider");
pub const bash = @import("bash.zig");
pub const read = @import("read.zig");
pub const tasks = @import("task.zig");
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

    if (end_byte >= output.len) return output;

    const slice = output[0..end_byte];

    const out = std.fmt.allocPrint(
        alloc,
        "<result>\n{s}\n</result>\n..<stats>showing {d} of {d} bytes, {d} of {d} lines</stats>",
        .{ slice, end_byte, output.len, lines_collected, total_lines },
    ) catch slice;

    return std.unicode.fmtUtf8(out).data;
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
