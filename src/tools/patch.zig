const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

pub const PatchTool = prv.tool.Tool{
    .def = .{
        .name = "patch",
        .description =
        \\Perform a patch request on one or more files.
        \\## `patch`
        \\
        \\Call this tool with a single JSON argument named `patch`.
        \\Do not run a shell command named `apply_patch`; put the patch text directly in the `patch` string.
        \\Your patch language is a stripped‑down, file‑oriented diff format designed to be easy to parse and safe to apply. You can think of it as a high‑level envelope:
        \\
        \\*** Begin Patch
        \\[ one or more file sections ]
        \\*** End Patch
        \\
        \\Within that envelope, you get a sequence of file operations.
        \\You MUST include a header to specify the action you are taking.
        \\Each operation starts with one of three headers:
        \\
        \\*** Add File: <path> - create a new file. Every following line is a + line (the initial contents).
        \\*** Delete File: <path> - remove an existing file. Nothing follows.
        \\*** Update File: <path> - patch an existing file in place (optionally with a rename).
        \\
        \\May be immediately followed by *** Move to: <new path> if you want to rename the file.
        \\Then one or more change chunks. The first chunk may start directly with change lines or with @@ (optionally followed by a hunk header). Additional chunks should use @@.
        \\Within a hunk each line starts with:
        \\- A space for unchanged context
        \\- `-` for removed lines
        \\- `+` for added lines
        \\
        \\For instructions on [context_before] and [context_after]:
        \\- By default, show 3 lines of code immediately above and 3 lines immediately below each change. If a change is within 3 lines of a previous change, do NOT duplicate the first change’s [context_after] lines in the second change’s [context_before] lines.
        \\- If 3 lines of context is insufficient to uniquely identify the snippet of code within the file, use the @@ operator to indicate the class or function to which the snippet belongs. For instance, we might have:
        \\@@ class BaseClass
        \\[3 lines of pre-context]
        \\- [old_code]
        \\+ [new_code]
        \\[3 lines of post-context]
        \\
        \\- If a code block is repeated so many times in a class or function such that even a single `@@` statement and 3 lines of context cannot uniquely identify the snippet of code, you can use multiple `@@` statements to jump to the right context. For instance:
        \\
        \\@@ class BaseClass
        \\@@    def method():
        \\[3 lines of pre-context]
        \\- [old_code]
        \\+ [new_code]
        \\[3 lines of post-context]
        \\
        \\The full grammar definition is below:
        \\Patch := Begin { FileOp } End
        \\Begin := "*** Begin Patch" NEWLINE
        \\End := "*** End Patch" NEWLINE
        \\FileOp := AddFile | DeleteFile | UpdateFile
        \\AddFile := "*** Add File: " path NEWLINE { "+" line NEWLINE }
        \\DeleteFile := "*** Delete File: " path NEWLINE
        \\UpdateFile := "*** Update File: " path NEWLINE [ MoveTo ] { Hunk }
        \\MoveTo := "*** Move to: " newPath NEWLINE
        \\Hunk := [ "@@" [ header ] NEWLINE ] { HunkLine } [ "*** End of File" NEWLINE ]
        \\HunkLine := (" " | "-" | "+") text NEWLINE
        \\
        \\A full patch can combine several operations:
        \\
        \\*** Begin Patch
        \\*** Add File: hello.txt
        \\+Hello world
        \\*** Update File: src/app.py
        \\*** Move to: src/main.py
        \\@@ def greet():
        \\-print("Hi")
        \\+print("Hello, world!")
        \\*** Delete File: obsolete.txt
        \\*** End Patch
        \\
        \\It is important to remember:
        \\
        \\- You must include a header with your intended action (Add/Delete/Update)
        \\- You must prefix new lines with `+` even when creating a new file
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "patch": {"type": "string", "description": "The patch string"}
        \\  },
        \\  "required": ["patch"]
        \\}
        ,
    },
    .func = &run,
};

const Args = struct { patch: []const u8 };

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().permission_level != .write) {
        return r.errResult(call, "Subagents must not write/edit/plan. Instead write a report back to the user");
    }

    const alloc = ctx.alloc;
    r.setToolStatusPrint(ctx, call, "patch", .{});

    const args = (std.json.parseFromSlice(Args, alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call,
        \\invalid JSON arguments, expected `{"patch": "..."}`
    )).value;

    if (args.patch.len == 0) return r.errResult(call, "patch is empty");

    // 1. Parse the patch.
    const parsed = parsePatch(alloc, args.patch) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "patch parse error: {s}", .{@errorName(err)}) catch
            "patch parse error";
        return r.errResult(call, msg);
    };
    const patch = parsed.value;

    if (patch.commands.len == 0) {
        return r.errResult(call, "patch contains no file operations");
    }

    // 2. Per-command: verify (preview before/after), request permission, apply.
    var applied: usize = 0;
    for (patch.commands, 0..) |cmd, ci| {
        if (ctx.isCanceled()) return r.errResult(call, "canceled");

        const cmd_path = commandPath(cmd);
        const resolved = std.fs.path.resolve(alloc, &.{ ctx.cwd, cmd_path }) catch
            return r.errResult(call, "failed to resolve path");

        r.setToolStatusPrint(ctx, call, "patch {s}", .{cmd_path});

        // For updates, the file must have been read first (matches edit.zig policy).
        if (cmd == .file_update) {
            const g = ctx.agent().file_stats.lock(ctx.io);
            const seen = g.ptr.get(resolved) != null;
            g.unlock();
            if (!seen) {
                const msg = std.fmt.allocPrint(
                    alloc,
                    "File {s} has not been read yet. Read it first before patching.",
                    .{cmd_path},
                ) catch "file not yet read";
                return r.errResult(call, msg);
            }
        }

        // Build before/after preview.
        const preview = buildPreview(ctx, resolved, cmd) catch |err| {
            const msg = std.fmt.allocPrint(alloc, "cannot preview {s} (cmd #{d}): {s}", .{
                cmd_path, ci, @errorName(err),
            }) catch "preview failed";
            return r.errResult(call, msg);
        };
        defer {
            if (preview.before) |b| alloc.free(b);
            if (preview.after) |a| alloc.free(a);
        }

        const decision = ctx.requestPerm(call.id, .always_check, .{ .diff = .{
            .before = preview.before,
            .after = preview.after orelse "",
            .path = cmd_path,
        } });
        switch (decision) {
            .approved => {},
            .denied => return r.errResult(call, "User declined patch"),
            .message => |txt| {
                const wrapped = std.fmt.allocPrint(
                    alloc,
                    "User declined patch and left feedback: {s}",
                    .{txt},
                ) catch txt;
                return r.errResult(call, wrapped);
            },
            else => return r.errResult(call, "permission unresolved"),
        }

        if (ctx.isCanceled()) return r.errResult(call, "canceled");

        // Apply against resolved absolute path.
        const abs_cmd = withResolvedPath(alloc, ctx.cwd, cmd, resolved) catch
            return r.errResult(call, "failed to resolve path");
        var diag: ApplyDiagnostics = .{};
        executeCommand(ctx, abs_cmd, &diag) catch |err| {
            const msg = std.fmt.allocPrint(
                alloc,
                "patch apply failed at command #{d} ({s}): {s}. anchor=\"{s}\" hunk_index={d} detail={s}",
                .{ ci, diag.path, @errorName(err), diag.expected_anchor, diag.hunk_index, diag.message },
            ) catch "patch apply failed";
            return r.errResult(call, msg);
        };

        // Update FileStats so subsequent edits don't block on "file not read".
        updateFileStats(ctx, resolved, abs_cmd);

        applied += 1;
    }

    const msg = std.fmt.allocPrint(alloc, "patch applied: {d} command(s)", .{applied}) catch
        "patch applied";
    return r.okResult(call, msg);
}

