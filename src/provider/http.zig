const std = @import("std");
const log = std.log.scoped(.http);

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
}

pub const RequestPool = struct {
    pub const MAX_SLOTS = 64;
    pub const BODY_BUF_SIZE = 64 * 1024;

    pub const Slot = struct {
        in_use: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        headers_ready: std.atomic.Value(bool) = .init(false),
        generation: u32 = 0,
        status: std.http.Status = .ok,
        duration_ms: u64 = 0,
        deadline_ms: ?i64 = null,
        err: ?anyerror = null,
        future: std.Io.Future(std.Io.Cancelable!void) = .{ .any_future = null, .result = {} },
        body: std.Io.Queue(u8) = undefined,
        body_buf: [BODY_BUF_SIZE]u8 = undefined,
    };

    pub const RequestHandle = packed struct {
        index: u16,
        generation: u32,
    };

    slots: [MAX_SLOTS]Slot = [_]Slot{.{}} ** MAX_SLOTS,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    client: std.http.Client = undefined,

    pub fn init(self: *RequestPool, allocator: std.mem.Allocator, io: std.Io) !void {
        self.allocator = allocator;
        self.io = io;
        self.client = .{ .allocator = allocator, .io = io };
        for (&self.slots) |*slot| slot.body = .init(&slot.body_buf);
    }

    pub fn deinit(self: *RequestPool) void {
        for (&self.slots) |*slot| {
            if (!slot.in_use.load(.acquire)) continue;
            slot.body.close(self.io);
            slot.future.cancel(self.io) catch {};
        }
        self.client.deinit();
    }

    pub fn fetch(
        self: *RequestPool,
        url: []const u8,
        method: std.http.Method,
        payload: ?[]const u8,
        extra_headers: []const std.http.Header,
        timeout_ms: ?u32,
    ) !RequestHandle {
        const idx = for (&self.slots, 0..) |*slot, i| {
            if (slot.in_use.cmpxchgStrong(false, true, .acquire, .monotonic) == null) break i;
        } else return error.PoolExhausted;

        const slot = &self.slots[idx];
        slot.generation +%= 1;
        slot.done.store(false, .release);
        slot.headers_ready.store(false, .release);
        slot.err = null;
        slot.deadline_ms = if (timeout_ms) |t| nowMs(self.io) + @as(i64, @intCast(t)) else null;
        slot.body = .init(&slot.body_buf);

        const handle = RequestHandle{ .index = @intCast(idx), .generation = slot.generation };

        errdefer {
            slot.body.close(self.io);
            slot.in_use.store(false, .release);
        }

        const duped_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(duped_url);

        const duped_payload = if (payload) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (duped_payload) |p| self.allocator.free(p);

        const duped_headers = try self.dupeHeaders(extra_headers);
        errdefer self.freeHeaders(duped_headers);

        slot.future = std.Io.async(self.io, workerFn, .{ self, slot, duped_url, duped_payload, method, duped_headers });

        return handle;
    }

    fn dupeHeaders(self: *RequestPool, headers: []const std.http.Header) ![]std.http.Header {
        if (headers.len == 0) return &.{};
        const duped = try self.allocator.alloc(std.http.Header, headers.len);
        for (headers, 0..) |h, i| {
            duped[i] = .{
                .name = try self.allocator.dupe(u8, h.name),
                .value = try self.allocator.dupe(u8, h.value),
            };
        }
        return duped;
    }

    fn freeHeaders(self: *RequestPool, headers: []const std.http.Header) void {
        if (headers.len == 0) return;
        for (headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(headers);
    }

    fn workerFn(
        self: *RequestPool,
        slot: *Slot,
        duped_url: []const u8,
        duped_payload: ?[]const u8,
        method: std.http.Method,
        duped_headers: []const std.http.Header,
    ) std.Io.Cancelable!void {
        defer self.allocator.free(duped_url);
        defer if (duped_payload) |p| self.allocator.free(p);
        defer self.freeHeaders(duped_headers);
        defer slot.body.close(self.io);
        defer slot.done.store(true, .release);

        const start = nowMs(self.io);

        log.debug("worker start url={s}", .{duped_url});
        self.runRequest(slot, duped_url, duped_payload, method, duped_headers) catch |err| {
            log.debug("worker failed: {s}", .{@errorName(err)});
            slot.duration_ms = @intCast(@max(0, nowMs(self.io) - start));
            slot.err = err;
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        log.debug("worker done status={d} dur={d}ms", .{ @intFromEnum(slot.status), nowMs(self.io) - start });
        slot.duration_ms = @intCast(@max(0, nowMs(self.io) - start));
    }

    fn runRequest(
        self: *RequestPool,
        slot: *Slot,
        url: []const u8,
        payload: ?[]const u8,
        method: std.http.Method,
        extra_headers: []const std.http.Header,
    ) !void {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(method, uri, .{
            .redirect_behavior = if (payload == null) @enumFromInt(3) else .unhandled,
            .extra_headers = extra_headers,
            .headers = .{ .accept_encoding = .omit },
            .keep_alive = false,
        });
        defer req.deinit();

        if (payload) |p| {
            log.debug("request payload {d} bytes", .{p.len});
            req.transfer_encoding = .{ .content_length = p.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(p);
            try body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        slot.status = response.head.status;
        slot.headers_ready.store(true, .release);
        log.debug("headers received status={d}", .{@intFromEnum(response.head.status)});

        const reader = response.reader(&.{});

        var scratch: [16 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&scratch);

        while (true) {
            writer.end = 0;
            _ = reader.stream(&writer, .limited(scratch.len)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    log.debug("stream ReadFailed: {?}", .{response.bodyErr()});
                    return response.bodyErr() orelse error.ReadFailed;
                },
                error.WriteFailed => unreachable,
            };
            if (writer.end == 0) continue;

            slot.body.putAll(self.io, scratch[0..writer.end]) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
        }
    }

    pub fn countPending(self: *const RequestPool) u32 {
        var count: u32 = 0;
        for (&self.slots) |*slot| {
            if (slot.in_use.load(.acquire) and !slot.done.load(.acquire)) count += 1;
        }
        return count;
    }

    /// True once response headers have arrived (status readable) OR the
    /// request has settled.
    pub fn headersReady(self: *RequestPool, handle: RequestHandle) bool {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return false;
        if (slot.headers_ready.load(.acquire)) return true;
        return slot.done.load(.acquire);
    }

    /// True once the worker has finished producing chunks.
    pub fn isStreamDone(self: *RequestPool, handle: RequestHandle) bool {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return true;
        return slot.done.load(.acquire);
    }

    /// Back-compat shim. "Done" means settled, or deadline elapsed.
    pub fn isDone(self: *RequestPool, handle: RequestHandle) bool {
        const slot = &self.slots[handle.index];
        if (slot.done.load(.acquire)) return true;
        if (self.timedOut(handle)) return true;
        return false;
    }

    pub fn timedOut(self: *RequestPool, handle: RequestHandle) bool {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return false;
        const deadline = slot.deadline_ms orelse return false;
        return nowMs(self.io) >= deadline;
    }

    pub fn getStatus(self: *RequestPool, handle: RequestHandle) !std.http.Status {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return error.StaleHandle;
        if (slot.err) |e| return e;
        if (!slot.headers_ready.load(.acquire)) return error.NotReady;
        return slot.status;
    }

    /// Pop the next available bytes from the body queue. Returns null if
    /// nothing is currently buffered (worker still running). Caller frees the
    /// returned slice via dropChunk.
    pub fn nextChunk(self: *RequestPool, handle: RequestHandle) !?[]u8 {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return error.StaleHandle;

        var scratch: [16 * 1024]u8 = undefined;
        const n = slot.body.getUncancelable(self.io, &scratch, 0) catch |err| switch (err) {
            error.Closed => {
                if (slot.err) |e| return e;
                return null;
            },
        };
        if (n == 0) return null;
        return try self.allocator.dupe(u8, scratch[0..n]);
    }

    pub fn dropChunk(self: *RequestPool, data: []u8) void {
        self.allocator.free(data);
    }

    /// Drain all remaining chunks into a single owned buffer. Caller frees
    /// via allocator.free.
    pub fn collectBody(self: *RequestPool, handle: RequestHandle, allocator: std.mem.Allocator) ![]u8 {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return error.StaleHandle;

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        var scratch: [16 * 1024]u8 = undefined;
        while (true) {
            const n = slot.body.getUncancelable(self.io, &scratch, 1) catch |err| switch (err) {
                error.Closed => break,
            };
            try list.appendSlice(allocator, scratch[0..n]);
        }
        if (slot.err) |e| return e;
        return list.toOwnedSlice(allocator);
    }

    /// Release a settled slot. No-op on stale handles.
    pub fn release(self: *RequestPool, handle: RequestHandle) void {
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation) return;
        if (!slot.in_use.load(.acquire)) return;

        // Worker finished or we cancel it. Either way we own the slot after.
        if (slot.done.load(.acquire)) {
            slot.future.await(self.io) catch {};
        } else {
            slot.body.close(self.io);
            slot.future.cancel(self.io) catch {};
        }

        slot.err = null;
        slot.deadline_ms = null;
        slot.generation +%= 1;
        slot.in_use.store(false, .release);
    }

    /// Cancel a handle regardless of state. Bumps generation.
    pub fn cancel(self: *RequestPool, handle: RequestHandle) void {
        self.release(handle);
    }

    pub fn cancelAll(self: *RequestPool) void {
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.in_use.load(.acquire)) continue;
            const handle = RequestHandle{ .index = @intCast(i), .generation = slot.generation };
            self.release(handle);
        }
    }
};
