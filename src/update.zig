const std = @import("std");
const r = @import("root.zig");
const exec = @import("exec");
const builtin = @import("builtin");

const REPO = "Lommix/blitzdenk";

const MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024;
const MAX_DOWNLOAD_TIMEOUT_MS = 10_000;

pub const DownloadFailure = union(enum) {
    timeout: i64,
    gateway: u16,
    http: u16,
    transport: ?u8,
    truncated,
    empty,
};

pub fn printDownloadFailure(context: []const u8, failure: DownloadFailure) void {
    switch (failure) {
        .timeout => |ms| std.debug.print("blitz: {s} failed: download timed out after {d} ms\n", .{ context, ms }),
        .gateway => |status| std.debug.print("blitz: {s} failed: upstream gateway/service error (HTTP {d})\n", .{ context, status }),
        .http => |status| std.debug.print("blitz: {s} failed: server returned HTTP {d}\n", .{ context, status }),
        .transport => |code| if (code) |exit_code|
            std.debug.print("blitz: {s} failed: network error (exit code {d})\n", .{ context, exit_code })
        else
            std.debug.print("blitz: {s} failed: network error\n", .{context}),
        .truncated => std.debug.print("blitz: {s} failed: response exceeded the size limit\n", .{context}),
        .empty => std.debug.print("blitz: {s} failed: empty response\n", .{context}),
    }
}

pub const VersionInfo = struct {
    latest: []const u8,
    asset_url: []const u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    available: bool,

    pub fn deinit(self: VersionInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.latest);
        alloc.free(self.asset_url);
    }
};

pub const CheckTask = struct {
    pool: *exec.CmdPool,
    gpa: std.mem.Allocator,
    io: std.Io,
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    result: ?VersionInfo = null,

    pub fn init(pool: *exec.CmdPool, gpa: std.mem.Allocator, io: std.Io) CheckTask {
        return .{ .pool = pool, .gpa = gpa, .io = io };
    }

    pub fn start(self: *CheckTask) void {
        self.future = std.Io.concurrent(self.io, run, .{self}) catch {
            self.finished.store(true, .release);
            return;
        };
    }

    pub fn availableVersion(self: *const CheckTask) ?[]const u8 {
        if (!self.finished.load(.acquire)) return null;
        const result = self.result orelse return null;
        return if (result.available) result.latest else null;
    }

    pub fn deinit(self: *CheckTask) void {
        if (self.future) |*future| future.cancel(self.io);
        if (self.result) |result| result.deinit(self.gpa);
        self.* = undefined;
    }

    fn run(self: *CheckTask) void {
        defer self.finished.store(true, .release);
        var failure: ?DownloadFailure = null;
        self.result = checkForUpdate(self.pool, self.gpa, &failure) catch return;
    }
};

const Release = struct {
    tag_name: []const u8,
    assets: []const Asset,

    const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
        digest: ?[]const u8 = null,
    };
};

pub fn checkForUpdate(
    pool: *exec.CmdPool,
    gpa: std.mem.Allocator,
    failure: *?DownloadFailure,
) !VersionInfo {
    const url = "https://api.github.com/repos/" ++ REPO ++ "/releases/latest";
    const body = try download(pool, gpa, url, 6000, failure);
    defer gpa.free(body);
    return parseRelease(body, gpa);
}

pub fn assetName(alloc: std.mem.Allocator) ![]const u8 {
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };
    const os: []const u8 = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return error.UnsupportedOs,
    };
    const suffix: []const u8 = switch (builtin.os.tag) {
        .macos => "",
        .linux => if (builtin.abi == .musl) "-musl" else "-gnu",
        else => "",
    };
    return std.fmt.allocPrint(alloc, "blitz-{s}-{s}{s}.gz", .{ arch, os, suffix });
}

pub fn installUpdate(
    io: std.Io,
    pool: *exec.CmdPool,
    gpa: std.mem.Allocator,
    info: VersionInfo,
    failure: *?DownloadFailure,
) !void {
    const archive = try download(pool, gpa, info.asset_url, MAX_DOWNLOAD_TIMEOUT_MS, failure);
    defer gpa.free(archive);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    if (!std.mem.eql(u8, &digest, &info.digest)) return error.ChecksumMismatch;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &path_buf);
    const exe_path = path_buf[0..n];
    const dir_path = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const basename = std.fs.path.basename(exe_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, basename, .{
        .permissions = .executable_file,
        .replace = true,
    });
    defer atomic.deinit(io);

    var input = std.Io.Reader.fixed(archive);
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buffer);
    _ = try decompressor.reader.streamRemaining(&writer.interface);
    try writer.flush();
    try atomic.replace(io);
}

