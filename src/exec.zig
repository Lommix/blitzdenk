//! Process execution pool: fixed slots, capped output, and blocking
//! `runAndWait`/`runAndWaitTimeout` calls whose futures only the slot owner releases.
const std = @import("std");
const builtin = @import("builtin");
pub const shim = @import("exec_shim.zig");
pub const vt = @import("vt.zig");

pub const MAX_OUTPUT = 1024 * 1024;
const TRIM_SLACK = 262144;
const MAX_DRAIN_BYTES = 64 * 1024 * 1024;
const SLOT_COUNT = 64;
const TERMINATE_GRACE_MS = 500;
const DRAIN_TIMEOUT_MS = 2000;
const PROCESS_POLL_MS = 10;
const PTY_READ_CHUNK = 16 * 1024;

pub const CmdSlot = struct {
    in_use: std.atomic.Value(bool) = .init(false),
    /// Set by the fiber that claimed the slot until it finished collecting the
    /// result. Only the owner may release: joining or freeing a future another
    /// fiber is currently `await`ing is undefined behavior (panic: `await`
    /// raced with `await`).
    owned: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(std.Io.Cancelable!void) = .{ .any_future = null, .result = {} },
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    result_ty: CmdResult.ResType = .failed,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    cap: usize = MAX_OUTPUT,
    drained: usize = 0,
    /// Set for `RunOpts.background` runs. The child gets a pty and `screen`
    /// renders its output; `mu` guards the screen while the worker feeds it.
    background: bool = false,
    screen: ?*vt.Screen = null,
    /// Pty master of a running background run, or -1. Guarded by `mu`.
    pty_master: c_int = -1,
    /// Set for `RunOpts.keep_head` runs.
    keep_head: bool = false,
    mu: std.Io.Mutex = .init,
};

pub const CmdResult = struct {
    pub const ResType = enum { success, failed, timeout };
    stdout: []const u8,
    stderr: []const u8,
    ty: ResType,
    /// Present when the child terminated normally, including non-zero exits.
    /// Callers that assign meaning to a specific exit code must inspect this
    /// instead of relying on the coarser `ty` field.
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    dropped_lines: usize = 0,
};

const Pty = struct {
    const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
    const POLLIN: c_short = 0x1;
    const F_SETFD: c_int = 2;
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const FD_CLOEXEC: c_int = 1;
    const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0o4000 else 0x4;

    const c = struct {
        extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termios: ?*const anyopaque, size: ?*const std.posix.winsize) c_int;
        extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        extern "c" fn poll(fds: *PollFd, count: c_ulong, timeout: c_int) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
        extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
    };

    master: c_int,
    slave: c_int,

    fn open(cols: usize, rows: usize) !Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        const size: std.posix.winsize = .{ .row = @intCast(rows), .col = @intCast(cols), .xpixel = 0, .ypixel = 0 };
        if (c.openpty(&master, &slave, null, null, &size) != 0) return error.OpenPtyFailed;
        _ = c.fcntl(master, F_SETFD, FD_CLOEXEC);
        _ = c.fcntl(slave, F_SETFD, FD_CLOEXEC);
        _ = c.fcntl(master, F_SETFL, c.fcntl(master, F_GETFL) | O_NONBLOCK);
        return .{ .master = master, .slave = slave };
    }

    fn slaveFile(self: Pty) std.Io.File {
        return .{ .handle = self.slave, .flags = .{ .nonblocking = false } };
    }

    fn closeSlave(self: *Pty) void {
        if (self.slave < 0) return;
        _ = c.close(self.slave);
        self.slave = -1;
    }

    fn closeAll(self: *Pty) void {
        self.closeSlave();
        _ = c.close(self.master);
    }
};

