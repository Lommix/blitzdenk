const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

// 4MB file edit limit
pub const MAX_EDIT_SIZE: u32 = 1024 * 1024 * 4;

pub const EditTool = prv.tool.Tool{
    .def = .{
        .name = "edit",
        .description =
        \\Edit a single file using text replacement. Prefer exact oldText; the tool can tolerate line-ending, indentation, escaped-newline, and whitespace mismatches when the target remains unique.
        \\Every oldText must match a unique, non-overlapping region of the original file.
        \\If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits.
        \\Do not include large unchanged regions just to connect distant changes.
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "The absolute path to the file to modify"},
        \\      "old_string": {"type": "string", "description": "The text to replace"},
        \\      "new_string": {"type": "string", "description": "The text to replace it with (must be different from old_string)"},
        \\      "replace_all": {"type": "boolean", "default": false, "description": "Replace all occurrences of old_string (default false)"}
        \\  },
        \\  "required": ["path", "old_string", "new_string"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const alloc = ctx.alloc;
    const Args = struct {
        path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
        replace_all: bool = false,
    };

    r.setToolStatusPrint(ctx, call, "edit", .{});

    const args = (std.json.parseFromSlice(Args, alloc, call.arguments, .{ .ignore_unknown_fields = true }) catch {
        std.log.err("ARGs ERROR: {s}", .{call.arguments});
        return r.errResult(call,
            \\invalid JSON arguments, expected `{"path": "...", "old_string": "...", "new_string": "...", "replace_all": ...}`
        );
    }).value;

    r.setToolStatusPrint(ctx, call, "edit {s}", .{args.path});

    if (args.path.len == 0) return r.errResult(call, "path is empty");
    if (args.old_string.len == 0) return r.errResult(call, "oldText is empty");

    const resolved = std.fs.path.resolve(alloc, &.{ ctx.cwd, args.path }) catch
        return r.errResult(call, "failed to resolve path");

    if (std.mem.eql(u8, args.old_string, args.new_string)) {
        return r.errResult(call, "No changes to make: old_string and new_string are exactly the same.");
    }

    const g = ctx.agent().file_stats.lock(ctx.io);
    defer g.unlock();

    if (g.ptr.get(resolved) == null) {
        return r.errResult(call, "File has not been read yet. Read it first before writing to it.");
    }

    // Read current content.
    const read_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "cat", resolved } }) catch
        return r.errResult(call, "failed to read file");
    defer ctx.swarm.exec.alloc.free(read_res.stdout);
    defer ctx.swarm.exec.alloc.free(read_res.stderr);

    if (read_res.ty != .success) {
        const msg = if (read_res.stderr.len > 0)
            alloc.dupe(u8, read_res.stderr) catch "cannot read file"
        else
            "cannot read file";
        return r.errResult(call, msg);
    }

    const file_content = alloc.dupe(u8, read_res.stdout) catch return r.errResult(call, "oom");

    const replacement = buildReplacement(alloc, file_content, args.old_string, args.new_string, args.replace_all) catch |err| switch (err) {
        error.Ambiguous => return r.errResult(call,
            \\Found multiple matches of the string to replace, but replace_all is false.
            \\To replace only one occurrence, please provide more context to uniquely identify the instance.
        ),
        error.OutOfMemory => return r.errResult(call, "out of memory"),
    };
    if (replacement == null) {
        const diag = diagnoseMismatch(alloc, file_content, args.old_string);
        return r.errResult(call, diag);
    }
    const new_content = replacement.?;

    const decision = ctx.requestPerm(call.id, .always_check, .{ .diff = .{
        .before = file_content,
        .after = new_content,
        .path = args.path,
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

    const write_res = ctx.swarm.exec.runAndWait(.{
        .argv = &.{ "tee", resolved },
        .stdin_data = new_content,
    }) catch return r.errResult(call, "failed to start process");
    defer ctx.swarm.exec.alloc.free(write_res.stdout);
    defer ctx.swarm.exec.alloc.free(write_res.stderr);

    if (write_res.ty != .success) {
        const msg = if (write_res.stderr.len > 0)
            alloc.dupe(u8, write_res.stderr) catch "write failed"
        else
            "write failed";
        return r.errResult(call, msg);
    }

    return r.okResult(call, std.fmt.allocPrint(alloc, "edit applied to {s}", .{args.path}) catch "edit applied successfully");
}

fn buildReplacement(
    alloc: std.mem.Allocator,
    file_content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    if (try exactReplace(alloc, file_content, old_string, new_string, replace_all)) |content| {
        return content;
    }

    const native_crlf = std.mem.indexOf(u8, file_content, "\r\n") != null;
    const file_lf = try normalizeLineEndings(alloc, file_content);
    const old_lf = try normalizeLineEndings(alloc, old_string);
    const new_lf = try normalizeLineEndings(alloc, new_string);

    if (!std.mem.eql(u8, file_lf, file_content) or
        !std.mem.eql(u8, old_lf, old_string) or
        !std.mem.eql(u8, new_lf, new_string))
    {
        if (try exactReplace(alloc, file_lf, old_lf, new_lf, replace_all)) |content_lf| {
            return try denormalizeLineEndings(alloc, content_lf, native_crlf);
        }
    }

    if (try unescapeCommon(alloc, old_lf)) |unescaped_old| {
        if (!std.mem.eql(u8, unescaped_old, old_lf)) {
            if (try exactReplace(alloc, file_lf, unescaped_old, new_lf, replace_all)) |content_lf| {
                return try denormalizeLineEndings(alloc, content_lf, native_crlf);
            }
        }
    }

    const trimmed_old = trimBoundary(old_lf);
    if (trimmed_old.len != old_lf.len) {
        if (try exactReplace(alloc, file_lf, trimmed_old, new_lf, replace_all)) |content_lf| {
            return try denormalizeLineEndings(alloc, content_lf, native_crlf);
        }
    }

    if (try lineTrimmedReplace(alloc, file_lf, old_lf, new_lf, replace_all)) |content_lf| {
        return try denormalizeLineEndings(alloc, content_lf, native_crlf);
    }

    if (try indentationFlexibleReplace(alloc, file_lf, old_lf, new_lf, replace_all)) |content_lf| {
        return try denormalizeLineEndings(alloc, content_lf, native_crlf);
    }

    if (try whitespaceNormalizedReplace(alloc, file_lf, old_lf, new_lf, replace_all)) |content_lf| {
        return try denormalizeLineEndings(alloc, content_lf, native_crlf);
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

fn unescapeCommon(alloc: std.mem.Allocator, s: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(alloc, s[i]);
            continue;
        }
        i += 1;
        try out.append(alloc, switch (s[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            else => |c| c,
        });
    }
    return try out.toOwnedSlice(alloc);
}

fn trimBoundary(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

const Range = struct {
    start: usize,
    end: usize,
};

const Line = struct {
    start: usize,
    text_end: usize,
    end: usize,
    text: []const u8,
};

fn lineAt(s: []const u8, start: usize) Line {
    var i = start;
    while (i < s.len and s[i] != '\n') : (i += 1) {}
    const end = if (i < s.len) i + 1 else i;
    return .{ .start = start, .text_end = i, .end = end, .text = s[start..i] };
}

fn nextLineStart(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    const line = lineAt(s, start);
    if (line.end >= s.len) return null;
    return line.end;
}

fn patternLineCount(s: []const u8) usize {
    if (s.len == 0) return 0;
    const nl = std.mem.count(u8, s, "\n");
    return if (s[s.len - 1] == '\n') nl else nl + 1;
}

fn patternLine(s: []const u8, line_index: usize) []const u8 {
    var start: usize = 0;
    var idx: usize = 0;
    while (idx < line_index) : (idx += 1) {
        const nl = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
        start = @min(nl + 1, s.len);
    }
    const end = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
    return s[start..end];
}

fn lineTrimmedReplace(
    alloc: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    return lineWindowReplace(alloc, content, old_string, new_string, replace_all, lineTrimmedEqual);
}

fn indentationFlexibleReplace(
    alloc: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    return lineWindowReplace(alloc, content, old_string, new_string, replace_all, indentationFlexibleEqual);
}

fn lineWindowReplace(
    alloc: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
    comptime equal: fn ([]const u8, []const u8) bool,
) !?[]const u8 {
    const line_count = patternLineCount(old_string);
    if (line_count == 0 or line_count > 128) return null;

    var ranges: std.ArrayList(Range) = .empty;
    var start_opt: ?usize = if (content.len == 0) null else 0;
    while (start_opt) |start| {
        var cursor = start;
        var matched = true;
        var last: Line = undefined;
        var i: usize = 0;
        while (i < line_count) : (i += 1) {
            if (cursor > content.len) {
                matched = false;
                break;
            }
            const candidate = lineAt(content, cursor);
            last = candidate;
            if (!equal(candidate.text, patternLine(old_string, i))) {
                matched = false;
                break;
            }
            cursor = candidate.end;
            if (i + 1 < line_count and cursor >= content.len) {
                matched = false;
                break;
            }
        }
        if (matched) {
            const old_ends_newline = old_string.len > 0 and old_string[old_string.len - 1] == '\n';
            try ranges.append(alloc, .{ .start = start, .end = if (old_ends_newline) last.end else last.text_end });
        }
        start_opt = nextLineStart(content, start);
    }

    if (ranges.items.len == 0) return null;
    if (ranges.items.len > 1 and !replace_all) return error.Ambiguous;
    return try applyRanges(alloc, content, ranges.items, new_string);
}

fn lineTrimmedEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, a, " \t"), std.mem.trim(u8, b, " \t"));
}

fn indentationFlexibleEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripIndent(a), stripIndent(b));
}

