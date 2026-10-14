const std = @import("std");
const r = @import("root.zig");
const kitty = @import("tui/kitty.zig");

pub const max_height_px = 300;
pub const max_width_px = 1920;
pub const placement_id = 1;
pub const max_source_bytes = 64 * 1024 * 1024;
pub const max_source_cache_bytes = 128 * 1024 * 1024;
pub const max_decoded_bytes = 64 * 1024 * 1024;
pub const max_decode_in_flight = 2;

pub const State = enum(u8) { pending, ready, failed };

pub const Entry = struct {
    agent_id: r.AgentId,
    call_id: []const u8,
    kitty_id: u32,
    img: ?r.image.Image = null,
    state: std.atomic.Value(State) = .init(.pending),
    decode_in_flight: std.atomic.Value(bool) = .init(false),
    decode_done: std.atomic.Value(bool) = .init(false),
    transmitted: bool = false,
    placed_gen: u64 = 0,
    frame_pinned: bool = false,
    data_url: []const u8 = "",
    data_owned: bool = true,
    last_used: u64 = 0,
    notify: ?*std.atomic.Value(bool) = null,
};

pub const Placement = struct {
    entry: *Entry,
    rect: r.tui.Rect,
    src: kitty.Crop,
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    threads: std.ArrayListUnmanaged(ThreadHandle) = .empty,
    next_id: u32 = 1_000_000,
    use_counter: u64 = 0,
    source_bytes: usize = 0,
    eviction_gen: u64 = 0,

    const ThreadHandle = struct {
        thread: std.Thread,
        entry: *Entry,
    };

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (self.threads.items) |handle| handle.thread.join();
        self.threads.deinit(gpa);
        for (self.entries.items) |entry| {
            if (entry.img) |img| img.deinit(gpa);
            if (entry.data_url.len > 0 and entry.data_owned) gpa.free(entry.data_url);
            gpa.free(entry.call_id);
            gpa.destroy(entry);
        }
        self.entries.deinit(gpa);
    }

    pub fn find(self: *Store, agent_id: r.AgentId, call_id: []const u8) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.agent_id.pack() == agent_id.pack() and std.mem.eql(u8, entry.call_id, call_id)) {
                self.touch(entry);
                return entry;
            }
        }
        return null;
    }

    pub fn touch(self: *Store, entry: *Entry) void {
        self.use_counter +%= 1;
        entry.last_used = self.use_counter;
    }

    pub fn remember(self: *Store, gpa: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, data_url: []const u8) ?*Entry {
        return self.rememberSource(gpa, agent_id, call_id, data_url, true);
    }

    pub fn rememberBorrowed(self: *Store, gpa: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, data_url: []const u8) ?*Entry {
        return self.rememberSource(gpa, agent_id, call_id, data_url, false);
    }

    fn rememberSource(self: *Store, gpa: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, data_url: []const u8, owned: bool) ?*Entry {
        if (data_url.len == 0 or data_url.len > max_source_bytes) return null;
        if (self.find(agent_id, call_id)) |entry| {
            if (entry.data_url.len == 0) {
                if (owned) {
                    self.makeSourceRoom(gpa, data_url.len, entry);
                    if (self.source_bytes +| data_url.len <= max_source_cache_bytes) {
                        entry.data_url = gpa.dupe(u8, data_url) catch return entry;
                        entry.data_owned = true;
                        self.source_bytes += data_url.len;
                    }
                } else {
                    entry.data_url = data_url;
                    entry.data_owned = false;
                }
            }
            return entry;
        }

        if (owned) {
            self.makeSourceRoom(gpa, data_url.len, null);
            if (self.source_bytes +| data_url.len > max_source_cache_bytes) return null;
        }

        const entry = gpa.create(Entry) catch return null;
        entry.* = .{
            .agent_id = agent_id,
            .call_id = gpa.dupe(u8, call_id) catch {
                gpa.destroy(entry);
                return null;
            },
            .kitty_id = self.next_id,
            .data_url = if (owned) gpa.dupe(u8, data_url) catch {
                gpa.free(entry.call_id);
                gpa.destroy(entry);
                return null;
            } else data_url,
            .data_owned = owned,
        };
        self.touch(entry);
        if (owned) self.source_bytes += data_url.len;
        self.next_id += 1;
        self.entries.append(gpa, entry) catch {
            if (entry.data_owned) {
                self.source_bytes -|= entry.data_url.len;
                gpa.free(entry.data_url);
            }
            gpa.free(entry.call_id);
            gpa.destroy(entry);
            return null;
        };

        return entry;
    }

    pub fn request(self: *Store, gpa: std.mem.Allocator, agent_id: r.AgentId, call_id: []const u8, data_url: []const u8, notify: ?*std.atomic.Value(bool)) ?*Entry {
        self.reapCompleted();
        const entry = self.remember(gpa, agent_id, call_id, data_url) orelse return null;
        if (notify) |flag| entry.notify = flag;
        if (entry.state.load(.acquire) == .ready) return entry;
        if (entry.state.load(.acquire) == .failed) return entry;
        if (entry.decode_in_flight.load(.acquire)) return entry;
        if (self.inFlightCount() >= max_decode_in_flight) return entry;
        self.startDecode(gpa, entry);
        return entry;
    }

    fn inFlightCount(self: *Store) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| count += @intFromBool(entry.decode_in_flight.load(.acquire));
        return count;
    }

    fn startDecode(self: *Store, gpa: std.mem.Allocator, entry: *Entry) void {
        if (self.inFlightCount() >= max_decode_in_flight) return;
        if (entry.decode_in_flight.swap(true, .acq_rel)) return;
        entry.decode_done.store(false, .release);
        entry.state.store(.pending, .release);
        _ = self.evictDecoded(gpa, entry, max_decoded_bytes);
        const thread = std.Thread.spawn(.{}, decodeThread, .{ gpa, entry, entry.notify }) catch {
            decodeThread(gpa, entry, entry.notify);
            return;
        };
        self.threads.append(gpa, .{ .thread = thread, .entry = entry }) catch thread.join();
    }

    pub fn prune(self: *Store, gpa: std.mem.Allocator) void {
        self.reapCompleted();
        _ = self.evictDecoded(gpa, null, max_decoded_bytes);
        var in_flight = self.inFlightCount();
        for (self.entries.items) |entry| {
            if (in_flight >= max_decode_in_flight) break;
            if (entry.state.load(.acquire) != .pending or entry.data_url.len == 0) continue;
            self.startDecode(gpa, entry);
            in_flight += @intFromBool(entry.decode_in_flight.load(.acquire));
        }
    }

    fn reapCompleted(self: *Store) void {
        var i: usize = 0;
        while (i < self.threads.items.len) {
            const handle = self.threads.items[i];
            if (!handle.entry.decode_done.load(.acquire)) {
                i += 1;
                continue;
            }
            handle.thread.join();
            _ = self.threads.swapRemove(i);
        }
    }

    fn evictDecoded(self: *Store, gpa: std.mem.Allocator, keep: ?*Entry, limit: usize) bool {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.state.load(.acquire) != .ready) continue;
            if (entry.img) |img| total +|= img.pixels.len;
        }
        var evicted = false;
        while (total > limit) {
            var oldest: ?*Entry = null;
            for (self.entries.items) |entry| {
                if ((keep != null and entry == keep.?) or entry.frame_pinned or entry.state.load(.acquire) != .ready) continue;
                if (entry.img == null) continue;
                if (oldest == null or entry.last_used < oldest.?.last_used) oldest = entry;
            }
            const entry = oldest orelse break;
            const bytes = entry.img.?.pixels.len;
            entry.img.?.deinit(gpa);
            entry.img = null;
            entry.state.store(.pending, .release);
            entry.transmitted = false;
            self.eviction_gen +%= 1;
            evicted = true;
            total -|= bytes;
        }
        return evicted;
    }

    fn makeSourceRoom(self: *Store, gpa: std.mem.Allocator, needed: usize, keep: ?*Entry) void {
        while (self.source_bytes +| needed > max_source_cache_bytes) {
            var oldest: ?*Entry = null;
            for (self.entries.items) |entry| {
                if (entry == keep or entry.data_url.len == 0 or !entry.data_owned or entry.decode_in_flight.load(.acquire)) continue;
                if (oldest == null or entry.last_used < oldest.?.last_used) oldest = entry;
            }
            const entry = oldest orelse break;
            self.source_bytes -|= entry.data_url.len;
            gpa.free(entry.data_url);
            entry.data_url = "";
        }
    }

    pub fn metrics(entry: *const Entry, cell_px: kitty.CellPixels, max_cols: u16) struct { cols: u16, rows: u16 } {
        if (entry.state.load(.acquire) != .ready) return .{ .cols = 0, .rows = 0 };
        const img = entry.img orelse return .{ .cols = 0, .rows = 0 };
        if (img.width == 0 or img.height == 0 or cell_px.w == 0 or cell_px.h == 0) return .{ .cols = 0, .rows = 0 };
        var cols: u32 = @as(u32, img.width) / cell_px.w;
        var rows: u32 = @as(u32, img.height) / cell_px.h;
        if (@as(u32, img.width) % cell_px.w != 0) cols += 1;
        if (@as(u32, img.height) % cell_px.h != 0) rows += 1;
        const col_cap: u32 = @max(1, max_cols);
        if (cols > col_cap) {
            cols = col_cap;
            const px_h = @as(u64, img.height) * @as(u64, cols) * cell_px.w / img.width;
            const rows_capped = (px_h +| cell_px.h - 1) / cell_px.h;
            rows = @max(1, @as(u32, @intCast(rows_capped)));
        }
        return .{
            .cols = @intCast(@min(cols, std.math.maxInt(u16))),
            .rows = @intCast(@min(rows, std.math.maxInt(u16))),
        };
    }
};

