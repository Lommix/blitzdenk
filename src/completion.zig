const std = @import("std");

pub const Kind = enum { dir, file };

pub const Entry = struct {
    name: []const u8,
    kind: Kind = .file,
};

pub const DirEntryList = struct {
    entries: std.ArrayList(Entry) = .empty,
    probed_dir: []const u8 = "",
    stamp_ms: i64 = 0,
    valid: bool = false,
    include_hidden: bool = false,

    pub fn deinit(self: *DirEntryList, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| alloc.free(e.name);
        self.entries.deinit(alloc);
        if (self.probed_dir.len > 0) alloc.free(self.probed_dir);
        self.probed_dir = "";
        self.valid = false;
    }

    pub fn fresh(self: *const DirEntryList, now_ms: i64) bool {
        return self.valid and now_ms - self.stamp_ms <= CACHE_TTL_MS;
    }
};

pub const CACHE_SLOTS = 8;
pub const CACHE_TTL_MS: i64 = 2000;
pub const PROBE_TIMEOUT_MS: i64 = 2000;
pub const DEBOUNCE_MS: i64 = 150;
pub const MAX_ENTRIES = 512;

pub const DirCache = struct {
    slots: [CACHE_SLOTS]?DirEntryList = @splat(null),

    pub fn find(self: *DirCache, probed_dir: []const u8) ?*DirEntryList {
        for (&self.slots) |*slot| {
            const list = &(slot.* orelse continue);
            if (std.mem.eql(u8, list.probed_dir, probed_dir)) return list;
        }
        return null;
    }

    pub fn evictSlotFor(self: *DirCache, alloc: std.mem.Allocator, probed_dir: []const u8) void {
        if (self.find(probed_dir) != null) return;
        var oldest_idx: ?usize = null;
        var oldest_ms: i64 = 0;
        for (self.slots, 0..) |slot, i| {
            const list = slot orelse continue;
            if (oldest_idx == null or list.stamp_ms < oldest_ms) {
                oldest_idx = i;
                oldest_ms = list.stamp_ms;
            }
        }
        if (oldest_idx) |i| {
            self.slots[i].?.deinit(alloc);
            self.slots[i] = null;
        }
    }

    pub fn beginInsert(self: *DirCache, alloc: std.mem.Allocator, probed_dir: []const u8) !*DirEntryList {
        if (self.find(probed_dir)) |list| {
            list.valid = false;
            list.entries.clearRetainingCapacity();
            return list;
        }
        self.evictSlotFor(alloc, probed_dir);
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                slot.* = .{};
                const list = &slot.*.?;
                list.probed_dir = try alloc.dupe(u8, probed_dir);
                return list;
            }
        }
        unreachable;
    }

    pub fn clear(self: *DirCache, alloc: std.mem.Allocator) void {
        for (&self.slots) |*slot| {
            if (slot.*) |*list| list.deinit(alloc);
            slot.* = null;
        }
    }
};

pub const Token = struct {
    start: usize,
    end: usize,
    is_path: bool,
};

pub fn tokenAt(input: []const u8, cursor: usize) Token {
    const end = @min(cursor, input.len);
    var start = end;
    while (start > 0) : (start -= 1) {
        const c = input[start - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == ':') break;
    }
    return .{ .start = start, .end = end, .is_path = std.mem.indexOfScalar(u8, input[start..end], '/') != null };
}

pub fn commandTokenOwns(input: []const u8, cursor: usize) bool {
    if (cursor == 0) return false;
    if (input[0] != '/') return false;
    const end = @min(cursor, input.len);
    if (std.mem.indexOfScalar(u8, input[0..end], ' ') != null) return false;
    return std.mem.indexOfScalarPos(u8, input[0..end], 1, '/') == null;
}

pub fn splitToken(
    alloc: std.mem.Allocator,
    token: []const u8,
    home: []const u8,
) !struct { dir: []const u8, insert_prefix: []const u8, filter: []const u8, include_hidden: bool } {
    if (token.len == 0) return error.Empty;
    const slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse return error.Empty;
    const insert_prefix = token[0 .. slash + 1];
    const filter = token[slash + 1 ..];
    const dir_part = token[0..slash];

    var dir: []const u8 = undefined;
    if (dir_part.len == 0) {
        dir = try alloc.dupe(u8, "/");
    } else if (dir_part[0] == '~') {
        if (dir_part.len == 1) {
            dir = try alloc.dupe(u8, home);
        } else if (dir_part[1] == '/') {
            const rest = dir_part[2..];
            dir = if (rest.len == 0)
                try alloc.dupe(u8, home)
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, rest });
        } else {
            dir = try alloc.dupe(u8, dir_part);
        }
    } else if (dir_part.len >= 2 and dir_part[0] == '.' and dir_part[1] == '/') {
        const rest = dir_part[2..];
        dir = if (rest.len == 0) try alloc.dupe(u8, ".") else try alloc.dupe(u8, rest);
    } else {
        dir = try alloc.dupe(u8, dir_part);
    }
    return .{
        .dir = dir,
        .insert_prefix = insert_prefix,
        .filter = filter,
        .include_hidden = filter.len > 0 and filter[0] == '.',
    };
}

