//! Process execution pool. Spawns each command as a `std.Io.async` worker.
//!
//! API surface:
//! - `runAndWait` blocks the caller until the command exits. Used by foreground
//!   tools that trust the child to exit.
//! - `runAndWaitTimeout` is the same synchronous surface with a wall-clock
//!   deadline. Used by foreground tools that spawn potentially hanging children.
//! - `release`/`cancel`/`cancelAll` release or cancel a worker future.
const std = @import("std");
const builtin = @import("builtin");

const MAX_OUTPUT = 4 * 1024 * 1024;
const SLOT_COUNT = 64;

pub const CmdSlot = struct {
    in_use: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(std.Io.Cancelable!void) = .{ .any_future = null, .result = {} },
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    result_ty: CmdResult.ResType = .failed,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
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

    pub fn toOwned(self: *const CmdResult, alloc: std.mem.Allocator) ![]const u8 {
        var response = try alloc.alloc(u8, self.stderr.len + self.stdout.len);
        @memcpy(response[0..self.stdout.len], self.stdout);
        @memcpy(response[self.stdout.len..], self.stderr);
        return response;
    }
};

pub const SshTarget = struct {
    user: []const u8,
    host: []const u8,
    cwd: []const u8,
};

pub const CmdPool = struct {
    const Self = @This();
    pub const Handle = enum(u8) { _ };

    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    slots: [SLOT_COUNT]CmdSlot = @splat(.{}),
    ssh_target: ?SshTarget = null,
    ssh_active: bool = false,
    agent_pid: ?std.posix.pid_t = null,
    agent_sock: ?[]const u8 = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, parent_env: *const std.process.Environ.Map) Self {
        return .{ .alloc = alloc, .io = io, .env = parent_env };
    }

    pub fn deinit(self: *Self) void {
        for (&self.slots) |*slot| {
            if (!slot.in_use.load(.acquire)) continue;
            slot.future.cancel(self.io) catch {};
            slot.stdout.deinit(self.alloc);
            slot.stderr.deinit(self.alloc);
        }
        self.clearSsh();
        self.killAgent();
    }

    pub fn setSsh(self: *Self, user: []const u8, host: []const u8, cwd: []const u8) !void {
        const u = try self.alloc.dupe(u8, user);
        errdefer self.alloc.free(u);
        const h = try self.alloc.dupe(u8, host);
        errdefer self.alloc.free(h);
        const c = try self.alloc.dupe(u8, cwd);
        errdefer self.alloc.free(c);
        self.clearSsh();
        self.ssh_target = .{ .user = u, .host = h, .cwd = c };
        self.ssh_active = true;
    }

    pub fn clearSsh(self: *Self) void {
        if (self.ssh_target) |t| {
            self.alloc.free(t.user);
            self.alloc.free(t.host);
            self.alloc.free(t.cwd);
        }
        self.ssh_target = null;
        self.ssh_active = false;
    }

    /// Returns a usable SSH_AUTH_SOCK path. If `inherited_sock` already points
    /// at a live socket, returns it untouched. Otherwise spawns `ssh-agent -s`
    /// and records pid + socket on self. Subsequent runWithOpts() calls
    /// transparently inject this socket into spawned-child env. Caller must
    /// NOT free the slice.
    pub fn ensureAgent(self: *Self, inherited_sock: ?[]const u8) ![]const u8 {
        if (inherited_sock) |s| if (s.len > 0 and socketUsable(s)) return s;

        if (self.agent_sock) |s| if (socketUsable(s)) return s;
        // Stale own-agent: drop it before spawning a replacement.
        self.killAgent();

        const res = try self.runAndWait(.{
            .argv = &.{ "ssh-agent", "-s" },
            .force_local = true,
            .skip_agent_overlay = true,
        });
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);

        if (res.ty != .success) return error.AgentSpawnFailed;

        const parsed = parseAgentOutput(res.stdout) orelse return error.AgentParseFailed;
        const sock_owned = try self.alloc.dupe(u8, parsed.sock);
        self.agent_sock = sock_owned;
        self.agent_pid = parsed.pid;
        return sock_owned;
    }

    pub fn killAgent(self: *Self) void {
        if (self.agent_pid) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
        if (self.agent_sock) |s| self.alloc.free(s);
        self.agent_pid = null;
        self.agent_sock = null;
    }

    fn socketUsable(path: []const u8) bool {
        if (path.len == 0 or path.len >= std.fs.max_path_bytes) return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        return std.c.access(z, std.c.F_OK) == 0;
    }

    /// Parses ssh-agent -s output. Format (stable across openssh versions):
    ///   SSH_AUTH_SOCK=/tmp/ssh-XXXX/agent.PID; export SSH_AUTH_SOCK;
    ///   SSH_AGENT_PID=12345; export SSH_AGENT_PID;
    ///   echo Agent pid 12345;
    fn parseAgentOutput(out: []const u8) ?struct { sock: []const u8, pid: std.posix.pid_t } {
        var sock: ?[]const u8 = null;
        var pid: ?std.posix.pid_t = null;

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const semi = std.mem.indexOfScalarPos(u8, line, eq + 1, ';') orelse continue;
            const key = line[0..eq];
            const val = line[eq + 1 .. semi];
            if (std.mem.eql(u8, key, "SSH_AUTH_SOCK")) {
                sock = val;
            } else if (std.mem.eql(u8, key, "SSH_AGENT_PID")) {
                pid = std.fmt.parseInt(std.posix.pid_t, val, 10) catch null;
            }
        }

        if (sock == null or pid == null) return null;
        return .{ .sock = sock.?, .pid = pid.? };
    }

    /// Returns the SSH target cwd when SSH is currently routing tool calls
    /// remotely; otherwise returns the caller's local fallback. Centralizes
    /// the routing predicate so callers (agent.zig) stay in one line.
    pub fn effectiveCwd(self: *const Self, fallback: []const u8) []const u8 {
        if (self.ssh_active) if (self.ssh_target) |t| return t.cwd;
        return fallback;
    }

    pub const RunOpts = struct {
        cwd: ?[]const u8 = null,
        argv: []const []const u8,
        stdin_data: ?[]const u8 = null,
        /// When set, the SSH-mode argv rewrite is skipped and these env vars
        /// are passed verbatim to the spawned child (parent env is NOT inherited).
        /// Used for ssh-add unlock so passphrase env doesn't appear in argv.
        env_overlay: ?std.process.Environ.Map = null,
        /// When true, do not route through SSH even when ssh_target+ssh_active.
        /// Used for the local SSH probe + ssh-add itself.
        force_local: bool = false,
        /// Spawn the child in a new process group and kill that group during
        /// cleanup. Useful for tools such as Chromium that may leave helpers
        /// holding stdout/stderr pipes open after the main process is killed.
        kill_process_group: bool = false,
        /// When true, skip the implicit SSH_AUTH_SOCK overlay even if we own
        /// an ssh-agent. Used when spawning the ssh-agent itself to avoid
        /// pointing the new agent at its own (not-yet-existing) socket.
        skip_agent_overlay: bool = false,
    };

    pub fn runWithOpts(self: *Self, opts: RunOpts) !Handle {
        const idx = for (&self.slots, 0..) |*slot, i| {
            if (slot.in_use.cmpxchgStrong(false, true, .acquire, .monotonic) == null) break i;
        } else return error.PoolExhausted;

        const slot = &self.slots[idx];
        slot.stdout = .empty;
        slot.stderr = .empty;
        slot.done.store(false, .release);
        slot.result_ty = .failed;
        slot.exit_code = null;
        slot.signal = null;

        var final_argv: ?[]const []const u8 = try self.maybeWrapSsh(opts.argv, opts.force_local);
        errdefer if (final_argv) |a| self.freeArgv(a);

        // When SSH-wrapped, the parent cwd must not constrain ssh's own resolution.
        const effective_cwd: ?[]const u8 = if (self.shouldRouteSsh(opts.force_local)) null else opts.cwd;

        const duped_cwd = if (effective_cwd) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (duped_cwd) |c| self.alloc.free(c);

        const duped_stdin = if (opts.stdin_data) |d| try self.alloc.dupe(u8, d) else null;
        errdefer if (duped_stdin) |d| self.alloc.free(d);

        const env_box = try self.buildEnvBox(opts);
        errdefer if (env_box) |b| {
            b.deinit();
            self.alloc.destroy(b);
        };

        const spawned_argv = if (builtin.os.tag == .linux) blk: {
            const out = try self.wrapSetsid(final_argv.?);
            final_argv = null;
            break :blk out;
        } else final_argv.?;

        slot.future = std.Io.async(self.io, workerFn, .{ self, slot, spawned_argv, duped_cwd, duped_stdin, env_box, opts.kill_process_group });

        return @enumFromInt(idx);
    }

    fn shouldRouteSsh(self: *const Self, force_local: bool) bool {
        if (force_local) return false;
        return self.ssh_target != null and self.ssh_active;
    }

    /// Decides which env to pass to the child:
    /// 1. Explicit env_overlay (e.g. unlock path) → take ownership as-is.
    /// 2. We own an ssh-agent and overlay not skipped → clone parent_env
    ///    and override SSH_AUTH_SOCK with our agent's socket.
    /// 3. Otherwise → null (child inherits parent env normally).
    fn buildEnvBox(self: *Self, opts: RunOpts) !?*std.process.Environ.Map {
        if (opts.env_overlay) |em| {
            const box = try self.alloc.create(std.process.Environ.Map);
            box.* = em;
            return box;
        }

        if (opts.skip_agent_overlay) return null;
        const sock = self.agent_sock orelse return null;

        const box = try self.alloc.create(std.process.Environ.Map);
        errdefer self.alloc.destroy(box);
        box.* = .init(self.alloc);
        errdefer box.deinit();

        const keys = self.env.keys();
        const vals = self.env.values();
        for (keys, vals) |k, v| try box.put(k, v);
        try box.put("SSH_AUTH_SOCK", sock);
        return box;
    }

    /// If SSH mode is active, return a freshly-allocated argv that wraps the
    /// caller's command in `ssh user@host '<remote shell line>'`. Otherwise
    /// returns a duplicate of the input argv. Caller frees via freeArgv.
    fn maybeWrapSsh(
        self: *Self,
        argv: []const []const u8,
        force_local: bool,
    ) ![]const []const u8 {
        if (!self.shouldRouteSsh(force_local)) return self.dupeArgv(argv);

        const target = self.ssh_target.?;
        const remote_cmd = try buildRemoteShellLine(self.alloc, target.cwd, argv);
        errdefer self.alloc.free(remote_cmd);

        const target_str = try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ target.user, target.host });
        errdefer self.alloc.free(target_str);

        const wrapped = [_][]const u8{
            "ssh",
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "ConnectTimeout=10",
            target_str,
            remote_cmd,
        };

        const out = try self.dupeArgv(&wrapped);
        self.alloc.free(target_str);
        self.alloc.free(remote_cmd);
        return out;
    }

    pub fn release(self: *Self, handle: Handle) void {
        const slot = &self.slots[@intFromEnum(handle)];
        if (!slot.in_use.load(.acquire)) return;

        if (slot.done.load(.acquire)) {
            slot.future.await(self.io) catch {};
        } else {
            slot.future.cancel(self.io) catch {};
        }

        slot.stdout.deinit(self.alloc);
        slot.stderr.deinit(self.alloc);
        slot.stdout = .empty;
        slot.stderr = .empty;
        slot.in_use.store(false, .release);
    }

    pub fn cancel(self: *Self, handle: Handle) void {
        self.release(handle);
    }

    pub fn cancelAll(self: *Self) void {
        for (0..self.slots.len) |i| {
            const handle: Handle = @enumFromInt(i);
            self.release(handle);
        }
    }

    /// Cancels a running worker and returns its partial output. Buffers are
    /// stable before reading: the worker is joined (cancelled first when
    /// still running) before duping.
    pub fn killAndCollect(self: *Self, handle: Handle) !CmdResult {
        const slot = &self.slots[@intFromEnum(handle)];
        const timed_out = !slot.done.load(.acquire);
        errdefer self.release(handle);
        if (timed_out) slot.future.cancel(self.io) catch {};
        slot.future.await(self.io) catch {};
        const out = try self.alloc.dupe(u8, slot.stdout.items);
        errdefer self.alloc.free(out);
        const err = try self.alloc.dupe(u8, slot.stderr.items);
        const ty = if (timed_out) CmdResult.ResType.timeout else slot.result_ty;
        const exit_code = slot.exit_code;
        const signal = slot.signal;
        self.release(handle);
        return .{ .stdout = out, .stderr = err, .ty = ty, .exit_code = exit_code, .signal = signal };
    }

    // -----------------

    fn workerFn(
        self: *Self,
        slot: *CmdSlot,
        argv: []const []const u8,
        cwd: ?[]const u8,
        stdin_data: ?[]const u8,
        env_box: ?*std.process.Environ.Map,
        kill_process_group: bool,
    ) std.Io.Cancelable!void {
        defer self.freeArgv(argv);
        defer if (cwd) |c| self.alloc.free(c);
        defer if (stdin_data) |d| self.alloc.free(d);
        defer if (env_box) |b| {
            // Zero values before deinit — they may carry secrets (passphrases).
            for (b.values()) |v| @memset(@constCast(v), 0);
            b.deinit();
            self.alloc.destroy(b);
        };
        defer slot.done.store(true, .release);

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .stdin = if (stdin_data != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = if (env_box) |b| b else null,
            .pgid = if (kill_process_group and builtin.os.tag != .windows) 0 else null,
        }) catch {
            slot.result_ty = .failed;
            slot.exit_code = null;
            slot.signal = null;
            return;
        };
        defer if (child.id != null) {
            if (kill_process_group and builtin.os.tag != .windows) {
                const pgid: std.posix.pid_t = child.id.?;
                std.posix.kill(-pgid, std.posix.SIG.KILL) catch {};
            }
            child.kill(self.io);
        };

        var stdin_future: ?std.Io.Future(std.Io.Cancelable!void) = null;
        if (stdin_data) |data| {
            const stdin = child.stdin.?;
            child.stdin = null;
            stdin_future = std.Io.async(self.io, writeStdin, .{ stdin, self.io, data });
        }
        defer if (stdin_future) |*future| future.cancel(self.io) catch {};

        const term = self.collectOutput(slot, &child) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.StreamTooLong => {
                // Output hit the cap; keep the partial output and report
                // success. Consumers truncate for display anyway, so a hard
                // failure here turns "huge result" into a baffling process
                // error with no exit code or stderr.
                slot.result_ty = .success;
                return;
            },
            else => {
                slot.result_ty = .failed;
                slot.exit_code = null;
                slot.signal = null;
                return;
            },
        };
        if (stdin_future) |*future| future.await(self.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };

        switch (term) {
            .exited => |code| {
                slot.exit_code = code;
                slot.result_ty = if (code == 0) .success else .failed;
            },
            .signal => |sig| {
                slot.signal = @intFromEnum(sig);
                slot.exit_code = null;
                slot.result_ty = .failed;
            },
            else => {
                slot.exit_code = null;
                slot.result_ty = .failed;
            },
        }
    }

    fn writeStdin(file: std.Io.File, io: std.Io, data: []const u8) std.Io.Cancelable!void {
        defer file.close(io);
        std.Io.File.writeStreamingAll(file, io, data) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
    }

    const CollectError = std.Io.File.MultiReader.UnendingError ||
        std.Io.Batch.AwaitConcurrentError ||
        std.process.Child.WaitError ||
        std.mem.Allocator.Error ||
        error{StreamTooLong};

    fn collectOutput(
        self: *Self,
        slot: *CmdSlot,
        child: *std.process.Child,
    ) CollectError!std.process.Child.Term {
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(self.alloc, self.io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();

        const stdout_reader = mr.reader(0);
        const stderr_reader = mr.reader(1);

        // Stream each drained chunk into the slot.
        while (mr.fill(64, .none)) |_| {
            try self.appendBuffered(slot, stdout_reader, stderr_reader);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }

        try mr.checkAnyError();

        const term = try child.wait(self.io);

        return term;
    }

    /// Moves all currently-buffered bytes out of the multi-reader and into the
    /// slot's stdout/stderr lists under the slot lock.
    fn appendBuffered(
        self: *Self,
        slot: *CmdSlot,
        stdout_reader: *std.Io.Reader,
        stderr_reader: *std.Io.Reader,
    ) (error{ OutOfMemory, StreamTooLong })!void {
        const out = stdout_reader.buffered();
        const err = stderr_reader.buffered();
        stdout_reader.toss(out.len);
        stderr_reader.toss(err.len);

        try slot.stdout.appendSlice(self.alloc, out);
        try slot.stderr.appendSlice(self.alloc, err);

        if (slot.stdout.items.len > MAX_OUTPUT) return error.StreamTooLong;
        if (slot.stderr.items.len > MAX_OUTPUT) return error.StreamTooLong;
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

    /// Returns argv with "setsid" prepended; takes ownership of argv.
    fn wrapSetsid(self: *Self, argv: []const []const u8) ![]const []const u8 {
        const wrapped = try self.alloc.alloc([]const u8, argv.len + 1);
        errdefer self.alloc.free(wrapped);
        wrapped[0] = try self.alloc.dupe(u8, "setsid");
        for (argv, 1..) |a, i| wrapped[i] = a;
        self.alloc.free(argv);
        return wrapped;
    }

    /// Builds `cd <quoted-ssh-root> && <quoted-argv0> <quoted-argv1> ...`.
    fn buildRemoteShellLine(
        alloc: std.mem.Allocator,
        ssh_root: []const u8,
        argv: []const []const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try out.appendSlice(alloc, "cd ");
        try appendShellQuoted(alloc, &out, ssh_root);
        try out.appendSlice(alloc, " && ");
        for (argv, 0..) |a, i| {
            if (i > 0) try out.append(alloc, ' ');
            try appendShellQuoted(alloc, &out, a);
        }
        return out.toOwnedSlice(alloc);
    }

    fn appendShellQuoted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        try out.append(alloc, '\'');
        for (s) |c| {
            if (c == '\'') {
                try out.appendSlice(alloc, "'\\''");
            } else {
                try out.append(alloc, c);
            }
        }
        try out.append(alloc, '\'');
    }

    /// Run synchronously: spawn, await, copy result into caller-owned buffers.
    /// Caller frees stdout/stderr.
    pub fn runAndWait(self: *Self, opts: RunOpts) !CmdResult {
        const handle = try self.runWithOpts(opts);
        const slot = &self.slots[@intFromEnum(handle)];
        slot.future.await(self.io) catch {};
        return self.killAndCollect(handle);
    }

    /// Run synchronously with a wall-clock deadline. On timeout, cancels the
    /// worker and returns its partial output with `.timeout`.
    pub fn runAndWaitTimeout(self: *Self, opts: RunOpts, timeout_ms: i64) !CmdResult {
        const handle = try self.runWithOpts(opts);
        const slot = &self.slots[@intFromEnum(handle)];
        const start_ms = nowMs(self.io);

        while (true) {
            if (slot.done.load(.acquire)) {
                return self.killAndCollect(handle);
            }

            if (nowMs(self.io) - start_ms > timeout_ms) {
                return self.killAndCollect(handle);
            }

            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(25), .real) catch {
                self.cancel(handle);
                return error.Canceled;
            };
        }
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
}

