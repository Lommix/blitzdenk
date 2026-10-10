const std = @import("std");
const session = @import("session.zig");
const sdk = @import("blitz-sdk");
const app = @import("app.zig");
const DIR_NAME = "sessions";
pub const GC_AGE_MS: i64 = 16 * 24 * 60 * 60 * std.time.ms_per_s;
const ID_RANDOM_LEN = 4;
const NAME_EXTENSION = ".jsonl";
const HEX = "0123456789abcdef";
pub const ID_LEN = "20250827-184000-".len + ID_RANDOM_LEN;
pub const PROMPT_CLIP: usize = 80;
pub const Header = struct { kind: []const u8, v: u32, id: []const u8, created_ms: i64 = 0, cwd: []const u8 = "" };
pub const Entry = struct { id: []const u8, modified_ms: i64 };
pub const Kind = enum { agent, main_agent, message, compaction, reset, timeline_append, timeline_truncate, tool_status, agent_update, agent_remove };
pub const Record = struct {
    kind: Kind,
    agentID: ?u32 = null,
    name: ?[]const u8 = null,
    type_idx: ?u8 = null,
    parent: ?u32 = null,
    depth: ?u16 = null,
    cwd: ?[]const u8 = null,
    background: ?bool = null,
    clean: ?bool = null,
    task_description: ?[]const u8 = null,
    message: ?session.WireMessage = null,
    history: ?[]const session.WireMessage = null,
    reason: ?[]const u8 = null,
    entry: ?app.TimelineEntry = null,
    length: ?usize = null,
    call_id: ?[]const u8 = null,
    ansi: []const u8 = "",
    state: session.ToolState = .pending,
    child: ?u32 = null,

    pub fn jsonStringify(self: Record, j: anytype) !void {
        switch (self.kind) {
            .agent, .agent_update => try j.write(.{ .kind = self.kind, .agentID = self.agentID, .name = self.name, .type_idx = self.type_idx, .parent = self.parent, .depth = self.depth, .cwd = self.cwd, .background = self.background, .clean = self.clean, .task_description = self.task_description }),
            .main_agent, .agent_remove => try j.write(.{ .kind = self.kind, .agentID = self.agentID }),
            .message => try j.write(.{ .kind = self.kind, .agentID = self.agentID, .message = self.message }),
            .compaction => try j.write(.{ .kind = self.kind, .agentID = self.agentID, .history = self.history }),
            .reset => try j.write(.{ .kind = self.kind, .agentID = self.agentID, .history = self.history, .reason = self.reason }),
            .timeline_append => try j.write(.{ .kind = self.kind, .entry = self.entry }),
            .timeline_truncate => try j.write(.{ .kind = self.kind, .length = self.length }),
            .tool_status => try j.write(.{ .kind = self.kind, .agentID = self.agentID, .call_id = self.call_id, .ansi = self.ansi, .state = self.state, .child = self.child }),
        }
    }
};

