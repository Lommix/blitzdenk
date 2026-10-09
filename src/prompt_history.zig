const std = @import("std");
const session_store = @import("session_store.zig");

pub const FILE_NAME = "prompts.jsonl";
pub const MAX_ENTRIES = 100;

pub const Entry = struct {
    text: []const u8,
    timestamp: i128,
};

/// Appends one prompt line; the file materializes with the first call. Heals a
/// torn tail before appending so entries never fuse onto a line missing '\n'.
/// The journal grows forever; `load` caps what callers see.
pub fn append(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var line: std.Io.Writer.Allocating = .init(arena.allocator());
    try line.writer.print("{{\"kind\":\"prompt\",\"v\":1,\"ts\":{d},\"text\":", .{session_store.wallMillis(io)});
    try std.json.Stringify.value(text, .{}, &line.writer);
    try line.writer.writeAll("}\n");

    var buffer: [512]u8 = undefined;
    const file = dir.openFile(io, FILE_NAME, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, FILE_NAME, .{}),
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const end = stat.size;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(end);
    if (end > 0) {
        var tail: [1]u8 = undefined;
        const got = try file.readPositionalAll(io, &tail, end - 1);
        if (got == 1 and tail[0] != '\n') try writer.interface.writeByte('\n');
    }
    try writer.interface.writeAll(line.written());
    try writer.interface.flush();
}

/// Newest MAX_ENTRIES entries, oldest first, allocated in `alloc` (arena; freed
/// by dropping it). Entry strings alias per-line Allocating buffers that are
/// deliberately not freed: parseFromSliceLeaky slices must not sit on memory
/// the arena recycles, so `alloc` must be an arena that outlives the entries.
/// Corrupt or non-prompt lines are skipped.
pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]Entry {
    const file = dir.openFile(io, FILE_NAME, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(alloc);
    while (true) {
        var line_buf: std.Io.Writer.Allocating = .init(alloc);
        _ = reader.streamDelimiterEnding(&line_buf.writer, '\n') catch break;
        const line = line_buf.written();
        if (line.len > 0) {
            if (parsePrompt(alloc, line)) |entry| try entries.append(alloc, entry);
        }
        _ = reader.discardDelimiterInclusive('\n') catch break;
    }
    if (entries.items.len > MAX_ENTRIES) {
        const keep = entries.items.len - MAX_ENTRIES;
        std.mem.copyForwards(Entry, entries.items[0..MAX_ENTRIES], entries.items[keep..]);
        entries.shrinkRetainingCapacity(MAX_ENTRIES);
    }
    return entries.toOwnedSlice(alloc);
}

fn parsePrompt(alloc: std.mem.Allocator, line: []const u8) ?Entry {
    const Envelope = struct {
        kind: []const u8 = "",
        ts: i128 = 0,
        text: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Envelope, alloc, line, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, parsed.kind, "prompt")) return null;
    if (parsed.text.len == 0) return null;
    return .{ .text = parsed.text, .timestamp = parsed.ts };
}

test "load skips corrupt and foreign lines" {
    const testing = std.testing;
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = std.Io.Dir{ .handle = tmp.dir.handle };

    const body = "garbage\n{\"kind\":\"checkpoint\"}\n{\"kind\":\"prompt\",\"v\":1,\"ts\":5,\"text\":\"kept\"}\n";
    {
        const f = try dir.createFile(io, FILE_NAME, .{});
        defer f.close(io);
        var wb: [256]u8 = undefined;
        var w = f.writer(io, &wb);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try load(arena.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("kept", entries[0].text);
    try testing.expectEqual(@as(i128, 5), entries[0].timestamp);
}
