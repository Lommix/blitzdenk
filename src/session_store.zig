const std = @import("std");
const session = @import("session.zig");

pub const DIR_RELATIVE = ".blitz/sessions";
pub const GC_AGE_MS: i64 = 16 * 24 * 60 * 60 * std.time.ms_per_s;
const FORMAT_VERSION = 1;
const MAX_CHECKPOINTS = 4;
const ID_RANDOM_LEN = 4;
const NAME_EXTENSION = ".jsonl";
const HEX = "0123456789abcdef";
pub const ID_LEN = "20250827-184000-".len + ID_RANDOM_LEN;

pub const Header = struct {
    id: []const u8,
    created_ms: i64 = 0,
    cwd: []const u8 = "",
};

pub const Entry = struct {
    id: []const u8,
    modified_ms: i64,
};

/// Header plus the newest parseable checkpoint, all allocated in the caller's
/// arena. Freed by dropping that arena.
pub const Loaded = struct {
    header: Header,
    save: session.SaveState,
};

/// Append-only JSONL journal: header line, then full-snapshot checkpoint
/// lines. All paths are resolved against `base` — always pass the *project*
/// directory, not the process cwd, so a session started via
/// `blitz /path/to/proj` is discoverable by `blitz continue` inside that
/// project. Loads tolerate torn or corrupt tail lines by falling back to the
/// last parseable checkpoint; a file without a usable checkpoint counts as
/// absent.
pub const Store = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    base: std.Io.Dir,
    file_name: ?[]const u8 = null,
    checkpoint_count: u32 = 0,

    pub fn deinit(self: *Store) void {
        if (self.file_name) |name| self.gpa.free(name);
        self.file_name = null;
    }

    pub fn create(self: *Store, cwd: []const u8) !void {
        var sessions_dir = try openSessionsDir(self.base, self.io);
        defer sessions_dir.close(self.io);

        const now = wallMillis(self.io);
        var id_buf: [ID_LEN]u8 = undefined;
        formatId(&id_buf, now, self.io);
        const file_name = try std.fmt.allocPrint(self.gpa, "{s}" ++ NAME_EXTENSION, .{id_buf});
        errdefer self.gpa.free(file_name);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const header_line = try headerLine(arena.allocator(), &id_buf, now, cwd);

        var buffer: [512]u8 = undefined;
        const file = try sessions_dir.createFile(self.io, file_name, .{});
        errdefer sessions_dir.deleteFile(self.io, file_name) catch {};
        defer file.close(self.io);
        var writer = file.writer(self.io, &buffer);
        try writer.interface.writeAll(header_line);
        try writer.interface.flush();

        if (self.file_name) |old| self.gpa.free(old);
        self.file_name = file_name;
        self.checkpoint_count = 0;
    }

    /// Opens an existing journal; the next append may compact immediately.
    pub fn open(self: *Store, file_name: []const u8) !void {
        const copy = try self.gpa.dupe(u8, file_name);
        if (self.file_name) |old| self.gpa.free(old);
        self.file_name = copy;
        self.checkpoint_count = MAX_CHECKPOINTS;
    }

    /// Copies the current session id into `buf`, null when no file is open.
    pub fn currentId(self: *Store, buf: []u8) ?[]const u8 {
        const name = self.file_name orelse return null;
        const stem_len = name.len - NAME_EXTENSION.len;
        if (stem_len > buf.len) return null;
        @memcpy(buf[0..stem_len], name[0..stem_len]);
        return buf[0..stem_len];
    }

    /// Appends one snapshot line; compacts (rewrite via temp+rename) past the cap.
    /// The 512-byte writer buffer streams fine even for multi-MB checkpoint
    /// lines — do not "optimize" it to line size.
    pub fn appendCheckpoint(self: *Store, save: session.SaveState) !void {
        const name = self.file_name orelse return error.NoSessionOpen;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var line: std.Io.Writer.Allocating = .init(alloc);
        try line.writer.print("{{\"kind\":\"checkpoint\",\"ms\":{d},\"save\":", .{wallMillis(self.io)});
        try std.json.Stringify.value(save, .{}, &line.writer);
        try line.writer.writeAll("}\n");

        var buffer: [512]u8 = undefined;
        var sessions_dir = try openSessionsDir(self.base, self.io);
        defer sessions_dir.close(self.io);
        const file = try sessions_dir.openFile(self.io, name, .{ .mode = .read_write });
        defer file.close(self.io);
        const end = try endOffset(file, self.io);
        var writer = file.writer(self.io, &buffer);
        try writer.seekTo(end);
        // Heal a torn tail (crash/ENOSPC mid-write): never fuse the fresh
        // checkpoint onto a line missing its '\n'.
        if (end > 0) {
            var tail: [1]u8 = undefined;
            const got = try file.readPositionalAll(self.io, &tail, end - 1);
            if (got == 1 and tail[0] != '\n') try writer.interface.writeByte('\n');
        }
        try writer.interface.writeAll(line.written());
        try writer.interface.flush();
        self.checkpoint_count += 1;

        if (self.checkpoint_count > MAX_CHECKPOINTS) self.compact() catch |err| {
            std.log.scoped(.session).warn("checkpoint compaction failed: {s}", .{@errorName(err)});
        };
    }

    /// Rewrites header + newest checkpoint through a temp file and rename.
    /// State (`checkpoint_count`) is only committed after the rename succeeds,
    /// so a failure leaves the Store consistent with the on-disk journal.
    fn compact(self: *Store) !void {
        const name = self.file_name orelse return error.NoSessionOpen;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const loaded = (try load(alloc, self.io, self.base, name)) orelse return error.NoCheckpoint;

        const tmp_name = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{name});
        defer self.gpa.free(tmp_name);

        var sessions_dir = try openSessionsDir(self.base, self.io);
        defer sessions_dir.close(self.io);

        const header_line = try headerLine(alloc, loaded.header.id, loaded.header.created_ms, loaded.header.cwd);

        var line: std.Io.Writer.Allocating = .init(alloc);
        try line.writer.print("{{\"kind\":\"checkpoint\",\"ms\":{d},\"save\":", .{wallMillis(self.io)});
        try std.json.Stringify.value(loaded.save, .{}, &line.writer);
        try line.writer.writeAll("}\n");

        var buffer: [512]u8 = undefined;
        const tmp = try sessions_dir.createFile(self.io, tmp_name, .{});
        defer tmp.close(self.io);
        var writer = tmp.writer(self.io, &buffer);
        try writer.interface.writeAll(header_line);
        try writer.interface.writeAll(line.written());
        try writer.interface.flush();

        try std.Io.Dir.rename(sessions_dir, tmp_name, sessions_dir, name, self.io);
        self.checkpoint_count = 1;
    }
};