const Display = struct { arena: std.heap.ArenaAllocator, entry: app.TimelineEntry };
const Pending = struct { bytes: []u8, chat: bool };
pub const Store = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    base: std.Io.Dir,
    file_name: ?[]const u8 = null,
    file: ?std.Io.File = null,
    offset: u64 = 0,
    holds_chat: bool = false,
    cwd: []const u8 = "",
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(Pending) = .empty,
    batch: std.ArrayList(Pending) = .empty,
    blocked: bool = false,
    write_batch: ?*const fn (std.Io.File, std.Io, []const u8, u64) anyerror!void = null,
    main: ?u32 = null,
    displays: std.ArrayList(Display) = .empty,
    interruptions: std.ArrayList(u32) = .empty,
    declared: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *Store) void {
        self.flush() catch {};
        self.bump();
        self.pending.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.displays.deinit(self.gpa);
        self.interruptions.deinit(self.gpa);
        self.declared.deinit(self.gpa);
        self.gpa.free(self.cwd);
    }

    pub fn create(self: *Store, cwd: []const u8) !void {
        try self.flush();
        self.bump();
        const copy = try self.gpa.dupe(u8, cwd);
        self.gpa.free(self.cwd);
        self.cwd = copy;
    }

    pub fn bump(self: *Store) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
        if (self.file_name) |name| self.gpa.free(name);
        self.file_name = null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items) |item| self.gpa.free(item.bytes);
        for (self.batch.items) |item| self.gpa.free(item.bytes);
        self.pending.clearRetainingCapacity();
        self.batch.clearRetainingCapacity();
        for (self.displays.items) |*display| display.arena.deinit();
        self.displays.clearRetainingCapacity();
        self.interruptions.clearRetainingCapacity();
        self.declared.clearRetainingCapacity();
        self.main = null;
        self.holds_chat = false;
        self.blocked = false;
        self.offset = 0;
    }

    pub fn enqueue(self: *Store, record: Record) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.enqueueLocked(record);
    }

    fn enqueueLocked(self: *Store, record: Record) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try std.json.Stringify.value(record, .{}, &out.writer);
        try out.writer.writeByte('\n');
        const bytes = try out.toOwnedSlice();
        errdefer self.gpa.free(bytes);
        try self.pending.append(self.gpa, .{ .bytes = bytes, .chat = record.kind == .message or (record.history != null and record.history.?.len > 0) });
        if (record.kind == .main_agent) self.main = record.agentID;
        if (record.kind == .agent_remove and self.main == record.agentID) self.main = null;
        if (record.kind == .agent) if (record.agentID) |id| try self.declared.put(self.gpa, id, {});
    }

    pub fn declares(self: *const Store, id: u32) bool {
        return self.declared.contains(id);
    }

    pub fn publish(self: *Store, id: u32, change: sdk.options.HistoryChange, messages: []const sdk.Message) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const wire = try session.encodeChat(messages, arena.allocator());
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (change == .interrupted_exchange) try self.interruptions.append(self.gpa, id);
        switch (change) {
            .append => {
                for (wire) |message| try self.enqueueLocked(.{ .kind = .message, .agentID = id, .message = message });
                if (self.main == id) for (messages) |message| {
                    if (message.role != .assistant) continue;
                    var display_arena = std.heap.ArenaAllocator.init(self.gpa);
                    errdefer display_arena.deinit();
                    const parts = app.renderSdkParts(display_arena.allocator(), .unpack(id), message.parts()) orelse {
                        display_arena.deinit();
                        continue;
                    };
                    const entry = app.TimelineEntry{ .role = .agent, .parts = parts };
                    try self.displays.ensureUnusedCapacity(self.gpa, 1);
                    try self.enqueueLocked(.{ .kind = .timeline_append, .entry = entry });
                    self.displays.appendAssumeCapacity(.{ .arena = display_arena, .entry = entry });
                };
            },
            .compaction, .history_replace, .interrupted_exchange, .rewind => try self.enqueueLocked(.{
                .kind = if (change == .compaction) .compaction else .reset,
                .agentID = id,
                .history = wire,
                .reason = @tagName(change),
            }),
        }
    }

    fn createJournal(self: *Store) !void {
        var dir = try openSessionsDir(self.base, self.io);
        defer dir.close(self.io);
        const now = wallMillis(self.io);
        var id: [ID_LEN]u8 = undefined;
        formatId(&id, now, self.io);
        const name = try fileName(self.gpa, &id);
        errdefer self.gpa.free(name);
        const file = try dir.createFile(self.io, name, .{ .read = true, .exclusive = true });
        errdefer file.close(self.io);
        errdefer dir.deleteFile(self.io, name) catch {};
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try std.json.Stringify.value(Header{ .kind = "header", .v = 2, .id = &id, .created_ms = now, .cwd = self.cwd }, .{}, &out.writer);
        try out.writer.writeByte('\n');
        try file.writePositionalAll(self.io, out.written(), 0);
        self.file = file;
        self.file_name = name;
        self.offset = out.written().len;
    }

    pub fn flush(self: *Store) !void {
        if (self.blocked) return error.JournalNeedsRecovery;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.batch.items.len == 0) {
                std.mem.swap(std.ArrayList(Pending), &self.pending, &self.batch);
            } else {
                try self.batch.appendSlice(self.gpa, self.pending.items);
                self.pending.clearRetainingCapacity();
            }
        }
        if (self.batch.items.len == 0) return;
        if (self.file == null) try self.createJournal();
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        for (self.batch.items) |item| try out.writer.writeAll(item.bytes);
        const file = self.file.?;
        (if (self.write_batch) |write| write(file, self.io, out.written(), self.offset) else file.writePositionalAll(self.io, out.written(), self.offset)) catch |err| {
            self.reconcile() catch {
                self.blocked = true;
                return error.JournalNeedsRecovery;
            };
            return err;
        };
        self.acknowledge(self.batch.items.len);
    }

    fn reconcile(self: *Store) !void {
        const size = (try self.file.?.stat(self.io)).size;
        if (size < self.offset) return error.InvalidJournalOffset;
        var end = self.offset;
        var count: usize = 0;
        for (self.batch.items) |item| {
            if (end + item.bytes.len > size) break;
            end += item.bytes.len;
            count += 1;
        }
        try self.file.?.setLength(self.io, end);
        self.acknowledge(count);
    }

    fn acknowledge(self: *Store, count: usize) void {
        for (self.batch.items[0..count]) |item| {
            self.offset += item.bytes.len;
            self.holds_chat = self.holds_chat or item.chat;
            self.gpa.free(item.bytes);
        }
        self.batch.replaceRangeAssumeCapacity(0, count, &.{});
    }

    pub fn open(self: *Store, cwd: []const u8, name: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const loaded = (try load(arena.allocator(), self.io, self.base, name)) orelse return error.SessionNotFound;
        var dir = try openSessionsDir(self.base, self.io);
        defer dir.close(self.io);
        if (loaded.problem != null) try repair(self.gpa, self.io, dir, name, loaded.accepted_bytes);
        try self.create(cwd);
        for (loaded.save.archived_ids) |id| try self.declared.put(self.gpa, id, {});
        self.file_name = try self.gpa.dupe(u8, name);
        self.file = try dir.openFile(self.io, name, .{ .mode = .read_write });
        self.offset = loaded.accepted_bytes;
        self.holds_chat = loaded.holds_chat;
        self.main = loaded.save.main_agent;
        for (loaded.repairs) |record| try self.enqueue(record);
        try self.flush();
    }

    pub fn drainDisplay(self: *Store, target: *app.App) !void {
        self.mutex.lockUncancelable(self.io);
        var displays = self.displays;
        self.displays = .empty;
        var interruptions = self.interruptions;
        self.interruptions = .empty;
        self.mutex.unlock(self.io);
        defer interruptions.deinit(self.gpa);
        for (interruptions.items) |id| target.interruptToolStatuses(.unpack(id));
        defer displays.deinit(self.gpa);
        defer for (displays.items) |*display| display.arena.deinit();
        for (displays.items) |display| {
            const entry = try @import("util.zig").deepClone(app.TimelineEntry, display.entry, target.sessionAlloc());
            try target.timeline.append(target.sessionAlloc(), entry);
        }
        if (displays.items.len > 0) {
            target.dropStreamingPreview();
            target.sdk_preview_flushed = true;
            target.dirty = true;
        }
    }

    pub fn holdsChat(self: *const Store) bool {
        return self.holds_chat;
    }
    pub fn currentId(self: *Store, buf: []u8) ?[]const u8 {
        const name = self.file_name orelse return null;
        const n = name.len - NAME_EXTENSION.len;
        if (n > buf.len) return null;
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }
};