fn decodeThread(gpa: std.mem.Allocator, entry: *Entry, notify: ?*std.atomic.Value(bool)) void {
    if (loadImage(gpa, entry.data_url)) |img| {
        entry.img = img;
        entry.state.store(.ready, .release);
    } else {
        entry.state.store(.failed, .release);
    }
    entry.decode_in_flight.store(false, .release);
    entry.decode_done.store(true, .release);
    if (notify) |flag| flag.store(true, .release);
}

fn loadImage(gpa: std.mem.Allocator, data_url: []const u8) ?r.image.Image {
    const prefix = "data:";
    const marker = ";base64,";
    if (!std.mem.startsWith(u8, data_url, prefix)) return null;
    const sep = std.mem.indexOf(u8, data_url, marker) orelse return null;
    const b64 = data_url[sep + marker.len ..];
    if (b64.len == 0) return null;

    const decoder = std.base64.standard.Decoder;
    const raw_len = decoder.calcSizeForSlice(b64) catch return null;
    if (raw_len > r.image.max_work_bytes) return null;
    const raw = gpa.alloc(u8, raw_len) catch return null;
    defer gpa.free(raw);
    decoder.decode(raw, b64) catch return null;

    var img = r.image.decode(gpa, raw) catch return null;
    img = r.image.scaleToFit(gpa, img, max_width_px, max_height_px) catch img;
    return img;
}