pub const CmdPool = struct {
    const Self = @This();
    pub const Handle = enum(u8) { _ };

    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    slots: [SLOT_COUNT]CmdSlot = @splat(.{}),

    pub fn init(alloc: std.mem.Allocator, io: std.Io, parent_env: *const std.process.Environ.Map) Self {
        return .{ .alloc = alloc, .io = io, .env = parent_env };
    }

    pub fn deinit(self: *Self) void {
        for (&self.slots) |*slot| {
            if (!slot.in_use.load(.acquire)) continue;
            slot.future.cancel(self.io) catch {};
            slot.stdout.deinit(self.alloc);
            slot.stderr.deinit(self.alloc);
            self.destroyScreen(slot);
        }
    }

    pub const RunOpts = struct {
        cwd: ?[]const u8 = null,
        argv: []const []const u8,
        /// Spawn the child in a new process group and kill that group during
        /// cleanup. Useful for tools such as Chromium that may leave helpers
        /// holding stdout/stderr pipes open after the main process is killed.
        kill_process_group: bool = false,
        scrub_env: bool = false,
        /// Variables set on top of the inherited (or scrubbed) environment.
        extra_env: []const [2][]const u8 = &.{},
        max_output: ?usize = null,
        /// Long-lived run on a pty: stdout and stderr merge, and a terminal
        /// emulator renders them. Scrollback is trimmed to `max_output` at line
        /// starts, with no drain ceiling. Read it while running with
        /// `readOutput`.
        background: bool = false,
        /// Keep the first `max_output` stdout bytes instead of the last, and
        /// stop the child once they are captured.
        keep_head: bool = false,
    };

    pub fn runWithOpts(self: *Self, opts: RunOpts) !Handle {
        const idx = for (&self.slots, 0..) |*slot, i| {
            if (slot.in_use.cmpxchgStrong(false, true, .acquire, .monotonic) == null) break i;
        } else return error.PoolExhausted;

        const slot = &self.slots[idx];
        slot.owned.store(true, .release);
        slot.stdout = .empty;
        slot.stderr = .empty;
        slot.done.store(false, .release);
        slot.result_ty = .failed;
        slot.exit_code = null;
        slot.signal = null;
        slot.stdout_truncated = false;
        slot.stderr_truncated = false;
        slot.cap = @max(opts.max_output orelse MAX_OUTPUT, 1);
        slot.drained = 0;
        slot.background = opts.background;
        slot.keep_head = opts.keep_head;
        errdefer {
            slot.owned.store(false, .release);
            slot.in_use.store(false, .release);
        }

        slot.screen = if (opts.background) try self.createScreen(slot.cap) else null;
        errdefer self.destroyScreen(slot);

        var final_argv: ?[]const []const u8 = try self.dupeArgv(opts.argv);
        errdefer if (final_argv) |a| self.freeArgv(a);

        const duped_cwd = if (opts.cwd) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (duped_cwd) |c| self.alloc.free(c);

        const env_box = try self.buildEnvBox(opts);
        errdefer if (env_box) |b| {
            b.deinit();
            self.alloc.destroy(b);
        };

        const spawned_argv = if (builtin.os.tag == .linux) blk: {
            const out = try self.wrapExecShim(final_argv.?);
            final_argv = null;
            break :blk out;
        } else final_argv.?;

        slot.future = std.Io.async(self.io, workerFn, .{ self, slot, spawned_argv, duped_cwd, env_box, opts.kill_process_group });

        return @fromBackingInt(@intCast(idx));
    }

    fn buildEnvBox(self: *Self, opts: RunOpts) !?*std.process.Environ.Map {
        if (!opts.scrub_env and opts.extra_env.len == 0) return null;

        const box = try self.alloc.create(std.process.Environ.Map);
        errdefer self.alloc.destroy(box);
        box.* = .init(self.alloc);
        errdefer box.deinit();

        const keys = self.env.keys();
        const vals = self.env.values();
        for (keys, vals) |k, v| {
            if (opts.scrub_env and stripEnvKey(k)) continue;
            try box.put(k, v);
        }
        for (opts.extra_env) |pair| try box.put(pair[0], pair[1]);
        return box;
    }

    fn stripEnvKey(key: []const u8) bool {
        return std.ascii.eqlIgnoreCase(key, "LD_PRELOAD") or
            std.ascii.eqlIgnoreCase(key, "LD_LIBRARY_PATH") or
            std.ascii.eqlIgnoreCase(key, "LD_AUDIT") or
            std.ascii.startsWithIgnoreCase(key, "DYLD_") or
            std.ascii.findIgnoreCase(key, "API") != null or
            std.ascii.findIgnoreCase(key, "AI") != null or
            std.ascii.findIgnoreCase(key, "KEY") != null or
            std.ascii.findIgnoreCase(key, "TOKEN") != null;
    }

    /// Release a slot owned by the caller (the `runAndWait`/`Handle` holder).
    /// Must not be called by anyone else: joining or freeing a future another
    /// fiber is currently `await`ing is undefined behavior (panic: `await`
    /// raced with `await`). Owners release exactly once, when done.
    pub fn release(self: *Self, handle: Handle) void {
        const slot = &self.slots[@backingInt(handle)];
        if (!slot.in_use.load(.acquire)) return;
        if (!slot.owned.swap(false, .acq_rel)) return;

        if (slot.done.load(.acquire)) {
            slot.future.await(self.io) catch {};
        } else {
            slot.future.cancel(self.io) catch {};
        }

        slot.stdout.deinit(self.alloc);
        slot.stderr.deinit(self.alloc);
        slot.stdout = .empty;
        slot.stderr = .empty;
        self.destroyScreen(slot);
        slot.in_use.store(false, .release);
    }

    pub fn cancel(self: *Self, handle: Handle) void {
        self.release(handle);
    }

    /// Owned copy of a rendered terminal. Free `text` with the pool allocator.
    pub const Output = struct {
        text: []u8,
        dropped_lines: usize,
    };

    /// Render a background run's terminal: scrollback plus the visible screen.
    pub fn readOutput(self: *Self, handle: Handle, alloc: std.mem.Allocator) !Output {
        const slot = &self.slots[@backingInt(handle)];
        const screen = slot.screen orelse return error.NotBackground;
        slot.mu.lockUncancelable(self.io);
        defer slot.mu.unlock(self.io);
        const snap = try screen.snapshot(alloc);
        return .{ .text = snap.text, .dropped_lines = snap.dropped_lines };
    }

    /// Cancels a running worker and returns its partial output. Buffers are
    /// stable before reading: the worker is joined (cancelled first when
    /// still running) before duping.
    pub fn killAndCollect(self: *Self, handle: Handle) !CmdResult {
        const slot = &self.slots[@backingInt(handle)];
        const timed_out = !slot.done.load(.acquire);
        errdefer self.release(handle);
        if (timed_out) slot.future.cancel(self.io) catch {};
        slot.future.await(self.io) catch {};
        var dropped_lines: usize = 0;
        const out = if (slot.screen) |screen| blk: {
            const snap = try screen.snapshot(self.alloc);
            dropped_lines = snap.dropped_lines;
            slot.stdout_truncated = dropped_lines > 0;
            break :blk snap.text;
        } else blk: {
            trimToTail(&slot.stdout, slot.cap, slot.cap, &slot.stdout_truncated);
            break :blk try self.alloc.dupe(u8, slot.stdout.items);
        };
        errdefer self.alloc.free(out);
        trimToTail(&slot.stderr, slot.cap, slot.cap, &slot.stderr_truncated);
        const err = try self.alloc.dupe(u8, slot.stderr.items);
        const ty = if (timed_out) CmdResult.ResType.timeout else slot.result_ty;
        const exit_code = slot.exit_code;
        const signal = slot.signal;
        const stdout_truncated = slot.stdout_truncated;
        const stderr_truncated = slot.stderr_truncated;
        self.release(handle);
        return .{ .stdout = out, .stderr = err, .ty = ty, .exit_code = exit_code, .signal = signal, .stdout_truncated = stdout_truncated, .stderr_truncated = stderr_truncated, .dropped_lines = dropped_lines };
    }

    // -----------------

    fn workerFn(
        self: *Self,
        slot: *CmdSlot,
        argv: []const []const u8,
        cwd: ?[]const u8,
        env_box: ?*std.process.Environ.Map,
        kill_process_group: bool,
    ) std.Io.Cancelable!void {
        defer self.freeArgv(argv);
        defer if (cwd) |c| self.alloc.free(c);
        defer if (env_box) |b| {
            b.deinit();
            self.alloc.destroy(b);
        };
        defer slot.done.store(true, .release);

        var pty: ?Pty = if (slot.background) Pty.open(slot.screen.?.cols, slot.screen.?.rows) catch {
            slot.result_ty = .failed;
            return;
        } else null;
        defer if (pty) |*p| self.closePty(slot, p);
        if (pty) |p| self.setPtyMaster(slot, p.master);

        const output_io: std.process.SpawnOptions.StdIo = if (pty) |p| .{ .file = p.slaveFile() } else .pipe;
        const input_io: std.process.SpawnOptions.StdIo = if (pty != null) output_io else .ignore;
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .stdin = input_io,
            .stdout = output_io,
            .stderr = output_io,
            .environ_map = if (env_box) |b| b else null,
            .pgid = if (kill_process_group and builtin.os.tag != .linux) 0 else null,
        }) catch {
            slot.result_ty = .failed;
            slot.exit_code = null;
            slot.signal = null;
            return;
        };
        if (pty) |*p| p.closeSlave();
        defer if (child.id) |pid| {
            self.terminateProcess(pid, kill_process_group);
            child.kill(self.io);
        };

        const term = (if (pty) |*p| self.collectPty(slot, &child, p, kill_process_group) else self.collectOutput(slot, &child, kill_process_group)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                slot.result_ty = .failed;
                slot.exit_code = null;
                slot.signal = null;
                return;
            },
        };
        switch (term) {
            .exited => |code| {
                slot.exit_code = code;
                slot.result_ty = if (code == 0) .success else .failed;
            },
            .signal => |sig| {
                slot.signal = @backingInt(sig);
                slot.exit_code = null;
                slot.result_ty = .failed;
            },
            else => {
                slot.exit_code = null;
                slot.result_ty = .failed;
            },
        }
    }

    const CollectError = std.Io.Cancelable ||
        std.Io.File.MultiReader.UnendingError ||
        std.Io.Batch.AwaitConcurrentError ||
        std.process.Child.WaitError ||
        std.mem.Allocator.Error;

    fn collectOutput(
        self: *Self,
        slot: *CmdSlot,
        child: *std.process.Child,
        kill_process_group: bool,
    ) CollectError!std.process.Child.Term {
        try self.drainOutput(slot, child, kill_process_group);
        return child.wait(self.io);
    }

    fn collectPty(
        self: *Self,
        slot: *CmdSlot,
        child: *std.process.Child,
        pty: *Pty,
        kill_process_group: bool,
    ) CollectError!std.process.Child.Term {
        try self.drainPty(slot, child, pty, kill_process_group);
        return child.wait(self.io);
    }

    fn drainPty(self: *Self, slot: *CmdSlot, child: *std.process.Child, pty: *Pty, kill_process_group: bool) CollectError!void {
        var chunk: [PTY_READ_CHUNK]u8 = undefined;
        var drain_start: ?i64 = null;
        while (true) {
            try self.io.checkCancel();
            if (drain_start == null and leaderExited(child.id.?)) drain_start = nowMs(self.io);
            if (drain_start) |start| if (nowMs(self.io) - start >= DRAIN_TIMEOUT_MS) {
                self.terminateProcess(child.id.?, kill_process_group);
                while (self.pumpPty(slot, pty, &chunk, 0) == .data) {}
                return;
            };
            if (self.pumpPty(slot, pty, &chunk, PROCESS_POLL_MS) == .closed) return;
        }
    }

    const Pump = enum { idle, data, closed };

    /// Move what the pty master has ready into the screen, then answer any
    /// terminal queries the child sent.
    fn pumpPty(self: *Self, slot: *CmdSlot, pty: *Pty, chunk: []u8, timeout_ms: c_int) Pump {
        var poll_fd: Pty.PollFd = .{ .fd = pty.master, .events = Pty.POLLIN, .revents = 0 };
        if (Pty.c.poll(@ptrCast(&poll_fd), 1, timeout_ms) <= 0) return .idle;
        const count = Pty.c.read(pty.master, chunk.ptr, chunk.len);
        if (count == 0) return .closed;
        if (count < 0) return if (std.posix.errno(count) == .INTR or std.posix.errno(count) == .AGAIN) .idle else .closed;

        const screen = slot.screen.?;
        var reply_buf: [vt.MAX_REPLY]u8 = undefined;
        var reply_len: usize = 0;
        {
            slot.mu.lockUncancelable(self.io);
            defer slot.mu.unlock(self.io);
            screen.feed(chunk[0..@intCast(count)]);
            reply_len = screen.replies().len;
            @memcpy(reply_buf[0..reply_len], screen.replies());
            screen.clearReplies();
        }
        if (reply_len > 0) _ = Pty.c.write(pty.master, &reply_buf, reply_len);
        return .data;
    }

    fn setPtyMaster(self: *Self, slot: *CmdSlot, master: c_int) void {
        slot.mu.lockUncancelable(self.io);
        defer slot.mu.unlock(self.io);
        slot.pty_master = master;
    }

    fn closePty(self: *Self, slot: *CmdSlot, pty: *Pty) void {
        self.setPtyMaster(slot, -1);
        pty.closeAll();
    }

    /// Send keystrokes to a running background run. Returns how many bytes the
    /// terminal accepted; fewer than `bytes.len` means its input buffer is full.
    pub fn writeInput(self: *Self, handle: Handle, bytes: []const u8) !usize {
        const slot = &self.slots[@backingInt(handle)];
        slot.mu.lockUncancelable(self.io);
        defer slot.mu.unlock(self.io);
        if (slot.pty_master < 0) return error.NotRunning;
        var written: usize = 0;
        while (written < bytes.len) {
            const count = Pty.c.write(slot.pty_master, bytes[written..].ptr, bytes.len - written);
            if (count > 0) {
                written += @intCast(count);
                continue;
            }
            switch (std.posix.errno(count)) {
                .INTR => continue,
                .AGAIN => break,
                else => return error.WriteFailed,
            }
        }
        return written;
    }

    fn createScreen(self: *Self, history_cap: usize) !*vt.Screen {
        const screen = try self.alloc.create(vt.Screen);
        errdefer self.alloc.destroy(screen);
        screen.* = try vt.Screen.init(self.alloc, vt.DEFAULT_COLS, vt.DEFAULT_ROWS, history_cap);
        return screen;
    }

    fn destroyScreen(self: *Self, slot: *CmdSlot) void {
        const screen = slot.screen orelse return;
        screen.deinit();
        self.alloc.destroy(screen);
        slot.screen = null;
    }

    fn drainOutput(self: *Self, slot: *CmdSlot, child: *std.process.Child, kill_process_group: bool) CollectError!void {
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(self.alloc, self.io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();

        const stdout_reader = mr.reader(0);
        const stderr_reader = mr.reader(1);

        var drain_start: ?i64 = null;
        var ceiling_hit = false;
        while (true) {
            if (drain_start == null and leaderExited(child.id.?)) drain_start = nowMs(self.io);
            if (drain_start) |start| if (nowMs(self.io) - start >= DRAIN_TIMEOUT_MS) {
                if (!ceiling_hit) self.terminateProcess(child.id.?, kill_process_group);
                try self.appendBuffered(slot, stdout_reader, stderr_reader);
                return;
            };
            mr.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(PROCESS_POLL_MS), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.EndOfStream => break,
                else => |e| return e,
            };
            try self.appendBuffered(slot, stdout_reader, stderr_reader);
            const ceiling = @max(MAX_DRAIN_BYTES, slot.cap *| 2);
            const head_full = slot.keep_head and slot.stdout_truncated;
            if (!ceiling_hit and (slot.drained > ceiling or head_full)) {
                ceiling_hit = true;
                self.terminateProcess(child.id.?, kill_process_group);
            }
        }

        try mr.checkAnyError();
    }

    fn leaderExited(pid: std.process.Child.Id) bool {
        if (builtin.os.tag != .linux) return false;
        const linux = std.os.linux;
        var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        return linux.errno(rc) == .SUCCESS and info.fields.common.first.piduid.pid == pid;
    }

    fn terminateProcess(self: *Self, pid: std.process.Child.Id, kill_process_group: bool) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        if (kill_process_group) std.posix.kill(-pid, std.posix.SIG.TERM) catch {};
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        const start = nowMs(self.io);
        while (nowMs(self.io) - start < TERMINATE_GRACE_MS) {
            if (!kill_process_group and leaderExited(pid)) break;
            std.Io.sleep(self.io, .fromMilliseconds(PROCESS_POLL_MS), .awake) catch {};
        }
        if (kill_process_group) std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    }

    /// Moves all currently-buffered bytes out of the multi-reader and into the
    /// slot's stdout/stderr lists under the slot lock.
    fn appendBuffered(
        self: *Self,
        slot: *CmdSlot,
        stdout_reader: *std.Io.Reader,
        stderr_reader: *std.Io.Reader,
    ) !void {
        const out = stdout_reader.buffered();
        const err = stderr_reader.buffered();
        stdout_reader.toss(out.len);
        stderr_reader.toss(err.len);

        if (slot.keep_head) {
            const room = slot.cap -| slot.stdout.items.len;
            try slot.stdout.appendSlice(self.alloc, out[0..@min(out.len, room)]);
            if (out.len > room) slot.stdout_truncated = true;
        } else {
            try slot.stdout.appendSlice(self.alloc, out);
            trimToTail(&slot.stdout, slot.cap, slot.cap + TRIM_SLACK, &slot.stdout_truncated);
        }
        try slot.stderr.appendSlice(self.alloc, err);
        slot.drained += out.len + err.len;

        trimToTail(&slot.stderr, slot.cap, slot.cap + TRIM_SLACK, &slot.stderr_truncated);
    }

    fn trimToTail(list: *std.ArrayList(u8), keep: usize, threshold: usize, truncated: *bool) void {
        if (keep > threshold or list.items.len <= threshold) return;
        var drop = list.items.len - keep;
        while (drop < list.items.len and (list.items[drop] & 0xC0) == 0x80) drop += 1;
        if (drop == list.items.len) drop = list.items.len - keep;
        const n = list.items.len - drop;
        std.mem.copyForwards(u8, list.items[0..n], list.items[drop..]);
        list.items.len = n;
        truncated.* = true;
    }

    fn dupeArgv(self: *Self, argv: []const []const u8) ![]const []const u8 {
        const out = try self.alloc.alloc([]const u8, argv.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |s| self.alloc.free(s);
            self.alloc.free(out);
        }
        while (i < argv.len) : (i += 1) {
            out[i] = try self.alloc.dupe(u8, argv[i]);
        }
        return out;
    }

    fn freeArgv(self: *Self, argv: []const []const u8) void {
        for (argv) |s| self.alloc.free(s);
        self.alloc.free(argv);
    }

    fn wrapExecShim(self: *Self, argv: []const []const u8) ![]const []const u8 {
        const wrapped = try self.alloc.alloc([]const u8, argv.len + 3);
        errdefer self.alloc.free(wrapped);
        wrapped[0] = if (builtin.is_test) blk: {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try std.Io.Dir.cwd().realPathFile(self.io, @import("exec_options").test_shim_path, &path_buf);
            break :blk try self.alloc.dupe(u8, path_buf[0..len]);
        } else try self.alloc.dupe(u8, "/proc/self/exe");
        errdefer self.alloc.free(wrapped[0]);
        wrapped[1] = try self.alloc.dupe(u8, shim.flag);
        errdefer self.alloc.free(wrapped[1]);
        wrapped[2] = try std.fmt.allocPrint(self.alloc, "{d}", .{std.c.getpid()});
        for (argv, 3..) |a, i| wrapped[i] = a;
        self.alloc.free(argv);
        return wrapped;
    }

    /// Run synchronously: spawn, await, copy result into caller-owned buffers.
    /// Caller frees stdout/stderr.
    pub fn runAndWait(self: *Self, opts: RunOpts) !CmdResult {
        const handle = try self.runWithOpts(opts);
        const slot = &self.slots[@backingInt(handle)];
        slot.future.await(self.io) catch {};
        return self.killAndCollect(handle);
    }

    /// Run synchronously with a wall-clock deadline. On timeout, cancels the
    /// worker and returns its partial output with `.timeout`.
    pub fn runAndWaitTimeout(self: *Self, opts: RunOpts, timeout_ms: i64) !CmdResult {
        const handle = try self.runWithOpts(opts);
        const slot = &self.slots[@backingInt(handle)];
        const start_ms = nowMs(self.io);
        var polls: usize = 0;

        while (true) {
            if (slot.done.load(.acquire)) {
                return self.killAndCollect(handle);
            }

            if (nowMs(self.io) - start_ms > timeout_ms) {
                return self.killAndCollect(handle);
            }

            const sleep_us: i64 = @min(@as(i64, 100) << @min(polls, 8), 5_000);
            polls += 1;
            std.Io.sleep(self.io, std.Io.Duration.fromMicroseconds(sleep_us), .real) catch {
                self.cancel(handle);
                return error.Canceled;
            };
        }
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
}