fn repair(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, length: u64) !void {
    const backup = try std.fmt.allocPrint(gpa, "{s}.{d}.bak", .{ name, wallMillis(io) });
    defer gpa.free(backup);
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{name});
    defer gpa.free(temp);
    const source = try dir.openFile(io, name, .{});
    defer source.close(io);
    const saved = try dir.createFile(io, backup, .{ .exclusive = true });
    defer saved.close(io);
    const target = try dir.createFile(io, temp, .{});
    defer target.close(io);
    errdefer dir.deleteFile(io, temp) catch {};
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try source.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        try saved.writePositionalAll(io, buffer[0..n], offset);
        if (offset < length) try target.writePositionalAll(io, buffer[0..@intCast(@min(n, length - offset))], offset);
        offset += n;
    }
    try std.Io.Dir.rename(dir, temp, dir, name, io);
}

pub fn wallMillis(io: std.Io) i64 {
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
    var sessions_dir = base.openDir(io, DIR_NAME, .{ .iterate = true }) catch |err| switch (err) {
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
        if (!supported(alloc, io, sessions_dir, item.name)) continue;
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

pub fn resolve(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, prefix: []const u8) !?[]const u8 {
    var dir = base.openDir(io, DIR_NAME, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    var found: ?[]const u8 = null;
    errdefer if (found) |id| alloc.free(id);
    var unsupported = false;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, NAME_EXTENSION)) continue;
        const id = entry.name[0 .. entry.name.len - NAME_EXTENSION.len];
        if (!std.mem.startsWith(u8, id, prefix)) continue;
        if (!supported(alloc, io, dir, entry.name)) {
            unsupported = true;
            continue;
        }
        if (found != null) return error.AmbiguousSessionId;
        found = try alloc.dupe(u8, id);
    }
    if (found == null and unsupported) return error.UnsupportedSessionFormat;
    return found;
}

pub fn fileName(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}" ++ NAME_EXTENSION, .{id});
}

fn firstUserText(chat: []const session.WireMessage) ?[]const u8 {
    for (chat) |message| {
        if (message.role != .user) continue;
        for (message.parts) |part| {
            const text = switch (part) {
                .text => |payload| payload,
                else => continue,
            };
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (session.isReminderText(trimmed)) continue;
            return trimmed;
        }
    }
    return null;
}

fn clipPrompt(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| words.append(alloc, word) catch return text;
    const one = std.mem.join(alloc, " ", words.items) catch return text;
    if (one.len <= PROMPT_CLIP) return one;
    var cut = PROMPT_CLIP;
    while (cut > 0 and (one[cut] & 0b1100_0000) == 0b1000_0000) cut -= 1;
    return std.fmt.allocPrint(alloc, "{s}...", .{one[0..cut]}) catch one[0..cut];
}

pub fn summaries(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir) ![]SummaryRow {
    const entries = try list(alloc, io, base);
    const rows = try alloc.alloc(SummaryRow, entries.len);
    var prompt_arena = std.heap.ArenaAllocator.init(alloc);
    defer prompt_arena.deinit();
    for (entries, rows) |entry, *row| {
        _ = prompt_arena.reset(.retain_capacity);
        const prompt = firstPrompt(prompt_arena.allocator(), io, base, entry.id);
        row.* = .{
            .id = entry.id,
            .modified_ms = entry.modified_ms,
            .prompt = try alloc.dupe(u8, prompt),
        };
    }
    return rows;
}

pub const SummaryRow = struct {
    id: []const u8,
    modified_ms: i64,
    prompt: []const u8,
};

pub fn collectGarbage(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, max_age_ms: i64) void {
    const entries = list(alloc, io, base) catch return;
    defer freeList(alloc, entries);
    var sessions_dir = base.openDir(io, DIR_NAME, .{}) catch return;
    defer sessions_dir.close(io);
    const now = wallMillis(io);
    for (entries) |entry| {
        if (now - entry.modified_ms <= max_age_ms) continue;
        const name = std.mem.concat(alloc, u8, &.{ entry.id, NAME_EXTENSION }) catch continue;
        defer alloc.free(name);
        sessions_dir.deleteFile(io, name) catch {};
    }
}

fn openSessionsDir(base: std.Io.Dir, io: std.Io) !std.Io.Dir {
    try base.createDirPath(io, DIR_NAME);
    return base.openDir(io, DIR_NAME, .{ .iterate = true });
}

pub const Loaded = struct {
    header: Header,
    save: session.SaveState,
    accepted_bytes: u64,
    problem: ?[]const u8 = null,
    holds_chat: bool = false,
    repairs: []const Record = &.{},
};

