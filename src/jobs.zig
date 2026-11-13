//! Background shell jobs. The exec slot keeps the merged output in memory;
//! the app tick reaps finished jobs and notifies the owning agent. Exited jobs
//! stay readable until a new job needs the entry or the owner goes away.
const std = @import("std");
const exec = @import("exec");
const util = @import("util.zig");
const AgentId = @import("agent-id").AgentId;

pub const MAX_JOBS = 8;
pub const LOG_CAP = 4 * 1024 * 1024;
pub const TAIL_LINES = 20;

pub const Job = struct {
    id: u32,
    owner: AgentId,
    command: []const u8,
    started_ms: i64,
    handle: exec.CmdPool.Handle,
    /// Set once the job exited; owns the final output.
    result: ?exec.CmdResult = null,
    elapsed_ms: i64 = 0,

    fn deinit(self: Job, alloc: std.mem.Allocator) void {
        alloc.free(self.command);
        if (self.result) |res| freeResult(alloc, res);
    }
};

/// Exit notice data. Owns `command` and `tail`.
pub const Finished = struct {
    id: u32,
    owner: AgentId,
    command: []const u8,
    exit_code: ?u8,
    signal: ?u32,
    elapsed_ms: i64,
    /// Last lines of the output, formatted by `formatLines`.
    tail: []const u8,

    pub fn deinit(self: Finished, alloc: std.mem.Allocator) void {
        alloc.free(self.command);
        alloc.free(self.tail);
    }
};

pub const Killed = struct {
    /// Last lines of the output, formatted by `formatLines`. Owned.
    tail: []const u8,
};

pub const State = union(enum) {
    running,
    exited: struct { exit_code: ?u8, signal: ?u32 },
};

pub const Page = struct {
    state: State,
    /// Owned, formatted by `formatLines`.
    text: []const u8,
};