fn endOffset(file: std.Io.File, io: std.Io) !u64 {
    const stat = try file.stat(io);
    return stat.size;
}

fn headerLine(alloc: std.mem.Allocator, id: []const u8, created_ms: i64, cwd: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.print("{{\"kind\":\"header\",\"v\":{d},\"id\":\"{s}\",\"created_ms\":{d},\"cwd\":", .{ FORMAT_VERSION, id, created_ms });
    try std.json.Stringify.value(cwd, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn wallMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
}

pub fn idLen() usize {
    return ID_LEN;
}

fn formatId(buf: []u8, millis: i64, io: std.Io) void {
    const secs: u64 = @intCast(@divTrunc(millis, std.time.ms_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var random_bytes: [ID_RANDOM_LEN]u8 = undefined;
    io.random(&random_bytes);
    const date_end = idLen() - ID_RANDOM_LEN;
    _ = std.fmt.bufPrint(buf[0..date_end], "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    for (buf[date_end..], random_bytes) |*out, b| out.* = HEX[b % HEX.len];
}

pub fn list(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir) ![]Entry {
    var sessions_dir = base.openDir(io, DIR_RELATIVE, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer sessions_dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| alloc.free(entry.id);
        entries.deinit(alloc);
    }
    var it = sessions_dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |item| {
        if (item.kind != .file) continue;
        if (!std.mem.endsWith(u8, item.name, NAME_EXTENSION)) continue;
        if (std.mem.endsWith(u8, item.name, ".tmp")) continue;
        const stat = sessions_dir.statFile(io, item.name, .{}) catch continue;
        try entries.append(alloc, .{
            .id = try alloc.dupe(u8, item.name[0 .. item.name.len - NAME_EXTENSION.len]),
            .modified_ms = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)),
        });
    }
    std.mem.sort(Entry, entries.items, {}, entryNewer);
    return entries.toOwnedSlice(alloc);
}

fn entryNewer(_: void, a: Entry, b: Entry) bool {
    return a.modified_ms > b.modified_ms;
}

pub fn freeList(alloc: std.mem.Allocator, entries: []Entry) void {
    if (entries.len == 0) return;
    for (entries) |entry| alloc.free(entry.id);
    alloc.free(entries);
}

/// Resolves an id prefix to exactly one session in `base`. Null when none
/// matches; `error.AmbiguousSessionId` when several do.
pub fn resolve(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, prefix: []const u8) !?[]const u8 {
    const entries = try list(alloc, io, base);
    defer freeList(alloc, entries);
    var found: ?[]const u8 = null;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.id, prefix)) continue;
        if (found != null) return error.AmbiguousSessionId;
        found = try alloc.dupe(u8, entry.id);
    }
    return found;
}