test "scrubbed environments exclude credentials and loader variables without changing the parent" {
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const stripped = [_][]const u8{ "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "OPENAI_API_KEY", "GITHUB_TOKEN", "mixed_api_key_value", "access_token" };
    for (stripped) |key| try env.put(key, "secret");
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/tmp");
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const box = (try pool.buildEnvBox(.{ .argv = &.{"env"}, .scrub_env = true })).?;
    defer testing.allocator.destroy(box);
    defer box.deinit();
    for (stripped) |key| {
        try testing.expect(!box.contains(key));
        try testing.expectEqualStrings("secret", env.get(key).?);
    }
    try testing.expectEqualStrings("/usr/bin:/bin", box.get("PATH").?);
    try testing.expectEqualStrings("/tmp", box.get("HOME").?);
    try testing.expectEqual(null, try pool.buildEnvBox(.{ .argv = &.{"env"} }));
}

test "scrubbing reaches spawned children" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("BLITZ_TEST_API_KEY", "secret");
    try env.put("BLITZ_TEST_TOKEN", "secret");
    try env.put("DYLD_TEST", "secret");
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{"/usr/bin/env"},
        .scrub_env = true,
    }, 2000);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(.success, res.ty);
    try testing.expectEqualStrings("PATH=/usr/bin:/bin\n", res.stdout);
}

