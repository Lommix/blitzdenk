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

/// Read `path` whole into `ctx.alloc`. Null when it does not exist;
/// `error.StreamTooLong` when it holds more than `cap` bytes.
pub fn readFileCapped(ctx: ToolContext, path: []const u8, cap: usize) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(cap + 1)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Replace `path` with `content` through a temp file and rename. Creates
/// missing parent directories and keeps the mode of an existing file.
pub fn atomicWrite(io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var permissions: std.Io.File.Permissions = .default_file;
    if (cwd.statFile(io, path, .{})) |st| {
        if (st.kind == .directory) return error.IsDir;
        permissions = st.permissions;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var atomic = try cwd.createFileAtomic(io, path, .{ .permissions = permissions, .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, content);
    try atomic.file.setPermissions(io, permissions);
    try atomic.replace(io);
}

pub fn fsFailure(ctx: ToolContext, action: []const u8, path: []const u8, err: anyerror) []const u8 {
    const detail = switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.NoSpaceLeft => "no space left on device",
        error.ReadOnlyFileSystem => "read-only file system",
        error.FileTooBig, error.StreamTooLong => "file too large",
        error.NameTooLong => "name too long",
        error.SymLinkLoop => "too many levels of symbolic links",
        else => @errorName(err),
    };
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

/// Parse tool-call JSON into `T` on the call arena; unknown fields are ignored.
pub fn parseArgs(comptime T: type, ctx: ToolContext, call: ToolCall) ?T {
    return std.json.parseFromSliceLeaky(T, ctx.alloc, call.input, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn toCrlf(alloc: std.mem.Allocator, lf_text: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, lf_text.len + std.mem.count(u8, lf_text, "\n"));
    var j: usize = 0;
    for (lf_text) |c| {
        if (c == '\n') {
            out[j] = '\r';
            out[j + 1] = '\n';
            j += 2;
        } else {
            out[j] = c;
            j += 1;
        }
    }
    return out;
}

pub fn permissionDenied(
    ctx: ToolContext,
    call: ToolCall,
    decision: r.permissions.State,
    comptime tool: []const u8,
    comptime feedback_subject: []const u8,
) ?ToolResult {
    return switch (decision) {
        .approved => null,
        .denied => errResult(call, "User declined " ++ tool ++ ". Change the approach or ask the user before retrying."),
        .message => |txt| errResult(call, std.fmt.allocPrint(
            ctx.alloc,
            "User declined " ++ feedback_subject ++ " and left feedback: {s}\nChange the approach or ask the user before retrying.",
            .{txt},
        ) catch txt),
        else => errResult(call, "permission unresolved"),
    };
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

test "atomicWrite creates parents, keeps the mode, and rejects directories" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const ctx: ToolContext = .{ .alloc = testing.allocator, .io = io, .base = undefined };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&buf, "{s}/a/b/c.txt", .{root});
    try atomicWrite(io, nested, "first");
    const first = (try readFileCapped(ctx, nested, 64)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first", first);

    try tmp.dir.writeFile(io, .{ .sub_path = "run.sh", .data = "old", .flags = .{ .permissions = .fromMode(0o755) } });
    var run_buf: [std.fs.max_path_bytes]u8 = undefined;
    const run = try std.fmt.bufPrint(&run_buf, "{s}/run.sh", .{root});
    try atomicWrite(io, run, "new");
    const st = try tmp.dir.statFile(io, "run.sh", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);

    try testing.expectError(error.IsDir, atomicWrite(io, root, "x"));
    try testing.expectError(error.StreamTooLong, readFileCapped(ctx, run, 2));
    try testing.expectEqual(null, try readFileCapped(ctx, "/nonexistent/blitz/file", 8));
}