const Exchange = struct {
    calls: std.StringHashMapUnmanaged(struct { name: []const u8, done: bool = false }) = .empty,
    remaining: usize = 0,
    start: ?usize = null,

    fn append(self: *Exchange, alloc: std.mem.Allocator, message: session.WireMessage, index: usize) !void {
        var calls: usize = 0;
        var results: usize = 0;
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        defer ids.deinit(alloc);
        for (message.parts) |part| switch (part) {
            .tool_call => |call| {
                if (message.role != .agent or call.id.len == 0) return error.InvalidToolCall;
                const entry = try ids.getOrPut(alloc, call.id);
                if (entry.found_existing) return error.DuplicateToolCall;
                calls += 1;
            },
            .tool_result => |result| {
                if (message.role != .user) return error.InvalidToolResult;
                const call = self.calls.get(result.call_id) orelse return error.ResultWithoutCall;
                if (call.done or !std.mem.eql(u8, call.name, result.name)) return error.InvalidToolResult;
                const entry = try ids.getOrPut(alloc, result.call_id);
                if (entry.found_existing) return error.DuplicateToolResult;
                results += 1;
            },
            else => {},
        };
        if (calls > 0 and results > 0) return error.InvalidToolExchange;
        if (results == 0 and self.remaining > 0) return error.UnfinishedToolExchange;
        if (results == 0) {
            self.calls.clearRetainingCapacity();
            self.start = null;
        }
        if (calls > 0) {
            for (message.parts) |part| if (part == .tool_call) {
                try self.calls.put(alloc, part.tool_call.id, .{ .name = part.tool_call.name });
            };
            self.remaining = calls;
            self.start = index;
        }
        if (results > 0) {
            for (message.parts) |part| if (part == .tool_result) {
                self.calls.getPtr(part.tool_result.call_id).?.done = true;
            };
            self.remaining -= results;
            if (self.remaining == 0) self.start = null;
        }
    }
};

const ReplayAgent = struct {
    metadata: session.WireAgent,
    history: std.ArrayList(session.WireMessage) = .empty,
    exchange: Exchange = .{},
    removed: bool = false,
};

const Replay = struct {
    alloc: std.mem.Allocator,
    agents: std.AutoArrayHashMapUnmanaged(u32, ReplayAgent) = .empty,
    main: ?u32 = null,
    timeline: std.ArrayList(app.TimelineEntry) = .empty,
    statuses: std.ArrayList(session.WireToolStatus) = .empty,
    status_indices: std.StringHashMapUnmanaged(usize) = .empty,
    holds_chat: bool = false,

    fn agent(self: *Replay, id: ?u32, retained: bool) !*ReplayAgent {
        const value = self.agents.getPtr(id orelse return error.MissingAgentId) orelse return error.UndeclaredAgent;
        if (retained and value.removed) return error.RemovedAgent;
        return value;
    }

    fn interruptCalls(self: *Replay, id: u32, exchange: *const Exchange, history: []const session.WireMessage) !void {
        for (history) |message| for (message.parts) |part| {
            if (part != .tool_call) continue;
            if (exchange.calls.get(part.tool_call.id)) |call| {
                if (call.done) continue;
            }
            var status = Record{ .kind = .tool_status, .agentID = id, .call_id = part.tool_call.id, .state = .interrupted };
            const key = try std.fmt.allocPrint(self.alloc, "{d}:{s}", .{ id, part.tool_call.id });
            if (self.status_indices.get(key)) |index| {
                status.ansi = self.statuses.items[index].ansi;
                status.child = self.statuses.items[index].child;
            }
            try self.apply(status, "{}");
        };
    }

    fn apply(self: *Replay, record: Record, raw: []const u8) anyerror!void {
        const alloc = self.alloc;
        switch (record.kind) {
            .agent => {
                const id = record.agentID orelse return error.MissingAgentId;
                if (self.agents.contains(id)) return error.DuplicateAgent;
                if (record.parent) |parent| _ = try self.agent(parent, false);
                try self.agents.put(alloc, id, .{ .metadata = .{
                    .id = id,
                    .name = record.name orelse return error.MissingAgentMetadata,
                    .type_idx = record.type_idx orelse return error.MissingAgentMetadata,
                    .parent = record.parent,
                    .depth = record.depth orelse return error.MissingAgentMetadata,
                    .cwd = record.cwd orelse return error.MissingAgentMetadata,
                    .background = record.background orelse return error.MissingAgentMetadata,
                    .clean = record.clean orelse return error.MissingAgentMetadata,
                    .task_description = record.task_description orelse return error.MissingAgentMetadata,
                } });
            },
            .agent_update => {
                const value = try self.agent(record.agentID, true);
                if (record.parent) |parent| _ = try self.agent(parent, false);
                const fields = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
                if (record.name) |v| value.metadata.name = v;
                if (record.type_idx) |v| value.metadata.type_idx = v;
                if (fields.object.contains("parent")) value.metadata.parent = record.parent;
                if (record.depth) |v| value.metadata.depth = v;
                if (record.cwd) |v| value.metadata.cwd = v;
                if (record.background) |v| value.metadata.background = v;
                if (record.clean) |v| value.metadata.clean = v;
                if (record.task_description) |v| value.metadata.task_description = v;
            },
            .main_agent => {
                if (record.agentID) |id| _ = try self.agent(id, true);
                self.main = record.agentID;
            },
            .agent_remove => {
                const value = try self.agent(record.agentID, true);
                value.removed = true;
                if (self.main == record.agentID) self.main = null;
            },
            .message => {
                const value = try self.agent(record.agentID, true);
                const message = record.message orelse return error.MissingMessage;
                try value.exchange.append(alloc, message, value.history.items.len);
                try value.history.append(alloc, message);
                self.holds_chat = true;
            },
            .compaction, .reset => {
                const value = try self.agent(record.agentID, true);
                const history = record.history orelse return error.MissingHistory;
                if (record.kind == .reset and record.reason == null) return error.MissingResetReason;
                var exchange: Exchange = .{};
                for (history, 0..) |message, index| try exchange.append(alloc, message, index);
                if (record.kind == .reset and std.mem.eql(u8, record.reason.?, "interrupted_exchange")) {
                    if (value.exchange.start) |start| try self.interruptCalls(record.agentID.?, &value.exchange, value.history.items[start..]);
                }
                value.exchange = exchange;
                value.history = .empty;
                try value.history.appendSlice(alloc, history);
                self.holds_chat = self.holds_chat or history.len > 0;
            },
            .timeline_append => {
                const entry = record.entry orelse return error.MissingTimelineEntry;
                for (entry.parts) |part| if (part == .tool_call) {
                    _ = try self.agent(part.tool_call.agent_id.pack(), false);
                };
                try self.timeline.append(alloc, entry);
            },
            .timeline_truncate => {
                const length = record.length orelse return error.MissingTimelineLength;
                if (length > self.timeline.items.len) return error.InvalidTimelineLength;
                self.timeline.shrinkRetainingCapacity(length);
            },
            .tool_status => {
                _ = try self.agent(record.agentID, false);
                if (record.child) |id| _ = try self.agent(id, false);
                const call = record.call_id orelse return error.MissingCallId;
                const key = try std.fmt.allocPrint(alloc, "{d}:{s}", .{ record.agentID.?, call });
                const entry = try self.status_indices.getOrPut(alloc, key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = self.statuses.items.len;
                    try self.statuses.append(alloc, undefined);
                }
                self.statuses.items[entry.value_ptr.*] = .{ .agent = record.agentID, .call_id = call, .ansi = record.ansi, .state = record.state, .is_error = switch (record.state) {
                    .failed, .interrupted => true,
                    .succeeded => false,
                    .pending => null,
                }, .child = record.child };
            },
        }
    }
};