test "inline image keys are scoped to the owning agent" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const first_id = r.AgentId{ .index = 1, .generation = 0 };
    const second_id = r.AgentId{ .index = 2, .generation = 0 };
    const first = store.rememberBorrowed(std.testing.allocator, first_id, "same", "data:image/png;base64,one") orelse return error.OutOfMemory;
    const second = store.rememberBorrowed(std.testing.allocator, second_id, "same", "data:image/png;base64,two") orelse return error.OutOfMemory;
    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, store.find(first_id, "same"));
    try std.testing.expectEqual(second, store.find(second_id, "same"));
}

test "decoded eviction preserves placement cleanup and rehydration state" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = r.AgentId{ .index = 1, .generation = 0 };
    const entry = store.rememberBorrowed(std.testing.allocator, id, "same", "data:image/png;base64,source") orelse return error.OutOfMemory;
    entry.img = .{ .width = 1, .height = 1, .pixels = try std.testing.allocator.alloc(u8, 4) };
    entry.state.store(.ready, .release);
    entry.transmitted = true;
    entry.placed_gen = 7;

    try std.testing.expect(store.evictDecoded(std.testing.allocator, null, 1));
    try std.testing.expectEqual(State.pending, entry.state.load(.acquire));
    try std.testing.expect(entry.img == null);
    try std.testing.expect(!entry.transmitted);
    try std.testing.expectEqual(@as(u64, 7), entry.placed_gen);
    try std.testing.expectEqual(@as(u64, 1), store.eviction_gen);
    try std.testing.expectEqualStrings("data:image/png;base64,source", entry.data_url);
}

test "owned image sources can be rehydrated after source eviction" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = r.AgentId{ .index = 1, .generation = 0 };
    const source = "data:image/png;base64,source";
    const entry = store.remember(std.testing.allocator, id, "same", source) orelse return error.OutOfMemory;
    store.makeSourceRoom(std.testing.allocator, max_source_cache_bytes, null);
    try std.testing.expectEqual(@as(usize, 0), entry.data_url.len);
    _ = store.rememberBorrowed(std.testing.allocator, id, "same", source) orelse return error.OutOfMemory;
    try std.testing.expectEqualStrings(source, entry.data_url);
    try std.testing.expect(!entry.data_owned);
}