fn stripIndent(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

const Normalized = struct {
    text: []const u8,
    map: []const usize,
};

fn whitespaceNormalizedReplace(
    alloc: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) !?[]const u8 {
    if (old_string.len > 4096) return null;

    const hay = try normalizeWhitespaceWithMap(alloc, content);
    const needle = try normalizeWhitespaceOnly(alloc, old_string);
    if (needle.len == 0) return null;

    var ranges: std.ArrayList(Range) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay.text, pos, needle)) |idx| {
        const end_idx = idx + needle.len - 1;
        try ranges.append(alloc, .{ .start = hay.map[idx], .end = hay.map[end_idx] + 1 });
        pos = idx + needle.len;
    }

    if (ranges.items.len == 0) return null;
    if (ranges.items.len > 1 and !replace_all) return error.Ambiguous;
    return try applyRanges(alloc, content, ranges.items, new_string);
}

fn normalizeWhitespaceOnly(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_ws = true;
    for (s) |c| {
        if (isFuzzyWhitespace(c)) {
            if (!prev_ws) try out.append(alloc, ' ');
            prev_ws = true;
        } else {
            try out.append(alloc, c);
            prev_ws = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

fn normalizeWhitespaceWithMap(alloc: std.mem.Allocator, s: []const u8) !Normalized {
    var text: std.ArrayList(u8) = .empty;
    var map: std.ArrayList(usize) = .empty;
    var prev_ws = true;
    for (s, 0..) |c, i| {
        if (isFuzzyWhitespace(c)) {
            if (!prev_ws) {
                try text.append(alloc, ' ');
                try map.append(alloc, i);
            }
            prev_ws = true;
        } else {
            try text.append(alloc, c);
            try map.append(alloc, i);
            prev_ws = false;
        }
    }
    if (text.items.len > 0 and text.items[text.items.len - 1] == ' ') {
        _ = text.pop();
        _ = map.pop();
    }
    return .{ .text = try text.toOwnedSlice(alloc), .map = try map.toOwnedSlice(alloc) };
}

fn isFuzzyWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn applyRanges(
    alloc: std.mem.Allocator,
    content: []const u8,
    ranges: []const Range,
    new_string: []const u8,
) ![]const u8 {
    var new_size = content.len;
    for (ranges) |range| {
        new_size = new_size - (range.end - range.start) + new_string.len;
    }

    const out = try alloc.alloc(u8, new_size);
    var src: usize = 0;
    var dst: usize = 0;
    for (ranges) |range| {
        if (range.start < src) return error.Ambiguous;
        @memcpy(out[dst .. dst + (range.start - src)], content[src..range.start]);
        dst += range.start - src;
        @memcpy(out[dst .. dst + new_string.len], new_string);
        dst += new_string.len;
        src = range.end;
    }
    @memcpy(out[dst .. dst + (content.len - src)], content[src..]);
    return out;
}

/// Build a diagnostic message when oldText is not found in file_content.
/// Detects common causes: read-tool line-number prefix copied in, CRLF mismatch,
/// trailing-newline mismatch, whitespace-only mismatch, and reports the closest
/// near-match line so the agent can correct without blind retries.
fn diagnoseMismatch(alloc: std.mem.Allocator, file_content: []const u8, oldText: []const u8) []const u8 {
    const preview_len = @min(oldText.len, 80);
    const head = std.fmt.allocPrint(alloc, "oldText not found in file. Preview: \"{s}\"", .{oldText[0..preview_len]}) catch return "oldText not found";

    // Detect line-number prefix copied from read-tool output.
    // Read tool emits `<spaces>N\t<content>`. If oldText starts with that pattern,
    // the agent likely pasted display output verbatim.
    if (looksLikeLineNumberPrefix(oldText)) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: oldText starts with a line-number prefix (`<spaces>N<TAB>`) from the read tool's display format. Strip the prefix from every line — the file does not contain those characters.", .{head}) catch head;
    }

    // Detect CRLF mismatch.
    const file_has_crlf = std.mem.indexOf(u8, file_content, "\r\n") != null;
    const old_has_crlf = std.mem.indexOf(u8, oldText, "\r\n") != null;
    if (file_has_crlf and !old_has_crlf and std.mem.indexOf(u8, oldText, "\n") != null) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: file uses CRLF line endings but oldText uses LF.", .{head}) catch head;
    }
    if (!file_has_crlf and old_has_crlf) {
        return std.fmt.allocPrint(alloc, "{s}. HINT: oldText uses CRLF line endings but file uses LF. Use \\n only.", .{head}) catch head;
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
        var prefix_len: usize = oldText.len;
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
    // Cheap normalisation: collapse runs of [ \t] to a single space, ignore trailing spaces.
    // Only worth doing when needle is short enough to avoid quadratic cost.
    if (needle.len > 4096) return false;
    var alloc_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const a = fba.allocator();
    const nh = normaliseWs(a, haystack) catch return false;
    fba.reset();
    const nn = normaliseWs(a, needle) catch return false;
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