const Lines = struct {
    file: std.Io.File,
    io: std.Io,
    alloc: std.mem.Allocator,
    buffer: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    read_offset: u64 = 0,
    accepted: u64 = 0,
    line: std.ArrayList(u8) = .empty,
    torn: bool = false,

    fn next(self: *Lines) !?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            if (self.start == self.end) {
                self.end = try self.file.readPositionalAll(self.io, &self.buffer, self.read_offset);
                self.read_offset += self.end;
                self.start = 0;
                if (self.end == 0) {
                    self.torn = self.line.items.len > 0;
                    return null;
                }
            }
            if (std.mem.indexOfScalarPos(u8, self.buffer[0..self.end], self.start, '\n')) |nl| {
                try self.line.appendSlice(self.alloc, self.buffer[self.start..nl]);
                self.start = nl + 1;
                self.accepted += self.line.items.len + 1;
                return self.line.items;
            }
            try self.line.appendSlice(self.alloc, self.buffer[self.start..self.end]);
            self.start = self.end;
        }
    }
};

fn parseHeader(alloc: std.mem.Allocator, line: []const u8) !Header {
    const header = std.json.parseFromSliceLeaky(Header, alloc, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.UnsupportedSessionFormat;
    if (header.v != 2 or !std.mem.eql(u8, header.kind, "header")) return error.UnsupportedSessionFormat;
    return header;
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, name: []const u8) !?Loaded {
    var dir = base.openDir(io, DIR_NAME, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    const file = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var lines = Lines{ .file = file, .io = io, .alloc = alloc };
    defer lines.line.deinit(alloc);
    const header = try parseHeader(alloc, (try lines.next()) orelse return error.UnsupportedSessionFormat);
    var accepted = lines.accepted;
    var replay = Replay{ .alloc = alloc };
    var problem: ?[]const u8 = null;
    while (try lines.next()) |line| {
        const record = std.json.parseFromSliceLeaky(Record, alloc, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            problem = @errorName(err);
            break;
        };
        replay.apply(record, line) catch |err| {
            if (err == error.OutOfMemory) return err;
            problem = @errorName(err);
            break;
        };
        accepted = lines.accepted;
    }
    if (lines.torn) problem = "UnterminatedRecord";
    if (problem) |reason| std.log.scoped(.session).warn("replay stopped at byte {d}: {s}", .{ accepted, reason });
    var retained: std.ArrayList(session.WireAgent) = .empty;
    var archived: std.ArrayList(u32) = .empty;
    var archived_agents: std.ArrayList(session.WireAgent) = .empty;
    var repairs: std.ArrayList(Record) = .empty;
    var main_metadata: ?session.WireAgent = null;
    for (replay.agents.values()) |*agent| {
        try archived.append(alloc, agent.metadata.id);
        if (agent.removed) {
            agent.metadata.chat = agent.history.items;
            try archived_agents.append(alloc, agent.metadata);
            continue;
        }
        if (agent.exchange.start) |start| {
            for (agent.history.items[start..]) |message| for (message.parts) |part| {
                if (part != .tool_call) continue;
                if (agent.exchange.calls.get(part.tool_call.id)) |call| {
                    if (call.done) continue;
                }
                var status = Record{ .kind = .tool_status, .agentID = agent.metadata.id, .call_id = part.tool_call.id, .state = .interrupted };
                const status_key = try std.fmt.allocPrint(alloc, "{d}:{s}", .{ agent.metadata.id, status.call_id.? });
                if (replay.status_indices.get(status_key)) |status_index| {
                    status.ansi = replay.statuses.items[status_index].ansi;
                    status.child = replay.statuses.items[status_index].child;
                }
                try replay.apply(status, "{}");
                try repairs.append(alloc, status);
            };
            agent.history.shrinkRetainingCapacity(start);
            try repairs.append(alloc, .{ .kind = .reset, .agentID = agent.metadata.id, .history = agent.history.items, .reason = "interrupted_exchange" });
        }
        agent.metadata.chat = agent.history.items;
        if (replay.main == agent.metadata.id) main_metadata = agent.metadata else try retained.append(alloc, agent.metadata);
    }
    return .{ .header = header, .accepted_bytes = accepted, .problem = problem, .holds_chat = replay.holds_chat, .repairs = repairs.items, .save = .{
        .chat = if (main_metadata) |main| main.chat else &.{},
        .timeline = replay.timeline.items,
        .main_agent = replay.main,
        .main_metadata = main_metadata,
        .archived_ids = archived.items,
        .archived_agents = archived_agents.items,
        .clean = if (main_metadata) |main| main.clean else false,
        .agents = retained.items,
        .tool_status = replay.statuses.items,
    } };
}

fn supported(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    const file = dir.openFile(io, name, .{}) catch return false;
    defer file.close(io);
    var lines = Lines{ .file = file, .io = io, .alloc = alloc };
    defer lines.line.deinit(alloc);
    const line = (lines.next() catch return false) orelse return false;
    const parsed = std.json.parseFromSlice(Header, alloc, line, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.v == 2 and std.mem.eql(u8, parsed.value.kind, "header");
}

pub fn firstPrompt(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) []const u8 {
    const name = fileName(alloc, id) catch return "";
    var dir = base.openDir(io, DIR_NAME, .{}) catch return "";
    defer dir.close(io);
    const file = dir.openFile(io, name, .{}) catch return "";
    defer file.close(io);
    var lines = Lines{ .file = file, .io = io, .alloc = alloc };
    defer lines.line.deinit(alloc);
    _ = parseHeader(alloc, (lines.next() catch return "") orelse return "") catch return "";
    var main: ?u32 = null;
    while (lines.next() catch return "") |line| {
        const parsed = std.json.parseFromSlice(Record, alloc, line, .{ .ignore_unknown_fields = true }) catch return "";
        defer parsed.deinit();
        const record = parsed.value;
        switch (record.kind) {
            .main_agent => main = record.agentID,
            .agent_remove => if (main == record.agentID) {
                main = null;
            },
            .message => if (main != null and record.agentID == main) {
                if (record.message) |message| if (firstUserText(&.{message})) |text| return clipPrompt(alloc, text);
            },
            else => {},
        }
    }
    return "";
}

const TestLog = struct {
    tmp: std.testing.TmpDir,
    io_state: std.Io.Threaded,
    store: Store,
    arena: std.heap.ArenaAllocator,

    fn init(self: *TestLog) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.io_state = std.Io.Threaded.init(std.testing.allocator, .{});
        self.arena = .init(std.testing.allocator);
        self.store = .{ .io = self.io_state.io(), .gpa = std.testing.allocator, .base = .{ .handle = self.tmp.dir.handle } };
        try self.store.create("/project");
    }

    fn deinit(self: *TestLog) void {
        self.store.deinit();
        self.arena.deinit();
        self.io_state.deinit();
        self.tmp.cleanup();
    }

    fn declare(self: *TestLog, id: u32) !void {
        try self.store.enqueue(.{ .kind = .agent, .agentID = id, .name = "agent", .type_idx = 0, .depth = 0, .cwd = "/project", .background = false, .clean = false, .task_description = "" });
    }

    fn message(self: *TestLog, id: u32, text: []const u8) !void {
        try self.store.enqueue(.{ .kind = .message, .agentID = id, .message = .{ .role = .user, .parts = &.{.{ .text = text }} } });
    }

    fn read(self: *TestLog) !Loaded {
        return (try load(self.arena.allocator(), self.store.io, self.store.base, self.store.file_name.?)).?;
    }

    fn raw(self: *TestLog, bytes: []const u8) !void {
        const file = self.store.file.?;
        try file.writePositionalAll(self.store.io, bytes, (try file.stat(self.store.io)).size);
    }
};

test "append log interleaves agents and compaction preserves display and preview" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    try std.testing.expect(store.file_name == null);
    try fixture.declare(1);
    try fixture.declare(2);
    try store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
    try fixture.message(1, "original prompt");
    try fixture.message(2, "child prompt");
    var timeline_parts = [_]app.TimelinePart{.{ .message = "original prompt" }};
    try store.enqueue(.{ .kind = .timeline_append, .entry = .{ .role = .user, .parts = &timeline_parts } });
    try store.enqueue(.{ .kind = .compaction, .agentID = 1, .history = &.{.{ .role = .user, .parts = &.{.{ .text = "summary" }} }} });
    try fixture.message(2, "child followup");
    try fixture.message(1, "continue");
    try store.flush();
    const loaded = try fixture.read();
    try std.testing.expect(loaded.problem == null);
    try std.testing.expectEqual(@as(usize, 2), loaded.save.chat.len);
    try std.testing.expectEqualStrings("summary", loaded.save.chat[0].parts[0].text);
    try std.testing.expectEqualStrings("continue", loaded.save.chat[1].parts[0].text);
    try std.testing.expectEqual(@as(usize, 2), loaded.save.agents[0].chat.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.save.timeline.len);
    var id: [ID_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("original prompt", firstPrompt(fixture.arena.allocator(), store.io, store.base, store.currentId(&id).?));
    const size = store.offset;
    try store.flush();
    try std.testing.expectEqual(size, store.offset);
}

test "partial exchange and torn record repair retain archive and make resumed work reachable" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    try fixture.declare(1);
    try store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
    try fixture.message(1, "hello");
    try store.enqueue(.{ .kind = .message, .agentID = 1, .message = .{ .role = .agent, .parts = &.{
        .{ .tool_call = .{ .id = "a", .name = "tool", .arguments = "{}" } },
        .{ .tool_call = .{ .id = "b", .name = "tool", .arguments = "{}" } },
    } } });
    try store.enqueue(.{ .kind = .message, .agentID = 1, .message = .{ .role = .user, .parts = &.{.{ .tool_result = .{ .call_id = "a", .name = "tool", .content = "done" } }} } });
    try store.flush();
    const prefix_size = store.offset;
    try fixture.raw("{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[]}}");
    const loaded = try fixture.read();
    try std.testing.expectEqualStrings("UnterminatedRecord", loaded.problem.?);
    try std.testing.expectEqual(prefix_size, loaded.accepted_bytes);
    try std.testing.expectEqual(@as(usize, 1), loaded.save.chat.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.repairs.len);
    try std.testing.expect(loaded.repairs[0].kind == .tool_status);
    try std.testing.expectEqualStrings("b", loaded.repairs[0].call_id.?);
    try std.testing.expect(loaded.repairs[0].state == .interrupted);
    try std.testing.expect(loaded.repairs[1].kind == .reset);
    const name = try fixture.arena.allocator().dupe(u8, store.file_name.?);
    try store.open("/project", name);
    try fixture.message(1, "resumed");
    try store.flush();
    const resumed = try fixture.read();
    try std.testing.expect(resumed.problem == null);
    try std.testing.expectEqual(@as(usize, 0), resumed.repairs.len);
    try std.testing.expectEqual(@as(usize, 2), resumed.save.chat.len);
    try std.testing.expectEqualStrings("resumed", resumed.save.chat[1].parts[0].text);
    var dir = try store.base.openDir(store.io, DIR_NAME, .{ .iterate = true });
    defer dir.close(store.io);
    var it = dir.iterateAssumeFirstIteration();
    var backups: usize = 0;
    while (try it.next(store.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".bak")) {
        backups += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), backups);
}