test "timeout and cancellation kill the command process group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);

    for ([_]bool{ false, true }) |cancel| {
        const handle = try pool.runWithOpts(.{
            .cwd = cwd,
            .argv = &.{ "/bin/sh", "-c", "sleep 300 & printf '%s' \"$!\" > child; printf 'ready\\n'; wait" },
            .kill_process_group = true,
        });
        defer pool.release(handle);
        var pid: ?std.posix.pid_t = null;
        const start = nowMs(testing.io);
        while (nowMs(testing.io) - start < 2000) {
            if (tmp.dir.readFileAlloc(testing.io, "child", testing.allocator, .limited(32))) |data| {
                defer testing.allocator.free(data);
                pid = std.fmt.parseInt(std.posix.pid_t, data, 10) catch null;
                if (pid != null) break;
            } else |err| if (err != error.FileNotFound) return err;
            try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
        }
        const child_pid = pid orelse return error.ChildNotReady;
        defer std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
        if (cancel) {
            pool.cancel(handle);
        } else {
            const res = try pool.killAndCollect(handle);
            defer testing.allocator.free(res.stdout);
            defer testing.allocator.free(res.stderr);
            try testing.expectEqual(.timeout, res.ty);
        }

        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{child_pid});
        const stopped = nowMs(testing.io);
        while (true) {
            const status = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096)) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            defer testing.allocator.free(status);
            if (std.mem.indexOf(u8, status, "State:\tZ") != null or std.mem.indexOf(u8, status, "State:\tX") != null) break;
            if (nowMs(testing.io) - stopped > 1000) return error.ChildSurvived;
            try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
        }
        try tmp.dir.deleteFile(testing.io, "child");
    }
}

