const std = @import("std");
const opts_mod = @import("options.zig");
const rate_limiter = @import("rate_limit.zig");

test "parallel acquire stress" {
    const saved_window = rate_limiter.window_ns;
    defer rate_limiter.window_ns = saved_window;
    rate_limiter.window_ns = 200 * std.time.ns_per_ms;

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();

    const Worker = struct {
        fn run(io_arg: std.Io, url: []const u8, limit: u32, token: ?*opts_mod.CancellationToken, attempts: usize) void {
            var i: usize = 0;
            while (i < attempts) : (i += 1) {
                rate_limiter.acquire(io_arg, url, limit, token) catch return;
            }
        }
    };

    const url = "https://stress.example.com/v1";
    var futures: [8]std.Io.Future(void) = undefined;
    for (&futures) |*f| {
        f.* = std.Io.async(io, Worker.run, .{ io, url, 3, null, @as(usize, 5) });
    }
    for (&futures) |*f| f.await(io);
}

test "parallel acquire stress with cancel" {
    const saved_window = rate_limiter.window_ns;
    defer rate_limiter.window_ns = saved_window;
    rate_limiter.window_ns = 200 * std.time.ns_per_ms;

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();

    const Worker = struct {
        fn run(io_arg: std.Io, url: []const u8, limit: u32, token: ?*opts_mod.CancellationToken, attempts: usize) void {
            var i: usize = 0;
            while (i < attempts) : (i += 1) {
                rate_limiter.acquire(io_arg, url, limit, token) catch return;
            }
        }
        fn canceller(io_arg: std.Io, token: *opts_mod.CancellationToken) void {
            std.Io.sleep(io_arg, .fromMilliseconds(50), .awake) catch {};
            token.cancel(io_arg);
        }
    };

    const url = "https://stress2.example.com/v1";
    var token = opts_mod.CancellationToken{};
    var cancel_future = std.Io.async(io, Worker.canceller, .{ io, &token });
    defer cancel_future.cancel(io);
    var futures: [8]std.Io.Future(void) = undefined;
    for (&futures) |*f| {
        f.* = std.Io.async(io, Worker.run, .{ io, url, 3, &token, @as(usize, 5) });
    }
    for (&futures) |*f| f.await(io);
}

test "acquire under thread pool saturation" {
    const saved_window = rate_limiter.window_ns;
    defer rate_limiter.window_ns = saved_window;
    rate_limiter.window_ns = 500 * std.time.ns_per_ms;

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();

    const Pool = struct {
        fn hog(io_arg: std.Io) void {
            std.Io.sleep(io_arg, .fromMilliseconds(300), .awake) catch {};
        }
        fn worker(io_arg: std.Io, url: []const u8, limit: u32, attempts: usize) void {
            var i: usize = 0;
            while (i < attempts) : (i += 1) {
                rate_limiter.acquire(io_arg, url, limit, null) catch return;
            }
        }
    };

    const url = "https://sat.example.com/v1";
    var hogs: [64]std.Io.Future(void) = undefined;
    for (&hogs) |*h| h.* = std.Io.async(io, Pool.hog, .{io});
    var futures: [8]std.Io.Future(void) = undefined;
    for (&futures) |*f| {
        f.* = std.Io.async(io, Pool.worker, .{ io, url, 2, @as(usize, 3) });
    }
    for (&futures) |*f| f.await(io);
    for (&hogs) |*h| h.await(io);
}
