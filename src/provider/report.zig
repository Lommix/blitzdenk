const std = @import("std");
const r = @import("root.zig");

pub const REPORT_DIR = "reports";
const BLITZ_DIR = ".blitz";
pub const MAX_TOOL_CHARS = 500;
const MAX_NAME_CHARS = 64;

pub fn writeReleasedReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    model: []const u8,
    slot_index: usize,
    chat: *const r.adapter.Chat,
) !void {
    var reports_dir = try openReportsDir(io);
    defer reports_dir.close(io);
    try writeOne(&reports_dir, io, gpa, name, model, slot_index, chat);
}

fn openReportsDir(io: std.Io) !std.Io.Dir {
    try std.Io.Dir.cwd().createDirPath(io, BLITZ_DIR);
    var blitz_dir = try std.Io.Dir.cwd().openDir(io, BLITZ_DIR, .{});
    defer blitz_dir.close(io);
    try blitz_dir.createDirPath(io, REPORT_DIR);
    return blitz_dir.openDir(io, REPORT_DIR, .{});
}

fn writeOne(
    reports_dir: *std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    model: []const u8,
    slot_index: usize,
    chat: *const r.adapter.Chat,
) !void {
    var name_buf: [MAX_NAME_CHARS]u8 = undefined;
    const safe_name = sanitize(name, &name_buf);
    const stamp = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const filename = try std.fmt.allocPrint(gpa, "{s}_{d}_{d}.md", .{ safe_name, stamp, slot_index });
    defer gpa.free(filename);

    var fbuf: [4096]u8 = undefined;
    const f = try reports_dir.createFile(io, filename, .{});
    defer f.close(io);
    var fw = f.writer(io, &fbuf);
    try writeAgentReport(&fw.interface, name, model, chat, slot_index);
    try fw.interface.flush();
}

fn writeAgentReport(
    w: *std.Io.Writer,
    name: []const u8,
    model: []const u8,
    chat: *const r.adapter.Chat,
    slot_index: usize,
) !void {
    var count: usize = 0;
    for (chat.messages.items) |msg| {
        if (reportable(msg)) count += 1;
    }

    try w.print("# Report: {s}\n\n", .{name});
    try w.print("- **Agent**: {s}\n- **Slot**: {d}\n- **Model**: {s}\n- **Messages**: {d}\n\n", .{ name, slot_index, model, count });

    for (chat.messages.items) |msg| try writeMessage(w, msg);
}

fn reportable(msg: r.adapter.Message) bool {
    return msg.role != .system and msg.flags.allow_export;
}

fn writeMessage(w: *std.Io.Writer, msg: r.adapter.Message) !void {
    if (!reportable(msg)) return;

    switch (msg.role) {
        .user => try w.writeAll("\n### User\n"),
        .agent => try w.writeAll("\n### Assistant\n"),
        .system => unreachable,
    }

    for (msg.parts) |part| switch (part) {
        .text => |txt| {
            if (std.mem.trim(u8, txt, " \t\r\n").len == 0) continue;
            try w.writeAll("\n");
            try w.writeAll(txt);
            try w.writeAll("\n");
        },
        .thinking => |th| {
            if (th.text.len == 0) continue;
            try w.writeAll("\n> ");
            try w.writeAll(th.text);
            try w.writeAll("\n");
        },
        .image => |img| {
            try w.print("\n_[image: {s}, {d} bytes]_\n", .{ img.media_type, img.data.len });
        },
        .tool_call => |call| {
            try w.print("\n**tool: {s}**\n\n```json\n", .{call.name});
            try writeTruncated(w, call.arguments, MAX_TOOL_CHARS);
            try w.writeAll("\n```\n");
        },
        .tool_result => |res| {
            if (res.is_error) {
                try w.writeAll("\n**tool result (error):**\n\n```\n");
            } else {
                try w.writeAll("\n**tool result:**\n\n```\n");
            }
            try writeTruncated(w, res.content, MAX_TOOL_CHARS);
            try w.writeAll("\n```\n");
        },
    };
}

fn writeTruncated(w: *std.Io.Writer, text: []const u8, max: usize) !void {
    if (text.len <= max) {
        try w.writeAll(text);
        return;
    }
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    try w.writeAll(text[0..end]);
    try w.print("\n_… truncated {d} bytes_", .{text.len - end});
}

fn sanitize(name: []const u8, buf: []u8) []const u8 {
    const len = @min(name.len, buf.len);
    const out = buf[0..len];
    for (name[0..len], 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
    }
    return out;
}

test "writeMessage renders roles and truncates tool results" {
    const alloc = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    const long = try alloc.alloc(u8, 600);
    defer alloc.free(long);
    @memset(long, 'x');

    var parts = [_]r.adapter.ContentPart{
        .{ .text = "hello" },
        .{ .tool_call = .{ .id = "c1", .name = "bash", .arguments = "{}" } },
        .{ .tool_result = .{ .call_id = "c1", .name = "bash", .content = long } },
    };

    const msg = r.adapter.Message{
        .role = .agent,
        .parts = &parts,
    };

    try writeMessage(&out.writer, msg);
    try out.writer.flush();
    const md = try out.toOwnedSlice();
    defer alloc.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "### Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**tool: bash**") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "truncated 100 bytes") != null);
}

test "writeOne writes a markdown report file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var chat: r.adapter.Chat = .{};
    defer chat.messages.deinit(alloc);
    defer for (chat.messages.items) |*msg| msg.freeParts(alloc);
    const text = try alloc.dupe(u8, "hello");
    try chat.addMessage(alloc, .user, &.{.{ .text = text }});

    try writeOne(&tmp.dir, std.testing.io, alloc, "code_reviewer", "test-model", 3, &chat);

    var iterate_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iterate_dir.close(std.testing.io);
    var entries = iterate_dir.iterate();
    const entry = (try entries.next(std.testing.io)) orelse return error.NoReportFile;
    try std.testing.expect((try entries.next(std.testing.io)) == null);
    try std.testing.expect(std.mem.startsWith(u8, entry.name, "code_reviewer_"));
    try std.testing.expect(std.mem.endsWith(u8, entry.name, "_3.md"));
}