const ProcessTestFixture = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    cwd: [:0]const u8,
    pool: CmdPool,

    fn init(self: *ProcessTestFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.cwd = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(self.cwd);
        self.env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
        self.pool = CmdPool.init(std.testing.allocator, std.testing.io, &self.env);
    }

    fn deinit(self: *ProcessTestFixture) void {
        self.pool.deinit();
        self.env.deinit();
        std.testing.allocator.free(self.cwd);
        self.tmp.cleanup();
    }

    fn launch(self: *ProcessTestFixture, command: []const u8) !CmdPool.Handle {
        return self.pool.runWithOpts(.{
            .cwd = self.cwd,
            .argv = &.{ "/bin/sh", "-c", command },
            .kill_process_group = true,
            .scrub_env = true,
        });
    }

    fn run(self: *ProcessTestFixture, command: []const u8, timeout_ms: i64) !CmdResult {
        return self.runCapped(command, timeout_ms, null);
    }

    fn runCapped(self: *ProcessTestFixture, command: []const u8, timeout_ms: i64, max_output: ?usize) !CmdResult {
        return self.pool.runAndWaitTimeout(.{
            .cwd = self.cwd,
            .argv = &.{ "/bin/sh", "-c", command },
            .kill_process_group = true,
            .scrub_env = true,
            .max_output = max_output,
        }, timeout_ms);
    }

    fn waitFile(self: *ProcessTestFixture, name: []const u8) ![]u8 {
        const start = nowMs(std.testing.io);
        while (nowMs(std.testing.io) - start < 3000) {
            const data = self.tmp.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024)) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
                    continue;
                },
                else => return err,
            };
            if (data.len > 0) return data;
            std.testing.allocator.free(data);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        }
        return error.ChildNotReady;
    }
};