fn commandPath(cmd: PatchCommand) []const u8 {
    return switch (cmd) {
        .file_add => |a| a.path,
        .file_delete => |d| d.path,
        .file_update => |u| u.path,
    };
}

/// Return a copy of `cmd` with paths resolved to absolute paths.
fn withResolvedPath(alloc: std.mem.Allocator, cwd: []const u8, cmd: PatchCommand, resolved: []const u8) !PatchCommand {
    return switch (cmd) {
        .file_add => |a| .{ .file_add = .{ .path = resolved, .lines = a.lines } },
        .file_delete => .{ .file_delete = .{ .path = resolved } },
        .file_update => |u| blk: {
            const move_to = if (u.move_to) |m| try std.fs.path.resolve(alloc, &.{ cwd, m }) else null;
            break :blk .{ .file_update = .{
                .path = resolved,
                .move_to = move_to,
                .hunks = u.hunks,
            } };
        },
    };
}

const Preview = struct {
    before: ?[]const u8,
    after: ?[]const u8,
};

/// Build a before/after preview for the permission prompt. Does not write
/// anything. Allocates `before` and `after` from `alloc`; caller frees.
fn buildPreview(
    ctx: prv.tool.ToolContext,
    abs_path: []const u8,
    cmd: PatchCommand,
) !Preview {
    const alloc = ctx.alloc;
    switch (cmd) {
        .file_add => |a| {
            const after = try joinLinesWithTrailingNewline(alloc, a.lines);
            return .{ .before = null, .after = after };
        },
        .file_delete => {
            const before = try readFileViaExec(ctx, abs_path, true, null);
            return .{ .before = before, .after = null };
        },
        .file_update => |u| {
            const before = (try readFileViaExec(ctx, abs_path, false, null)) orelse return ApplyError.FileNotFound;
            errdefer alloc.free(before);
            var diag: ApplyDiagnostics = .{};
            const after = try applyHunks(alloc, before, u.hunks, &diag);
            return .{ .before = before, .after = after };
        },
    }
}

fn updateFileStats(ctx: prv.tool.ToolContext, resolved: []const u8, cmd: PatchCommand) void {
    var ts: std.posix.timespec = undefined;
    const now = if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) == 0)
        ts.sec
    else
        0;

    const g = ctx.agent().file_stats.lock(ctx.io);
    defer g.unlock();

    switch (cmd) {
        .file_add => {
            const e = g.ptr.getOrPut(ctx.alloc, resolved) catch return;
            e.value_ptr.* = .{ .last_read = now, .last_write = now };
        },
        .file_delete => {
            _ = g.ptr.remove(resolved);
        },
        .file_update => |u| {
            if (u.move_to) |move_to| {
                _ = g.ptr.remove(resolved);
                const e = g.ptr.getOrPut(ctx.alloc, move_to) catch return;
                e.value_ptr.* = .{ .last_read = now, .last_write = now };
            } else {
                const e = g.ptr.getOrPut(ctx.alloc, resolved) catch return;
                if (!e.found_existing) e.value_ptr.last_read = now;
                e.value_ptr.last_write = now;
            }
        },
    }
}

pub const Patch = struct {
    commands: []const PatchCommand,
};

pub const PatchCommand = union(enum) {
    file_add: FileAdd,
    file_delete: FileDelete,
    file_update: FileUpdate,

    pub const FileAdd = struct { path: []const u8, lines: []const []const u8 };
    pub const FileDelete = struct { path: []const u8 };
    pub const FileUpdate = struct {
        path: []const u8,
        move_to: ?[]const u8,
        hunks: []const Hunk,
    };
};

pub const Hunk = struct {
    header: ?[]const u8,
    lines: []const HunkLine,
    end_of_file: bool,
};

pub const HunkLine = union(enum) {
    context: []const u8, // " " unchanged anchor line
    add: []const u8, // "+" new line
    delete: []const u8, // "-" removed line
};

pub const ParseError = error{
    UnexpectedEof,
    ExpectedTag,
    ExpectedNewline,
    NoMatch,
    EmptyUpdateFile,
    InvalidHunkLine,
} || std.mem.Allocator.Error;

pub const MAX_FILE_BYTES: usize = 1 * 1024 * 1024; // 1 MiB

pub const ApplyError = error{
    HunkAnchorNotFound,
    FileNotFound,
    FileTooLarge,
    ExecFailed,
    InvalidCommand,
} || std.mem.Allocator.Error;

/// Populated on apply failure so callers can show *why* / *where*.
pub const ApplyDiagnostics = struct {
    path: []const u8 = "",
    hunk_index: usize = 0,
    /// Index of the offending HunkLine within the hunk (0 if N/A).
    hunk_line_index: usize = 0,
    /// First non-add line of the hunk we tried to anchor on.
    expected_anchor: []const u8 = "",
    message: []const u8 = "",
};

pub fn Result(comptime T: type) type {
    return struct {
        value: T,
        rest: []const u8,
    };
}

pub fn Parser(comptime T: type) type {
    return *const fn (alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(T);
}

// ---- primitive combinators ----------------------------------------------

fn ok(comptime T: type, value: T, rest: []const u8) Result(T) {
    return .{ .value = value, .rest = rest };
}

/// Match exact literal. Returns matched slice.
fn tag(comptime literal: []const u8) Parser([]const u8) {
    return struct {
        fn p(_: std.mem.Allocator, bytes: []const u8) ParseError!Result([]const u8) {
            if (bytes.len < literal.len) return ParseError.ExpectedTag;
            if (!std.mem.eql(u8, bytes[0..literal.len], literal)) return ParseError.ExpectedTag;
            return ok([]const u8, bytes[0..literal.len], bytes[literal.len..]);
        }
    }.p;
}

fn trimMarkerLine(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r");
}

fn firstLine(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
    var slice = bytes[0..i];
    if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
    return slice;
}

fn lineRest(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
    if (i >= bytes.len) return bytes[bytes.len..];
    return skipNewline(bytes[i..]);
}

fn peekTrimmedEql(bytes: []const u8, literal: []const u8) bool {
    return std.mem.eql(u8, trimMarkerLine(firstLine(bytes)), literal);
}

fn peekTrimmedStartsWith(bytes: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, trimMarkerLine(firstLine(bytes)), prefix);
}