test "invalid complete records stop before their effects" {
    const invalid = [_][]const u8{
        "{\"kind\":\"unknown\"}\n",
        "{\"kind\":\"message\",\"agentID\":99,\"message\":{\"role\":\"user\",\"parts\":[]}}\n",
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"ghost\",\"name\":\"tool\",\"content\":\"bad\"}}]}}\n",
        "{\"kind\":\"reset\",\"agentID\":1,\"reason\":\"history_replace\",\"history\":[{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"ghost\",\"name\":\"tool\",\"content\":\"bad\"}}]}]}\n",
        "{\"kind\":\"timeline_truncate\",\"length\":1}\n",
        "{\"kind\":\"agent\",\"agentID\":1}\n",
    };
    for (invalid) |line| {
        var fixture: TestLog = undefined;
        try fixture.init();
        defer fixture.deinit();
        try fixture.declare(1);
        try fixture.store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
        try fixture.message(1, "accepted");
        try fixture.store.flush();
        const accepted = fixture.store.offset;
        try fixture.raw(line);
        try fixture.raw("{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"unreachable\"}]}}\n");
        const loaded = try fixture.read();
        try std.testing.expect(loaded.problem != null);
        try std.testing.expectEqual(accepted, loaded.accepted_bytes);
        try std.testing.expectEqual(@as(usize, 1), loaded.save.chat.len);
        try std.testing.expectEqualStrings("accepted", loaded.save.chat[0].parts[0].text);
        const name = try fixture.arena.allocator().dupe(u8, fixture.store.file_name.?);
        try fixture.store.open("/project", name);
        try fixture.message(1, "reachable");
        try fixture.store.flush();
        const resumed = try fixture.read();
        try std.testing.expect(resumed.problem == null);
        try std.testing.expectEqual(@as(usize, 2), resumed.save.chat.len);
    }
}

