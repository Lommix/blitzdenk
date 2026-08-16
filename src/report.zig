const std = @import("std");
const sdk = @import("blitz-sdk");

pub const REPORT_DIR = "reports";
const BLITZ_DIR = ".blitz";
const MAX_NAME_CHARS = 64;

pub fn writeReleasedReport(
    io: std.Io,
    alloc: std.mem.Allocator,
    name: []const u8,
    model: []const u8,
    slot_index: usize,
    messages: []const sdk.Message,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, BLITZ_DIR);
    var blitz_dir = try std.Io.Dir.cwd().openDir(io, BLITZ_DIR, .{});
    defer blitz_dir.close(io);
    try blitz_dir.createDirPath(io, REPORT_DIR);
    var reports_dir = try blitz_dir.openDir(io, REPORT_DIR, .{});
    defer reports_dir.close(io);
    var name_buffer: [MAX_NAME_CHARS]u8 = undefined;
    const safe_name = sanitize(name, &name_buffer);
    const stamp = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const filename = try std.fmt.allocPrint(alloc, "{s}_{d}_{d}.md", .{ safe_name, stamp, slot_index });
    defer alloc.free(filename);
    var file_buffer: [4096]u8 = undefined;
    const file = try reports_dir.createFile(io, filename, .{});
    defer file.close(io);
    var writer = file.writer(io, &file_buffer);
    try writeAgentReport(&writer.interface, name, model, slot_index, messages);
    try writer.interface.flush();
}

fn writeAgentReport(writer: *std.Io.Writer, name: []const u8, model: []const u8, slot_index: usize, messages: []const sdk.Message) !void {
    var count: usize = 0;
    for (messages) |message| {
        if (reportable(message)) count += 1;
    }
    try writer.print("# Report: {s}\n\n", .{name});
    try writer.print("- **Agent**: {s}\n- **Slot**: {d}\n- **Model**: {s}\n- **Messages**: {d}\n", .{ name, slot_index, model, count });
    for (messages) |message| try writeMessage(writer, message);
}

fn reportable(message: sdk.Message) bool {
    return message.role != .system and message.role != .developer;
}

fn writeMessage(writer: *std.Io.Writer, message: sdk.Message) !void {
    if (!reportable(message)) return;
    try writer.print("\n### {s}\n", .{switch (message.role) {
        .user => "User",
        .assistant => "Assistant",
        .tool => "Tool",
        .system, .developer => unreachable,
    }});
    for (message.parts()) |part| switch (part) {
        .text => |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) try writer.print("\n{s}\n", .{text});
        },
        .reasoning => |reasoning| {
            if (reasoning.text.len > 0) try writer.print("\n> {s}\n", .{reasoning.text});
        },
        .image => |image| try writer.print("\n_[image: {s}]_\n", .{image.media_type}),
        .tool_call => |call| try writer.print("\n#### Tool call: `{s}`\n\n```json\n{s}\n```\n", .{ call.name, call.input }),
        .tool_result => |result| try writer.print("\n#### Tool result: `{s}`{s}\n\n```text\n{s}\n```\n", .{ result.name, if (result.is_error) " (error)" else "", result.output }),
        .file => |file| try writer.print("\n_[file: {s}, {s}]_\n", .{ file.filename, file.media_type }),
        .provider_data => {},
    };
}

fn sanitize(value: []const u8, buffer: *[MAX_NAME_CHARS]u8) []const u8 {
    var length: usize = 0;
    for (value) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') byte else '_';
        length += 1;
    }
    return if (length > 0) buffer[0..length] else "agent";
}

test "SDK report renders messages and tool parts" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeAgentReport(&writer, "worker", "model", 2, &.{
        sdk.UserMessage("hello"),
        .{ .role = .assistant, .content = &.{
            sdk.Part.textPart("done"),
            sdk.Part.toolCallPart("call", "read", "{\"path\":\"a\"}"),
        } },
        sdk.ToolMessage("call", "read", "content"),
    });
    const output = buffer[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "# Report: worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Tool call: `read`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Tool result: `read`") != null);
}
