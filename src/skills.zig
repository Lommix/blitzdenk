const std = @import("std");
const context_factory = @import("context_factory.zig");

pub const SkillMeta = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: ?[]const u8 = null,
    user_invocable: bool = true,
    model_invocable: bool = true,
};

pub const SkillEntry = struct {
    meta: SkillMeta,
    path: []const u8,
};

pub const LoadedSkill = struct {
    raw: []u8,
    name: []const u8,
    body: []const u8,
};

pub const SkillCommand = struct {
    name: []const u8,
    prompt: []const u8,
};

pub const SkillRegistry = struct {
    //NOTE: might require mutex, rare race between agents triggering multi scans
    entries: std.ArrayList(SkillEntry) = .empty,

    pub fn clear(self: *SkillRegistry, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| freeEntry(alloc, entry);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *SkillRegistry, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
    }

    pub fn scan(self: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, user_dir: ?std.Io.Dir, cwd: []const u8) void {
        self.clear(alloc);
        if (cwd.len > 0) {
            if (findProjectRoot(alloc, io, cwd)) |root| {
                defer alloc.free(root);
                scanProjectLayer(self, alloc, io, root, ".blitz/skills");
                scanProjectLayer(self, alloc, io, root, ".agents/skills");
            }
        }
        if (user_dir) |dir| scanDir(self, alloc, io, dir);
    }

    pub fn find(self: *const SkillRegistry, name: []const u8) ?*const SkillEntry {
        for (self.entries.items, 0..) |entry, i| {
            if (std.ascii.eqlIgnoreCase(entry.meta.name, name)) return &self.entries.items[i];
        }
        return null;
    }
};

pub fn loadSkill(io: std.Io, alloc: std.mem.Allocator, entry: *const SkillEntry) ?LoadedSkill {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, entry.path, alloc, .limited64(1024 * 1024)) catch return null;
    _ = parseSkillMeta(raw) orelse {
        alloc.free(raw);
        return null;
    };
    const body = parseSkillBody(raw) orelse {
        alloc.free(raw);
        return null;
    };
    return .{ .raw = raw, .name = entry.meta.name, .body = body };
}

fn scanProjectLayer(reg: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, root: []const u8, rel: []const u8) void {
    const layer = std.fs.path.join(alloc, &.{ root, rel }) catch return;
    defer alloc.free(layer);
    var dir = std.Io.Dir.openDirAbsolute(io, layer, .{ .iterate = true }) catch return;
    defer dir.close(io);
    scanDir(reg, alloc, io, dir);
}

fn scanDir(reg: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) void {
    var it = dir.iterate();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var header_buf: [4096]u8 = undefined;

    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        addEntry(reg, alloc, io, dir, entry.name, &path_buf, &header_buf);
    }
}

fn addEntry(reg: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, path_buf: []u8, header_buf: []u8) void {
    const len = dir.realPathFile(io, sub_path, path_buf) catch return;
    const meta = loadSkillMeta(io, path_buf[0..len], header_buf) orelse return;
    if (!isSkillName(meta.name)) {
        std.log.warn("ignoring skill with invalid name '{s}' at '{s}'", .{ meta.name, path_buf[0..len] });
        return;
    }
    if (reg.find(meta.name) != null) return;
    const entry = allocEntry(alloc, meta, path_buf[0..len]) orelse return;
    reg.entries.append(alloc, entry) catch {
        freeEntry(alloc, entry);
    };
}

fn allocEntry(alloc: std.mem.Allocator, meta: SkillMeta, path: []const u8) ?SkillEntry {
    const name = alloc.dupe(u8, meta.name) catch return null;
    errdefer alloc.free(name);
    const description = alloc.dupe(u8, meta.description) catch return null;
    errdefer alloc.free(description);
    const when_to_use = if (meta.when_to_use) |w| alloc.dupe(u8, w) catch return null else null;
    errdefer if (when_to_use) |w| alloc.free(w);
    const path_dup = alloc.dupe(u8, path) catch return null;
    return .{
        .meta = .{
            .name = name,
            .description = description,
            .when_to_use = when_to_use,
            .user_invocable = meta.user_invocable,
            .model_invocable = meta.model_invocable,
        },
        .path = path_dup,
    };
}