fn isBlankInputLine(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    return trimMarkerLine(firstLine(bytes)).len == 0;
}

fn markerLine(
    comptime literal: []const u8,
    alloc: std.mem.Allocator,
    bytes: []const u8,
) ParseError!Result([]const u8) {
    _ = alloc;
    if (bytes.len == 0) return ParseError.UnexpectedEof;
    const raw = firstLine(bytes);
    const trimmed = trimMarkerLine(raw);
    if (!std.mem.eql(u8, trimmed, literal)) return ParseError.ExpectedTag;
    return ok([]const u8, trimmed, lineRest(bytes));
}

fn markerPrefixLine(
    comptime prefix: []const u8,
    alloc: std.mem.Allocator,
    bytes: []const u8,
) ParseError!Result([]const u8) {
    _ = alloc;
    if (bytes.len == 0) return ParseError.UnexpectedEof;
    const raw = firstLine(bytes);
    const trimmed = trimMarkerLine(raw);
    if (!std.mem.startsWith(u8, trimmed, prefix)) return ParseError.ExpectedTag;
    return ok([]const u8, trimmed[prefix.len..], lineRest(bytes));
}

/// Consume one '\n' (also accepts CRLF by stripping the '\r' from caller-side text).
fn newline(_: std.mem.Allocator, bytes: []const u8) ParseError!Result(void) {
    if (bytes.len == 0) return ParseError.UnexpectedEof;
    if (bytes[0] == '\n') return ok(void, {}, bytes[1..]);
    if (bytes[0] == '\r' and bytes.len >= 2 and bytes[1] == '\n') return ok(void, {}, bytes[2..]);
    return ParseError.ExpectedNewline;
}

/// Take bytes until (but not including) '\n'. Strips trailing '\r' if present.
fn untilNewline(_: std.mem.Allocator, bytes: []const u8) ParseError!Result([]const u8) {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != '\n') : (i += 1) {}
    var slice = bytes[0..i];
    if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
    return ok([]const u8, slice, bytes[i..]);
}

/// One line: `untilNewline` then `newline`. EOF without trailing newline also OK (treated as last line).
fn line(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result([]const u8) {
    const text = try untilNewline(alloc, bytes);
    if (text.rest.len == 0) return text; // EOF — no newline to consume
    const nl = try newline(alloc, text.rest);
    return ok([]const u8, text.value, nl.rest);
}

/// Peek: does input start with literal?
fn peek(bytes: []const u8, literal: []const u8) bool {
    return bytes.len >= literal.len and std.mem.eql(u8, bytes[0..literal.len], literal);
}

/// Skip a single newline if present.
fn skipNewline(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[0] == '\n') return bytes[1..];
    if (bytes.len >= 2 and bytes[0] == '\r' and bytes[1] == '\n') return bytes[2..];
    return bytes;
}

fn stripMarkdownFenceWrapper(bytes: []const u8) []const u8 {
    const first = firstLine(bytes);
    const trimmed = trimMarkerLine(first);
    if (!std.mem.startsWith(u8, trimmed, "```")) return bytes;

    const body = lineRest(bytes);
    var cursor = body;
    var body_end: usize = body.len;
    var offset: usize = 0;
    while (cursor.len > 0) {
        const raw = firstLine(cursor);
        if (std.mem.eql(u8, trimMarkerLine(raw), "```")) {
            body_end = offset;
            break;
        }
        const rest = lineRest(cursor);
        offset += cursor.len - rest.len;
        cursor = rest;
    }
    return body[0..body_end];
}

fn heredocTokenFromLine(line_bytes: []const u8) ?[]const u8 {
    const trimmed = trimMarkerLine(line_bytes);
    const marker_at = std.mem.indexOf(u8, trimmed, "<<") orelse return null;
    var token = trimMarkerLine(trimmed[marker_at + 2 ..]);
    if (token.len > 0 and token[0] == '-') token = trimMarkerLine(token[1..]);

    if (token.len >= 2) {
        const first_ch = token[0];
        const last_ch = token[token.len - 1];
        if ((first_ch == '\'' and last_ch == '\'') or (first_ch == '"' and last_ch == '"')) {
            token = token[1 .. token.len - 1];
        }
    }
    if (token.len == 0) return null;
    return token;
}

fn stripHeredocWrapper(bytes: []const u8) []const u8 {
    const first = firstLine(bytes);
    const token = heredocTokenFromLine(first) orelse return bytes;
    const body = lineRest(bytes);
    var cursor = body;
    var body_end: usize = body.len;
    var offset: usize = 0;
    while (cursor.len > 0) {
        const raw = firstLine(cursor);
        if (std.mem.eql(u8, trimMarkerLine(raw), token)) {
            body_end = offset;
            break;
        }
        const rest = lineRest(cursor);
        offset += cursor.len - rest.len;
        cursor = rest;
    }
    return body[0..body_end];
}

fn stripCommonWrappers(bytes: []const u8) []const u8 {
    return stripHeredocWrapper(stripMarkdownFenceWrapper(bytes));
}

fn hunkBoundaryStartsWith(bytes: []const u8, prefix: []const u8) bool {
    if (bytes.len == 0) return false;
    switch (bytes[0]) {
        ' ', '+', '-', '\n', '\r' => return false,
        else => {},
    }
    return std.mem.startsWith(u8, trimMarkerLine(firstLine(bytes)), prefix);
}

fn hunkBoundaryEql(bytes: []const u8, literal: []const u8) bool {
    if (bytes.len == 0) return false;
    switch (bytes[0]) {
        ' ', '+', '-', '\n', '\r' => return false,
        else => {},
    }
    return std.mem.eql(u8, trimMarkerLine(firstLine(bytes)), literal);
}

// ---- patch grammar parsers ----------------------------------------------