test "partial writes acknowledge complete lines and retain exactly the suffix" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    try fixture.declare(1);
    try store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
    try store.flush();
    try fixture.message(1, "first");
    try fixture.message(1, "second");
    std.mem.swap(std.ArrayList(Pending), &store.pending, &store.batch);
    try fixture.raw(store.batch.items[0].bytes);
    try fixture.raw(store.batch.items[1].bytes[0..17]);
    try store.reconcile();
    try std.testing.expectEqual(@as(usize, 1), store.batch.items.len);
    try store.flush();
    const loaded = try fixture.read();
    try std.testing.expect(loaded.problem == null);
    try std.testing.expectEqual(@as(usize, 2), loaded.save.chat.len);
    try std.testing.expectEqualStrings("first", loaded.save.chat[0].parts[0].text);
    try std.testing.expectEqualStrings("second", loaded.save.chat[1].parts[0].text);
    try fixture.message(1, "third");
    const Failure = struct {
        fn write(file: std.Io.File, io: std.Io, bytes: []const u8, offset: u64) !void {
            try file.writePositionalAll(io, bytes[0..13], offset);
            return error.SimulatedFailure;
        }
    };
    store.write_batch = Failure.write;
    try std.testing.expectError(error.SimulatedFailure, store.flush());
    try std.testing.expectEqual(@as(usize, 1), store.batch.items.len);
    store.write_batch = null;
    try store.flush();
    const retried = try fixture.read();
    try std.testing.expectEqual(@as(usize, 3), retried.save.chat.len);
}

test "metadata switching removal and cleared status fields survive replay" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    try fixture.declare(1);
    try fixture.declare(2);
    try store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
    try fixture.message(1, "first main");
    try store.enqueue(.{ .kind = .tool_status, .agentID = 1, .call_id = "link", .ansi = "styled", .state = .failed, .child = 2 });
    try store.enqueue(.{ .kind = .tool_status, .agentID = 1, .call_id = "link", .state = .pending });
    try store.enqueue(.{ .kind = .agent_remove, .agentID = 1 });
    try store.enqueue(.{ .kind = .main_agent, .agentID = 2 });
    try fixture.message(2, "second main");
    try store.flush();
    try fixture.raw("{\"kind\":\"agent_update\",\"agentID\":2,\"cwd\":\"/changed\"}\n");
    const loaded = try fixture.read();
    try std.testing.expect(loaded.problem == null);
    try std.testing.expectEqual(@as(?u32, 2), loaded.save.main_agent);
    try std.testing.expectEqualStrings("agent", loaded.save.main_metadata.?.name);
    try std.testing.expectEqualStrings("/changed", loaded.save.main_metadata.?.cwd);
    try std.testing.expectEqual(@as(usize, 0), loaded.save.agents.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.save.archived_ids.len);
    try std.testing.expectEqualStrings("", loaded.save.tool_status[0].ansi);
    try std.testing.expect(loaded.save.tool_status[0].child == null);
    try std.testing.expectEqual(session.ToolState.pending, loaded.save.tool_status[0].state);
    try fixture.raw("{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[]}}\n");
    const invalid = try fixture.read();
    try std.testing.expectEqualStrings("RemovedAgent", invalid.problem.?);
}