pub const Jobs = struct {
    mu: std.Io.Mutex = .init,
    items: [MAX_JOBS]?Job = @splat(null),
    next_id: u32 = 1,

    /// Run `command` with `/bin/sh -c` in the background. Evicts the oldest
    /// exited job when the table is full.
    pub fn start(self: *Jobs, pool: *exec.CmdPool, owner: AgentId, command: []const u8, cwd: []const u8) !u32 {
        const io = pool.io;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        const index = self.freeIndex(pool.alloc) orelse return error.TooManyJobs;
        const owned_command = try pool.alloc.dupe(u8, command);
        errdefer pool.alloc.free(owned_command);

        const handle = try pool.runWithOpts(.{
            .cwd = cwd,
            .argv = &.{ "/bin/sh", "-c", command },
            .kill_process_group = true,
            .scrub_env = true,
            .background = true,
            .max_output = LOG_CAP,
        });

        const id = self.next_id;
        self.next_id += 1;
        self.items[index] = .{
            .id = id,
            .owner = owner,
            .command = owned_command,
            .started_ms = nowMs(io),
            .handle = handle,
        };
        return id;
    }

    /// Kill a running job and drop it. Null when no running job has `id`.
    pub fn kill(self: *Jobs, pool: *exec.CmdPool, alloc: std.mem.Allocator, id: u32) !?Killed {
        const job = blk: {
            self.mu.lockUncancelable(pool.io);
            defer self.mu.unlock(pool.io);
            for (&self.items) |*item| {
                const job = item.* orelse continue;
                if (job.id != id or job.result != null) continue;
                item.* = null;
                break :blk job;
            }
            return null;
        };
        defer job.deinit(pool.alloc);
        // Cancelling the worker kills the process group.
        const res = try pool.killAndCollect(job.handle);
        defer freeResult(pool.alloc, res);
        return .{ .tail = try formatLines(alloc, res.stdout, res.dropped_lines, null, TAIL_LINES) };
    }

    /// Read lines of a job's output. Null when `id` is unknown.
    pub fn read(self: *Jobs, pool: *exec.CmdPool, alloc: std.mem.Allocator, id: u32, offset: ?usize, limit: usize) !?Page {
        self.mu.lockUncancelable(pool.io);
        defer self.mu.unlock(pool.io);
        for (self.items) |item| {
            const job = item orelse continue;
            if (job.id != id) continue;
            if (job.result) |res| return .{
                .state = .{ .exited = .{ .exit_code = res.exit_code, .signal = res.signal } },
                .text = try formatLines(alloc, res.stdout, res.dropped_lines, offset, limit),
            };
            const view = pool.lockOutput(job.handle);
            defer view.unlock();
            return .{ .state = .running, .text = try formatLines(alloc, view.text, view.dropped_lines, offset, limit) };
        }
        return null;
    }

    pub fn countRunning(self: *Jobs, io: std.Io) u32 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        var count: u32 = 0;
        for (self.items) |item| {
            const job = item orelse continue;
            if (job.result == null) count += 1;
        }
        return count;
    }

    pub fn killAll(self: *Jobs, pool: *exec.CmdPool) void {
        for (&self.items) |*item| {
            const job = item.* orelse continue;
            item.* = null;
            if (job.result == null) pool.release(job.handle);
            job.deinit(pool.alloc);
        }
    }

    /// Collect exits into `out`, and kill or drop jobs whose owner is gone.
    /// `alive` answers `fn (ctx, AgentId) bool`. Deinit each entry of `out`
    /// with `pool.alloc`.
    pub fn tick(
        self: *Jobs,
        pool: *exec.CmdPool,
        ctx: anytype,
        comptime alive: fn (@TypeOf(ctx), AgentId) bool,
        out: *std.ArrayList(Finished),
    ) !void {
        const io = pool.io;
        var orphans: [MAX_JOBS]Job = undefined;
        var orphan_count: usize = 0;
        // Cancelling an orphan's worker kills its process group; may block
        // briefly, so it runs after the table lock is released.
        defer for (orphans[0..orphan_count]) |job| {
            if (job.result == null) pool.release(job.handle);
            job.deinit(pool.alloc);
        };

        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        for (&self.items) |*item| {
            const job = if (item.*) |*j| j else continue;
            if (!alive(ctx, job.owner)) {
                orphans[orphan_count] = job.*;
                orphan_count += 1;
                item.* = null;
                continue;
            }
            if (job.result != null) continue;
            if (!pool.slots[@backingInt(job.handle)].done.load(.acquire)) continue;
            const res = pool.killAndCollect(job.handle) catch {
                // The slot is already released; drop the job.
                job.deinit(pool.alloc);
                item.* = null;
                continue;
            };
            job.result = res;
            job.elapsed_ms = nowMs(io) - job.started_ms;
            const command = try pool.alloc.dupe(u8, job.command);
            errdefer pool.alloc.free(command);
            const tail = try formatLines(pool.alloc, res.stdout, res.dropped_lines, null, TAIL_LINES);
            errdefer pool.alloc.free(tail);
            try out.append(pool.alloc, .{
                .id = job.id,
                .owner = job.owner,
                .command = command,
                .exit_code = res.exit_code,
                .signal = res.signal,
                .elapsed_ms = job.elapsed_ms,
                .tail = tail,
            });
        }
    }

    fn freeIndex(self: *Jobs, alloc: std.mem.Allocator) ?usize {
        var oldest: ?usize = null;
        for (self.items, 0..) |item, i| {
            const job = item orelse return i;
            if (job.result == null) continue;
            if (oldest == null or job.id < self.items[oldest.?].?.id) oldest = i;
        }
        const i = oldest orelse return null;
        self.items[i].?.deinit(alloc);
        self.items[i] = null;
        return i;
    }
};

fn freeResult(alloc: std.mem.Allocator, res: exec.CmdResult) void {
    alloc.free(res.stdout);
    alloc.free(res.stderr);
}

/// Format output lines like `cat -n`, numbered from the job start. `dropped`
/// lines were trimmed from the front of `text`. A null `offset` returns the
/// last `limit` lines.
pub fn formatLines(alloc: std.mem.Allocator, text: []const u8, dropped: usize, offset: ?usize, limit: usize) ![]const u8 {
    var kept: usize = std.mem.count(u8, text, "\n");
    if (text.len > 0 and text[text.len - 1] != '\n') kept += 1;
    const total = dropped + kept;
    if (total == 0) return alloc.dupe(u8, "(no output yet)");

    const wanted = offset orelse (total -| limit) + 1;
    if (wanted > total) return std.fmt.allocPrint(alloc, "offset {d} is past the end ({d} lines)", .{ wanted, total });
    const first = @max(wanted, dropped + 1);
    const last = @min(total, first + limit -| 1);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.print(alloc, "[lines {d}-{d} of {d}", .{ first, last, total });
    if (wanted <= dropped) try body.print(alloc, "; lines 1-{d} were dropped by the memory cap", .{dropped});
    try body.appendSlice(alloc, "]\n");

    var lines = std.mem.splitScalar(u8, text, '\n');
    var number = dropped + 1;
    while (lines.next()) |line| : (number += 1) {
        if (number > last) break;
        if (number < first) continue;
        try body.print(alloc, "{d:>6}\t{s}\n", .{ number, line });
    }
    return alloc.dupe(u8, body.items);
}

const nowMs = util.nowMs;

const testing = std.testing;