fn parsePath(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result([]const u8) {
    return line(alloc, bytes);
}

fn parseAddFile(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(PatchCommand) {
    const hdr = try markerPrefixLine("*** Add File: ", alloc, bytes);
    const path = hdr.value;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);

    var cursor = hdr.rest;
    while (cursor.len > 0 and cursor[0] == '+') {
        const lr = try line(alloc, cursor[1..]);
        try lines.append(alloc, lr.value);
        cursor = lr.rest;
    }

    const owned = try lines.toOwnedSlice(alloc);
    return ok(PatchCommand, .{ .file_add = .{ .path = path, .lines = owned } }, cursor);
}

fn parseDeleteFile(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(PatchCommand) {
    const hdr = try markerPrefixLine("*** Delete File: ", alloc, bytes);
    return ok(PatchCommand, .{ .file_delete = .{ .path = hdr.value } }, hdr.rest);
}

fn parseMoveTo(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result([]const u8) {
    return markerPrefixLine("*** Move to: ", alloc, bytes);
}

fn parseHunkLine(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(HunkLine) {
    if (bytes.len == 0) return ParseError.UnexpectedEof;
    if (bytes[0] == '\n') return ok(HunkLine, .{ .context = "" }, bytes[1..]);
    if (bytes.len >= 2 and bytes[0] == '\r' and bytes[1] == '\n') {
        return ok(HunkLine, .{ .context = "" }, bytes[2..]);
    }
    const prefix = bytes[0];
    if (prefix != ' ' and prefix != '+' and prefix != '-') return ParseError.InvalidHunkLine;
    const lr = try line(alloc, bytes[1..]);
    const hl: HunkLine = switch (prefix) {
        ' ' => .{ .context = lr.value },
        '+' => .{ .add = lr.value },
        '-' => .{ .delete = lr.value },
        else => unreachable,
    };
    return ok(HunkLine, hl, lr.rest);
}

fn parseHunk(alloc: std.mem.Allocator, bytes: []const u8, allow_missing_context: bool) ParseError!Result(Hunk) {
    var header: ?[]const u8 = null;
    var cursor: []const u8 = bytes;

    if (hunkBoundaryStartsWith(bytes, "@@")) {
        const header_line = try markerPrefixLine("@@", alloc, bytes);
        const h = trimMarkerLine(header_line.value);
        if (h.len > 0) {
            header = h;
        }
        cursor = header_line.rest;
    } else if (!allow_missing_context) {
        return ParseError.ExpectedTag;
    }

    var lines: std.ArrayList(HunkLine) = .empty;
    defer lines.deinit(alloc);

    while (cursor.len > 0) {
        // stop conditions: another hunk, an end marker, or another FileOp / *** End Patch
        if (hunkBoundaryStartsWith(cursor, "@@")) break;
        if (hunkBoundaryStartsWith(cursor, "*** ")) break;
        if (cursor[0] != ' ' and cursor[0] != '+' and cursor[0] != '-' and cursor[0] != '\n' and cursor[0] != '\r') break;
        const hl = try parseHunkLine(alloc, cursor);
        try lines.append(alloc, hl.value);
        cursor = hl.rest;
    }

    var end_of_file = false;
    if (hunkBoundaryEql(cursor, "*** End of File")) {
        cursor = lineRest(cursor);
        end_of_file = true;
    }

    const owned = try lines.toOwnedSlice(alloc);
    return ok(Hunk, .{ .header = header, .lines = owned, .end_of_file = end_of_file }, cursor);
}

fn parseUpdateFile(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(PatchCommand) {
    const hdr = try markerPrefixLine("*** Update File: ", alloc, bytes);
    const path = hdr.value;

    var move_to: ?[]const u8 = null;
    var cursor = hdr.rest;
    if (peekTrimmedStartsWith(cursor, "*** Move to: ")) {
        const mv = try parseMoveTo(alloc, cursor);
        move_to = mv.value;
        cursor = mv.rest;
    }

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(alloc);

    var allow_missing_context = true;
    while (cursor.len > 0) {
        if (isBlankInputLine(cursor)) {
            cursor = lineRest(cursor);
            continue;
        }
        if (peekTrimmedStartsWith(cursor, "*** ")) break;
        if (!allow_missing_context and !hunkBoundaryStartsWith(cursor, "@@")) break;

        const h = try parseHunk(alloc, cursor, allow_missing_context);
        try hunks.append(alloc, h.value);
        cursor = h.rest;
        allow_missing_context = false;
    }

    if (hunks.items.len == 0) return ParseError.EmptyUpdateFile;

    const owned = try hunks.toOwnedSlice(alloc);
    return ok(PatchCommand, .{ .file_update = .{
        .path = path,
        .move_to = move_to,
        .hunks = owned,
    } }, cursor);
}

fn parseFileOp(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(PatchCommand) {
    if (peekTrimmedStartsWith(bytes, "*** Add File: ")) return parseAddFile(alloc, bytes);
    if (peekTrimmedStartsWith(bytes, "*** Delete File: ")) return parseDeleteFile(alloc, bytes);
    if (peekTrimmedStartsWith(bytes, "*** Update File: ")) return parseUpdateFile(alloc, bytes);
    return ParseError.NoMatch;
}

pub fn parsePatch(alloc: std.mem.Allocator, bytes: []const u8) ParseError!Result(Patch) {
    const input = stripCommonWrappers(bytes);
    const begin = try markerLine("*** Begin Patch", alloc, input);

    var cmds: std.ArrayList(PatchCommand) = .empty;
    defer cmds.deinit(alloc);

    var cursor = begin.rest;
    if (peekTrimmedStartsWith(cursor, "*** Environment ID: ")) {
        cursor = lineRest(cursor);
    }
    while (!peekTrimmedEql(cursor, "*** End Patch")) {
        const op = try parseFileOp(alloc, cursor);
        try cmds.append(alloc, op.value);
        cursor = op.rest;
        if (cursor.len == 0) return ParseError.UnexpectedEof;
    }

    const final_rest = lineRest(cursor);

    const owned = try cmds.toOwnedSlice(alloc);
    return ok(Patch, .{ .commands = owned }, final_rest);
}

// ---- apply ---------------------------------------------------------------

/// Split source into lines. Empty trailing slice represents the final newline
/// (or an empty file). Preserves whether file ended with `\n` so we can
/// reconstruct exactly.
fn splitLines(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |s| try out.append(alloc, s);
    return out.toOwnedSlice(alloc);
}

/// Join lines back with `\n`. Mirrors `splitLines` so round-trip is identity.
fn joinLines(alloc: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (lines) |l| total += l.len;
    if (lines.len > 0) total += lines.len - 1;
    var buf = try alloc.alloc(u8, total);
    var i: usize = 0;
    for (lines, 0..) |l, idx| {
        @memcpy(buf[i .. i + l.len], l);
        i += l.len;
        if (idx + 1 < lines.len) {
            buf[i] = '\n';
            i += 1;
        }
    }
    return buf;
}

/// Apply hunks to `src`, returning new content. Caller owns the result.
pub fn applyHunks(
    alloc: std.mem.Allocator,
    src: []const u8,
    hunks: []const Hunk,
    diag: *ApplyDiagnostics,
) ApplyError![]u8 {
    var lines = try splitLines(alloc, src);
    defer alloc.free(lines);

    var cursor: usize = 0; // can only match anchors at/after this row
    for (hunks, 0..) |h, hi| {
        diag.hunk_index = hi;

        // Extract the "old" view of the hunk (context + delete) and the "new" view (context + add).
        var old_view: std.ArrayList([]const u8) = .empty;
        defer old_view.deinit(alloc);
        var new_view: std.ArrayList([]const u8) = .empty;
        defer new_view.deinit(alloc);
        for (h.lines) |hl| switch (hl) {
            .context => |t| {
                try old_view.append(alloc, t);
                try new_view.append(alloc, t);
            },
            .delete => |t| try old_view.append(alloc, t),
            .add => |t| try new_view.append(alloc, t),
        };

        if (h.header) |header| {
            const header_pattern = [_][]const u8{header};
            const header_at = try seekSequence(alloc, lines, cursor, &header_pattern, false) orelse {
                diag.expected_anchor = header;
                diag.message = "could not locate hunk header in target file";
                return ApplyError.HunkAnchorNotFound;
            };
            cursor = header_at.index + header_at.matched_len;
        }

        if (old_view.items.len == 0) {
            const insert_at = if (h.end_of_file)
                insertionIndexBeforeTrailingEmptyLine(lines)
            else
                @min(cursor, lines.len);
            const new_lines = try alloc.alloc([]const u8, lines.len + new_view.items.len);
            @memcpy(new_lines[0..insert_at], lines[0..insert_at]);
            @memcpy(new_lines[insert_at .. insert_at + new_view.items.len], new_view.items);
            @memcpy(new_lines[insert_at + new_view.items.len ..], lines[insert_at..]);
            alloc.free(lines);
            lines = new_lines;
            cursor = insert_at + new_view.items.len;
            continue;
        }

        diag.expected_anchor = old_view.items[0];

        const match = try seekSequence(alloc, lines, cursor, old_view.items, h.end_of_file) orelse {
            diag.message = "could not locate hunk anchor in target file";
            return ApplyError.HunkAnchorNotFound;
        };
        const match_at = match.index;

        // Splice: replace lines[match_at..match_at+old_view.len] with new_view.items
        const after_idx = match_at + match.matched_len;
        const tail_len = lines.len - after_idx;
        const new_total = match_at + new_view.items.len + tail_len;
        const new_lines = try alloc.alloc([]const u8, new_total);
        @memcpy(new_lines[0..match_at], lines[0..match_at]);
        @memcpy(new_lines[match_at .. match_at + new_view.items.len], new_view.items);
        @memcpy(new_lines[match_at + new_view.items.len ..], lines[after_idx..]);
        alloc.free(lines);
        lines = new_lines;
        cursor = match_at + new_view.items.len;
    }

    return joinLines(alloc, lines);
}

const MatchMode = enum {
    exact,
    rstrip,
    trim,
    normalized_trim,
};

const SequenceMatch = struct {
    index: usize,
    matched_len: usize,
};

fn seekSequence(
    alloc: std.mem.Allocator,
    haystack: []const []const u8,
    start: usize,
    needle: []const []const u8,
    end_of_file: bool,
) !?SequenceMatch {
    if (needle.len == 0) return null;

    const modes = [_]MatchMode{ .exact, .rstrip, .trim, .normalized_trim };
    if (needle.len <= haystack.len) {
        const start_at = if (end_of_file)
            haystack.len - needle.len
        else
            @min(start, haystack.len - needle.len);
        for (modes) |mode| {
            if (try findSliceWithMode(alloc, haystack, start_at, needle, mode)) |idx| {
                return .{ .index = idx, .matched_len = needle.len };
            }
        }
        if (end_of_file and start_at != @min(start, haystack.len - needle.len)) {
            const fallback_start = @min(start, haystack.len - needle.len);
            for (modes) |mode| {
                if (try findSliceWithMode(alloc, haystack, fallback_start, needle, mode)) |idx| {
                    return .{ .index = idx, .matched_len = needle.len };
                }
            }
        }
    }

    if (needle.len > 1 and needle[needle.len - 1].len == 0) {
        const shorter = needle[0 .. needle.len - 1];
        if (shorter.len <= haystack.len) {
            const shorter_start_at = if (end_of_file)
                haystack.len - shorter.len
            else
                @min(start, haystack.len - shorter.len);
            for (modes) |mode| {
                if (try findSliceWithMode(alloc, haystack, shorter_start_at, shorter, mode)) |idx| {
                    return .{ .index = idx, .matched_len = shorter.len };
                }
            }
            if (end_of_file and shorter_start_at != @min(start, haystack.len - shorter.len)) {
                const fallback_start = @min(start, haystack.len - shorter.len);
                for (modes) |mode| {
                    if (try findSliceWithMode(alloc, haystack, fallback_start, shorter, mode)) |idx| {
                        return .{ .index = idx, .matched_len = shorter.len };
                    }
                }
            }
        }
    }

    return null;
}

fn insertionIndexBeforeTrailingEmptyLine(lines: []const []const u8) usize {
    if (lines.len > 0 and lines[lines.len - 1].len == 0) return lines.len - 1;
    return lines.len;
}

fn findSliceWithMode(
    alloc: std.mem.Allocator,
    haystack: []const []const u8,
    start: usize,
    needle: []const []const u8,
    mode: MatchMode,
) !?usize {
    if (needle.len == 0) return null;
    if (needle.len > haystack.len) return null;
    var i: usize = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok_match = true;
        for (needle, 0..) |n, j| {
            if (!try lineMatches(alloc, haystack[i + j], n, mode)) {
                ok_match = false;
                break;
            }
        }
        if (ok_match) return i;
    }
    return null;
}

fn lineMatches(
    alloc: std.mem.Allocator,
    actual: []const u8,
    pattern: []const u8,
    mode: MatchMode,
) !bool {
    return switch (mode) {
        .exact => std.mem.eql(u8, actual, pattern),
        .rstrip => std.mem.eql(
            u8,
            trimLineRight(actual),
            trimLineRight(pattern),
        ),
        .trim => std.mem.eql(
            u8,
            std.mem.trim(u8, actual, " \t\r"),
            std.mem.trim(u8, pattern, " \t\r"),
        ),
        .normalized_trim => blk: {
            const normalized_actual = try normalizeCommonUnicode(alloc, actual);
            defer alloc.free(normalized_actual);
            const normalized_pattern = try normalizeCommonUnicode(alloc, pattern);
            defer alloc.free(normalized_pattern);
            break :blk std.mem.eql(
                u8,
                std.mem.trim(u8, normalized_actual, " \t\r"),
                std.mem.trim(u8, normalized_pattern, " \t\r"),
            );
        },
    };
}

fn trimLineRight(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0) {
        switch (bytes[end - 1]) {
            ' ', '\t', '\r' => end -= 1,
            else => break,
        }
    }
    return bytes[0..end];
}

fn normalizeCommonUnicode(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 3 <= bytes.len and bytes[i] == 0xE2 and bytes[i + 1] == 0x80) {
            const b = bytes[i + 2];
            if ((b >= 0x90 and b <= 0x95)) {
                try out.append(alloc, '-');
                i += 3;
                continue;
            }
            if (b >= 0x98 and b <= 0x9B) {
                try out.append(alloc, '\'');
                i += 3;
                continue;
            }
            if (b >= 0x9C and b <= 0x9F) {
                try out.append(alloc, '"');
                i += 3;
                continue;
            }
            if ((b >= 0x82 and b <= 0x8A) or b == 0xAF) {
                try out.append(alloc, ' ');
                i += 3;
                continue;
            }
        }

        if (i + 3 <= bytes.len and bytes[i] == 0xE2 and bytes[i + 1] == 0x88 and bytes[i + 2] == 0x92) {
            try out.append(alloc, '-');
            i += 3;
            continue;
        }

        if (i + 3 <= bytes.len and bytes[i] == 0xE2 and bytes[i + 1] == 0x81 and bytes[i + 2] == 0x9F) {
            try out.append(alloc, ' ');
            i += 3;
            continue;
        }

        if (i + 2 <= bytes.len and bytes[i] == 0xC2 and bytes[i + 1] == 0xA0) {
            try out.append(alloc, ' ');
            i += 2;
            continue;
        }

        if (i + 3 <= bytes.len and bytes[i] == 0xE3 and bytes[i + 1] == 0x80 and bytes[i + 2] == 0x80) {
            try out.append(alloc, ' ');
            i += 3;
            continue;
        }

        try out.append(alloc, bytes[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Execute one PatchCommand through the exec pool using GNU coreutils.
/// On failure, `diag` is populated with details.
pub fn executeCommand(
    ctx: prv.tool.ToolContext,
    cmd: PatchCommand,
    diag: *ApplyDiagnostics,
) ApplyError!void {
    const alloc = ctx.alloc;
    switch (cmd) {
        .file_add => |a| {
            diag.path = a.path;
            const content = try joinLinesWithTrailingNewline(alloc, a.lines);
            defer alloc.free(content);
            try writeFileViaExec(ctx, a.path, content, diag);
        },
        .file_delete => |d| {
            diag.path = d.path;
            try deleteFileViaExec(ctx, d.path, diag);
        },
        .file_update => |u| {
            diag.path = u.path;
            const src = (try readFileViaExec(ctx, u.path, false, diag)) orelse return ApplyError.FileNotFound;
            defer alloc.free(src);

            const new_content = try applyHunks(alloc, src, u.hunks, diag);
            defer alloc.free(new_content);

            const out_path = u.move_to orelse u.path;
            try writeFileViaExec(ctx, out_path, new_content, diag);
            if (u.move_to != null) try deleteFileViaExec(ctx, u.path, diag);
        },
    }
}

fn readFileViaExec(
    ctx: prv.tool.ToolContext,
    path: []const u8,
    missing_ok: bool,
    diag: ?*ApplyDiagnostics,
) ApplyError!?[]const u8 {
    const res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "cat", path } }) catch {
        if (diag) |d| d.message = "read command failed to start";
        return ApplyError.ExecFailed;
    };
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

    if (res.ty != .success) {
        if (missing_ok and std.mem.indexOf(u8, res.stderr, "No such file") != null) return null;
        if (diag) |d| {
            d.message = if (res.stderr.len > 0)
                (ctx.alloc.dupe(u8, res.stderr) catch "read command failed")
            else
                "read command failed";
        }
        return ApplyError.ExecFailed;
    }

    if (res.stdout.len > MAX_FILE_BYTES) {
        if (diag) |d| d.message = "file exceeds maximum size";
        return ApplyError.FileTooLarge;
    }
    return try ctx.alloc.dupe(u8, res.stdout);
}

fn writeFileViaExec(
    ctx: prv.tool.ToolContext,
    path: []const u8,
    content: []const u8,
    diag: *ApplyDiagnostics,
) ApplyError!void {
    const command = try writeShellCommand(ctx.alloc, path);
    defer ctx.alloc.free(command);

    const res = ctx.swarm.exec.runAndWait(.{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin_data = content,
    }) catch return ApplyError.ExecFailed;
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

    if (res.ty != .success) {
        diag.message = if (res.stderr.len > 0)
            (ctx.alloc.dupe(u8, res.stderr) catch "write command failed")
        else
            "write command failed";
        return ApplyError.ExecFailed;
    }
}

fn deleteFileViaExec(ctx: prv.tool.ToolContext, path: []const u8, diag: *ApplyDiagnostics) ApplyError!void {
    const res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "rm", path } }) catch return ApplyError.ExecFailed;
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

    if (res.ty != .success) {
        diag.message = if (res.stderr.len > 0)
            (ctx.alloc.dupe(u8, res.stderr) catch "delete command failed")
        else
            "delete command failed";
        return ApplyError.ExecFailed;
    }
}

