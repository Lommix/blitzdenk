const r = @import("root.zig");
const std = @import("std");

pub const MAX_EDIT_SIZE: u32 = 1024 * 1024 * 4;

pub const EditTool = r.Tool{
    .def = .{
        .name = "edit",
        .description =
        \\Edit a single file using text replacement.
        \\Every old_string must match a unique, non-overlapping region of the original file.
        \\If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits.
        \\Do not include large unchanged regions just to connect distant changes.
        \\
        ,
        .prompt_snippet = "Edit a single file using text replacement",
        .prompt_guidelines = "Always prefer edit over bash for editing files",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "file_path": {"type": "string", "description": "The absolute path to the file to modify"},
        \\      "old_string": {"type": "string", "description": "The text to replace"},
        \\      "new_string": {"type": "string", "description": "The text to replace it with (must be different from old_string)"},
        \\      "replace_all": {"type": "boolean", "default": false, "description": "Replace all occurrences of old_string (default false)"}
        \\  },
        \\  "required": ["file_path", "old_string", "new_string"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const alloc = ctx.alloc;
    const Args = struct {
        file_path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
        replace_all: bool = false,
    };

    r.setToolStatusPrint(ctx, call, "edit", .{});

    const args = (std.json.parseFromSlice(Args, alloc, call.input, .{ .ignore_unknown_fields = true }) catch {
        std.log.err("ARGs ERROR: {s}", .{call.input});
        return r.errResult(call,
            \\invalid JSON arguments, expected `{"file_path": "...", "old_string": "...", "new_string": "...", "replace_all": ...}`
        );
    }).value;

    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var tool_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&tool_buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "edit ");
    w.styledPrint(.{ .fg = app.theme.muted }, "{s}", .{args.file_path});
    r.setToolStatus(ctx, call, w.finish()) catch {};

    if (args.file_path.len == 0) return r.errResult(call, "path is empty");
    if (args.old_string.len == 0) return r.errResult(call, "old_string is empty");

    const resolved = std.fs.path.resolve(alloc, &.{ ctx.base.cwd, args.file_path }) catch
        return r.errResult(call, "failed to resolve path");

    if (std.mem.eql(u8, args.old_string, args.new_string)) {
        return r.errResult(call, "No changes to make: old_string and new_string are exactly the same.");
    }

    r.file_mutex.lock(ctx.io) catch {
        if (ctx.isCanceled()) return r.errResult(call, "canceled while waiting for the file lock");
        return r.errResult(call, "failed to lock file");
    };
    defer r.file_mutex.unlock(ctx.io);

    const read_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "cat", resolved } }) catch
        return r.errResult(call, "failed to read file");
    defer ctx.base.exec_pool.alloc.free(read_res.stdout);
    defer ctx.base.exec_pool.alloc.free(read_res.stderr);

    if (read_res.ty != .success) {
        return r.errResult(call, "invalid file");
    }

    if (read_res.stdout.len > MAX_EDIT_SIZE) {
        return r.errResult(call, "file exceeds the 4MB edit limit");
    }

    const file_content = alloc.dupe(u8, read_res.stdout) catch return r.errResult(call, "oom");

    const replacement = buildReplacement(alloc, file_content, args.old_string, args.new_string, args.replace_all) catch |err| switch (err) {
        error.Ambiguous => {
            const msg = if (args.replace_all)
                \\Matched regions overlap; repeated adjacent regions cannot be replaced as separate occurrences.
                \\Merge the repeated region into one larger edit.
            else
                \\Found multiple matches of the string to replace, but replace_all is false.
                \\To replace only one occurrence, please provide more context to uniquely identify the instance.
            ;
            return r.errResult(call, msg);
        },
        error.OutOfMemory => return r.errResult(call, "out of memory"),
    };
    if (replacement == null) {
        if (std.mem.indexOf(u8, file_content, args.new_string) != null) {
            return r.errResult(call, "edit already applied: new_string is already present in the file; verify the file state instead of retrying the same edit");
        }
        const diag = diagnoseMismatch(alloc, file_content, args.old_string);
        return r.errResult(call, diag);
    }
    const new_content = replacement.?;

    const decision = ctx.requestPermission(call, .{ .diff = .{
        .before = file_content,
        .after = new_content,
        .path = args.file_path,
    } });
    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined edit"),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(
                alloc,
                "User declined the edit and left feedback: {s}",
                .{txt},
            ) catch txt;
            return r.errResult(call, wrapped);
        },
        else => return r.errResult(call, "permission unresolved"),
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    const verify_res = ctx.base.exec_pool.runAndWait(.{ .argv = &.{ "cat", resolved } }) catch
        return r.errResult(call, "failed to re-read file");
    defer ctx.base.exec_pool.alloc.free(verify_res.stdout);
    defer ctx.base.exec_pool.alloc.free(verify_res.stderr);

    if (verify_res.ty != .success or !std.mem.eql(u8, verify_res.stdout, file_content)) {
        return r.errResult(call, "file changed on disk while the edit was pending; re-read the file and retry");
    }

    const write_res = r.atomicWriteViaExec(ctx, resolved, new_content) orelse
        return r.errResult(call, "failed to start process");
    defer ctx.base.exec_pool.alloc.free(write_res.stdout);
    defer ctx.base.exec_pool.alloc.free(write_res.stderr);

    if (write_res.ty != .success) {
        const msg = if (write_res.stderr.len > 0)
            alloc.dupe(u8, write_res.stderr) catch "write failed"
        else
            "write failed";
        return r.errResult(call, msg);
    }

    r.markConfigTouched(ctx, resolved);

    r.writeToolChangedStatus(ctx, call, "edit", file_content, new_content, args.file_path);

    return r.okResult(call, std.fmt.allocPrint(alloc, "edit applied to {s}", .{args.file_path}) catch "edit applied successfully");
}

