const std = @import("std");

pub const context = @import("context.zig");
pub const Tool = context.Definition;
pub const ToolContext = context.Context;
pub const ToolCall = r.sdk.ToolCall;
pub const ToolResult = r.sdk.ToolOutput;
pub const bash = @import("bash.zig");
pub const read = @import("read.zig");
pub const ask = @import("ask.zig");
pub const edit = @import("edit.zig");
pub const write = @import("write.zig");
pub const reg = @import("../context_factory.zig");
pub const patch = @import("patch.zig");
pub const r = @import("../root.zig");
pub const tui = r.tui;
pub const search = @import("search.zig");
pub const start = @import("start.zig");
pub const skill = @import("skill.zig");

pub const display = @import("display.zig");
pub const MAX_DISPLAY_BYTES = display.MAX_DISPLAY_BYTES;
pub const MAX_DISPLAY_LINES = display.MAX_DISPLAY_LINES;
pub const MAX_IMAGE_BYTES = display.MAX_IMAGE_BYTES;
pub const MAX_IMAGE_BASE64_BYTES = display.MAX_IMAGE_BASE64_BYTES;
pub const DISPLAY_CAP_TEXT = display.DISPLAY_CAP_TEXT;
pub const STATUS_BUF: usize = 512;

/// Global file mutation lock, it just works!
pub var file_mutex: std.Io.Mutex = .init;

pub fn isHarnessPath(path: []const u8) bool {
    var prefix_buf: [80]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/{d}/", .{ r.util.TMP_DIR, std.c.getpid() }) catch return false;
    return std.mem.startsWith(u8, path, prefix);
}

fn transportLine(line: []const u8) bool {
    const text = std.mem.trim(u8, line, " \t\r");
    return std.mem.startsWith(u8, text, "ssh:") or
        std.mem.startsWith(u8, text, "Warning: Permanently added") or
        std.mem.startsWith(u8, text, "Warning: Identity file") or
        std.mem.startsWith(u8, text, "Host key verification failed") or
        std.mem.startsWith(u8, text, "kex_exchange_identification:") or
        std.mem.indexOf(u8, text, "Permission denied (publickey") != null;
}

pub fn filterTransportStderr(ctx: ToolContext, stderr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.alloc);
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (transportLine(line)) continue;
        if (out.items.len > 0) out.append(ctx.alloc, '\n') catch continue;
        out.appendSlice(ctx.alloc, std.mem.trim(u8, line, " \t\r")) catch continue;
    }
    if (out.items.len == 0) return "";
    return ctx.alloc.dupe(u8, out.items) catch "";
}

pub fn failureDetail(ctx: ToolContext, stderr: []const u8) []const u8 {
    const filtered = filterTransportStderr(ctx, stderr);
    return if (filtered.len == 0) "command failed" else filtered;
}

pub fn execFailure(ctx: ToolContext, action: []const u8, path: []const u8, stderr: []const u8) []const u8 {
    const detail = failureDetail(ctx, stderr);
    return std.fmt.allocPrint(ctx.alloc, "{s} {s}: {s}", .{ action, path, detail }) catch action;
}

pub fn pathFailure(ctx: ToolContext, message: []const u8, path: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}: {s}", .{ message, path }) catch message;
}

pub fn setToolStatusPrint(ctx: ToolContext, call: ToolCall, comptime fmt: []const u8, args: anytype) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var buf: [STATUS_BUF]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    app.setToolStatus(ctx.base.self_id, call.id, w.buffered()) catch return;
}

pub fn setToolStatus(ctx: ToolContext, call: ToolCall, text: []const u8) !void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    try app.setToolStatus(ctx.base.self_id, call.id, text);
}

pub const DiffStat = struct {
    insertions: usize = 0,
    deletions: usize = 0,

    pub fn total(self: DiffStat) usize {
        return self.insertions + self.deletions;
    }
};

pub fn diffStat(before: ?[]const u8, after: []const u8, alloc: std.mem.Allocator) ?DiffStat {
    var stat: DiffStat = .{};
    if (before) |old_text| {
        const old_lines = r.diff.splitLinesAlloc(old_text, alloc) orelse return null;
        const new_lines = r.diff.splitLinesAlloc(after, alloc) orelse return null;
        const ops = r.diff.myersDiff(old_lines, new_lines, alloc) orelse return null;
        for (ops) |op| switch (op) {
            .keep => {},
            .delete => stat.deletions += 1,
            .insert => stat.insertions += 1,
        };
    } else {
        stat.insertions = countLines(after);
    }
    return stat;
}