test "runAndWaitTimeout cancels long-running command and releases slot" {
    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{ "/bin/sh", "-c", "printf 'partial-output'; sleep 1" },
        .force_local = true,
    }, 50);
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.timeout, res.ty);
    try testing.expectEqual(@as(?u8, null), res.exit_code);
    try testing.expect(res.stdout.len > 0);
    try testing.expectEqual(@as(usize, 0), res.stderr.len);
    try testing.expectEqual(false, pool.slots[0].in_use.load(.acquire));
}

test "runAndWait captures signal kill" {
    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const res = try pool.runAndWait(.{
        .argv = &.{ "/bin/sh", "-c", "kill -KILL $$" },
        .force_local = true,
    });
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.failed, res.ty);
    try testing.expectEqual(@as(?u8, null), res.exit_code);
    try testing.expectEqual(@as(?u32, @intFromEnum(std.posix.SIG.KILL)), res.signal);
}

test "runAndWait drains output while writing large stdin" {
    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const input = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(input);
    @memset(input, 'x');

    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{ "tee", "/dev/null" },
        .stdin_data = input,
        .force_local = true,
    }, 2_000);
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.success, res.ty);
    try testing.expectEqual(@as(?u8, 0), res.exit_code);
    try testing.expectEqualSlices(u8, input, res.stdout);
    try testing.expectEqual(@as(usize, 0), res.stderr.len);
}

test "runAndWait preserves non-zero child exit code" {
    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const res = try pool.runAndWait(.{
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .force_local = true,
    });
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.failed, res.ty);
    try testing.expectEqual(@as(?u8, 7), res.exit_code);
}

test "no_tty makes /dev/tty reads fail instead of hanging" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{ "/bin/sh", "-c", "cat /dev/tty" },
        .force_local = true,
    }, 2_000);
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.failed, res.ty);
    try testing.expect(res.exit_code != null);
    try testing.expect(res.stderr.len > 0);
}

test "output over cap is reported as truncated success, not failure" {
    const testing = std.testing;

    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();

    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{ "/bin/sh", "-c", "yes x | head -c 6000000" },
        .force_local = true,
    }, 5_000);
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.success, res.ty);
    try testing.expect(res.stdout.len >= MAX_OUTPUT);
    try testing.expectEqual(@as(?u8, null), res.exit_code);
}