fn buildReplacement(
    alloc: std.mem.Allocator,
    file_content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    const newline_count = std.mem.count(u8, file_content, "\n");
    const crlf_count = std.mem.count(u8, file_content, "\r\n");
    const consistent_crlf = newline_count == crlf_count;

    const exact_new = if (consistent_crlf and
        std.mem.indexOfScalar(u8, new_string, '\n') != null and
        std.mem.indexOfScalar(u8, new_string, '\r') == null)
        try denormalizeLineEndings(alloc, new_string, true)
    else
        new_string;

    if (try exactReplace(alloc, file_content, old_string, exact_new, replace_all)) |content| {
        return content;
    }

    const normalize = consistent_crlf and std.mem.indexOfScalar(u8, file_content, '\r') != null;
    const file_lf = if (normalize) try normalizeLineEndings(alloc, file_content) else file_content;
    const old_lf = if (normalize) try normalizeLineEndings(alloc, old_string) else old_string;
    const new_lf = if (normalize) try normalizeLineEndings(alloc, new_string) else new_string;

    if (!std.mem.eql(u8, file_lf, file_content) or
        !std.mem.eql(u8, old_lf, old_string) or
        !std.mem.eql(u8, new_lf, new_string))
    {
        if (try exactReplace(alloc, file_lf, old_lf, new_lf, replace_all)) |content_lf| {
            return try denormalizeLineEndings(alloc, content_lf, normalize);
        }
    }

    return null;
}

fn exactReplace(
    alloc: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    if (old_string.len == 0) return null;
    const matches = std.mem.count(u8, content, old_string);
    if (matches == 0) return null;
    if (matches > 1 and !replace_all) return error.Ambiguous;

    const new_size = std.mem.replacementSize(u8, content, old_string, new_string);
    const new_content = try alloc.alloc(u8, new_size);
    _ = std.mem.replace(u8, content, old_string, new_string, new_content);
    return new_content;
}