pub fn appendDiffStat(w: *tui.AnsiWriter, theme: r.app.Theme, stat: DiffStat) void {
    if (stat.total() == 0) {
        w.styledPrint(.{ .fg = theme.muted }, "0 lines", .{});
        return;
    }
    if (stat.insertions > 0)
        w.styledPrint(.{ .modifier = .{ .bold = true }, .fg = theme.diff_add }, "+{d}", .{stat.insertions});
    if (stat.deletions > 0) {
        if (stat.insertions > 0) w.print(" ", .{});
        w.styledPrint(.{ .modifier = .{ .bold = true }, .fg = theme.diff_remove }, "-{d}", .{stat.deletions});
    }
    w.styledPrint(.{ .modifier = .{ .bold = true }, .fg = theme.text_hl }, " lines", .{});
}

pub fn writeToolChangedStatus(
    ctx: ToolContext,
    call: ToolCall,
    tool_name: []const u8,
    before: ?[]const u8,
    after: []const u8,
    path: []const u8,
) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    const stat = diffStat(before, after, ctx.alloc) orelse DiffStat{};

    var buf: [STATUS_BUF]u8 = undefined;
    var w = tui.AnsiWriter.init(&buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, tool_name);
    w.print(" ", .{});

    appendDiffStat(&w, app.theme, stat);

    var rel_buf: [STATUS_BUF]u8 = undefined;
    const rel_path = if (ctx.base.cwd.len > 0)
        replaceAll(path, ctx.base.cwd, ".", &rel_buf)
    else
        path;
    w.print(" ", .{});
    w.styled(.{ .fg = app.theme.muted }, rel_path);

    setToolStatus(ctx, call, w.finish()) catch {};

    if (app.main_agent_id != ctx.base.self_id) return;
    app.queueDiffToHistory(.{ .path = path, .before = before, .after = after }) catch {};
}

pub fn addToolChild(ctx: ToolContext, call: ToolCall, child_id: r.AgentId) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    const owner = ctx.owner(call.id);
    app.addToolChild(owner.agent_id, owner.call_id, child_id) catch {};
}

pub fn markConfigTouched(ctx: ToolContext, resolved: []const u8) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    if (app.lua_config_abs) |abs| {
        if (std.mem.eql(u8, resolved, abs)) {
            app.requestLuaReload();
            ctx.agent().markToolsDirty();
            return;
        }
    }
    if (app.lua_config_dir) |dir| {
        if (r.app.pathInsideDir(resolved, dir)) {
            app.requestLuaReload();
            ctx.agent().markToolsDirty();
        }
    }
}

fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

pub fn atomicWriteViaExec(ctx: ToolContext, resolved: []const u8, content: []const u8) ?r.exec.CmdResult {
    const alloc = ctx.alloc;
    const dir = std.fs.path.dirname(resolved) orelse ".";
    const qdir = shellQuote(alloc, dir) catch return null;
    const qdest = shellQuote(alloc, resolved) catch return null;
    const qtmp = std.fmt.allocPrint(alloc, "{s}.$$.blitztmp", .{qdest}) catch return null;
    const command = std.fmt.allocPrint(
        alloc,
        "mkdir -p {[qdir]s} && {{ [ ! -d {[qdest]s} ] || {{ echo \"write failed: destination is a directory\" >&2; exit 1; }}; }} && cat > {[qtmp]s} && {{ chmod --reference={[qdest]s} {[qtmp]s} 2>/dev/null; mv -f {[qtmp]s} {[qdest]s}; }}",
        .{ .qdir = qdir, .qtmp = qtmp, .qdest = qdest },
    ) catch return null;
    return ctx.base.exec_pool.runAndWait(.{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin_data = content,
    }) catch null;
}

pub fn errResult(_: ToolCall, msg: []const u8) ToolResult {
    return .{
        .content = msg,
        .is_error = true,
    };
}

pub fn okResult(_: ToolCall, content: []const u8) ToolResult {
    return .{
        .content = content,
    };
}

pub fn parseArgs(comptime T: type, alloc: std.mem.Allocator, call: ToolCall) ?T {
    const parsed = std.json.parseFromSlice(T, alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.value;
}

pub fn replaceAll(input: []const u8, needle: []const u8, replacement: []const u8, buffer: []u8) []const u8 {
    if (needle.len == 0) return input;
    const out_len = std.mem.replacementSize(u8, input, needle, replacement);
    if (out_len > buffer.len) return input;
    _ = std.mem.replace(u8, input, needle, replacement, buffer[0..out_len]);
    return buffer[0..out_len];
}

pub const truncateOutputToOwned = display.truncateOutputToOwned;
pub const truncateOutputToOwnedSpill = display.truncateOutputToOwnedSpill;
pub const isOversized = display.isOversized;
pub const writeSpillFile = display.writeSpillFile;
pub const capOutput = display.capOutput;
pub const countLines = display.countLines;