/// Journal file name for a session id (owns the extension knowledge).
pub fn fileName(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}" ++ NAME_EXTENSION, .{id});
}

/// Full read: header + last parseable checkpoint line, allocated in `alloc`
/// (use an arena and drop it to free). Null when the file is missing or has
/// no usable checkpoint. A corrupt or missing header line does not disable
/// checkpoint scanning; the id then falls back to the file name.
pub fn load(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, name: []const u8) !?Loaded {
    var sessions_dir = base.openDir(io, DIR_RELATIVE, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer sessions_dir.close(io);
    const file = sessions_dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader = &file_reader.interface;

    var last: ?session.SaveState = null;
    var header: ?Header = null;
    // One pass; each iteration consumes the line plus its delimiter (the
    // delimiter consumption is what guarantees loop progress), and EOF ends
    // the scan. Each line gets its own Allocating buffer that is deliberately
    // NOT freed: parsed header/checkpoint strings reference it, and freeing
    // would let the arena recycle the region under those slices. All line
    // buffers die together when the caller drops its arena.
    while (true) {
        var line_buf: std.Io.Writer.Allocating = .init(alloc);
        _ = reader.streamDelimiterEnding(&line_buf.writer, '\n') catch break;
        const line = line_buf.written();
        if (line.len > 0) {
            if (parseHeader(alloc, line)) |parsed| {
                if (header == null) header = parsed;
            } else if (parseCheckpoint(alloc, line)) |save| {
                last = save;
            }
        }
        // Skip the '\n' delimiter; on EOF (or a final line without '\n') stop.
        _ = reader.discardDelimiterInclusive('\n') catch break;
    }
    const save = last orelse return null;
    if (header) |parsed| {
        return .{ .header = parsed, .save = save };
    }
    // Header line missing/corrupt: derive the id from the journal file name.
    return .{ .header = .{
        .id = try alloc.dupe(u8, name[0 .. name.len - NAME_EXTENSION.len]),
        .cwd = "",
    }, .save = save };
}

fn parseHeader(alloc: std.mem.Allocator, line: []const u8) ?Header {
    return std.json.parseFromSliceLeaky(Header, alloc, line, .{ .ignore_unknown_fields = true }) catch null;
}

/// Deletes session files untouched for longer than `max_age_ms`.
pub fn collectGarbage(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, max_age_ms: i64) void {
    const entries = list(alloc, io, base) catch return;
    defer freeList(alloc, entries);
    var sessions_dir = base.openDir(io, DIR_RELATIVE, .{}) catch return;
    defer sessions_dir.close(io);
    const now = wallMillis(io);
    for (entries) |entry| {
        if (now - entry.modified_ms <= max_age_ms) continue;
        const name = std.mem.concat(alloc, u8, &.{ entry.id, NAME_EXTENSION }) catch continue;
        defer alloc.free(name);
        sessions_dir.deleteFile(io, name) catch {};
    }
}

/// Parses one checkpoint line; parsed values stay live in `alloc` (the load
/// arena — superseded snapshots are released when the caller drops it).
fn parseCheckpoint(alloc: std.mem.Allocator, line: []const u8) ?session.SaveState {
    const Envelope = struct { kind: []const u8 = "", save: session.SaveState };
    const parsed = std.json.parseFromSliceLeaky(Envelope, alloc, line, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, parsed.kind, "checkpoint")) return null;
    return parsed.save;
}