fn expectProcessStopped(pid: std.posix.pid_t) !void {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/status", .{pid});
    const start = nowMs(std.testing.io);
    while (true) {
        const status = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer std.testing.allocator.free(status);
        if (std.mem.indexOf(u8, status, "State:\tZ") != null or std.mem.indexOf(u8, status, "State:\tX") != null) return;
        if (nowMs(std.testing.io) - start > 1500) return error.ChildSurvived;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
}

test "exec shim ignores PATH setsid and preserves command exit status" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("PATH", f.cwd);
    const poisoned = try f.tmp.dir.createFile(std.testing.io, "setsid", .{ .permissions = .executable_file });
    poisoned.close(std.testing.io);
    const result = try f.run("printf output; printf diagnostic >&2; exit 7", 3000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqualStrings("output", result.stdout);
    try std.testing.expectEqualStrings("diagnostic", result.stderr);
    try std.testing.expectEqual(.failed, result.ty);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
}

test "exec shim kills its command when the spawning parent dies" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const wrapped = try f.pool.wrapExecShim(try f.pool.dupeArgv(&.{"/bin/true"}));
    defer f.pool.freeArgv(wrapped);
    var parent = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "\"$1\" \"$2\" \"$$\" /bin/sh -c 'printf \"%s\" \"$$\" > child; exec /bin/sleep 300' & wait", "parent", wrapped[0], shim.flag },
        .cwd = .{ .path = f.cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer parent.kill(std.testing.io);
    const data = try f.waitFile("child");
    defer std.testing.allocator.free(data);
    const pid = try std.fmt.parseInt(std.posix.pid_t, data, 10);
    defer std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    try std.posix.kill(parent.id.?, std.posix.SIG.KILL);
    _ = try parent.wait(std.testing.io);
    try expectProcessStopped(pid);
}