test "version one and legacy journals are rejected and omitted without modification" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    var dir = try openSessionsDir(store.base, store.io);
    defer dir.close(store.io);
    const contents = [_][]const u8{ "{\"kind\":\"header\",\"v\":1,\"id\":\"old\"}\n", "{\"chat\":[],\"timeline\":[]}\n" };
    for (contents, 0..) |bytes, index| {
        const name = try std.fmt.allocPrint(fixture.arena.allocator(), "old{d}.jsonl", .{index});
        const file = try dir.createFile(store.io, name, .{ .read = true });
        defer file.close(store.io);
        try file.writePositionalAll(store.io, bytes, 0);
        try std.testing.expectError(error.UnsupportedSessionFormat, store.open("/project", name));
        try std.testing.expectEqual(@as(u64, bytes.len), (try file.stat(store.io)).size);
    }
    const entries = try list(std.testing.allocator, store.io, store.base);
    defer freeList(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
    try std.testing.expectError(error.UnsupportedSessionFormat, resolve(std.testing.allocator, store.io, store.base, "old"));
    try std.testing.expect(store.file == null);
}

test "fixed append payload does not grow with prior history and never reads journal" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    try fixture.declare(1);
    try store.publish(1, .append, &.{sdk.UserMessage("fixed")});
    const bytes = store.pending.items[store.pending.items.len - 1].bytes.len;
    try store.flush();
    for (0..2000) |_| try store.publish(1, .append, &.{sdk.UserMessage("history")});
    try store.flush();
    try store.publish(1, .append, &.{sdk.UserMessage("fixed")});
    try std.testing.expectEqual(bytes, store.pending.items[0].bytes.len);
    try store.flush();
    const loaded = try fixture.read();
    try std.testing.expectEqual(@as(usize, 2002), loaded.save.agents[0].chat.len);
    try std.testing.expect(loaded.problem == null);
}

test "tool exchange validation rejects duplicates and crossing conversation records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const call = session.WireMessage{ .role = .agent, .parts = &.{
        .{ .tool_call = .{ .id = "a", .name = "tool", .arguments = "{}" } },
        .{ .tool_call = .{ .id = "b", .name = "tool", .arguments = "{}" } },
    } };
    const result = session.WireMessage{ .role = .user, .parts = &.{.{ .tool_result = .{ .call_id = "a", .name = "tool", .content = "ok" } }} };
    var exchange = Exchange{};
    try exchange.append(alloc, call, 0);
    try exchange.append(alloc, result, 1);
    try std.testing.expectError(error.InvalidToolResult, exchange.append(alloc, result, 2));
    try std.testing.expectError(error.UnfinishedToolExchange, exchange.append(alloc, .{ .role = .user, .parts = &.{.{ .text = "crossing" }} }, 2));
    try std.testing.expectEqual(@as(usize, 1), exchange.remaining);
    try exchange.append(alloc, .{ .role = .user, .parts = &.{.{ .tool_result = .{ .call_id = "b", .name = "tool", .content = "ok" } }} }, 2);
    try std.testing.expect(exchange.start == null);
    try exchange.append(alloc, .{ .role = .agent, .parts = &.{.{ .text = "finished" }} }, 3);
}

test "header only sessions are valid and main selection can be cleared" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.store.createJournal();
    const empty = try fixture.read();
    try std.testing.expect(empty.problem == null);
    try std.testing.expect(empty.save.main_agent == null);
    try std.testing.expect(!empty.holds_chat);
    var id: [ID_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("", firstPrompt(fixture.arena.allocator(), fixture.store.io, fixture.store.base, fixture.store.currentId(&id).?));
    try fixture.declare(1);
    try fixture.store.enqueue(.{ .kind = .main_agent, .agentID = 1 });
    try fixture.store.enqueue(.{ .kind = .main_agent });
    try fixture.store.flush();
    const cleared = try fixture.read();
    try std.testing.expect(cleared.save.main_agent == null);
    try std.testing.expectEqual(@as(usize, 1), cleared.save.agents.len);
}

test "failed reconciliation blocks subsequent writes" {
    var fixture: TestLog = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.declare(1);
    try fixture.store.flush();
    try fixture.message(1, "pending");
    const Failure = struct {
        fn write(file: std.Io.File, io: std.Io, _: []const u8, offset: u64) !void {
            try file.setLength(io, offset - 1);
            return error.SimulatedFailure;
        }
    };
    fixture.store.write_batch = Failure.write;
    try std.testing.expectError(error.JournalNeedsRecovery, fixture.store.flush());
    fixture.store.write_batch = null;
    const size = (try fixture.store.file.?.stat(fixture.store.io)).size;
    try std.testing.expectError(error.JournalNeedsRecovery, fixture.store.flush());
    try std.testing.expectEqual(size, (try fixture.store.file.?.stat(fixture.store.io)).size);
    try std.testing.expectEqual(@as(usize, 1), fixture.store.batch.items.len);
}