fn parseRelease(body: []const u8, gpa: std.mem.Allocator) !VersionInfo {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(Release, arena.allocator(), body, .{ .ignore_unknown_fields = true });

    const name = try assetName(arena.allocator());
    const asset = for (parsed.value.assets) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) break candidate;
    } else return error.AssetNotFound;
    const digest_text = asset.digest orelse return error.MissingDigest;
    if (!std.mem.startsWith(u8, digest_text, "sha256:")) return error.InvalidDigest;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, digest_text["sha256:".len..]) catch return error.InvalidDigest;

    const ver_str = if (parsed.value.tag_name.len > 0 and parsed.value.tag_name[0] == 'v')
        parsed.value.tag_name[1..]
    else
        parsed.value.tag_name;
    const current_v = try std.SemanticVersion.parse(r.VERSION);
    const latest_v = try std.SemanticVersion.parse(ver_str);
    const latest = try gpa.dupe(u8, parsed.value.tag_name);
    errdefer gpa.free(latest);
    const asset_url = try gpa.dupe(u8, asset.browser_download_url);

    return .{
        .latest = latest,
        .asset_url = asset_url,
        .digest = digest,
        .available = latest_v.order(current_v) == .gt,
    };
}

fn download(
    pool: *exec.CmdPool,
    gpa: std.mem.Allocator,
    url: []const u8,
    timeout_ms: i64,
    failure: *?DownloadFailure,
) ![]const u8 {
    failure.* = null;
    const commands = [_][]const []const u8{
        &.{ "curl", "-fsSL", "--retry", "3", "--write-out", "%{stderr}%{http_code}\n", url },
        &.{ "wget", "-q", "-S", "-O-", url },
    };
    const deadline = nowMs(pool.io) + @min(timeout_ms, MAX_DOWNLOAD_TIMEOUT_MS);

    for (commands) |argv| {
        const remaining_ms = deadline - nowMs(pool.io);
        if (remaining_ms <= 0) {
            recordTimeout(failure, @min(timeout_ms, MAX_DOWNLOAD_TIMEOUT_MS));
            return error.DownloadFailed;
        }

        const res = pool.runAndWaitTimeout(.{
            .argv = argv,
            .force_local = true,
            .skip_agent_overlay = true,
            .max_output = MAX_DOWNLOAD_BYTES,
        }, remaining_ms) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        const status = parseHttpStatus(res.stderr);
        const timed_out = res.ty == .timeout;
        const truncated = res.stdout_truncated;

        if (timed_out or truncated) {
            gpa.free(res.stdout);
            gpa.free(res.stderr);
            if (timed_out) {
                recordTimeout(failure, @min(timeout_ms, MAX_DOWNLOAD_TIMEOUT_MS));
            } else {
                failure.* = .truncated;
            }
            return error.DownloadFailed;
        }

        if (res.ty == .success and res.stdout.len > 0) {
            gpa.free(res.stderr);
            failure.* = null;
            return res.stdout;
        }

        recordFailure(failure, classifyFailure(status, res));
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    return error.DownloadFailed;
}

fn classifyFailure(status: ?u16, res: exec.CmdResult) DownloadFailure {
    if (status) |code| {
        if (code == 502 or code == 503 or code == 504) return .{ .gateway = code };
        if (code < 200 or code >= 300) return .{ .http = code };
    }
    if (res.exit_code) |code| {
        if (code == 0) return .empty;
        return .{ .transport = code };
    }
    return .{ .transport = null };
}

fn recordTimeout(slot: *?DownloadFailure, limit_ms: i64) void {
    if (slot.*) |current| switch (current) {
        .gateway, .http => return,
        else => {},
    };
    slot.* = .{ .timeout = limit_ms };
}

fn recordFailure(slot: *?DownloadFailure, candidate: DownloadFailure) void {
    const current = slot.* orelse {
        slot.* = candidate;
        return;
    };
    if (failureRank(candidate) >= failureRank(current)) slot.* = candidate;
}

fn failureRank(failure: DownloadFailure) u8 {
    return switch (failure) {
        .timeout => 4,
        .gateway, .http => 3,
        .truncated => 2,
        .transport => 1,
        .empty => 0,
    };
}

fn parseHttpStatus(stderr: []const u8) ?u16 {
    var status: ?u16 = null;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 3 and std.ascii.isDigit(line[0]) and std.ascii.isDigit(line[1]) and std.ascii.isDigit(line[2])) {
            const code = std.fmt.parseInt(u16, line, 10) catch continue;
            if (code != 0) status = code;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "HTTP/")) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const code_text = line[space + 1 ..];
        const end = std.mem.indexOfScalar(u8, code_text, ' ') orelse code_text.len;
        const code = std.fmt.parseInt(u16, code_text[0..end], 10) catch continue;
        if (code != 0) status = code;
    }
    return status;
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_ms));
}