fn openSessionsDir(base: std.Io.Dir, io: std.Io) !std.Io.Dir {
    try base.createDirPath(io, DIR_RELATIVE);
    return base.openDir(io, DIR_RELATIVE, .{ .iterate = true });
}

test "formatId layout and randomness" {
    const testing = std.testing;
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    var buf: [ID_LEN]u8 = undefined;
    formatId(&buf, 1756320000123, io);
    try testing.expectEqualStrings("20250827-184000-", buf[0 .. ID_LEN - ID_RANDOM_LEN]);
    for (buf[ID_LEN - ID_RANDOM_LEN ..]) |c| try testing.expect(std.mem.indexOfScalar(u8, HEX, c) != null);
}

test "create, checkpoint, load, resolve, gc roundtrip" {
    const testing = std.testing;
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_path_buf: [std.posix.PATH_MAX + 1:0]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &tmp_path_buf);
    tmp_path_buf[tmp_len] = 0;
    const base = std.Io.Dir{ .handle = tmp.dir.handle };

    var store = Store{ .io = io, .gpa = testing.allocator, .base = base };
    defer store.deinit();
    try store.create("/tmp/project");
    try testing.expect(store.file_name != null);

    const save = session.SaveState{ .chat = &.{}, .chat_render = &.{} };
    try store.appendCheckpoint(save);
    try store.appendCheckpoint(save);

    var id_buf: [64]u8 = undefined;
    const id = store.currentId(&id_buf).?;
    try testing.expectEqual(ID_LEN, id.len);

    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = (try load(load_arena.allocator(), io, base, store.file_name.?)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/tmp/project", loaded.header.cwd);
    try testing.expectEqualStrings(id, loaded.header.id);
    try testing.expectEqual(@as(usize, 0), loaded.save.chat.len);

    const entries = try list(testing.allocator, io, base);
    defer freeList(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(id, entries[0].id);

    const resolved = try resolve(testing.allocator, io, base, id[0..8]);
    try testing.expect(resolved != null);
    defer testing.allocator.free(resolved.?);
    try testing.expectEqualStrings(id, resolved.?);

    const missing = try resolve(testing.allocator, io, base, "zzzz");
    try testing.expect(missing == null);

    collectGarbage(testing.allocator, io, base, GC_AGE_MS);
    const fresh_after_gc = try list(testing.allocator, io, base);
    defer freeList(testing.allocator, fresh_after_gc);
    try testing.expectEqual(@as(usize, 1), fresh_after_gc.len);

    collectGarbage(testing.allocator, io, base, -1);
    const after_gc = try list(testing.allocator, io, base);
    defer freeList(testing.allocator, after_gc);
    try testing.expectEqual(@as(usize, 0), after_gc.len);
}

test "torn tail and corrupt header fall back to last checkpoint" {
    const testing = std.testing;
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = std.Io.Dir{ .handle = tmp.dir.handle };
    try base.createDirPath(io, DIR_RELATIVE);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Torn tail: header + checkpoint + partial garbage line without '\n'.
    const good_checkpoint = "{\"kind\":\"checkpoint\",\"ms\":1,\"save\":{\"chat\":[],\"chat_render\":[]}}";
    {
        const body = try std.fmt.allocPrint(alloc, "{{\"kind\":\"header\",\"v\":1,\"id\":\"aaa\",\"created_ms\":0,\"cwd\":\"/x\"}}\n{s}\n{{\"kind\":\"chec", .{good_checkpoint});
        var sessions_dir = try base.openDir(io, DIR_RELATIVE, .{ .iterate = true });
        defer sessions_dir.close(io);
        const file = try sessions_dir.createFile(io, "20250101-000000-aaaa.jsonl", .{});
        defer file.close(io);
        var wb: [256]u8 = undefined;
        var w = file.writer(io, &wb);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }

    const loaded = (try load(alloc, io, base, "20250101-000000-aaaa.jsonl")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("aaa", loaded.header.id);
    try testing.expectEqual(@as(usize, 0), loaded.save.chat.len);

    // Corrupt header: checkpoints must still be found; id from file name.
    {
        var sessions_dir = try base.openDir(io, DIR_RELATIVE, .{ .iterate = true });
        defer sessions_dir.close(io);
        const file = try sessions_dir.createFile(io, "20250101-000000-bbbb.jsonl", .{ .truncate = true });
        defer file.close(io);
        var wb: [256]u8 = undefined;
        var w = file.writer(io, &wb);
        try w.interface.writeAll("this is not json\n");
        try w.interface.writeAll(good_checkpoint);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded2 = (try load(arena2.allocator(), io, base, "20250101-000000-bbbb.jsonl")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("20250101-000000-bbbb", loaded2.header.id);
    try testing.expectEqual(@as(usize, 0), loaded2.save.chat.len);

    // Compaction: past the cap the journal is header + one checkpoint.
    var store = Store{ .io = io, .gpa = testing.allocator, .base = base };
    defer store.deinit();
    try store.create("/tmp/project");
    const empty = session.SaveState{ .chat = &.{}, .chat_render = &.{} };
    for (0..MAX_CHECKPOINTS + 1) |_| try store.appendCheckpoint(empty);
    try testing.expectEqual(@as(u32, 1), store.checkpoint_count);
    const stat = blk: {
        var sessions_dir = try base.openDir(io, DIR_RELATIVE, .{ .iterate = true });
        defer sessions_dir.close(io);
        break :blk try sessions_dir.statFile(io, store.file_name.?, .{});
    };
    try testing.expect(stat.size < 512);

    // Torn-tail healing: the next append must not fuse onto a missing '\n'.
    {
        var sessions_dir = try base.openDir(io, DIR_RELATIVE, .{ .iterate = true });
        defer sessions_dir.close(io);
        const f = try sessions_dir.openFile(io, store.file_name.?, .{ .mode = .read_write });
        defer f.close(io);
        const end = try endOffset(f, io);
        try f.setLength(io, end - 1);
    }
    store.checkpoint_count = MAX_CHECKPOINTS;
    try store.appendCheckpoint(empty);
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    const healed = (try load(arena3.allocator(), io, base, store.file_name.?)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), store.checkpoint_count);
    try testing.expectEqual(@as(usize, 0), healed.save.chat.len);
}

test "pre-tool_status save file loads with empty tool_status" {
    const testing = std.testing;
    const json =
        \\{"chat":[],"chat_render":[]}
    ;
    const parsed = try std.json.parseFromSlice(session.SaveState, testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.tool_status.len);
    try testing.expect(parsed.value.main_agent == null);
}