fn writeShellCommand(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const quoted_path = try shellQuote(alloc, path);
    defer alloc.free(quoted_path);

    if (std.fs.path.dirname(path)) |dir| {
        const quoted_dir = try shellQuote(alloc, dir);
        defer alloc.free(quoted_dir);
        return std.fmt.allocPrint(alloc, "mkdir -p {s} && tee {s} >/dev/null", .{ quoted_dir, quoted_path });
    }

    return std.fmt.allocPrint(alloc, "tee {s} >/dev/null", .{quoted_path});
}

fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

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

/// Like joinLines but always end with a newline (file-add lines come from `+` rows).
fn joinLinesWithTrailingNewline(alloc: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (lines) |l| total += l.len + 1; // each line + '\n'
    var buf = try alloc.alloc(u8, total);
    var i: usize = 0;
    for (lines) |l| {
        @memcpy(buf[i .. i + l.len], l);
        i += l.len;
        buf[i] = '\n';
        i += 1;
    }
    return buf;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "tag matches exact literal" {
    const alloc = testing.allocator;
    const p = tag("*** Begin Patch");
    const res = try p(alloc, "*** Begin Patch\nrest");
    try testing.expectEqualStrings("*** Begin Patch", res.value);
    try testing.expectEqualStrings("\nrest", res.rest);
}

test "tag fails on mismatch" {
    const alloc = testing.allocator;
    const p = tag("foo");
    try testing.expectError(ParseError.ExpectedTag, p(alloc, "bar"));
}

test "untilNewline strips CR from value, leaves newline on rest" {
    const alloc = testing.allocator;
    const res = try untilNewline(alloc, "hello\r\nworld");
    try testing.expectEqualStrings("hello", res.value);
    try testing.expectEqualStrings("\nworld", res.rest);
}

test "line accepts CRLF" {
    const alloc = testing.allocator;
    const res = try line(alloc, "foo\r\nbar");
    try testing.expectEqualStrings("foo", res.value);
    try testing.expectEqualStrings("bar", res.rest);
}

test "line consumes trailing newline" {
    const alloc = testing.allocator;
    const res = try line(alloc, "foo\nbar");
    try testing.expectEqualStrings("foo", res.value);
    try testing.expectEqualStrings("bar", res.rest);
}

test "parseHunkLine variants" {
    const alloc = testing.allocator;
    const ctx_r = try parseHunkLine(alloc, " context line\n");
    try testing.expectEqualStrings("context line", ctx_r.value.context);

    const add_r = try parseHunkLine(alloc, "+added\n");
    try testing.expectEqualStrings("added", add_r.value.add);

    const del_r = try parseHunkLine(alloc, "-gone\n");
    try testing.expectEqualStrings("gone", del_r.value.delete);

    try testing.expectError(ParseError.InvalidHunkLine, parseHunkLine(alloc, "xnope\n"));
}

test "parseAddFile collects + lines" {
    const alloc = testing.allocator;
    const input =
        "*** Add File: hello.txt\n" ++
        "+Hello world\n" ++
        "+Second line\n";
    const res = try parseAddFile(alloc, input);
    const add = res.value.file_add;
    defer alloc.free(add.lines);
    try testing.expectEqualStrings("hello.txt", add.path);
    try testing.expectEqual(@as(usize, 2), add.lines.len);
    try testing.expectEqualStrings("Hello world", add.lines[0]);
    try testing.expectEqualStrings("Second line", add.lines[1]);
}

test "parseDeleteFile" {
    const alloc = testing.allocator;
    const res = try parseDeleteFile(alloc, "*** Delete File: obsolete.txt\n");
    try testing.expectEqualStrings("obsolete.txt", res.value.file_delete.path);
}

test "parseHunk with header and end-of-file marker" {
    const alloc = testing.allocator;
    const input =
        "@@ def greet():\n" ++
        " keep\n" ++
        "-old\n" ++
        "+new\n" ++
        "*** End of File\n";
    const res = try parseHunk(alloc, input, false);
    defer alloc.free(res.value.lines);
    try testing.expectEqualStrings("def greet():", res.value.header.?);
    try testing.expectEqual(true, res.value.end_of_file);
    try testing.expectEqual(@as(usize, 3), res.value.lines.len);
    try testing.expectEqualStrings("keep", res.value.lines[0].context);
    try testing.expectEqualStrings("old", res.value.lines[1].delete);
    try testing.expectEqualStrings("new", res.value.lines[2].add);
}

test "parseUpdateFile with move_to and hunk" {
    const alloc = testing.allocator;
    const input =
        "*** Update File: src/app.py\n" ++
        "*** Move to: src/main.py\n" ++
        "@@ def greet():\n" ++
        "-print(\"Hi\")\n" ++
        "+print(\"Hello, world!\")\n";
    const res = try parseUpdateFile(alloc, input);
    const upd = res.value.file_update;
    defer {
        for (upd.hunks) |h| alloc.free(h.lines);
        alloc.free(upd.hunks);
    }
    try testing.expectEqualStrings("src/app.py", upd.path);
    try testing.expectEqualStrings("src/main.py", upd.move_to.?);
    try testing.expectEqual(@as(usize, 1), upd.hunks.len);
    try testing.expectEqual(@as(usize, 2), upd.hunks[0].lines.len);
}

test "parsePatch full example" {
    const alloc = testing.allocator;
    const input =
        "*** Begin Patch\n" ++
        "*** Add File: hello.txt\n" ++
        "+Hello world\n" ++
        "*** Update File: src/app.py\n" ++
        "*** Move to: src/main.py\n" ++
        "@@ def greet():\n" ++
        "-print(\"Hi\")\n" ++
        "+print(\"Hello, world!\")\n" ++
        "*** Delete File: obsolete.txt\n" ++
        "*** End Patch\n";
    const res = try parsePatch(alloc, input);
    const patch = res.value;
    defer {
        for (patch.commands) |c| switch (c) {
            .file_add => |a| alloc.free(a.lines),
            .file_update => |u| {
                for (u.hunks) |h| alloc.free(h.lines);
                alloc.free(u.hunks);
            },
            .file_delete => {},
        };
        alloc.free(patch.commands);
    }
    try testing.expectEqual(@as(usize, 3), patch.commands.len);
    try testing.expectEqualStrings("hello.txt", patch.commands[0].file_add.path);
    try testing.expectEqualStrings("src/app.py", patch.commands[1].file_update.path);
    try testing.expectEqualStrings("src/main.py", patch.commands[1].file_update.move_to.?);
    try testing.expectEqualStrings("obsolete.txt", patch.commands[2].file_delete.path);
    try testing.expectEqualStrings("", res.rest);
}

test "parsePatch errors on missing Begin" {
    const alloc = testing.allocator;
    try testing.expectError(ParseError.ExpectedTag, parsePatch(alloc, "*** Add File: x\n*** End Patch\n"));
}

test "parsePatch errors on unknown FileOp" {
    const alloc = testing.allocator;
    const input = "*** Begin Patch\n*** Bogus: x\n*** End Patch\n";
    try testing.expectError(ParseError.NoMatch, parsePatch(alloc, input));
}

test "parsePatch strips heredoc wrapper and trims markers" {
    const alloc = testing.allocator;
    const input =
        "<<'EOF'\n" ++
        "  *** Begin Patch  \n" ++
        "  *** Add File: hello.txt  \n" ++
        "+Hello world\n" ++
        "  *** End Patch  \n" ++
        "EOF\n";
    const res = try parsePatch(alloc, input);
    const patch = res.value;
    defer {
        alloc.free(patch.commands[0].file_add.lines);
        alloc.free(patch.commands);
    }

    try testing.expectEqual(@as(usize, 1), patch.commands.len);
    try testing.expectEqualStrings("hello.txt", patch.commands[0].file_add.path);
    try testing.expectEqualStrings("", res.rest);
}

test "parsePatch strips fenced patch wrapper" {
    const alloc = testing.allocator;
    const input =
        "```diff\n" ++
        "*** Begin Patch\n" ++
        "*** Add File: hello.txt\n" ++
        "+Hello world\n" ++
        "*** End Patch\n" ++
        "```\n";
    const res = try parsePatch(alloc, input);
    const patch = res.value;
    defer {
        alloc.free(patch.commands[0].file_add.lines);
        alloc.free(patch.commands);
    }

    try testing.expectEqual(@as(usize, 1), patch.commands.len);
    try testing.expectEqualStrings("hello.txt", patch.commands[0].file_add.path);
    try testing.expectEqualStrings("", res.rest);
}

test "parsePatch strips shell heredoc wrapper" {
    const alloc = testing.allocator;
    const input =
        "apply_patch <<'PATCH'\n" ++
        "*** Begin Patch\n" ++
        "*** Add File: hello.txt\n" ++
        "+Hello world\n" ++
        "*** End Patch\n" ++
        "PATCH\n";
    const res = try parsePatch(alloc, input);
    const patch = res.value;
    defer {
        alloc.free(patch.commands[0].file_add.lines);
        alloc.free(patch.commands);
    }

    try testing.expectEqual(@as(usize, 1), patch.commands.len);
    try testing.expectEqualStrings("hello.txt", patch.commands[0].file_add.path);
    try testing.expectEqualStrings("", res.rest);
}

test "parsePatch accepts optional environment id preamble" {
    const alloc = testing.allocator;
    const input =
        "*** Begin Patch\n" ++
        "*** Environment ID: local\n" ++
        "*** Add File: hello.txt\n" ++
        "+Hello world\n" ++
        "*** End Patch\n";
    const res = try parsePatch(alloc, input);
    const patch = res.value;
    defer {
        alloc.free(patch.commands[0].file_add.lines);
        alloc.free(patch.commands);
    }

    try testing.expectEqual(@as(usize, 1), patch.commands.len);
    try testing.expectEqualStrings("hello.txt", patch.commands[0].file_add.path);
}

test "parseUpdateFile accepts first chunk without context marker" {
    const alloc = testing.allocator;
    const input =
        "*** Update File: src/app.py\n" ++
        "-print(\"Hi\")\n" ++
        "+print(\"Hello\")\n";
    const res = try parseUpdateFile(alloc, input);
    const upd = res.value.file_update;
    defer {
        for (upd.hunks) |h| alloc.free(h.lines);
        alloc.free(upd.hunks);
    }

    try testing.expectEqual(@as(usize, 1), upd.hunks.len);
    try testing.expectEqual(@as(?[]const u8, null), upd.hunks[0].header);
    try testing.expectEqualStrings("print(\"Hi\")", upd.hunks[0].lines[0].delete);
}

test "parseUpdateFile accepts blank separators and raw blank context lines" {
    const alloc = testing.allocator;
    const input =
        "*** Update File: src/app.py\n" ++
        "@@\n" ++
        " line one\n" ++
        "\n" ++
        "-old\n" ++
        "+new\n" ++
        "\n" ++
        "@@ def second():\n" ++
        "-old2\n" ++
        "+new2\n";
    const res = try parseUpdateFile(alloc, input);
    const upd = res.value.file_update;
    defer {
        for (upd.hunks) |h| alloc.free(h.lines);
        alloc.free(upd.hunks);
    }

    try testing.expectEqual(@as(usize, 2), upd.hunks.len);
    try testing.expectEqualStrings("", upd.hunks[0].lines[1].context);
    try testing.expectEqualStrings("def second():", upd.hunks[1].header.?);
}

test "parseHunk keeps context lines that look like patch syntax" {
    const alloc = testing.allocator;
    const input =
        "@@\n" ++
        " @@decorator\n" ++
        " *** not a file marker\n" ++
        "-old\n" ++
        "+new\n" ++
        "*** End of File\n";
    const res = try parseHunk(alloc, input, false);
    defer alloc.free(res.value.lines);

    try testing.expectEqual(true, res.value.end_of_file);
    try testing.expectEqual(@as(usize, 4), res.value.lines.len);
    try testing.expectEqualStrings("@@decorator", res.value.lines[0].context);
    try testing.expectEqualStrings("*** not a file marker", res.value.lines[1].context);
}

test "parseUpdateFile first context line may start with hunk marker text" {
    const alloc = testing.allocator;
    const input =
        "*** Update File: README.md\n" ++
        " @@literal text\n" ++
        "-old\n" ++
        "+new\n";
    const res = try parseUpdateFile(alloc, input);
    const upd = res.value.file_update;
    defer {
        for (upd.hunks) |h| alloc.free(h.lines);
        alloc.free(upd.hunks);
    }

    try testing.expectEqual(@as(usize, 1), upd.hunks.len);
    try testing.expectEqual(@as(?[]const u8, null), upd.hunks[0].header);
    try testing.expectEqualStrings("@@literal text", upd.hunks[0].lines[0].context);
}

test "applyHunks splice context + delete + add" {
    const alloc = testing.allocator;
    const src = "alpha\nbeta\ngamma\ndelta\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "alpha" },
        .{ .delete = "beta" },
        .{ .add = "BETA" },
        .{ .context = "gamma" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("alpha\nBETA\ngamma\ndelta\n", out);
}

test "applyHunks pure delete" {
    const alloc = testing.allocator;
    const src = "one\ntwo\nthree\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "one" },
        .{ .delete = "two" },
        .{ .context = "three" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("one\nthree\n", out);
}

test "applyHunks anchor miss populates diag" {
    const alloc = testing.allocator;
    const src = "x\ny\nz\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "missing" },
        .{ .delete = "y" },
        .{ .add = "Y" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    try testing.expectError(ApplyError.HunkAnchorNotFound, applyHunks(alloc, src, &hunks, &diag));
    try testing.expectEqualStrings("missing", diag.expected_anchor);
    try testing.expectEqual(@as(usize, 0), diag.hunk_index);
}

test "applyHunks matches with trailing whitespace tolerance" {
    const alloc = testing.allocator;
    const src = "alpha   \nbeta\t\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "alpha" },
        .{ .delete = "beta" },
        .{ .add = "BETA" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("alpha\nBETA\n", out);
}

test "applyHunks matches with full trim tolerance" {
    const alloc = testing.allocator;
    const src = "    alpha\n    beta\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "alpha" },
        .{ .delete = "beta" },
        .{ .add = "BETA" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("alpha\nBETA\n", out);
}

test "applyHunks matches normalized unicode punctuation" {
    const alloc = testing.allocator;
    const src = "note: local import – avoids top‑level dep\n";

    const hunk_lines = [_]HunkLine{
        .{ .delete = "note: local import - avoids top-level dep" },
        .{ .add = "note: local import - avoids module dep" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = false }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("note: local import - avoids module dep\n", out);
}

test "applyHunks header repositions cursor after earlier edit" {
    const alloc = testing.allocator;
    const src = "fn first() {\n    old();\n}\n\nfn second() {\n    old();\n}\n";

    const h1_lines = [_]HunkLine{
        .{ .context = "fn first() {" },
        .{ .delete = "    old();" },
        .{ .add = "    new_first();" },
        .{ .context = "}" },
    };
    const h2_lines = [_]HunkLine{
        .{ .delete = "    old();" },
        .{ .add = "    new_second();" },
    };
    const hunks = [_]Hunk{
        .{ .header = null, .lines = &h1_lines, .end_of_file = false },
        .{ .header = "fn second() {", .lines = &h2_lines, .end_of_file = false },
    };

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("fn first() {\n    new_first();\n}\n\nfn second() {\n    new_second();\n}\n", out);
}

test "applyHunks end-of-file hunk anchors at tail" {
    const alloc = testing.allocator;
    const src = "target\nmiddle\ntarget\n";

    const hunk_lines = [_]HunkLine{
        .{ .context = "target" },
        .{ .add = "tail" },
        .{ .context = "" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = true }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("target\nmiddle\ntarget\ntail\n", out);
}

test "applyHunks pure add at end inserts before trailing newline sentinel" {
    const alloc = testing.allocator;
    const src = "alpha\n";

    const hunk_lines = [_]HunkLine{
        .{ .add = "omega" },
    };
    const hunks = [_]Hunk{.{ .header = null, .lines = &hunk_lines, .end_of_file = true }};

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("alpha\nomega\n", out);
}

test "applyHunks two hunks sequential, second after first" {
    const alloc = testing.allocator;
    const src = "a\nb\nc\nd\ne\nf\n";

    const h1_lines = [_]HunkLine{
        .{ .context = "a" },
        .{ .delete = "b" },
        .{ .add = "B" },
    };
    const h2_lines = [_]HunkLine{
        .{ .context = "d" },
        .{ .delete = "e" },
        .{ .add = "E" },
    };
    const hunks = [_]Hunk{
        .{ .header = null, .lines = &h1_lines, .end_of_file = false },
        .{ .header = null, .lines = &h2_lines, .end_of_file = false },
    };

    var diag: ApplyDiagnostics = .{};
    const out = try applyHunks(alloc, src, &hunks, &diag);
    defer alloc.free(out);

    try testing.expectEqualStrings("a\nB\nc\nd\nE\nf\n", out);
}