pub fn parseLsOutput(alloc: std.mem.Allocator, out: *DirEntryList, stdout: []const u8) !void {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        if (out.entries.items.len >= MAX_ENTRIES) break;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        var kind: Kind = .file;
        var name = line;
        if (line[line.len - 1] == '/') {
            kind = .dir;
            name = line[0 .. line.len - 1];
            if (name.len == 0) continue;
        }
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const stored_name = if (kind == .dir)
            try std.fmt.allocPrint(alloc, "{s}/", .{name})
        else
            try alloc.dupe(u8, name);
        errdefer alloc.free(stored_name);
        try out.entries.append(alloc, .{ .name = stored_name, .kind = kind });
    }
}

fn kindRank(kind: Kind) u8 {
    return switch (kind) {
        .dir => 0,
        .file => 1,
    };
}

pub fn sortEntries(entries: []Entry) void {
    const Ctx = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const ra = kindRank(a.kind);
            const rb = kindRank(b.kind);
            if (ra != rb) return ra < rb;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(Entry, entries, {}, Ctx.lessThan);
}

pub fn kindDescription(kind: Kind) []const u8 {
    return switch (kind) {
        .dir => "dir",
        .file => "file",
    };
}

test "tokenAt splits on whitespace and colon" {
    const Case = struct {
        input: []const u8,
        cursor: usize,
        want_start: usize,
        want_end: usize,
        want_path: bool,
    };
    const cases = [_]Case{
        .{ .input = "./src/m", .cursor = 7, .want_start = 0, .want_end = 7, .want_path = true },
        .{ .input = "run ./src/m", .cursor = 11, .want_start = 4, .want_end = 11, .want_path = true },
        .{ .input = "check:/var/lo", .cursor = 13, .want_start = 6, .want_end = 13, .want_path = true },
        .{ .input = "plain", .cursor = 5, .want_start = 0, .want_end = 5, .want_path = false },
        .{ .input = "a b c", .cursor = 3, .want_start = 2, .want_end = 3, .want_path = false },
        .{ .input = "src ", .cursor = 4, .want_start = 4, .want_end = 4, .want_path = false },
    };
    for (cases) |c| {
        const tok = tokenAt(c.input, c.cursor);
        try std.testing.expectEqual(c.want_start, tok.start);
        try std.testing.expectEqual(c.want_end, tok.end);
        try std.testing.expectEqual(c.want_path, tok.is_path);
    }
}

test "commandTokenOwns single-segment leading slash" {
    try std.testing.expect(commandTokenOwns("/et", 3));
    try std.testing.expect(!commandTokenOwns("/etc/", 5));
    try std.testing.expect(commandTokenOwns("/ssh-", 5));
    try std.testing.expect(!commandTokenOwns("run /et", 7));
}

test "splitToken resolves tilde dot and root" {
    const a = std.testing.allocator;

    {
        const got = try splitToken(a, "~/Doc/re", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings("/home/u/Doc", got.dir);
        try std.testing.expectEqualStrings("~/Doc/", got.insert_prefix);
        try std.testing.expectEqualStrings("re", got.filter);
        try std.testing.expect(!got.include_hidden);
    }
    {
        const got = try splitToken(a, "~/", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings("/home/u", got.dir);
        try std.testing.expectEqualStrings("~/", got.insert_prefix);
        try std.testing.expectEqualStrings("", got.filter);
    }
    {
        const got = try splitToken(a, "./sr", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings(".", got.dir);
        try std.testing.expectEqualStrings("./", got.insert_prefix);
    }
    {
        const got = try splitToken(a, "/etc/ap", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings("/etc", got.dir);
        try std.testing.expectEqualStrings("/etc/", got.insert_prefix);
    }
    {
        const got = try splitToken(a, "src/co", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings("src", got.dir);
        try std.testing.expectEqualStrings("src/", got.insert_prefix);
    }
    {
        const got = try splitToken(a, "./.gi", "/home/u");
        defer a.free(got.dir);
        try std.testing.expectEqualStrings(".", got.dir);
        try std.testing.expectEqualStrings("./", got.insert_prefix);
        try std.testing.expect(got.include_hidden);
    }
    {
        try std.testing.expectError(error.Empty, splitToken(a, "no_slash", "/home/u"));
    }
}

test "parseLsOutput keeps dir slash and skips dot entries" {
    const a = std.testing.allocator;
    var out = DirEntryList{};
    defer out.deinit(a);
    try parseLsOutput(a, &out, "alpha/\nbeta\n.\n..\n.gamma\n\r\n");
    try std.testing.expectEqual(@as(usize, 3), out.entries.items.len);
    try std.testing.expectEqualStrings("alpha/", out.entries.items[0].name);
    try std.testing.expectEqual(Kind.dir, out.entries.items[0].kind);
    try std.testing.expectEqualStrings("beta", out.entries.items[1].name);
    try std.testing.expectEqualStrings(".gamma", out.entries.items[2].name);
}

test "sortEntries dirs first then alphabetical" {
    var entries = [_]Entry{
        .{ .name = "zeta" },
        .{ .name = "abc/" },
        .{ .name = "mid" },
        .{ .name = "abd/" },
    };
    sortEntries(&entries);
    try std.testing.expectEqualStrings("abc/", entries[0].name);
    try std.testing.expectEqualStrings("abd/", entries[1].name);
    try std.testing.expectEqualStrings("mid", entries[2].name);
    try std.testing.expectEqualStrings("zeta", entries[3].name);
}
