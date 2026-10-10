const std = @import("std");

pub const Entry = struct {
    path: []u8,
    mtime: i128,
    size: u64,
    digest: u64,
    warned: bool = false,
};

pub fn isReloadableConfigLua(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".lua") and !std.mem.eql(u8, name, "meta.lua");
}

pub const Watch = struct {
    alloc: std.mem.Allocator,
    blitz_path: []const u8 = "",
    config_dir: []const u8 = "",
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Watch {
        return .{ .alloc = allocator };
    }

    pub fn deinit(self: *Watch) void {
        for (self.entries.items) |entry| self.alloc.free(entry.path);
        self.entries.deinit(self.alloc);
    }

    pub fn addBaseline(self: *Watch, io: std.Io, abs_path: []const u8) void {
        const stat = std.Io.Dir.cwd().statFile(io, abs_path, .{}) catch return;
        const digest = hashFile(io, abs_path) catch return;
        self.appendEntry(abs_path, stat.mtime.nanoseconds, stat.size, digest);
    }

    pub fn pollCycle(self: *Watch, io: std.Io) bool {
        var changed = false;
        if (self.blitz_path.len > 0 and self.processFile(io, self.blitz_path)) changed = true;
        if (self.config_dir.len > 0) {
            var dir = std.Io.Dir.openDirAbsolute(io, self.config_dir, .{ .iterate = true }) catch return changed;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!isReloadableConfigLua(entry.name)) continue;
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const abs_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.config_dir, entry.name }) catch continue;
                if (self.processFile(io, abs_path)) changed = true;
            }
        }
        return changed;
    }

    pub fn refreshAfterReload(self: *Watch, io: std.Io) void {
        for (self.entries.items) |entry| self.alloc.free(entry.path);
        self.entries.clearRetainingCapacity();
        if (self.blitz_path.len > 0) self.addBaseline(io, self.blitz_path);
        if (self.config_dir.len > 0) {
            var dir = std.Io.Dir.openDirAbsolute(io, self.config_dir, .{ .iterate = true }) catch return;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!isReloadableConfigLua(entry.name)) continue;
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const abs_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.config_dir, entry.name }) catch continue;
                self.addBaseline(io, abs_path);
            }
        }
    }

    fn processFile(self: *Watch, io: std.Io, abs_path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(io, abs_path, .{}) catch |err| {
            if (err != error.FileNotFound) self.warnOnce(abs_path);
            return false;
        };
        const index = self.findIndex(abs_path) orelse {
            const digest = hashFile(io, abs_path) catch return false;
            self.appendEntry(abs_path, stat.mtime.nanoseconds, stat.size, digest);
            return false;
        };
        const entry = &self.entries.items[index];
        if (stat.mtime.nanoseconds == entry.mtime and stat.size == entry.size) return false;
        const digest = hashFile(io, abs_path) catch {
            self.warnOnce(abs_path);
            return false;
        };
        if (digest == entry.digest) {
            entry.mtime = stat.mtime.nanoseconds;
            entry.size = stat.size;
            return false;
        }
        return true;
    }

    fn appendEntry(self: *Watch, abs_path: []const u8, mtime: i128, size: u64, digest: u64) void {
        const path = self.alloc.dupe(u8, abs_path) catch return;
        self.entries.append(self.alloc, .{ .path = path, .mtime = mtime, .size = size, .digest = digest }) catch {
            self.alloc.free(path);
        };
    }

    fn findIndex(self: *Watch, abs_path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, abs_path)) return i;
        }
        return null;
    }

    fn warnOnce(self: *Watch, abs_path: []const u8) void {
        const index = self.findIndex(abs_path) orelse return;
        const entry = &self.entries.items[index];
        if (entry.warned) return;
        entry.warned = true;
        std.log.scoped(.config_watch).warn("failed to read {s}", .{abs_path});
    }
};

fn hashFile(io: std.Io, abs_path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, abs_path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    var hasher = std.hash.Fnv1a_64.init();
    while (true) {
        var buf: [16 * 1024]u8 = undefined;
        const n = try file_reader.interface.readSliceShort(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}

fn absPath(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
}

fn findEntry(watch: *Watch, abs_path: []const u8) ?*Entry {
    for (watch.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, abs_path)) return entry;
    }
    return null;
}

fn futureTimestamp(seconds: i96) std.Io.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(seconds * std.time.ns_per_s);
}

