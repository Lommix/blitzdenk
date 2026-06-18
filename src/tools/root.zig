const prv = @import("provider");
const std = @import("std");

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

pub const MAX_DISPLAY_BYTES = 16 * 1024;
pub const MAX_DISPLAY_LINES = 500;

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