fn freeEntry(alloc: std.mem.Allocator, entry: SkillEntry) void {
    alloc.free(entry.meta.name);
    alloc.free(entry.meta.description);
    if (entry.meta.when_to_use) |w| alloc.free(w);
    alloc.free(entry.path);
}

fn findProjectRoot(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) ?[]const u8 {
    var path = alloc.dupe(u8, cwd) catch return null;
    while (true) {
        const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch {
            alloc.free(path);
            return null;
        };
        const has_git = blk: {
            _ = dir.statFile(io, ".git", .{}) catch break :blk false;
            break :blk true;
        };
        dir.close(io);
        if (has_git) return path;
        const parent = std.fs.path.dirname(path) orelse {
            alloc.free(path);
            return null;
        };
        const next = alloc.dupe(u8, parent) catch {
            alloc.free(path);
            return null;
        };
        alloc.free(path);
        path = next;
    }
}

pub fn isSkillName(name: []const u8) bool {
    if (name.len == 0) return false;
    var prev_dash = true;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            prev_dash = false;
            continue;
        }
        if (c == '-') {
            if (prev_dash) return false;
            prev_dash = true;
            continue;
        }
        return false;
    }
    return !prev_dash;
}

pub fn loadSkillMeta(io: std.Io, path: []const u8, buf: []u8) ?SkillMeta {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [256]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const n = file_reader.interface.readSliceShort(buf) catch return null;
    return parseSkillMeta(buf[0..n]);
}

pub fn parseSkillMeta(raw: []u8) ?SkillMeta {
    if (!std.mem.startsWith(u8, raw, "---\n")) return null;

    const header_end = std.mem.indexOf(u8, raw[4..], "\n---") orelse return null;
    const header = raw[4..][0..header_end];

    var meta: SkillMeta = .{ .name = "", .description = "" };

    var i: usize = 0;
    while (i < header.len) {
        const line_start = i;
        const line_end = lineEnd(header, line_start);
        var line = trimCr(header[line_start..line_end]);
        i = if (line_end < header.len) line_end + 1 else header.len;

        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (val.len == 1 and (val[0] == '>' or val[0] == '|')) {
            const block_start = i;
            var block_end = i;
            while (block_end < header.len) {
                const next_end = lineEnd(header, block_end);
                const block_line = trimCr(header[block_end..next_end]);
                if (block_line.len != 0 and block_line[0] != ' ' and block_line[0] != '\t') break;
                block_end = if (next_end < header.len) next_end + 1 else header.len;
            }
            val = parseYamlBlock(header[block_start..block_end], val[0] == '|');
            i = block_end;
        }

        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        } else if (std.mem.eql(u8, key, "whenToUse")) {
            meta.when_to_use = val;
        } else if (std.mem.eql(u8, key, "user-invocable")) {
            meta.user_invocable = parseBool(val, true);
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            meta.model_invocable = !parseBool(val, false);
        }
    }

    if (meta.name.len == 0 or meta.description.len == 0) return null;
    return meta;
}

pub fn parseSkillBody(raw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, raw, "---\n")) return null;
    const header_end = std.mem.indexOf(u8, raw[4..], "\n---") orelse return null;
    var i = 4 + header_end + 4;
    if (i < raw.len and raw[i] == '\r') i += 1;
    if (i < raw.len and raw[i] == '\n') i += 1;
    return raw[i..];
}

pub fn parseSkillCommand(raw: []const u8) ?SkillCommand {
    const parsed = context_factory.parsePrefixedCommand(raw, "skill-") orelse return null;
    return .{ .name = parsed.name, .prompt = std.mem.trim(u8, parsed.rest, " \t\r\n") };
}

pub fn skillSendText(alloc: std.mem.Allocator, body: []const u8, prompt: []const u8) ![]const u8 {
    if (prompt.len == 0) return body;
    return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ body, prompt });
}