test "editor activity in a real config dir drives reload decisions" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var blitz_tmp = std.testing.tmpDir(.{});
    defer blitz_tmp.cleanup();
    var cfg_tmp = std.testing.tmpDir(.{});
    defer cfg_tmp.cleanup();
    try blitz_tmp.dir.writeFile(io, .{ .sub_path = "blitz.lua", .data = "return 0" });
    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "mod.lua", .data = "return 1" });
    const blitz_dir = try blitz_tmp.dir.realPathFileAlloc(io, ".", alloc);
    const config_dir = try cfg_tmp.dir.realPathFileAlloc(io, ".", alloc);
    const blitz_abs = try absPath(alloc, blitz_dir, "blitz.lua");
    const mod_abs = try absPath(alloc, config_dir, "mod.lua");
    var watch = Watch.init(std.testing.allocator);
    defer watch.deinit();
    watch.blitz_path = blitz_abs;
    watch.config_dir = config_dir;
    watch.refreshAfterReload(io);

    {
        var blitz_file = try blitz_tmp.dir.openFile(io, "blitz.lua", .{});
        defer blitz_file.close(io);
        try blitz_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_000_000) } });
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_000_100) } });
    }
    try std.testing.expectEqual(false, watch.pollCycle(io));
    const blitz_stat = try std.Io.Dir.cwd().statFile(io, blitz_abs, .{});
    try std.testing.expectEqual(blitz_stat.mtime.nanoseconds, findEntry(&watch, blitz_abs).?.mtime);
    const mod_stat = try std.Io.Dir.cwd().statFile(io, mod_abs, .{});
    try std.testing.expectEqual(mod_stat.mtime.nanoseconds, findEntry(&watch, mod_abs).?.mtime);

    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "mod.lua", .data = "return 2" });
    {
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_001_000) } });
    }
    try std.testing.expectEqual(true, watch.pollCycle(io));
    watch.refreshAfterReload(io);
    try std.testing.expectEqual(false, watch.pollCycle(io));

    {
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(1_000_000) } });
    }
    try std.testing.expectEqual(false, watch.pollCycle(io));
    const backwards_stat = try std.Io.Dir.cwd().statFile(io, mod_abs, .{});
    try std.testing.expectEqual(backwards_stat.mtime.nanoseconds, findEntry(&watch, mod_abs).?.mtime);

    try cfg_tmp.dir.deleteFile(io, "mod.lua");
    try std.testing.expectEqual(false, watch.pollCycle(io));
    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "mod.lua", .data = "return 2" });
    {
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_002_000) } });
    }
    try std.testing.expectEqual(false, watch.pollCycle(io));
    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "mod.lua", .data = "return 3" });
    {
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_002_500) } });
    }
    try std.testing.expectEqual(true, watch.pollCycle(io));

    watch.refreshAfterReload(io);
    if (std.os.linux.geteuid() != 0) {
        const before: Entry = findEntry(&watch, mod_abs).?.*;
        var mod_file = try cfg_tmp.dir.openFile(io, "mod.lua", .{});
        defer mod_file.close(io);
        try mod_file.setPermissions(io, .fromMode(0o000));
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_002_600) } });
        try std.testing.expectEqual(false, watch.pollCycle(io));
        try std.testing.expectEqual(before.mtime, findEntry(&watch, mod_abs).?.mtime);
        try std.testing.expectEqual(before.digest, findEntry(&watch, mod_abs).?.digest);
        try mod_file.setPermissions(io, .fromMode(0o644));
        try mod_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_002_700) } });
        try std.testing.expectEqual(false, watch.pollCycle(io));
    }

    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "new.lua", .data = "return 10" });
    {
        var new_file = try cfg_tmp.dir.openFile(io, "new.lua", .{});
        defer new_file.close(io);
        try new_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_003_000) } });
    }
    try std.testing.expectEqual(false, watch.pollCycle(io));
    try cfg_tmp.dir.writeFile(io, .{ .sub_path = "new.lua", .data = "return 11" });
    {
        var new_file = try cfg_tmp.dir.openFile(io, "new.lua", .{});
        defer new_file.close(io);
        try new_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = futureTimestamp(4_000_004_000) } });
    }
    try std.testing.expectEqual(true, watch.pollCycle(io));

    try std.testing.expectEqual(true, watch.pollCycle(io));
    watch.refreshAfterReload(io);
    try std.testing.expectEqual(false, watch.pollCycle(io));
}
