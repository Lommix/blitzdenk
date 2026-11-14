const std = @import("std");
const context_factory = @import("context_factory.zig");

pub const Filter = struct {
    enabled: bool = true,
    only: []const []const u8 = &.{},
    except: []const []const u8 = &.{},
};

pub const Target = struct {
    name: []const u8,
    is_main: bool,
    filter: Filter,
};

pub const SkillMeta = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: ?[]const u8 = null,
    user_invocable: bool = true,
    model_invocable: bool = true,
    deny_agents: ?[]const u8 = null,
    main_agent_only: bool = false,
};

pub const SkillEntry = struct {
    meta: SkillMeta,
    path: []const u8,
};

pub const LoadedSkill = struct {
    raw: []u8,
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

    /// Project skills, then user skills, then plugin skill dirs in order. The first name wins.
    pub fn scan(self: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, user_dir: ?std.Io.Dir, cwd: []const u8, plugin_dirs: []const []const u8) void {
        self.clear(alloc);
        if (cwd.len > 0) {
            if (findProjectRoot(alloc, io, cwd)) |root| {
                defer alloc.free(root);
                const path = std.fs.path.join(alloc, &.{ root, "skills" }) catch return;
                defer alloc.free(path);
                if (std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })) |project_dir| {
                    var dir = project_dir;
                    defer dir.close(io);
                    scanDir(self, alloc, io, dir, false);
                } else |_| {}
            }
        }
        if (user_dir) |dir| scanDir(self, alloc, io, dir, false);
        for (plugin_dirs) |path| {
            var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            scanDir(self, alloc, io, dir, true);
        }
    }

    pub fn find(self: *const SkillRegistry, name: []const u8) ?*const SkillEntry {
        for (self.entries.items, 0..) |entry, i| {
            if (std.ascii.eqlIgnoreCase(entry.meta.name, name)) return &self.entries.items[i];
        }
        return null;
    }

    pub fn findPath(self: *const SkillRegistry, path: []const u8) ?*const SkillEntry {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) return &self.entries.items[i];
        }
        return null;
    }
};

pub fn visibleTo(entry: *const SkillEntry, agent_name: []const u8, is_main: bool, filter: Filter) bool {
    if (!filter.enabled) return false;
    if (entry.meta.main_agent_only and !is_main) return false;
    if (entry.meta.deny_agents) |deny| {
        if (commaListContains(deny, agent_name)) return false;
    }
    if (nameListContains(filter.except, entry.meta.name)) return false;
    if (filter.only.len > 0 and !nameListContains(filter.only, entry.meta.name)) return false;
    return true;
}

fn commaListContains(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| {
        if (std.mem.eql(u8, std.mem.trim(u8, item, " \t\"'"), name)) return true;
    }
    return false;
}

fn nameListContains(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, target)) return true;
    }
    return false;
}

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
    return .{ .raw = raw, .body = body };
}

fn scanDir(reg: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, warn_shadowed: bool) void {
    var it = dir.iterate();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var header_buf: [4096]u8 = undefined;

    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        addEntry(reg, alloc, io, dir, entry.name, &path_buf, &header_buf, warn_shadowed);
    }
}

fn addEntry(reg: *SkillRegistry, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, path_buf: []u8, header_buf: []u8, warn_shadowed: bool) void {
    const len = dir.realPathFile(io, sub_path, path_buf) catch return;
    const meta = loadSkillMeta(io, path_buf[0..len], header_buf) orelse return;
    if (!isSkillName(meta.name)) {
        if (!@import("builtin").is_test) {
            std.log.warn("ignoring skill with invalid name '{s}' at '{s}'", .{ meta.name, path_buf[0..len] });
        }
        return;
    }
    if (reg.find(meta.name) != null) {
        if (warn_shadowed and !@import("builtin").is_test) {
            std.log.warn("plugin skill '{s}' at '{s}' is shadowed by an earlier skill", .{ meta.name, path_buf[0..len] });
        }
        return;
    }
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
    const deny_agents = if (meta.deny_agents) |list| alloc.dupe(u8, list) catch return null else null;
    errdefer if (deny_agents) |list| alloc.free(list);
    const path_dup = alloc.dupe(u8, path) catch return null;
    return .{
        .meta = .{
            .name = name,
            .description = description,
            .when_to_use = when_to_use,
            .user_invocable = meta.user_invocable,
            .model_invocable = meta.model_invocable,
            .deny_agents = deny_agents,
            .main_agent_only = meta.main_agent_only,
        },
        .path = path_dup,
    };
}

