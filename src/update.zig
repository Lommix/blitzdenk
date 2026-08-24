const std = @import("std");
const r = @import("root.zig");
const exec = @import("exec");
const builtin = @import("builtin");

const REPO = "Lommix/blitzdenk";

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
) !VersionInfo {
    const url = "https://api.github.com/repos/" ++ REPO ++ "/releases/latest";
    const body = try download(pool, gpa, url, 6000);
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

pub fn installUpdate(io: std.Io, pool: *exec.CmdPool, gpa: std.mem.Allocator, info: VersionInfo) !void {
    const archive = try download(pool, gpa, info.asset_url, 180_000);
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

fn download(pool: *exec.CmdPool, gpa: std.mem.Allocator, url: []const u8, timeout_ms: i64) ![]const u8 {
    const commands = [_][]const []const u8{
        &.{ "curl", "-fsSL", "--retry", "3", url },
        &.{ "wget", "-qO-", url },
    };
    for (commands) |argv| {
        const res = pool.runAndWaitTimeout(.{ .argv = argv, .force_local = true }, timeout_ms) catch continue;
        gpa.free(res.stderr);
        if (res.ty == .success and res.stdout.len > 0) return res.stdout;
        gpa.free(res.stdout);
    }
    return error.DownloadFailed;
}

test "release metadata selects the current platform asset" {
    const name = try assetName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "tag_name": "v99.0.0",
        \\  "assets": [{{
        \\    "name": "{s}",
        \\    "browser_download_url": "https://example.test/{s}",
        \\    "digest": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        \\  }}]
        \\}}
    , .{ name, name });
    defer std.testing.allocator.free(json);

    const info = try parseRelease(json, std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(info.available);
    try std.testing.expectEqualStrings("v99.0.0", info.latest);
    try std.testing.expect(std.mem.endsWith(u8, info.asset_url, name));
}

test "release metadata requires a digest" {
    const name = try assetName(std.testing.allocator);
    defer std.testing.allocator.free(name);
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"tag_name":"v99.0.0","assets":[{{"name":"{s}","browser_download_url":"https://example.test/a"}}]}}
    , .{name});
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.MissingDigest, parseRelease(json, std.testing.allocator));
}
