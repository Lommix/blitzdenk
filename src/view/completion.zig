const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;

const COMMAND_COMPLETION_ROWS = 64;

pub const CommandCompletion = struct {
    text: []const u8,
    description: ?[]const u8 = null,
};

const builtin_command_completions: []const CommandCompletion = &.{
    .{ .text = "/ssh", .description = "connect user@host:cwd" },
    .{ .text = "/mcp connect", .description = "authorize and enable an MCP server" },
    .{ .text = "/mcp cancel", .description = "cancel MCP authorization" },
};

pub fn commandCompletionPrefix(input: []const u8, cursor: usize) []const u8 {
    return input[0..@min(cursor, input.len)];
}

fn commandQueryPrefix(input: []const u8, cursor: usize, query_len: usize, open: bool) []const u8 {
    if (open and query_len > 0 and query_len <= input.len) return input[0..query_len];
    return commandCompletionPrefix(input, cursor);
}

fn containsCommandCompletion(items: []?CommandCompletion, needle: []const u8) bool {
    for (items) |item| {
        const value = item orelse continue;
        if (std.mem.eql(u8, value.text, needle)) return true;
    }
    return false;
}

fn completionMatches(completion: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(completion, prefix) and !std.ascii.eqlIgnoreCase(completion, prefix);
}

pub fn commandTokenActive(input: []const u8, cursor: usize) bool {
    if (input.len == 0) return false;
    const end = @min(@as(usize, cursor), input.len);
    if (end == 0) return false;
    return input[0] == '/';
}

pub fn textWidthCols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn descriptionWidth(description: ?[]const u8) usize {
    const desc = description orelse return 0;
    return textWidthCols(desc);
}

fn appendBuiltinCommandCompletions(prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    for (builtin_command_completions) |completion| {
        if (count.* >= out.len) return;
        if (!completionMatches(completion.text, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], completion.text)) continue;

        out[count.*] = completion;
        count.* += 1;
    }
}

fn appendLuaCommandCompletions(app: *App, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;
    if (!app.lua_vm.vm_mu.tryLock()) return;
    defer app.lua_vm.vm_mu.unlock(app.io);
    app.lua_vm.appendCommandCompletions(prefix, out, count);
}

fn appendSkillCommandCompletions(app: *App, alloc: std.mem.Allocator, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;
    const target = app.mainSkillTarget() orelse return;

    for (app.context_factory.skills.entries.items) |entry| {
        if (count.* >= out.len) return;
        if (!entry.meta.user_invocable) continue;
        if (!r.skills.visibleTo(&entry, target.name, target.is_main, target.filter)) continue;
        const formatted = std.fmt.allocPrint(alloc, "/skill-{s}", .{entry.meta.name}) catch return;
        if (!completionMatches(formatted, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], formatted)) continue;

        out[count.*] = .{ .text = formatted };
        count.* += 1;
    }
}

fn appendSshAliasCompletions(app: *App, alloc: std.mem.Allocator, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (count.* >= out.len) return;

    for (app.context_factory.ssh_aliases.items) |alias| {
        if (count.* >= out.len) return;
        const formatted = std.fmt.allocPrint(alloc, "/ssh-{s}", .{alias.name}) catch return;
        if (!completionMatches(formatted, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], formatted)) continue;

        out[count.*] = .{ .text = formatted };
        count.* += 1;
    }
}

fn appendMcpServerCompletions(app: *App, alloc: std.mem.Allocator, prefix: []const u8, out: []?CommandCompletion, count: *usize) void {
    if (!std.ascii.startsWithIgnoreCase(prefix, "/mcp connect ")) return;
    if (count.* >= out.len) return;
    if (!app.lua_vm.vm_mu.tryLock()) return;
    defer app.lua_vm.vm_mu.unlock(app.io);

    for (app.lua_vm.mcp_entries.items) |entry| {
        if (count.* >= out.len) return;
        const formatted = std.fmt.allocPrint(alloc, "/mcp connect {s}", .{entry.name}) catch return;
        if (!completionMatches(formatted, prefix)) continue;
        if (containsCommandCompletion(out[0..count.*], formatted)) continue;

        out[count.*] = .{ .text = formatted };
        count.* += 1;
    }
}

const CompletionRows = struct {
    items: [COMMAND_COMPLETION_ROWS]CommandCompletion = @splat(.{ .text = "" }),
    len: usize = 0,
};

pub fn commandCompletions(app: *App, alloc: std.mem.Allocator, input: []const u8, cursor: usize) CompletionRows {
    var matches: [COMMAND_COMPLETION_ROWS]?CommandCompletion = @splat(null);
    var count: usize = 0;

    const prefix = switch (app.input_mode) {
        .text => |t| commandQueryPrefix(input, cursor, t.completion_query_len, t.completion_open),
        else => commandCompletionPrefix(input, cursor),
    };
    appendBuiltinCommandCompletions(prefix, &matches, &count);
    appendMcpServerCompletions(app, alloc, prefix, &matches, &count);
    appendLuaCommandCompletions(app, prefix, &matches, &count);
    appendSkillCommandCompletions(app, alloc, prefix, &matches, &count);
    appendSshAliasCompletions(app, alloc, prefix, &matches, &count);

    var rows = CompletionRows{};
    for (matches[0..count]) |item| {
        const value = item orelse continue;
        if (!completionMatches(value.text, prefix)) continue;
        rows.items[rows.len] = value;
        rows.len += 1;
    }
    return rows;
}

pub fn activeCompletions(app: *App, alloc: std.mem.Allocator, input: []const u8, cursor: usize) CompletionRows {
    if (app.pathTokenActive()) return pathCompletions(app, alloc);
    return commandCompletions(app, alloc, input, cursor);
}

pub fn pathCompletions(app: *App, alloc: std.mem.Allocator) CompletionRows {
    var rows = CompletionRows{};

    const parts = app.currentTokenParts() orelse return rows;
    var dir_buf: [1024]u8 = undefined;
    const probe_dir = app.resolveProbeDir(parts.prefix, &dir_buf) orelse return rows;
    const list = app.path_completion.cache.find(probe_dir) orelse return rows;
    if (!list.valid) return rows;

    for (list.entries.items) |entry| {
        if (rows.len >= rows.items.len) break;
        if (parts.filter.len > 0 and !std.ascii.startsWithIgnoreCase(entry.name, parts.filter)) continue;
        const text = std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.prefix, entry.name }) catch break;
        rows.items[rows.len] = .{
            .text = text,
            .description = r.completion.kindDescription(entry.kind),
        };
        rows.len += 1;
    }
    return rows;
}

pub fn insertCompletionToken(self: *App, entry: []const u8) void {
    self.input_desired_col = null;
    if (self.pathTokenActive()) {
        const tok = r.completion.tokenAt(self.input.slice(), self.input.cursor);
        self.input.deleteRange(tok.start, tok.end);
        self.input.cursor = tok.start;
        self.input.insert(entry);
        return;
    }
    const s = self.input.slice();
    const end = std.mem.indexOfScalarPos(u8, s, self.input.cursor, ' ') orelse s.len;
    self.input.deleteRange(0, end);
    self.input.insert(entry);
}
