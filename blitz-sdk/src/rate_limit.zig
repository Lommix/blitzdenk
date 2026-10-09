const std = @import("std");
const opts_mod = @import("options.zig");

pub var window_ns: i128 = 60 * std.time.ns_per_s;

const MAX_ENTRIES = 64;
const MAX_URL_LEN = 512;

const Entry = struct {
    url: [MAX_URL_LEN]u8 = undefined,
    url_len: usize = 0,
    rate_limit: u32 = 0,
    window_start: i128 = 0,
    count: u32 = 0,
    mutex: std.Io.Mutex = .init,
};

var entries: [MAX_ENTRIES]Entry = @splat(.{});
var used: usize = 0;
var registry_mutex: std.Io.Mutex = .init;

pub fn acquire(io: std.Io, url: []const u8, rate_limit: u32, cancellation: ?*opts_mod.CancellationToken) !void {
    if (rate_limit == 0 or url.len == 0) return;
    const entry = try getOrCreate(io, url, rate_limit) orelse return;
    while (true) {
        if (cancellation) |token| try token.check();
        try entry.mutex.lock(io);
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now - entry.window_start >= window_ns) {
            entry.window_start = now;
            entry.count = 0;
        }
        if (entry.count < entry.rate_limit) {
            entry.count += 1;
            entry.mutex.unlock(io);
            return;
        }
        const wait_ms: u64 = @intCast(@max(@divTrunc(entry.window_start + window_ns - now, std.time.ns_per_ms), 1));
        entry.mutex.unlock(io);
        try opts_mod.sleepCancellable(io, wait_ms, cancellation);
    }
}

fn getOrCreate(io: std.Io, url: []const u8, rate_limit: u32) !?*Entry {
    try registry_mutex.lock(io);
    defer registry_mutex.unlock(io);
    for (entries[0..used]) |*e| {
        if (e.url_len == url.len and std.mem.eql(u8, e.url[0..e.url_len], url)) return e;
    }
    if (used >= MAX_ENTRIES or url.len > MAX_URL_LEN) return null;
    const e = &entries[used];
    used += 1;
    @memcpy(e.url[0..url.len], url);
    e.url_len = url.len;
    e.rate_limit = rate_limit;
    e.window_start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    return e;
}
