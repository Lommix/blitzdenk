//! Process execution pool. Spawns each command as a `std.Io.async` worker.
//!
//! Two API surfaces:
//! - `runAndWait` blocks the caller until the command exits. Used by foreground
//!   tools that trust the child to exit.
//! - `runAndWaitTimeout` is the same synchronous surface with a wall-clock
//!   deadline. Used by foreground tools that spawn potentially hanging children.
//! - `run` + `poll`/`isDone`/`release`/`cancel` expose the worker future
//!   without blocking. Used only for bash background commands and the read
//!   tool's bg-task inspection path.
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.exec);

const MAX_OUTPUT = 4 * 1024 * 1024;
const SLOT_COUNT = 64;

pub const CmdSlot = struct {
    in_use: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(std.Io.Cancelable!void) = .{ .any_future = null, .result = {} },
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    result_ty: CmdResult.ResType = .failed,
};

pub const CmdResult = struct {
    pub const ResType = enum { success, failed, timeout };
    stdout: []const u8,
    stderr: []const u8,
    ty: ResType,

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

    pub fn setSshActive(self: *Self, active: bool) void {
        self.ssh_active = active;
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

    pub fn run(self: *Self, cwd: ?[]const u8, argv: []const []const u8) !Handle {
        return self.runWithOpts(.{ .cwd = cwd, .argv = argv });
    }

    pub fn runWithStdin(
        self: *Self,
        cwd: ?[]const u8,
        argv: []const []const u8,
        stdin_data: ?[]const u8,
    ) !Handle {
        return self.runWithOpts(.{ .cwd = cwd, .argv = argv, .stdin_data = stdin_data });
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

        const final_argv = try self.maybeWrapSsh(opts.argv, opts.force_local);
        errdefer self.freeArgv(final_argv);

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

        slot.future = std.Io.async(self.io, workerFn, .{ self, slot, final_argv, duped_cwd, duped_stdin, env_box, opts.kill_process_group });

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

    /// Non-blocking poll. Returns null while running, result when exited.
    pub fn poll(self: *Self, handle: Handle) ?CmdResult {
        const slot = &self.slots[@intFromEnum(handle)];
        if (!slot.done.load(.acquire)) return null;
        return .{
            .stdout = slot.stdout.items,
            .stderr = slot.stderr.items,
            .ty = slot.result_ty,
        };
    }

    pub fn isDone(self: *Self, handle: Handle) bool {
        const slot = &self.slots[@intFromEnum(handle)];
        return slot.done.load(.acquire);
    }

    pub fn release(self: *Self, handle: Handle) void {
        const slot = &self.slots[@intFromEnum(handle)];
        if (!slot.in_use.load(.acquire)) return;

        // Worker is either done (await returns instantly) or still running
        // (cancel propagates). Either way we own the slot afterward.
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
            return;
        };
        defer if (child.id != null) {
            if (kill_process_group and builtin.os.tag != .windows) {
                const pgid: std.posix.pid_t = child.id.?;
                std.posix.kill(-pgid, std.posix.SIG.KILL) catch {};
            }
            child.kill(self.io);
        };

        if (stdin_data) |data| {
            const stdin = child.stdin.?;
            std.Io.File.writeStreamingAll(stdin, self.io, data) catch {};
            stdin.close(self.io);
            child.stdin = null;
        }

        const term = self.collectOutput(slot, &child) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                slot.result_ty = .failed;
                return;
            },
        };

        slot.result_ty = switch (term) {
            .exited => |c| if (c == 0) .success else .failed,
            else => .failed,
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

        while (mr.fill(64, .none)) |_| {
            if (stdout_reader.buffered().len > MAX_OUTPUT) return error.StreamTooLong;
            if (stderr_reader.buffered().len > MAX_OUTPUT) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }

        try mr.checkAnyError();

        const term = try child.wait(self.io);

        const out = try mr.toOwnedSlice(0);
        const err_slice = try mr.toOwnedSlice(1);
        slot.stdout = .{ .items = out, .capacity = out.len };
        slot.stderr = .{ .items = err_slice, .capacity = err_slice.len };

        return term;
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
        // Wait for worker completion.
        slot.future.await(self.io) catch {};
        const out = try self.alloc.dupe(u8, slot.stdout.items);
        errdefer self.alloc.free(out);
        const err = try self.alloc.dupe(u8, slot.stderr.items);
        const ty = slot.result_ty;
        self.release(handle);
        return .{ .stdout = out, .stderr = err, .ty = ty };
    }

    /// Run synchronously with a wall-clock deadline. On timeout, cancels the
    /// worker, kills the child via worker cleanup, and returns `.timeout`.
    /// Caller frees stdout/stderr.
    pub fn runAndWaitTimeout(self: *Self, opts: RunOpts, timeout_ms: i64) !CmdResult {
        const handle = try self.runWithOpts(opts);
        const slot = &self.slots[@intFromEnum(handle)];
        const start_ms = @import("http.zig").nowMs(self.io);

        while (true) {
            if (slot.done.load(.acquire)) {
                slot.future.await(self.io) catch {};
                const out = try self.alloc.dupe(u8, slot.stdout.items);
                errdefer self.alloc.free(out);
                const err = try self.alloc.dupe(u8, slot.stderr.items);
                const ty = slot.result_ty;
                self.release(handle);
                return .{ .stdout = out, .stderr = err, .ty = ty };
            }

            if (@import("http.zig").nowMs(self.io) - start_ms > timeout_ms) {
                const out = try self.alloc.dupe(u8, "");
                errdefer self.alloc.free(out);
                const err = try self.alloc.dupe(u8, "");
                self.cancel(handle);
                return .{ .stdout = out, .stderr = err, .ty = .timeout };
            }

            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(25), .real) catch {
                self.cancel(handle);
                return error.Canceled;
            };
        }
    }
};

test "runAndWaitTimeout cancels long-running command and releases slot" {
    const testing = std.testing;

    var pool = CmdPool.init(testing.allocator, testing.io, &testing.environ);
    defer pool.deinit();

    const res = try pool.runAndWaitTimeout(.{
        .argv = &.{ "/bin/sh", "-c", "sleep 1" },
        .force_local = true,
    }, 50);
    defer pool.alloc.free(res.stdout);
    defer pool.alloc.free(res.stderr);

    try testing.expectEqual(CmdResult.ResType.timeout, res.ty);
    try testing.expectEqual(@as(usize, 0), res.stdout.len);
    try testing.expectEqual(@as(usize, 0), res.stderr.len);
    try testing.expectEqual(false, pool.slots[0].in_use.load(.acquire));
}
