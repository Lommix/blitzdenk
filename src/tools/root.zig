const std = @import("std");

pub const context = @import("context.zig");
pub const Tool = context.Definition;
pub const ToolContext = context.Context;
pub const ToolCall = r.sdk.ToolCall;
pub const ToolResult = r.sdk.ToolOutput;
pub const bash = @import("bash.zig");
pub const read = @import("read.zig");
pub const ask = @import("ask.zig");
pub const agent = @import("agent.zig");
pub const edit = @import("edit.zig");
pub const write = @import("write.zig");
pub const reg = @import("../context_factory.zig");
pub const patch = @import("patch.zig");
pub const r = @import("../root.zig");
pub const tui = r.tui;
pub const search = @import("search.zig");
pub const start = @import("start.zig");
pub const skill = @import("skill.zig");

pub const MAX_DISPLAY_BYTES = 32 * 1024;
pub const MAX_DISPLAY_LINES = 2000;
pub const DISPLAY_CAP_TEXT = std.fmt.comptimePrint("{d} lines or {d}KB", .{ MAX_DISPLAY_LINES, @divTrunc(MAX_DISPLAY_BYTES, 1024) });
pub const STATUS_BUF: usize = 512;

/// Global file mutation lock, it just works!
pub var file_mutex: std.Io.Mutex = .init;

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
        const old_lines = r.app.splitLinesAlloc(old_text, alloc) orelse return null;
        const new_lines = r.app.splitLinesAlloc(after, alloc) orelse return null;
        const ops = r.app.myersDiff(old_lines, new_lines, alloc) orelse return null;
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

pub fn setToolChild(ctx: ToolContext, call: ToolCall, child_id: r.AgentId) void {
    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    app.setToolChild(ctx.base.self_id, call.id, child_id) catch {};
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
        if (std.mem.startsWith(u8, resolved, dir)) {
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

pub fn truncateOutputToOwned(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
) []const u8 {
    return truncateOutputToOwnedSpill(alloc, output, max_bytes, max_lines, null);
}

/// Truncate `output` to its tail (last `max_lines` lines, last `max_bytes`
/// bytes — whichever binds first), with an optional spill locator embedded in
/// the notice. `spill_locator` points at a file (or null) holding the full output.
pub fn truncateOutputToOwnedSpill(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
    spill_locator: ?[]const u8,
) []const u8 {
    const total_lines = countLines(output);
    if (output.len <= max_bytes and total_lines <= max_lines) return ensureValidUtf8(alloc, output);

    const cut = collectLinesBack(output, max_bytes, max_lines);
    const tail = output[cut.start..];
    const kept = countLines(tail);

    var cap_buf: [64]u8 = undefined;
    const kb = @divTrunc(max_bytes, 1024);
    const cap_text = if (cut.byte_bound and cut.line_bound)
        std.fmt.bufPrint(&cap_buf, "{d}-line and {d}KB caps", .{ max_lines, kb }) catch "caps"
    else if (cut.byte_bound)
        std.fmt.bufPrint(&cap_buf, "{d}KB cap", .{kb}) catch "cap"
    else
        std.fmt.bufPrint(&cap_buf, "{d}-line cap", .{max_lines}) catch "cap";

    const notice = if (spill_locator) |path|
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({s}). Full result saved at: {s} — call read with offset/limit to page through it.]",
            .{ kept, total_lines, cap_text, path },
        ) catch return output
    else
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({s})]",
            .{ kept, total_lines, cap_text },
        ) catch return output;
    defer alloc.free(notice);

    const raw = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ tail, notice }) catch
        return output;
    return ensureValidUtf8(alloc, raw);
}

/// True when `output` would be truncated by the given caps (matches
/// truncateOutputToOwnedSpill's entry condition). Callers gate spill-file
/// writes on this.
pub fn isOversized(output: []const u8, max_bytes: usize, max_lines: usize) bool {
    return output.len > max_bytes or countLines(output) > max_lines;
}

const MAX_SPILL_BYTES: usize = 64 * 1024 * 1024;

pub fn writeSpillFile(pool: *@import("exec").CmdPool, alloc: std.mem.Allocator, call_id: []const u8, content: []const u8) ?[]const u8 {
    const basename = std.fmt.allocPrint(alloc, "blitz-spill-{s}.txt", .{call_id}) catch return null;
    defer alloc.free(basename);
    var cut = content.len -| MAX_SPILL_BYTES;
    while (cut < content.len and (content[cut] & 0xC0) == 0x80) cut += 1;
    return r.artifact.write(pool, alloc, basename, content[cut..]) catch null;
}

/// Collect trailing lines from the end of `output`: the last `max_lines`
/// lines (matching `countLines` semantics), byte-clamped to `max_bytes` from
/// the end, then advanced to a line boundary. `byte_bound` reports whether
/// the byte clamp actually cut the kept tail.
const TailCut = struct { start: usize, line_bound: bool, byte_bound: bool };

fn collectLinesBack(output: []const u8, max_bytes: usize, max_lines: usize) TailCut {
    const total = countLines(output);
    const line_bound = total > max_lines;
    var line_start: usize = 0;
    if (line_bound) {
        const target_line = total - max_lines; // 0-based index of first kept line
        var line_idx: usize = 0;
        var i: usize = 0;
        while (i < output.len and line_idx < target_line) : (i += 1) {
            if (output[i] == '\n') {
                line_idx += 1;
                line_start = i + 1;
            }
        }
    }
    if (output.len - line_start <= max_bytes)
        return .{ .start = line_start, .line_bound = line_bound, .byte_bound = false };
    var tail_start = utf8Floor(output, output.len - max_bytes);
    if (tail_start == 0 or output[tail_start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, output, tail_start, '\n')) |nl| {
            tail_start = nl + 1;
        } else {
            tail_start = output.len;
        }
    }
    if (tail_start < line_start) tail_start = line_start;
    return .{ .start = tail_start, .line_bound = line_bound, .byte_bound = true };
}