const TestCtx = struct {
    dead: ?AgentId = null,
    fn alive(self: *const TestCtx, id: AgentId) bool {
        const dead = self.dead orelse return true;
        return dead.pack() != id.pack();
    }
};

fn waitFinished(jobs: *Jobs, pool: *exec.CmdPool, ctx: *const TestCtx, out: *std.ArrayList(Finished)) !void {
    const start_ms = nowMs(testing.io);
    while (out.items.len == 0) {
        try jobs.tick(pool, ctx, TestCtx.alive, out);
        if (nowMs(testing.io) - start_ms > 5000) return error.JobNeverFinished;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
}

fn freeFinished(out: *std.ArrayList(Finished)) void {
    for (out.items) |f| f.deinit(testing.allocator);
    out.deinit(testing.allocator);
}

test "formatLines numbers lines, pages, and reports dropped lines" {
    const alloc = testing.allocator;
    const tail = try formatLines(alloc, "c\nd\ne\n", 2, null, 2);
    defer alloc.free(tail);
    try testing.expectEqualStrings("[lines 4-5 of 5]\n     4\td\n     5\te\n", tail);

    const early = try formatLines(alloc, "c\nd\ne", 2, 1, 2);
    defer alloc.free(early);
    try testing.expectEqualStrings("[lines 3-4 of 5; lines 1-2 were dropped by the memory cap]\n     3\tc\n     4\td\n", early);

    const past = try formatLines(alloc, "a\n", 0, 3, 10);
    defer alloc.free(past);
    try testing.expectEqualStrings("offset 3 is past the end (1 lines)", past);

    const empty = try formatLines(alloc, "", 0, null, 10);
    defer alloc.free(empty);
    try testing.expectEqualStrings("(no output yet)", empty);
}

test "job merges output, reports the exit, and stays readable" {
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = exec.CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    var jobs: Jobs = .{};
    defer jobs.killAll(&pool);
    const owner: AgentId = .{ .index = 1, .generation = 0 };
    const id = try jobs.start(&pool, owner, "echo out; sleep 0.1; echo err >&2; exit 3", ".");

    var out: std.ArrayList(Finished) = .empty;
    defer freeFinished(&out);
    const ctx: TestCtx = .{};
    try waitFinished(&jobs, &pool, &ctx, &out);

    const done = out.items[0];
    try testing.expectEqual(id, done.id);
    try testing.expectEqual(@as(?u8, 3), done.exit_code);
    try testing.expectEqual(@as(u32, 0), jobs.countRunning(testing.io));
    try testing.expectEqualStrings("[lines 1-2 of 2]\n     1\tout\n     2\terr\n", done.tail);

    const page = (try jobs.read(&pool, testing.allocator, id, 2, 5)).?;
    defer testing.allocator.free(page.text);
    try testing.expect(page.state == .exited);
    try testing.expectEqualStrings("[lines 2-2 of 2]\n     2\terr\n", page.text);
    try testing.expect(try jobs.read(&pool, testing.allocator, id + 1, null, 5) == null);
}

test "running job is readable, kill stops it, orphans die with the owner" {
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = exec.CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    var jobs: Jobs = .{};
    defer jobs.killAll(&pool);
    const owner: AgentId = .{ .index = 2, .generation = 0 };
    const a = try jobs.start(&pool, owner, "echo ready; sleep 30", ".");
    const b = try jobs.start(&pool, owner, "sleep 30", ".");

    const start_ms = nowMs(testing.io);
    while (true) {
        const page = (try jobs.read(&pool, testing.allocator, a, null, 5)).?;
        defer testing.allocator.free(page.text);
        try testing.expect(page.state == .running);
        if (std.mem.indexOf(u8, page.text, "ready") != null) break;
        if (nowMs(testing.io) - start_ms > 5000) return error.NoOutput;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }

    try testing.expectEqual(@as(u32, 2), jobs.countRunning(testing.io));
    const killed = (try jobs.kill(&pool, testing.allocator, a)).?;
    defer testing.allocator.free(killed.tail);
    try testing.expectEqualStrings("[lines 1-1 of 1]\n     1\tready\n", killed.tail);
    try testing.expect(try jobs.kill(&pool, testing.allocator, a) == null);

    var out: std.ArrayList(Finished) = .empty;
    defer freeFinished(&out);
    const ctx: TestCtx = .{ .dead = owner };
    try jobs.tick(&pool, &ctx, TestCtx.alive, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(try jobs.read(&pool, testing.allocator, b, null, 5) == null);
    for (jobs.items) |item| try testing.expect(item == null);
    try testing.expect(nowMs(testing.io) - start_ms < 5000);
}