pub fn skillChatText(alloc: std.mem.Allocator, name: []const u8, prompt: []const u8) ![]const u8 {
    if (prompt.len == 0) return std.fmt.allocPrint(alloc, "[skill-{s}]", .{name});
    return std.fmt.allocPrint(alloc, "[skill-{s}] {s}", .{ name, prompt });
}

fn parseBool(val: []const u8, default: bool) bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return default;
}

fn lineEnd(buf: []const u8, start: usize) usize {
    return start + (std.mem.indexOfScalar(u8, buf[start..], '\n') orelse buf.len - start);
}

fn trimCr(line: []u8) []u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn parseYamlBlock(block: []u8, literal: bool) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    var wrote = false;

    while (i < block.len) {
        const end = lineEnd(block, i);
        const line = std.mem.trim(u8, trimCr(block[i..end]), " \t");
        i = if (end < block.len) end + 1 else block.len;

        if (line.len == 0) {
            if (wrote and out > 0 and block[out - 1] != '\n') {
                block[out] = '\n';
                out += 1;
            }
            continue;
        }

        if (wrote) {
            block[out] = if (literal) '\n' else ' ';
            out += 1;
        }
        @memmove(block[out .. out + line.len], line);
        out += line.len;
        wrote = true;
    }

    return std.mem.trim(u8, block[0..out], " \t\r\n");
}

test "skill meta parses folded yaml description" {
    var raw = ("---\n" ++
        "name: ponytail-audit\n" ++
        "description: >\n" ++
        "  Whole-repo audit for over-engineering. Like ponytail-review, but scans the\n" ++
        "  entire codebase instead of a diff.\n" ++
        "---\n" ++
        "body\n").*;

    const meta = parseSkillMeta(raw[0..]).?;
    try std.testing.expectEqualStrings("ponytail-audit", meta.name);
    try std.testing.expectEqualStrings(
        "Whole-repo audit for over-engineering. Like ponytail-review, but scans the entire codebase instead of a diff.",
        meta.description,
    );
    try std.testing.expectEqualStrings("body\n", parseSkillBody(raw[0..]).?);
}

test "skill meta parses policy keys and block scalars" {
    var raw = ("---\n" ++
        "name: zig\n" ++
        "whenToUse: |\n" ++
        "  use for zig\n" ++
        "  code changes\n" ++
        "user-invocable: false\n" ++
        "disable-model-invocation: true\n" ++
        "license: MIT\n" ++
        "description: zig help\n" ++
        "---\n" ++
        "body\n").*;

    const meta = parseSkillMeta(raw[0..]).?;
    try std.testing.expectEqualStrings("zig", meta.name);
    try std.testing.expectEqualStrings("use for zig\ncode changes", meta.when_to_use.?);
    try std.testing.expect(!meta.user_invocable);
    try std.testing.expect(!meta.model_invocable);
}

test "skill meta keeps defaults for malformed booleans" {
    var raw = ("---\n" ++
        "name: zig\n" ++
        "description: zig help\n" ++
        "user-invocable: nope\n" ++
        "disable-model-invocation: maybe\n" ++
        "---\n" ++
        "body\n").*;

    const meta = parseSkillMeta(raw[0..]).?;
    try std.testing.expect(meta.user_invocable);
    try std.testing.expect(meta.model_invocable);
}

test "skill body extract empty body" {
    var raw = ("---\nname: x\ndescription: y\n---\n").*;
    try std.testing.expectEqualStrings("", parseSkillBody(raw[0..]).?);
}

test "skill body extract missing header returns none" {
    try std.testing.expect(parseSkillBody("no header\n") == null);
    try std.testing.expect(parseSkillBody("---\nname: x\n") == null);
}