/// Walk end back so it never splits a multi-byte UTF-8 sequence.
fn utf8Floor(s: []const u8, end: usize) usize {
    var i = @min(end, s.len);
    if (i == s.len) return i;
    while (i > 0 and (s[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Return `raw` if already valid UTF-8; otherwise owned lossy copy (U+FFFD).
fn ensureValidUtf8(alloc: std.mem.Allocator, raw: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    return std.fmt.allocPrint(alloc, "{f}", .{std.unicode.fmtUtf8(raw)}) catch
        "(binary output; failed to sanitize utf-8)";
}

pub fn countLines(output: []const u8) usize {
    var lines: usize = 0;
    var pos: usize = 0;
    while (pos < output.len) {
        lines += 1;
        if (std.mem.indexOfScalar(u8, output[pos..], '\n')) |nl| {
            pos += nl + 1;
        } else {
            break;
        }
    }
    return lines;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "truncateOutputToOwned keeps valid utf8 as string payload" {
    const testing = std.testing;
    const in = "hello\nworld";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    try testing.expectEqualStrings(in, out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "truncateOutputToOwned sanitizes invalid utf8" {
    const testing = std.testing;
    // 0xFF is never valid UTF-8 lead/cont — classic binary command output.
    const in = "ok\xffnope";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    // Must serialize as a JSON string, never a byte array.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(out, .{}, &w);
    const json = w.buffered();
    try testing.expect(json.len >= 2 and json[0] == '"');
    try testing.expect(json[json.len - 1] == '"');
}

test "truncateOutputToOwned keeps the tail for oversized output" {
    const testing = std.testing;
    // 100 lines of "line N\n"; a small budget forces a tail-only cut.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "line{d}\n", .{i});
        defer testing.allocator.free(line);
        try buf.appendSlice(testing.allocator, line);
    }
    const out = truncateOutputToOwned(testing.allocator, buf.items, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES);
    defer if (out.ptr != buf.items.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    // The final line "line99" must survive as the tail.
    try testing.expect(std.mem.indexOf(u8, out, "line99") != null);
}

test "truncateOutputToOwned drops the head and keeps the tail on line cap" {
    const testing = std.testing;
    const in = "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\n";
    const out = truncateOutputToOwned(testing.allocator, in, MAX_DISPLAY_BYTES, 2);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "EEEE\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "AAAA") == null);
}

test "collectLinesBack is codepoint-safe at the byte boundary" {
    const testing = std.testing;
    // "é" is c3 a9; cutting at a byte count that lands mid-sequence must floor.
    const in = "ab\xc3\xa9cd\nef\xc3\xa9gh\n";
    const cut = collectLinesBack(in, 4, 100);
    try testing.expect(std.unicode.utf8ValidateSlice(in[cut.start..]));
}

test "collectLinesBack handles a cut inside the first codepoint" {
    const testing = std.testing;
    const in = "\xc3\xa9x";
    const cut = collectLinesBack(in, 2, 100);
    try testing.expect(cut.byte_bound);
    try testing.expect(std.unicode.utf8ValidateSlice(in[cut.start..]));
}

test "truncateOutputToOwned notice names the cap that fired" {
    const testing = std.testing;
    const line_only = "A\nB\nC\nD\nE\n";
    const out = truncateOutputToOwned(testing.allocator, line_only, MAX_DISPLAY_BYTES, 2);
    defer if (out.ptr != line_only.ptr) testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "2-line cap") != null);
    try testing.expect(std.mem.indexOf(u8, out, "KB cap") == null);

    const bytes_only = "x" ** 5000;
    const out2 = truncateOutputToOwned(testing.allocator, bytes_only, 4096, MAX_DISPLAY_LINES);
    defer if (out2.ptr != bytes_only.ptr) testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "4KB cap") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "-line cap") == null);
}

test "collectLinesBack skips a partial line at the byte boundary" {
    const testing = std.testing;
    const in = "xxxxxxxxxx\nBB\n";
    const cut = collectLinesBack(in, 5, 100);
    try testing.expect(cut.start == 0 or in[cut.start - 1] == '\n');
    try testing.expectEqualStrings("BB\n", in[cut.start..]);
}

test "truncateOutputToOwned does not split multi-byte utf8" {
    const testing = std.testing;
    // "é" is c3 a9 — cut max_bytes inside the sequence.
    const in = "ab\xc3\xa9cd";
    const out = truncateOutputToOwned(testing.allocator, in, 3, MAX_DISPLAY_LINES);
    defer if (out.ptr != in.ptr) testing.allocator.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "writeSpillFile persists a small payload and sanitizes the call id" {
    const testing = std.testing;
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = @import("exec").CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    const payload = "hello spill\n";
    const path = writeSpillFile(&pool, testing.allocator, "b.a/d/1", payload).?;
    defer testing.allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const content = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited64(1024)) catch
        return error.TestUnexpectedResult;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(payload, content);

    const base = std.fs.path.basename(path);
    try testing.expect(std.mem.indexOf(u8, base, "/") == null);
    try testing.expect(std.mem.eql(u8, base, "blitz-spill-b.a_d_1.txt"));
}
