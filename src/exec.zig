//! Process execution pool. Spawns each command as a `std.Io.async` worker.
//!
//! API surface:
//! - `runAndWait` blocks the caller until the command exits. Used by foreground
//!   tools that trust the child to exit.
//! - `runAndWaitTimeout` is the same synchronous surface with a wall-clock
//!   deadline. Used by foreground tools that spawn potentially hanging children.
//! - `release`/`cancel` release or cancel a worker future. Only the slot
//!   owner (the `runAndWait` caller or `Handle` holder) may release.
const std = @import("std");
const builtin = @import("builtin");
pub const shim = @import("exec_shim.zig");

pub const MAX_OUTPUT = 1024 * 1024;
const TRIM_SLACK = 262144;
const MAX_DRAIN_BYTES = 64 * 1024 * 1024;
const SLOT_COUNT = 64;
const TERMINATE_GRACE_MS = 500;
const DRAIN_TIMEOUT_MS = 2000;
const PROCESS_POLL_MS = 10;

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
    control: []const u8 = "",
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

    pub fn setSsh(self: *Self, user: []const u8, host: []const u8, cwd: []const u8, control: []const u8) !void {
        const u = try self.alloc.dupe(u8, user);
        errdefer self.alloc.free(u);
        const h = try self.alloc.dupe(u8, host);
        errdefer self.alloc.free(h);
        const c = try self.alloc.dupe(u8, cwd);
        errdefer self.alloc.free(c);
        const ctl: []const u8 = if (control.len > 0) try self.alloc.dupe(u8, control) else "";
        errdefer if (ctl.len > 0) self.alloc.free(ctl);
        self.clearSsh();
        self.ssh_target = .{ .user = u, .host = h, .cwd = c, .control = ctl };
        self.ssh_active = true;
    }

    pub fn clearSsh(self: *Self) void {
        if (self.ssh_target) |t| {
            self.closeMaster(t);
            self.alloc.free(t.user);
            self.alloc.free(t.host);
            self.alloc.free(t.cwd);
            if (t.control.len > 0) self.alloc.free(t.control);
        }
        self.ssh_target = null;
        self.ssh_active = false;
    }

    fn closeMaster(self: *Self, t: SshTarget) void {
        if (t.control.len == 0) return;
        const target = std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ t.user, t.host }) catch return;
        defer self.alloc.free(target);
        var cp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cp = std.fmt.bufPrint(&cp_buf, "ControlPath={s}", .{t.control}) catch return;
        if (self.runAndWaitTimeout(.{
            .argv = &.{ "ssh", "-o", cp, "-O", "exit", target },
            .force_local = true,
        }, 3000)) |res| {
            self.alloc.free(res.stdout);
            self.alloc.free(res.stderr);
            std.Io.Dir.deleteFileAbsolute(self.io, t.control) catch {};
        } else |_| {}
    }

    pub fn ensureAgent(self: *Self, inherited_sock: ?[]const u8) ![]const u8 {
        if (inherited_sock) |s| if (s.len > 0 and socketUsable(s)) return s;

        if (self.agent_sock) |s| if (socketUsable(s)) return s;
        self.killAgent();

        const res = try self.runAndWaitTimeout(.{
            .argv = &.{ "ssh-agent", "-s" },
            .force_local = true,
            .skip_agent_overlay = true,
        }, 3000);
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);

        if (res.ty != .success) return error.AgentSpawnFailed;

        const parsed = parseAgentOutput(res.stdout) orelse return error.AgentParseFailed;
        errdefer {
            std.posix.kill(parsed.pid, std.posix.SIG.TERM) catch {};
            std.Io.Dir.deleteFileAbsolute(self.io, parsed.sock) catch {};
        }
        if (!socketUsable(parsed.sock)) return error.AgentSpawnFailed;
        const sock_owned = try self.alloc.dupe(u8, parsed.sock);
        self.agent_sock = sock_owned;
        self.agent_pid = parsed.pid;
        return sock_owned;
    }

    pub fn killAgent(self: *Self) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        if (self.agent_pid) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
        if (self.agent_sock) |s| {
            std.Io.Dir.deleteFileAbsolute(self.io, s) catch {};
            self.alloc.free(s);
        }
        self.agent_pid = null;
        self.agent_sock = null;
    }

    fn socketUsable(path: []const u8) bool {
        var address: std.c.sockaddr.un = .{ .path = @splat(0) };
        if (path.len == 0 or path.len >= address.path.len or std.mem.indexOfScalar(u8, path, 0) != null) return false;
        @memcpy(address.path[0..path.len], path);
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK, 0);
        if (fd < 0) return false;
        defer _ = std.c.close(fd);
        return std.c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0;
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

        if (sock == null or pid == null or pid.? <= 1) return null;
        return .{ .sock = sock.?, .pid = pid.? };
    }

    /// Returns the SSH target cwd when SSH is currently routing tool calls
    /// remotely; otherwise returns the caller's local fallback. Centralizes
    /// the routing predicate so callers (agent.zig) stay in one line.
    pub fn effectiveCwd(self: *const Self, fallback: []const u8) []const u8 {
        if (self.ssh_active) if (self.ssh_target) |t| return t.cwd;
        return fallback;
    }

    /// Stable identity of the current routing environment. Distinct values for
    /// local mode and each SSH target let callers cache per-environment state
    /// and detect routing changes.
    pub fn routeKey(self: *const Self) u64 {
        if (!self.ssh_active) return 1;
        const target = self.ssh_target orelse return 1;
        var hash = std.hash.Wyhash.init(0);
        hash.update(target.user);
        hash.update(&.{0});
        hash.update(target.host);
        hash.update(&.{0});
        hash.update(target.cwd);
        return hash.final();
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
        scrub_env: bool = false,
        /// When true, skip the implicit SSH_AUTH_SOCK overlay even if we own
        /// an ssh-agent. Used when spawning the ssh-agent itself to avoid
        /// pointing the new agent at its own (not-yet-existing) socket.
        skip_agent_overlay: bool = false,
        max_output: ?usize = null,
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
        errdefer {
            slot.owned.store(false, .release);
            slot.in_use.store(false, .release);
        }

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
            for (b.values()) |v| @memset(@constCast(v), 0);
            b.deinit();
            self.alloc.destroy(b);
        };

        const spawned_argv = if (builtin.os.tag == .linux) blk: {
            const out = try self.wrapExecShim(final_argv.?);
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

    fn buildEnvBox(self: *Self, opts: RunOpts) !?*std.process.Environ.Map {
        if (opts.env_overlay) |em| {
            const box = try self.alloc.create(std.process.Environ.Map);
            box.* = em;
            if (opts.scrub_env) scrubEnv(box);
            return box;
        }

        const sock = if (opts.skip_agent_overlay) null else self.agent_sock;
        if (!opts.scrub_env and sock == null) return null;

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
        if (sock) |s| try box.put("SSH_AUTH_SOCK", s);
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

    fn scrubEnv(env: *std.process.Environ.Map) void {
        var i = env.keys().len;
        while (i > 0) {
            i -= 1;
            const key = env.keys()[i];
            if (!stripEnvKey(key)) continue;
            @memset(@constCast(env.values()[i]), 0);
            _ = env.swapRemove(key);
        }
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

        var cp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cp = std.fmt.bufPrint(&cp_buf, "ControlPath={s}", .{target.control}) catch "";
        const wrapped: []const []const u8 = if (cp.len > 0)
            &.{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", cp, "-o", "ConnectTimeout=10", target_str, remote_cmd }
        else
            &.{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "ConnectTimeout=10", target_str, remote_cmd };

        const out = try self.dupeArgv(wrapped);
        self.alloc.free(target_str);
        self.alloc.free(remote_cmd);
        return out;
    }

    /// Release a slot owned by the caller (the `runAndWait`/`Handle` holder).
    /// Must not be called by anyone else: joining or freeing a future another
    /// fiber is currently `await`ing is undefined behavior (panic: `await`
    /// raced with `await`). Owners release exactly once, when done.
    pub fn release(self: *Self, handle: Handle) void {
        const slot = &self.slots[@intFromEnum(handle)];
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
        slot.in_use.store(false, .release);
    }

    pub fn cancel(self: *Self, handle: Handle) void {
        self.release(handle);
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
        trimToTail(&slot.stdout, slot.cap, slot.cap, &slot.stdout_truncated);
        trimToTail(&slot.stderr, slot.cap, slot.cap, &slot.stderr_truncated);
        const out = try self.alloc.dupe(u8, slot.stdout.items);
        errdefer self.alloc.free(out);
        const err = try self.alloc.dupe(u8, slot.stderr.items);
        const ty = if (timed_out) CmdResult.ResType.timeout else slot.result_ty;
        const exit_code = slot.exit_code;
        const signal = slot.signal;
        const stdout_truncated = slot.stdout_truncated;
        const stderr_truncated = slot.stderr_truncated;
        self.release(handle);
        return .{ .stdout = out, .stderr = err, .ty = ty, .exit_code = exit_code, .signal = signal, .stdout_truncated = stdout_truncated, .stderr_truncated = stderr_truncated };
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
            .pgid = if (kill_process_group and builtin.os.tag != .linux and builtin.os.tag != .windows) 0 else null,
        }) catch {
            slot.result_ty = .failed;
            slot.exit_code = null;
            slot.signal = null;
            return;
        };
        defer if (child.id) |pid| {
            self.terminateProcess(pid, kill_process_group);
            child.kill(self.io);
        };

        var stdin_future: ?std.Io.Future(std.Io.Cancelable!void) = null;
        if (stdin_data) |data| {
            const stdin = child.stdin.?;
            child.stdin = null;
            stdin_future = std.Io.async(self.io, writeStdin, .{ stdin, self.io, data });
        }
        defer if (stdin_future) |*future| future.cancel(self.io) catch {};

        const term = self.collectOutput(slot, &child, kill_process_group) catch |err| switch (err) {
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
            if (!ceiling_hit and slot.drained > ceiling) {
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
        if (builtin.os.tag == .windows) return;
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

        try slot.stdout.appendSlice(self.alloc, out);
        try slot.stderr.appendSlice(self.alloc, err);
        slot.drained += out.len + err.len;

        trimToTail(&slot.stdout, slot.cap, slot.cap + TRIM_SLACK, &slot.stdout_truncated);
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

    /// Builds `cd <quoted-ssh-root> && <quoted-argv0> <quoted-argv1> ...`.
    fn buildRemoteShellLine(
        alloc: std.mem.Allocator,
        ssh_root: []const u8,
        argv: []const []const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try out.appendSlice(alloc, "cd ");
        try appendShellPath(alloc, &out, ssh_root);
        try out.appendSlice(alloc, " && ");
        for (argv, 0..) |a, i| {
            if (i > 0) try out.append(alloc, ' ');
            try appendShellQuoted(alloc, &out, a);
        }
        return out.toOwnedSlice(alloc);
    }

    fn appendShellPath(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        if (std.mem.eql(u8, s, "~")) {
            try out.appendSlice(alloc, "\"$HOME\"");
            return;
        }
        if (std.mem.startsWith(u8, s, "~/")) {
            try out.appendSlice(alloc, "\"$HOME\"/");
            try appendShellQuoted(alloc, out, s[2..]);
            return;
        }
        try appendShellQuoted(alloc, out, s);
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
    try env.put("SSH_AUTH_SOCK", "/tmp/inherited.sock");
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
    try testing.expectEqualStrings("/tmp/inherited.sock", box.get("SSH_AUTH_SOCK").?);
    try testing.expectEqual(null, try pool.buildEnvBox(.{ .argv = &.{"ssh"} }));

    pool.agent_sock = try testing.allocator.dupe(u8, "/tmp/owned.sock");
    const overlaid = (try pool.buildEnvBox(.{ .argv = &.{"env"}, .scrub_env = true })).?;
    defer testing.allocator.destroy(overlaid);
    defer overlaid.deinit();
    try testing.expectEqualStrings("/tmp/owned.sock", overlaid.get("SSH_AUTH_SOCK").?);
    try testing.expect(!overlaid.contains("OPENAI_API_KEY"));

    const internal = (try pool.buildEnvBox(.{ .argv = &.{"ssh"} })).?;
    defer testing.allocator.destroy(internal);
    defer internal.deinit();
    try testing.expectEqualStrings("secret", internal.get("OPENAI_API_KEY").?);
}

test "scrubbing applies to explicit environments and reaches spawned children" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var pool = CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    var overlay = std.process.Environ.Map.init(testing.allocator);
    try overlay.put("PATH", "/usr/bin:/bin");
    try overlay.put("BLITZ_TEST_API_KEY", "secret");
    try overlay.put("BLITZ_TEST_TOKEN", "secret");
    try overlay.put("DYLD_TEST", "secret");
    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{"/usr/bin/env"},
        .env_overlay = overlay,
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

test "leader exit cancels stdin writes held open by descendants" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    const data = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    const start = nowMs(std.testing.io);
    const result = try f.pool.runAndWaitTimeout(.{
        .cwd = f.cwd,
        .argv = &.{ "/bin/sh", "-c", "sleep 300 <&0 >/dev/null 2>&1 & printf '%s' \"$!\" > child; printf complete" },
        .stdin_data = data,
        .kill_process_group = true,
    }, 5000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const pid_text = try f.waitFile("child");
    defer std.testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    defer std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    try std.testing.expect(nowMs(std.testing.io) - start < 3000);
    try std.testing.expectEqual(.success, result.ty);
    try std.testing.expectEqualStrings("complete", result.stdout);
}

test "SSH socket probes reject files and stale sockets and preserve inherited agents" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/sock", .{f.cwd});
    try std.testing.expect(!CmdPool.socketUsable(path));
    const file = try f.tmp.dir.createFile(std.testing.io, "sock", .{});
    file.close(std.testing.io);
    try std.testing.expect(!CmdPool.socketUsable(path));
    try f.tmp.dir.deleteFile(std.testing.io, "sock");
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(std.testing.io, .{});
    try std.testing.expect(CmdPool.socketUsable(path));
    try std.testing.expectEqualStrings(path, try f.pool.ensureAgent(path));
    f.pool.killAgent();
    try std.testing.expect(CmdPool.socketUsable(path));
    server.deinit(std.testing.io);
    try std.testing.expect(!CmdPool.socketUsable(path));
    f.pool.agent_sock = try std.testing.allocator.dupe(u8, path);
    f.pool.killAgent();
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "sock", .{}));
}

test "owned ssh-agent teardown removes its socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/ssh-agent", .{}) catch return error.SkipZigTest;
    var f: ProcessTestFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("PATH", "/usr/bin:/bin");
    const sock = try std.testing.allocator.dupe(u8, try f.pool.ensureAgent(null));
    defer std.testing.allocator.free(sock);
    try std.testing.expect(CmdPool.socketUsable(sock));
    try std.testing.expectEqualStrings(sock, try f.pool.ensureAgent(null));
    f.pool.killAgent();
    try std.testing.expect(!CmdPool.socketUsable(sock));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, sock, .{}));
    try std.testing.expectEqual(null, f.pool.agent_pid);
    try std.testing.expectEqual(null, f.pool.agent_sock);
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

test "remote shell line expands a leading tilde in the cwd" {
    const line = try CmdPool.buildRemoteShellLine(std.testing.allocator, "~/project", &.{"ls"});
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("cd \"$HOME\"/'project' && 'ls'", line);

    const home = try CmdPool.buildRemoteShellLine(std.testing.allocator, "~", &.{"ls"});
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("cd \"$HOME\" && 'ls'", home);
}

test "remote shell line quotes cwd and argv safely" {
    const line = try CmdPool.buildRemoteShellLine(std.testing.allocator, "/tmp/it's", &.{ "/bin/echo", "hi" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("cd '/tmp/it'\\''s' && '/bin/echo' 'hi'", line);
}