test "exec shim rejects a changed parent before executing the command" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const wrapped = try f.pool.wrapExecShim(try f.pool.dupeArgv(&.{"/bin/true"}));
    defer f.pool.freeArgv(wrapped);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ wrapped[0], shim.flag, "2147483647", "/bin/true" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);
    const term = try child.wait(std.testing.io);
    try std.testing.expectEqual(@as(u8, 126), term.exited);
}

test "cancellation allows TERM cleanup and escalates for TERM resistant children" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]bool{ false, true }) |ignore_term| {
        const command = if (ignore_term)
            "trap '' TERM; printf '%s' \"$$\" > marker; exec /bin/sleep 300"
        else
            "trap 'rm -f marker; exit 0' TERM; printf '%s' \"$$\" > marker; while :; do sleep 1; done";
        const handle = try f.launch(command);
        defer f.pool.release(handle);
        const data = try f.waitFile("marker");
        defer std.testing.allocator.free(data);
        const pid = try std.fmt.parseInt(std.posix.pid_t, data, 10);
        defer std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        const start = nowMs(std.testing.io);
        f.pool.cancel(handle);
        try std.testing.expect(nowMs(std.testing.io) - start < 2000);
        try expectProcessStopped(pid);
        if (ignore_term) {
            try f.tmp.dir.deleteFile(std.testing.io, "marker");
        } else {
            try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "marker", .{}));
        }
    }
}

