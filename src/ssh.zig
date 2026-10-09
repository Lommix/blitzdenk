const std = @import("std");
const r = @import("root.zig");

pub const SshConnectTask = struct {
    pub const MAX_USER = 64;
    pub const MAX_HOST = 256;
    pub const MAX_CWD = 256;
    const MAX_PASS = 256;
    const MAX_HOME = 256;
    const MAX_CONTROL = 96;
    const MAX_REASON = 192;

    pool: *r.exec.CmdPool,
    gpa: std.mem.Allocator,
    unlock: bool = false,
    user_buf: [MAX_USER]u8 = undefined,
    user_len: usize = 0,
    host_buf: [MAX_HOST]u8 = undefined,
    host_len: usize = 0,
    cwd_buf: [MAX_CWD]u8 = undefined,
    cwd_len: usize = 0,
    pass_buf: [MAX_PASS]u8 = @splat(0),
    pass_len: usize = 0,
    home_buf: [MAX_HOME]u8 = undefined,
    home_len: usize = 0,
    control_buf: [MAX_CONTROL]u8 = undefined,
    control_len: usize = 0,
    reason_buf: [MAX_REASON]u8 = undefined,
    reason_len: usize = 0,
    outcome: Outcome = .failed,
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    pub const Outcome = enum { connected, need_pass, failed };

    pub fn isFinished(self: *const SshConnectTask) bool {
        return self.finished.load(.acquire);
    }

    pub fn deinit(self: *SshConnectTask) void {
        if (self.future) |*future| future.cancel(self.pool.io);
        self.zeroPassphrase();
        self.* = undefined;
    }

    pub fn user(self: *const SshConnectTask) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn host(self: *const SshConnectTask) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn cwd(self: *const SshConnectTask) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn home(self: *const SshConnectTask) []const u8 {
        return self.home_buf[0..self.home_len];
    }

    pub fn control(self: *const SshConnectTask) []const u8 {
        return self.control_buf[0..self.control_len];
    }

    pub fn reason(self: *const SshConnectTask) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn passphrase(self: *const SshConnectTask) []const u8 {
        return self.pass_buf[0..self.pass_len];
    }

    pub fn start(self: *SshConnectTask) void {
        self.future = std.Io.concurrent(self.pool.io, run, .{self}) catch {
            self.fail("failed to start connect");
            self.finished.store(true, .release);
            return;
        };
    }

    fn run(self: *SshConnectTask) void {
        defer self.finished.store(true, .release);
        var target_buf: [MAX_USER + MAX_HOST + 1]u8 = undefined;
        const target = std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ self.user(), self.host() }) catch {
            self.fail("ssh target too long");
            return;
        };
        if (!self.connect(target)) return;
        if (self.control_len == 0) self.startMaster(target);
        self.fetchHome(target);
        self.outcome = .connected;
    }

    fn connect(self: *SshConnectTask, target: []const u8) bool {
        if (!self.unlock) return self.probe(target, true);
        return self.askpassConnect(target);
    }

    fn probe(self: *SshConnectTask, target: []const u8, allow_modal: bool) bool {
        const res = self.pool.runAndWaitTimeout(.{
            .argv = &.{ "ssh", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "ConnectTimeout=5", target, "true" },
            .force_local = true,
        }, 10000) catch {
            self.fail("ssh failed to spawn");
            return false;
        };
        defer self.pool.alloc.free(res.stdout);
        defer self.pool.alloc.free(res.stderr);
        if (res.ty == .success) return true;
        self.classify(res, allow_modal);
        return false;
    }

    fn askpassConnect(self: *SshConnectTask, target: []const u8) bool {
        const io = self.pool.io;
        var script_buf: [64]u8 = undefined;
        const script_path = std.fmt.bufPrint(&script_buf, "/tmp/blitz-askpass-{d}.sh", .{std.c.getpid()}) catch {
            self.fail("out of memory");
            return false;
        };
        defer std.Io.Dir.deleteFileAbsolute(io, script_path) catch {};
        if (!self.writeAskpass(io, script_path)) return false;
        if (!self.setControlPath()) {
            self.fail("out of memory");
            return false;
        }

        const inherited = self.pool.env.get("SSH_AUTH_SOCK");
        const sock = self.pool.ensureAgent(inherited) catch null;

        var env = std.process.Environ.Map.init(self.gpa);
        var env_keep = false;
        defer if (!env_keep) {
            zeroEnv(&env);
            env.deinit();
        };
        const inherit_keys = [_][]const u8{ "HOME", "USER", "PATH", "TERM", "LANG", "LC_ALL" };
        for (inherit_keys) |k| {
            if (self.pool.env.get(k)) |v| env.put(k, v) catch {};
        }
        if (sock) |s| env.put("SSH_AUTH_SOCK", s) catch {};
        env.put("SSH_ASKPASS", script_path) catch {};
        env.put("SSH_ASKPASS_REQUIRE", "force") catch {};
        env.put("DISPLAY", ":0") catch {};
        env.put("BLITZ_PASSPHRASE", self.passphrase()) catch {};

        var cp_buf: [MAX_CONTROL + 24]u8 = undefined;
        const cp = self.controlOpt(&cp_buf);
        env_keep = true;
        const res = self.pool.runAndWaitTimeout(.{
            .argv = &.{ "ssh", "-o", "PasswordAuthentication=yes", "-o", "ControlMaster=auto", "-o", cp, "-o", "ControlPersist=8h", "-o", "ConnectTimeout=10", target, "true" },
            .env_overlay = env,
            .force_local = true,
        }, 15000) catch |err| {
            if (err == error.PoolExhausted) env_keep = false;
            self.fail("ssh failed to spawn");
            self.zeroPassphrase();
            return false;
        };
        defer self.zeroPassphrase();
        defer self.pool.alloc.free(res.stdout);
        defer self.pool.alloc.free(res.stderr);
        if (res.ty != .success) {
            self.classify(res, false);
            return false;
        }
        if (!self.controlSocketExists()) {
            self.fail("master socket never appeared");
            return false;
        }
        return true;
    }

    fn startMaster(self: *SshConnectTask, target: []const u8) void {
        if (!self.setControlPath()) return;
        var cp_buf: [MAX_CONTROL + 24]u8 = undefined;
        const cp = self.controlOpt(&cp_buf);
        const res = self.pool.runAndWaitTimeout(.{
            .argv = &.{ "ssh", "-Nf", "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "ControlMaster=yes", "-o", cp, "-o", "ControlPersist=8h", "-o", "ConnectTimeout=10", target },
            .force_local = true,
        }, 12000) catch return;
        defer self.pool.alloc.free(res.stdout);
        defer self.pool.alloc.free(res.stderr);
        if (res.ty != .success or !self.controlSocketExists()) {
            self.control_len = 0;
        }
    }

    fn setControlPath(self: *SshConnectTask) bool {
        const path = std.fmt.bufPrint(&self.control_buf, "/tmp/blitz-sshctl-{d}.sock", .{std.c.getpid()}) catch return false;
        self.control_len = path.len;
        return true;
    }

    fn controlOpt(self: *SshConnectTask, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "ControlPath={s}", .{self.control()}) catch "";
    }

    fn controlSocketExists(self: *SshConnectTask) bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..self.control_len], self.control());
        path_buf[self.control_len] = 0;
        const z: [*:0]const u8 = @ptrCast(&path_buf);
        return std.c.access(z, std.c.F_OK) == 0;
    }

    fn fetchHome(self: *SshConnectTask, target: []const u8) void {
        var cp_buf: [MAX_CONTROL + 24]u8 = undefined;
        const cp = self.controlOpt(&cp_buf);
        const argv: []const []const u8 = if (cp.len > 0)
            &.{ "ssh", "-o", "BatchMode=yes", "-o", cp, "-o", "ConnectTimeout=5", target, "echo $HOME" }
        else
            &.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", target, "echo $HOME" };
        const res = self.pool.runAndWaitTimeout(.{
            .argv = argv,
            .force_local = true,
        }, 12000) catch return;
        defer self.pool.alloc.free(res.stdout);
        defer self.pool.alloc.free(res.stderr);
        if (res.ty != .success) return;
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '/' or trimmed.len > MAX_HOME) return;
        if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return;
        @memcpy(self.home_buf[0..trimmed.len], trimmed);
        self.home_len = trimmed.len;
    }

    fn writeAskpass(self: *SshConnectTask, io: std.Io, path: []const u8) bool {
        const f = std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
            self.fail("failed to create askpass helper");
            return false;
        };
        defer f.close(io);
        std.Io.File.writeStreamingAll(f, io, "#!/bin/sh\nprintf '%s' \"$BLITZ_PASSPHRASE\"\n") catch {
            self.fail("failed to write askpass helper");
            return false;
        };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&path_buf);
        _ = std.posix.system.chmod(z, 0o700);
        return true;
    }

    fn classify(self: *SshConnectTask, res: r.exec.CmdResult, allow_modal: bool) void {
        self.outcome = .failed;
        if (res.ty == .timeout) {
            self.setReason("timed out");
            return;
        }
        if (std.mem.indexOf(u8, res.stderr, "Permission denied") != null) {
            self.setReason("auth refused");
            if (allow_modal) self.outcome = .need_pass;
            return;
        }
        if (lastMeaningfulLine(res.stderr)) |line| {
            self.setReason(line);
            return;
        }
        if (res.exit_code) |code| {
            var buf: [24]u8 = undefined;
            self.setReason(std.fmt.bufPrint(&buf, "exit {d}", .{code}) catch "exit");
        } else {
            self.setReason("connection failed");
        }
    }

    fn fail(self: *SshConnectTask, msg: []const u8) void {
        self.outcome = .failed;
        self.setReason(msg);
    }

    fn setReason(self: *SshConnectTask, msg: []const u8) void {
        const n = @min(msg.len, MAX_REASON);
        @memcpy(self.reason_buf[0..n], msg[0..n]);
        self.reason_len = n;
    }

    fn zeroPassphrase(self: *SshConnectTask) void {
        @memset(self.pass_buf[0..self.pass_len], 0);
        self.pass_len = 0;
    }
};

fn zeroEnv(env: *std.process.Environ.Map) void {
    for (env.values()) |v| @memset(@constCast(v), 0);
}

fn lastMeaningfulLine(text: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) last = line;
    }
    return last;
}

pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}