fn freeEntry(alloc: std.mem.Allocator, entry: SkillEntry) void {
    alloc.free(entry.meta.name);
    alloc.free(entry.meta.description);
    if (entry.meta.when_to_use) |w| alloc.free(w);
    if (entry.meta.deny_agents) |list| alloc.free(list);
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
    var in_metadata = false;

    var i: usize = 0;
    while (i < header.len) {
        const line_start = i;
        const line_end = lineEnd(header, line_start);
        var line = trimCr(header[line_start..line_end]);
        i = if (line_end < header.len) line_end + 1 else header.len;

        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (in_metadata) parseMetadataLine(line, &meta);
            continue;
        }
        in_metadata = false;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = unquoteYamlInPlace(trimSpaces(line[0..colon]));
        const scalar = trimSpaces(line[colon + 1 ..]);
        var val: []const u8 = undefined;

        if (isBlockIndicator(scalar)) {
            const block_start = i;
            var block_end = i;
            while (block_end < header.len) {
                const next_end = lineEnd(header, block_end);
                const block_line = trimCr(header[block_end..next_end]);
                if (block_line.len != 0 and block_line[0] != ' ' and block_line[0] != '\t') break;
                block_end = if (next_end < header.len) next_end + 1 else header.len;
            }
            val = parseYamlBlock(header[block_start..block_end], scalar[0] == '|');
            i = block_end;
        } else {
            val = unquoteYamlInPlace(scalar);
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
        } else if (std.mem.eql(u8, key, "metadata")) {
            const rest = trimSpaces(stripYamlComment(scalar));
            if (rest.len == 0) {
                in_metadata = true;
            } else if (rest.len >= 2 and rest[0] == '{' and rest[rest.len - 1] == '}') {
                parseFlowMetadata(rest[1 .. rest.len - 1], &meta);
            }
        }
    }

    if (meta.name.len == 0 or meta.description.len == 0) return null;
    return meta;
}

fn parseMetadataLine(line_in: []u8, meta: *SkillMeta) void {
    const line = trimSpaces(trimCr(line_in));
    if (line.len == 0 or line[0] == '#') return;

    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
    const key = unquoteYamlInPlace(trimSpaces(line[0..colon]));
    var val = unquoteYamlInPlace(trimSpaces(stripYamlComment(trimSpaces(line[colon + 1 ..]))));

    if (std.mem.eql(u8, key, "blitzdenk.deny-agents")) {
        if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']') val = val[1 .. val.len - 1];
        meta.deny_agents = val;
    } else if (std.mem.eql(u8, key, "blitzdenk.main-agent-only")) {
        meta.main_agent_only = parseBool(val, false);
    }
}

/// Splits `a: x, b: [y, z]` on top-level commas, honoring quotes and brackets.
fn parseFlowMetadata(flow: []u8, meta: *SkillMeta) void {
    var quote: u8 = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (flow, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                parseMetadataLine(flow[start..i], meta);
                start = i + 1;
            },
            else => {},
        }
    }
    parseMetadataLine(flow[start..], meta);
}