fn normalizeLineEndings(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                try out.append(alloc, '\n');
                i += 1;
            } else {
                try out.append(alloc, '\n');
            }
        } else {
            try out.append(alloc, s[i]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn denormalizeLineEndings(alloc: std.mem.Allocator, s: []const u8, crlf: bool) ![]const u8 {
    if (!crlf) return s;
    const extra = std.mem.count(u8, s, "\n");
    const out = try alloc.alloc(u8, s.len + extra);
    var j: usize = 0;
    for (s) |c| {
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

/// Build a diagnostic message when oldText is not found in file_content.
/// Detects common causes: read-tool line-number prefix copied in, CRLF mismatch,
/// trailing-newline mismatch, whitespace-only mismatch, and reports the closest
/// near-match line so the agent can correct without blind retries.
fn diagnoseMismatch(alloc: std.mem.Allocator, file_content: []const u8, oldText: []const u8) []const u8 {
    const preview_len = @min(oldText.len, 80);
    const head = std.fmt.allocPrint(alloc, "old_string not found in file. Your old_string: \"{s}\"", .{oldText[0..preview_len]}) catch return "old_string not found";

    // Detect line-number prefix copied from read-tool output.
    // Read tool emits `<spaces>N\t<content>`. If oldText starts with that pattern,
    // the agent likely pasted display output verbatim.
    if (looksLikeLineNumberPrefix(oldText)) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: old_string starts with a line-number prefix (`<spaces>N<TAB>`) from the read tool's display format. Strip the prefix from every line — the file does not contain those characters.", .{head}) catch head;
    }

    // Detect CRLF mismatch.
    const file_has_crlf = std.mem.indexOf(u8, file_content, "\r\n") != null;
    const old_has_crlf = std.mem.indexOf(u8, oldText, "\r\n") != null;
    if (file_has_crlf and !old_has_crlf and std.mem.indexOf(u8, oldText, "\n") != null) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: file uses CRLF line endings but old_string uses LF.", .{head}) catch head;
    }
    if (!file_has_crlf and old_has_crlf) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: old_string uses CRLF line endings but file uses LF. Use \\n only.", .{head}) catch head;
    }

    // Trailing-newline mismatch: oldText ends in \n but matches EOF region without final newline.
    if (oldText.len > 0 and oldText[oldText.len - 1] == '\n') {
        if (file_content.len > 0 and file_content[file_content.len - 1] != '\n') {
            const stripped = oldText[0 .. oldText.len - 1];
            if (std.mem.endsWith(u8, file_content, stripped)) {
                return std.fmt.allocPrint(alloc, "{s}. HINT: oldText ends with a trailing newline but the matching region is at EOF and the file has no final newline. Drop the trailing \\n from oldText.", .{head}) catch head;
            }
        }
    }

    // Whitespace-normalised match -> tabs vs spaces or extra/missing whitespace.
    if (whitespaceNormalisedMatch(file_content, oldText)) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: oldText matches when whitespace is normalised — likely tabs-vs-spaces or extra/missing indentation. Re-read the file and copy bytes exactly (the read tool preserves tabs).", .{head}) catch head;
    }

    // Near-match: find the longest prefix of oldText that occurs in file.
    if (oldText.len >= 16) {
        var prefix_len: usize = @min(oldText.len, 128);
        while (prefix_len >= 16) : (prefix_len -= 1) {
            if (std.mem.indexOf(u8, file_content, oldText[0..prefix_len])) |idx| {
                const line_no = countLinesUpTo(file_content, idx) + 1;
                return std.fmt.allocPrint(alloc, "{s}. HINT: only the first {d} bytes of oldText match (around line {d}). The mismatch starts there — re-read that region and copy exactly.", .{ head, prefix_len, line_no }) catch head;
            }
        }
    }

    return head;
}

fn looksLikeLineNumberPrefix(s: []const u8) bool {
    // Pattern: optional leading spaces, one or more digits, then a tab.
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    const digits_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == digits_start) return false;
    return i < s.len and s[i] == '\t';
}

fn whitespaceNormalisedMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > 4096) return false;
    var hay_buf: [8192]u8 = undefined;
    var needle_buf: [8192]u8 = undefined;
    var fba_hay = std.heap.FixedBufferAllocator.init(&hay_buf);
    var fba_needle = std.heap.FixedBufferAllocator.init(&needle_buf);
    const nh = normaliseWs(fba_hay.allocator(), haystack) catch return false;
    const nn = normaliseWs(fba_needle.allocator(), needle) catch return false;
    return std.mem.indexOf(u8, nh, nn) != null;
}

fn normaliseWs(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_ws = false;
    for (s) |c| {
        if (c == ' ' or c == '\t') {
            if (!prev_ws) try out.append(a, ' ');
            prev_ws = true;
        } else {
            try out.append(a, c);
            prev_ws = false;
        }
    }
    return out.toOwnedSlice(a);
}

fn countLinesUpTo(s: []const u8, idx: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < idx and i < s.len) : (i += 1) {
        if (s[i] == '\n') n += 1;
    }
    return n;
}

const testing = std.testing;

test "mixed line endings require exact bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try buildReplacement(arena.allocator(), "a\r\nb\nc\nd\n", "a\nb", "A\nB", false);
    try testing.expect(res == null);
}

test "consistent CRLF file still denormalizes fallback path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try buildReplacement(arena.allocator(), "a\r\nb\r\n", "a\nb", "A\nB", false);
    try testing.expectEqualStrings("A\r\nB\r\n", res.?);
}

test "exact path converts LF new_string on consistent CRLF file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try buildReplacement(arena.allocator(), "a\r\nb\r\n", "a\r\nb", "A\nB", false);
    try testing.expectEqualStrings("A\r\nB\r\n", res.?);
}

test "whitespaceNormalisedMatch rejects unrelated needle" {
    try testing.expect(!whitespaceNormalisedMatch("const alpha = 1;\nfn main() {}\n", "zzzz_unrelated_qq"));
}

test "whitespaceNormalisedMatch accepts real whitespace variant" {
    try testing.expect(whitespaceNormalisedMatch("let  x  =  1;\n", "let x = 1;"));
}