test "skill command parse" {
    const Case = struct { in: []const u8, name: ?[]const u8, prompt: []const u8 };
    const cases = [_]Case{
        .{ .in = "/skill-zig", .name = "zig", .prompt = "" },
        .{ .in = "/skill-zig fix the allocator", .name = "zig", .prompt = "fix the allocator" },
        .{ .in = "/skill-ponytail-review", .name = "ponytail-review", .prompt = "" },
        .{ .in = "/skill-ponytail-review do it", .name = "ponytail-review", .prompt = "do it" },
        .{ .in = "/skill-PonyTail", .name = "PonyTail", .prompt = "" },
        .{ .in = "/skill-zig   spaced", .name = "zig", .prompt = "spaced" },
        .{ .in = "/skill", .name = null, .prompt = "" },
        .{ .in = ":skill", .name = null, .prompt = "" },
        .{ .in = "/skill-", .name = null, .prompt = "" },
        .{ .in = "/foo", .name = null, .prompt = "" },
        .{ .in = ":clear", .name = null, .prompt = "" },
        .{ .in = "/plan", .name = null, .prompt = "" },
        .{ .in = "skill-zig", .name = null, .prompt = "" },
    };
    for (cases) |c| {
        const got = parseSkillCommand(c.in);
        if (c.name) |n| {
            try std.testing.expectEqualStrings(n, got.?.name);
            try std.testing.expectEqualStrings(c.prompt, got.?.prompt);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "skill send and chat text" {
    const body = "BODY";
    try std.testing.expectEqualStrings(body, try skillSendText(std.testing.allocator, body, ""));
    const joined = try skillSendText(std.testing.allocator, body, "do it");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("BODY\n\ndo it", joined);

    const tag = try skillChatText(std.testing.allocator, "zig", "");
    defer std.testing.allocator.free(tag);
    try std.testing.expectEqualStrings("[skill-zig]", tag);

    const tagp = try skillChatText(std.testing.allocator, "zig", "fix");
    defer std.testing.allocator.free(tagp);
    try std.testing.expectEqualStrings("[skill-zig] fix", tagp);
}

test "isSkillName" {
    try std.testing.expect(isSkillName("zig"));
    try std.testing.expect(isSkillName("ponytail-review"));
    try std.testing.expect(isSkillName("a0-b1"));
    try std.testing.expect(!isSkillName(""));
    try std.testing.expect(!isSkillName("-zig"));
    try std.testing.expect(!isSkillName("zig-"));
    try std.testing.expect(!isSkillName("zig--x"));
    try std.testing.expect(!isSkillName("Zig"));
    try std.testing.expect(!isSkillName("zig_x"));
}

test "registry merges layers first-wins and ignores invalid names" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "project", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.git", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.blitz", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.blitz/skills", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.agents", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.agents/skills", .default_dir);

    {
        const file = try tmp.dir.createFile(std.testing.io, "project/.blitz/skills/zig.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: zig\ndescription: project zig\n---\nproject body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "project/.agents/skills/zig.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: zig\ndescription: agents zig\n---\nagents body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "project/.agents/skills/other.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: other\ndescription: interop\n---\ninterop body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "project/.blitz/skills/Bad_Name.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: Bad_Name\ndescription: bad\n---\nbad body\n");
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "project", &cwd_buf);

    var reg = SkillRegistry{};
    defer reg.deinit(std.testing.allocator);
    reg.scan(std.testing.allocator, std.testing.io, null, cwd_buf[0..cwd_len]);

    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    const zig = reg.find("zig").?;
    try std.testing.expectEqualStrings("project zig", zig.meta.description);
    try std.testing.expect(reg.find("other") != null);
    try std.testing.expect(reg.find("bad_name") == null);
}

test "registry lookup is case-insensitive and loads body" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const contents =
        \\---
        \\name: ponytail
        \\description: lazy
        \\---
        \\do less
    ;
    {
        const file = try tmp.dir.createFile(std.testing.io, "x.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, contents);
    }

    var reg = SkillRegistry{};
    defer reg.deinit(std.testing.allocator);
    reg.scan(std.testing.allocator, std.testing.io, tmp.dir, "");

    const entry = reg.find("PonyTail").?;
    const loaded = loadSkill(std.testing.io, std.testing.allocator, entry).?;
    defer std.testing.allocator.free(loaded.raw);
    try std.testing.expectEqualStrings("ponytail", loaded.name);
    try std.testing.expectEqualStrings("do less", loaded.body);
    try std.testing.expect(reg.find("nope") == null);
}