test "leader exit bounds pipe draining and preserves partial output and exit status" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const start = nowMs(std.testing.io);
    const result = try f.run("sleep 300 & printf '%s' \"$!\" > child; printf partial; printf diagnostic >&2; exit 7", 10000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const data = try f.waitFile("child");
    defer std.testing.allocator.free(data);
    const pid = try std.fmt.parseInt(std.posix.pid_t, data, 10);
    defer std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    try std.testing.expect(nowMs(std.testing.io) - start < 6000);
    try std.testing.expectEqual(.failed, result.ty);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expectEqualStrings("partial", result.stdout);
    try std.testing.expectEqualStrings("diagnostic", result.stderr);
    try expectProcessStopped(pid);
}

test "output beyond the cap keeps the tail and marks truncation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const big = try f.run("seq 1 500000", 10000);
    defer std.testing.allocator.free(big.stdout);
    defer std.testing.allocator.free(big.stderr);
    try std.testing.expect(std.mem.indexOf(u8, big.stdout, "500000") != null);
    try std.testing.expect(big.stdout_truncated);
    try std.testing.expect(!big.stderr_truncated);
    const small = try f.run("printf ok", 3000);
    defer std.testing.allocator.free(small.stdout);
    defer std.testing.allocator.free(small.stderr);
    try std.testing.expect(!small.stdout_truncated);
    try std.testing.expect(!small.stderr_truncated);
    const capped = try f.runCapped("seq 1 500000", 10000, 64 * 1024);
    defer std.testing.allocator.free(capped.stdout);
    defer std.testing.allocator.free(capped.stderr);
    try std.testing.expect(std.mem.indexOf(u8, capped.stdout, "500000") != null);
    try std.testing.expect(capped.stdout.len <= 64 * 1024);
    try std.testing.expect(capped.stdout_truncated);
    try std.testing.expect(!capped.stderr_truncated);
}

test "keep_head keeps the first bytes and stops the child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const start = nowMs(std.testing.io);
    const res = try f.pool.runAndWaitTimeout(.{
        .cwd = f.cwd,
        .argv = &.{ "/bin/sh", "-c", "yes" },
        .max_output = 16,
        .keep_head = true,
    }, 10000);
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try std.testing.expect(nowMs(std.testing.io) - start < 5000);
    try std.testing.expectEqualStrings("y\ny\ny\ny\ny\ny\ny\ny\n", res.stdout);
    try std.testing.expect(res.stdout_truncated);
}