fn stripYamlComment(val: []u8) []u8 {
    var quote: u8 = 0;
    for (val, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#' and (i == 0 or val[i - 1] == ' ' or val[i - 1] == '\t')) return val[0..i];
    }
    return val;
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

pub fn skillSendText(alloc: std.mem.Allocator, name: []const u8, path: []const u8, body: []const u8, prompt: []const u8) ![]const u8 {
    if (prompt.len == 0) {
        return std.fmt.allocPrint(alloc, "<skill>\n<name>{s}</name>\n<path>{s}</path>\n\n{s}\n</skill>", .{ name, path, body });
    }
    return std.fmt.allocPrint(alloc, "<skill>\n<name>{s}</name>\n<path>{s}</path>\n\n{s}\n</skill>\n\n{s}", .{ name, path, body, prompt });
}

pub fn skillTimelineText(alloc: std.mem.Allocator, name: []const u8, prompt: []const u8) ![]const u8 {
    if (prompt.len == 0) return std.fmt.allocPrint(alloc, "## [Skill: {s}]\n", .{name});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "## [Skill: ");
    try out.appendSlice(alloc, name);
    try out.appendSlice(alloc, "]\n\n");
    for (prompt) |c| {
        try out.append(alloc, c);
    }
    try out.appendSlice(alloc, "\n\n");
    return out.toOwnedSlice(alloc);
}

fn parseBool(val: []const u8, default: bool) bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return default;
}

fn isBlockIndicator(val: []const u8) bool {
    if (val.len == 0 or val.len > 2) return false;
    if (val[0] != '>' and val[0] != '|') return false;
    if (val.len == 1) return true;
    return val[1] == '-' or val[1] == '+';
}

fn unquoteYamlInPlace(val: []u8) []const u8 {
    if (val.len < 2) return val;
    const quote = val[0];
    if (quote != val[val.len - 1]) return val;
    if (quote != '"' and quote != '\'') return val;

    const inner = val[1 .. val.len - 1];
    var out: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const escapable = quote == '"' and inner[i] == '\\' and i + 1 < inner.len and
            (inner[i + 1] == '"' or inner[i + 1] == '\\');
        if (escapable) {
            inner[out] = inner[i + 1];
            i += 2;
            out += 1;
            continue;
        }
        if (quote == '\'' and inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
            inner[out] = '\'';
            i += 2;
            out += 1;
            continue;
        }
        if (inner[i] == quote) return val;
        inner[out] = inner[i];
        i += 1;
        out += 1;
    }
    return inner[0..out];
}

fn lineEnd(buf: []const u8, start: usize) usize {
    return start + (std.mem.indexOfScalar(u8, buf[start..], '\n') orelse buf.len - start);
}

fn trimCr(line: []u8) []u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(line: []u8) []u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    var end = line.len;
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    return line[start..end];
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

test "registry merges layers first-wins and ignores invalid names" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "project", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/.git", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project/skills", .default_dir);
    try tmp.dir.createDir(std.testing.io, "user", .default_dir);

    {
        const file = try tmp.dir.createFile(std.testing.io, "project/skills/zig.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: zig\ndescription: project zig\n---\nproject body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "user/zig.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: zig\ndescription: user zig\n---\nuser body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "user/other.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: other\ndescription: user only\n---\nuser body\n");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, "user/linked.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: linked\ndescription: via symlink\n---\nlinked body\n");
    }
    try tmp.dir.symLink(std.testing.io, "../../user/linked.md", "project/skills/linked.md", .{});
    {
        const file = try tmp.dir.createFile(std.testing.io, "project/skills/Bad_Name.md", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "---\nname: Bad_Name\ndescription: bad\n---\nbad body\n");
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "project", &cwd_buf);
    var user_dir = try tmp.dir.openDir(std.testing.io, "user", .{ .iterate = true });
    defer user_dir.close(std.testing.io);

    var reg = SkillRegistry{};
    defer reg.deinit(std.testing.allocator);
    reg.scan(std.testing.allocator, std.testing.io, user_dir, cwd_buf[0..cwd_len], &.{});

    try std.testing.expectEqual(@as(usize, 3), reg.entries.items.len);
    const zig = reg.find("zig").?;
    try std.testing.expectEqualStrings("project zig", zig.meta.description);
    try std.testing.expect(reg.find("other") != null);
    try std.testing.expectEqualStrings("via symlink", reg.find("linked").?.meta.description);
    try std.testing.expect(reg.find("bad_name") == null);
}
