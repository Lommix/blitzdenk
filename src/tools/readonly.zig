const std = @import("std");
const r = @import("root.zig");

const SEARCH_TIMEOUT_MS = 10_000;
const MAX_CONTEXT_LINES = 100;
const MAX_CAPTURE_BYTES = 4 * 1024 * 1024;
const MAX_STDERR_BYTES = 512;
const MAX_STDERR_LINES = 5;

pub const SET_READONLY = [_][]const u8{ GrepTool.def.name, FindTool.def.name, LsTool.def.name };

pub const GrepTool = r.Tool{
    .def = .{
        .name = "grep",
        .description =
        \\Search file contents with ripgrep. Use this for definitions, references, error messages, configuration keys, and any other content search; use find when you only need filenames.
        \\
        \\`pattern` is a regular expression by default; set `literal` when punctuation must be matched literally. `file_path` narrows the search, `glob` filters files, `context` includes surrounding lines, and `filesOnly` lists matching files instead of lines. Results respect .gitignore, include hidden files but skip `.git`, include file paths and line numbers, cut lines longer than 300 columns, and keep the first
        ++ r.DISPLAY_CAP_TEXT ++
            \\; the full result spills to a file. Unreadable paths do not fail the search: matches come back with a warning. The search stops after 4MB of output or 10 seconds and returns a partial result.
            \\
            \\Every field is data, not a shell fragment. Do not add `rg`, shell quoting, or pipes to any argument.
        ,
        .prompt_snippet = "Search file contents",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {"type": "string", "description": "Search pattern (regex or literal string)"},
        \\    "file_path": {"type": "string", "default": ".", "description": "File or directory to search, relative to the current working directory or absolute"},
        \\    "glob": {"type": "string", "description": "Filter files by glob pattern, e.g. `*.zig` or `src/**/*.zig`"},
        \\    "ignoreCase": {"type": "boolean", "default": false, "description": "Case-insensitive search (default: false)"},
        \\    "literal": {"type": "boolean", "default": false, "description": "Treat pattern as literal string instead of regex (default: false)"},
        \\    "context": {"type": "number", "minimum": 0, "maximum": 100, "default": 0, "description": "Number of lines to show before and after each match (default: 0)"},
        \\    "filesOnly": {"type": "boolean", "default": false, "description": "Only list paths of files with a match (default: false)"}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runGrep,
};

pub const FindTool = r.Tool{
    .def = .{
        .name = "find",
        .description =
        \\Find files and directories by name with fd. Use this whenever you need to discover files by name, extension, or path shape; use grep when you need to search file contents.
        \\
        \\`pattern` is a regular expression matched against the file name by default; set `glob` to match it as a glob, e.g. `*.zig`. A pattern containing `/` matches the full absolute path instead (unanchored), e.g. `src/*.zig` or `tools/.*\.zig$`. Matching is case-sensitive when the pattern has an uppercase letter, unless `ignoreCase` is set. `file_path` narrows the directory being searched, `type` limits results to files or directories. Results respect ignore files, include hidden files but skip `.git`, are sorted by path, and keep the first
        ++ r.DISPLAY_CAP_TEXT ++
            \\; the full result spills to a file. The search stops after 4MB of output or 10 seconds and returns a partial result.
            \\
            \\Every field is data, not a shell fragment. Do not add `fd`, `find`, shell syntax, or pipes to any argument.
        ,
        .prompt_snippet = "Find files by name",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {"type": "string", "description": "Name pattern (regex, or glob when `glob` is set), e.g. `\\.zig$` or `*.zig`"},
        \\    "file_path": {"type": "string", "default": ".", "description": "Directory to search in, relative to the current working directory or absolute"},
        \\    "glob": {"type": "boolean", "default": false, "description": "Treat pattern as a glob instead of a regex (default: false)"},
        \\    "ignoreCase": {"type": "boolean", "default": false, "description": "Case-insensitive match (default: smart case)"},
        \\    "type": {"type": "string", "enum": ["file", "directory"], "description": "Only return files or only directories"}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runFind,
};

pub const LsTool = r.Tool{
    .def = .{
        .name = "ls",
        .description =
        \\List the entries of one directory, sorted by name. Directories end in `/`, symlinks in `@`. Hidden and ignored entries are included. Output keeps the first
        ++ r.DISPLAY_CAP_TEXT ++
            \\; the full listing spills to a file.
        ,
        .prompt_snippet = "List a directory",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "file_path": {"type": "string", "default": ".", "description": "Directory to list, relative to the current working directory or absolute"}
        \\  }
        \\}
        ,
    },
    .func = &runLs,
};

fn statusSearch(ctx: r.ToolContext, call: r.ToolCall, label: []const u8, pattern: []const u8, path: []const u8) void {
    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, label);
    w.styled(.{ .fg = app.theme.muted }, pattern);
    w.print(" ", .{});
    w.styled(.{ .fg = app.theme.muted, .modifier = .{ .bold = true } }, path);

    r.setToolStatus(ctx, call, w.finish()) catch {};
}

const GrepArgs = struct {
    pattern: []const u8,
    file_path: []const u8 = ".",
    glob: ?[]const u8 = null,
    ignoreCase: bool = false,
    literal: bool = false,
    context: u32 = 0,
    filesOnly: bool = false,
};

const FindArgs = struct {
    pattern: []const u8,
    file_path: []const u8 = ".",
    glob: bool = false,
    ignoreCase: bool = false,
    type: ?enum { file, directory } = null,
};

const LsArgs = struct { file_path: []const u8 = "." };

fn runGrep(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const args = switch (parseStrict(GrepArgs, ctx.alloc, call.input)) {
        .ok => |a| a,
        .err => |msg| return r.errResult(call, msg),
    };

    if (validateCommon(args.pattern, args.file_path)) |msg| return r.errResult(call, msg);
    if (args.context > MAX_CONTEXT_LINES) return r.errResult(call, "context must be between 0 and 100");

    statusSearch(ctx, call, "grep ", args.pattern, args.file_path);

    const argv = grepArgv(ctx.alloc, ctx.base.cwd, args) catch |err| switch (err) {
        error.EmptyGlob => return r.errResult(call, "glob must not be empty"),
        else => return r.errResult(call, "failed to build grep command"),
    };

    return runSearch(ctx, call, argv, .{
        .kind = "grep",
        .pattern = args.pattern,
        .file_path = args.file_path,
        .regex = !args.literal,
        .no_match_exit = 1,
        .empty_message = "No matches found.",
    });
}

fn grepArgv(alloc: std.mem.Allocator, cwd: []const u8, args: GrepArgs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "rg", "--color=never", "--no-heading", "--line-number", "--with-filename", "--hidden", "--max-columns=300", "--max-columns-preview" });
    if (args.ignoreCase) try argv.append(alloc, "--ignore-case");
    if (args.literal) try argv.append(alloc, "--fixed-strings");
    if (args.filesOnly) try argv.append(alloc, "--files-with-matches");
    if (args.glob) |g| {
        if (g.len == 0) return error.EmptyGlob;
        try argv.appendSlice(alloc, &.{ "--glob", try resolveGlobForSearchPath(alloc, cwd, args.file_path, g) });
    }
    // Last glob wins in rg, so this one overrides a caller glob matching `.git`.
    try argv.appendSlice(alloc, &.{ "--glob", "!.git" });
    if (args.context > 0) try argv.appendSlice(alloc, &.{ "--context", try std.fmt.allocPrint(alloc, "{d}", .{args.context}) });
    try argv.appendSlice(alloc, &.{ "--regexp", args.pattern, "--" });
    try appendSearchPath(alloc, &argv, args.file_path);
    return argv.items;
}

fn runFind(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const args = switch (parseStrict(FindArgs, ctx.alloc, call.input)) {
        .ok => |a| a,
        .err => |msg| return r.errResult(call, msg),
    };

    if (validateCommon(args.pattern, args.file_path)) |msg| return r.errResult(call, msg);

    statusSearch(ctx, call, "find ", args.pattern, args.file_path);

    const argv = findArgv(ctx.alloc, args) catch return r.errResult(call, "failed to build find command");
    return runSearch(ctx, call, argv, .{
        .kind = "find",
        .pattern = args.pattern,
        .file_path = args.file_path,
        .regex = !args.glob,
        .sort = true,
        .empty_message = "No files matched.",
    });
}

fn findArgv(alloc: std.mem.Allocator, args: FindArgs) ![]const []const u8 {
    // fd rejects a `/` in a name pattern; match those against the full
    // (absolute) path, and let a relative glob start at any depth.
    const full_path = std.mem.indexOfScalar(u8, args.pattern, '/') != null;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "fd", "--color=never", "--hidden", "--exclude", ".git" });
    if (args.glob) try argv.append(alloc, "--glob");
    if (args.ignoreCase) try argv.append(alloc, "--ignore-case");
    if (full_path) try argv.append(alloc, "--full-path");
    if (args.type) |kind| try argv.appendSlice(alloc, &.{ "--type", if (kind == .file) "f" else "d" });
    const pattern = if (full_path and args.glob and args.pattern[0] != '/' and !std.mem.startsWith(u8, args.pattern, "**"))
        try std.mem.concat(alloc, u8, &.{ "**/", args.pattern })
    else
        args.pattern;
    // `--` first: a pattern like `-x` or `--hidden` is a positional, not an option.
    try argv.appendSlice(alloc, &.{ "--", pattern });
    try appendSearchPath(alloc, &argv, args.file_path);
    return argv.items;
}

fn runLs(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const args = switch (parseStrict(LsArgs, ctx.alloc, call.input)) {
        .ok => |a| a,
        .err => |msg| return r.errResult(call, msg),
    };
    if (args.file_path.len == 0) return r.errResult(call, "path is empty");

    statusSearch(ctx, call, "ls", "", args.file_path);

    const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.base.cwd, args.file_path }) catch
        return r.errResult(call, "failed to resolve path");
    const listing = listDir(ctx.io, ctx.alloc, resolved) catch |err|
        return r.errResult(call, r.fsFailure(ctx, "ls", args.file_path, err));
    if (listing.len == 0) return r.okResult(call, "Directory is empty.");
    return r.okResult(call, capHead(ctx, call, listing));
}

/// Parse tool arguments and reject unknown keys, so a misspelled filter
/// fails loudly instead of silently doing nothing.
fn parseStrict(comptime T: type, alloc: std.mem.Allocator, input: []const u8) union(enum) { ok: T, err: []const u8 } {
    const names = @typeInfo(T).@"struct".field_names;
    const valid = comptime blk: {
        var list: []const u8 = "";
        for (names, 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
        break :blk list;
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return .{ .err = "invalid JSON arguments" };
    if (value != .object) return .{ .err = "arguments must be a JSON object" };
    for (value.object.keys()) |key| {
        const known = for (names) |name| {
            if (std.mem.eql(u8, name, key)) break true;
        } else false;
        if (!known) return .{ .err = std.fmt.allocPrint(alloc, "unknown argument `{s}`; valid arguments: " ++ valid, .{key}) catch "unknown argument" };
    }
    const args = std.json.parseFromValueLeaky(T, alloc, value, .{}) catch
        return .{ .err = "invalid arguments; valid arguments: " ++ valid };
    return .{ .ok = args };
}

/// Listings and matches read top-down: keep the head, unlike the tail cap of
/// command output, and point at the spill file for the rest.
fn capHead(ctx: r.ToolContext, call: r.ToolCall, output: []const u8) []const u8 {
    if (!r.isOversized(output, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES)) return output;
    const head = headLines(output, r.MAX_DISPLAY_BYTES - 1024, r.MAX_DISPLAY_LINES - 2);
    const spill = r.writeSpillFile(ctx.io, ctx.alloc, call.id, output);
    const where = if (spill) |path|
        std.fmt.allocPrint(ctx.alloc, " Full result saved at: {s} — call read with offset/limit to page through it, or narrow the query.", .{path}) catch ""
    else
        " Narrow the query.";
    return std.fmt.allocPrint(ctx.alloc, "{s}\n[Truncated: kept head {d} of {d} lines (" ++ r.DISPLAY_CAP_TEXT ++ " cap).{s}]", .{
        head.text, head.lines, r.countLines(output), where,
    }) catch head.text;
}

/// Whole leading lines of `output` within `max_bytes` and `max_lines`.
fn headLines(output: []const u8, max_bytes: usize, max_lines: usize) struct { text: []const u8, lines: usize } {
    const budget = output[0..@min(output.len, max_bytes)];
    var end: usize = 0;
    var lines: usize = 0;
    while (lines < max_lines) : (lines += 1) {
        end = (std.mem.indexOfScalarPos(u8, budget, end, '\n') orelse break) + 1;
    }
    return .{ .text = output[0..end], .lines = lines };
}

fn listDir(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const suffix: []const u8 = switch (entry.kind) {
            .directory => "/",
            .sym_link => "@",
            else => "",
        };
        try names.append(alloc, try std.mem.concat(alloc, u8, &.{ entry.name, suffix }));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return joinLines(alloc, names.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn joinLines(alloc: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    const joined = try std.mem.join(alloc, "\n", lines);
    return std.mem.concat(alloc, u8, &.{ joined, "\n" });
}

fn validateCommon(pattern: []const u8, file_path: []const u8) ?[]const u8 {
    if (pattern.len == 0) return "pattern is empty";
    if (file_path.len == 0) return "path is empty";
    return null;
}

/// Ripgrep evaluates slash-containing globs against paths rooted at its cwd,
/// even when the search operand is narrower. Expose the less surprising tool
/// contract that such globs are relative to `path`, while continuing to accept
/// callers that already supplied the cwd-relative `path/…` form.
fn resolveGlobForSearchPath(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    path_arg: []const u8,
    pattern_arg: []const u8,
) ![]const u8 {
    const relative_path = if (std.fs.path.isAbsolute(path_arg) and std.fs.path.isAbsolute(cwd))
        try std.fs.path.relative(alloc, cwd, null, cwd, path_arg)
    else
        path_arg;
    const relative_pattern = if (std.fs.path.isAbsolute(pattern_arg) and std.fs.path.isAbsolute(cwd))
        try std.fs.path.relative(alloc, cwd, null, cwd, pattern_arg)
    else
        pattern_arg;
    const path = stripDotSlash(std.mem.trimEnd(u8, relative_path, "/"));
    const pattern = stripDotSlash(relative_pattern);
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return pattern;
    if (std.fs.path.isAbsolute(pattern)) return pattern;
    if (std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../")) {
        if (std.mem.indexOfScalar(u8, pattern, '/') != null and !std.mem.startsWith(u8, pattern, "**")) {
            return std.fmt.allocPrint(alloc, "**/{s}", .{pattern});
        }
        return pattern;
    }
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) return pattern;

    if (std.mem.startsWith(u8, pattern, path) and
        pattern.len > path.len and pattern[path.len] == '/') return pattern;

    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, pattern });
}

fn stripDotSlash(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "./")) value[2..] else value;
}

/// Omitting the default `.` operand keeps paths relative without a leading
/// `./`, consistently across grep and find output. Callers put `--` first.
fn appendSearchPath(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), file_path: []const u8) !void {
    if (!std.mem.eql(u8, file_path, ".")) try argv.append(alloc, file_path);
}

const SearchFailureContext = struct {
    kind: []const u8,
    pattern: []const u8,
    file_path: []const u8,
    regex: bool = false,
    /// Exit code meaning "ran fine, found nothing" (ripgrep uses 1).
    no_match_exit: ?u8 = null,
    /// Sort output lines; fd walks in parallel and prints in arbitrary order.
    sort: bool = false,
    empty_message: []const u8,
};

fn runSearch(
    ctx: r.ToolContext,
    call: r.ToolCall,
    argv: []const []const u8,
    failure: SearchFailureContext,
) r.ToolResult {
    const raw = ctx.base.exec_pool.runAndWaitTimeout(.{
        .cwd = ctx.base.cwd,
        .argv = argv,
        .max_output = MAX_CAPTURE_BYTES,
        .keep_head = true,
    }, SEARCH_TIMEOUT_MS) catch {
        const message = std.fmt.allocPrint(ctx.alloc, "{s} failed for pattern `{s}` in `{s}`: could not spawn `{s}`", .{
            failure.kind, failure.pattern, failure.file_path, argv[0],
        }) catch return r.errResult(call, "failed to spawn search process");
        return r.errResult(call, message);
    };
    defer ctx.base.exec_pool.alloc.free(raw.stdout);
    defer ctx.base.exec_pool.alloc.free(raw.stderr);

    const stderr = std.mem.trim(u8, raw.stderr, " \t\r\n");
    if (raw.stdout.len == 0) {
        if (raw.ty == .timeout) return r.errResult(call, "search timed out after 10 seconds; narrow path or filters and retry");
        if (failure.no_match_exit != null and raw.exit_code == failure.no_match_exit) return r.okResult(call, failure.empty_message);
        if (raw.ty == .failed) {
            const content = formatSearchError(ctx.alloc, failure, raw.exit_code, stderr) catch
                return r.errResult(call, "failed to format search error");
            return r.errResult(call, content);
        }
        if (stderr.len == 0) return r.okResult(call, failure.empty_message);
    }

    // A capture stopped at the cap ends mid-line; keep whole lines.
    const captured = if (!raw.stdout_truncated)
        raw.stdout
    else if (std.mem.lastIndexOfScalar(u8, raw.stdout, '\n')) |nl|
        raw.stdout[0 .. nl + 1]
    else
        "";
    // Copy out of the exec pool; it frees its buffers before the result commits.
    const body = (if (failure.sort) sortLines(ctx.alloc, captured) else ctx.alloc.dupe(u8, captured)) catch
        return r.errResult(call, "failed to format search output");

    const partial: []const u8 = if (raw.stdout_truncated)
        "\n[Partial: output passed the 4MB capture cap and the search stopped early; narrow the query for complete results.]"
    else if (raw.ty == .timeout)
        "\n[Partial: search timed out after 10 seconds; narrow the query for complete results.]"
    else
        "";
    const warning = if (stderr.len == 0) "" else std.fmt.allocPrint(ctx.alloc, "\n[Warning: some paths could not be searched:\n{s}]", .{stderrNote(ctx.alloc, stderr)}) catch "";
    const output = std.mem.concat(ctx.alloc, u8, &.{ capHead(ctx, call, body), partial, warning }) catch
        return r.errResult(call, "failed to format search output");
    return r.okResult(call, output);
}

/// First lines of a search's stderr; one unreadable path per line can run long.
fn stderrNote(alloc: std.mem.Allocator, stderr: []const u8) []const u8 {
    const total = r.countLines(stderr);
    if (stderr.len <= MAX_STDERR_BYTES and total <= MAX_STDERR_LINES) return stderr;
    const head = headLines(stderr, MAX_STDERR_BYTES, MAX_STDERR_LINES);
    return std.fmt.allocPrint(alloc, "{s}… {d} more lines", .{ head.text, total - head.lines }) catch head.text;
}

fn sortLines(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try lines.append(alloc, line);
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    return joinLines(alloc, lines.items);
}

fn formatSearchError(
    alloc: std.mem.Allocator,
    failure: SearchFailureContext,
    exit_code: ?u8,
    stderr: []const u8,
) ![]const u8 {
    if (failure.regex and std.mem.indexOf(u8, stderr, "regex parse error") != null) {
        const detail = lastErrorDetail(stderr) orelse "invalid regular expression";
        return std.fmt.allocPrint(alloc, "invalid regular expression `{s}` for path `{s}`: {s}", .{
            failure.pattern, failure.file_path, detail,
        });
    }

    const detail = if (stderr.len == 0) "search process produced no error output" else stderrNote(alloc, stderr);
    if (exit_code) |code| {
        return std.fmt.allocPrint(alloc, "{s} failed for pattern `{s}` in `{s}` (exit code {d}): {s}", .{
            failure.kind, failure.pattern, failure.file_path, code, detail,
        });
    }
    return std.fmt.allocPrint(alloc, "{s} failed for pattern `{s}` in `{s}`: {s}", .{
        failure.kind, failure.pattern, failure.file_path, detail,
    });
}

fn lastErrorDetail(stderr: []const u8) ?[]const u8 {
    const marker = "error: ";
    const start = std.mem.lastIndexOf(u8, stderr, marker) orelse return null;
    const remaining = stderr[start + marker.len ..];
    const end = std.mem.indexOfAny(u8, remaining, "\r\n") orelse remaining.len;
    return remaining[0..end];
}

test "resolveGlobForSearchPath roots slash globs at the search path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("*.zig", try resolveGlobForSearchPath(a, "/p", "src", "*.zig"));
    try std.testing.expectEqualStrings("src/tools/*.zig", try resolveGlobForSearchPath(a, "/p", "src", "tools/*.zig"));
    try std.testing.expectEqualStrings("src/tools/*.zig", try resolveGlobForSearchPath(a, "/p", "./src/", "src/tools/*.zig"));
    try std.testing.expectEqualStrings("src/tools/*.zig", try resolveGlobForSearchPath(a, "/p", "/p/src", "tools/*.zig"));
    try std.testing.expectEqualStrings("**/a/*.zig", try resolveGlobForSearchPath(a, "/p", "../x", "a/*.zig"));
}

fn expectArgvHas(argv: []const []const u8, seq: []const []const u8) !void {
    for (0..argv.len -| seq.len + 1) |i| {
        for (seq, 0..) |want, j| {
            if (!std.mem.eql(u8, argv[i + j], want)) break;
        } else return;
    }
    return error.TestExpectedSequence;
}

test "find puts `--` before dash-leading patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "-x", "--hidden", "--" }) |pattern| {
        const argv = try findArgv(a, .{ .pattern = pattern, .file_path = "src" });
        try std.testing.expectEqualStrings("src", argv[argv.len - 1]);
        try std.testing.expectEqualStrings(pattern, argv[argv.len - 2]);
        try std.testing.expectEqualStrings("--", argv[argv.len - 3]);
    }
    const cwd_argv = try findArgv(a, .{ .pattern = "-x" });
    try std.testing.expectEqualStrings("-x", cwd_argv[cwd_argv.len - 1]);
    try std.testing.expectEqualStrings("--", cwd_argv[cwd_argv.len - 2]);
}

test "grep binds the pattern to --regexp, ends options before the path, and skips .git" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try grepArgv(arena.allocator(), "/p", .{ .pattern = "-x", .file_path = "-src", .glob = "*.zig" });
    try expectArgvHas(argv, &.{ "--regexp", "-x", "--", "-src" });
    try expectArgvHas(argv, &.{ "--glob", "*.zig", "--glob", "!.git" });
}

test "parseStrict rejects unknown and misspelled arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = parseStrict(GrepArgs, a, "{\"pattern\":\"x\",\"ignorecase\":true}");
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "`ignorecase`") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "ignoreCase") != null);
    try std.testing.expect(parseStrict(FindArgs, a, "{\"pattern\":\"x\",\"bogus_field\":1}") == .err);
    const ok = parseStrict(FindArgs, a, "{\"pattern\":\"x\",\"type\":\"file\",\"ignoreCase\":true}");
    try std.testing.expect(ok.ok.ignoreCase and ok.ok.type.? == .file);
}

test "stderrNote caps long error output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("one", stderrNote(arena.allocator(), "one"));
    const long = "e1\ne2\ne3\ne4\ne5\ne6\ne7";
    try std.testing.expectEqualStrings("e1\ne2\ne3\ne4\ne5\n… 2 more lines", stderrNote(arena.allocator(), long));
}

test "headLines keeps whole leading lines within both caps" {
    const text = "aa\nbb\ncc\n";
    try std.testing.expectEqualStrings("aa\nbb\n", headLines(text, 64, 2).text);
    try std.testing.expectEqualStrings("aa\n", headLines(text, 5, 10).text);
    try std.testing.expectEqual(@as(usize, 1), headLines(text, 5, 10).lines);
    try std.testing.expectEqualStrings("", headLines(text, 2, 10).text);
}

test "listDir sorts entries and marks directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    try tmp.dir.createDirPath(io, "a");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    try std.testing.expectEqualStrings(".hidden\na/\nb.txt\n", try listDir(io, arena.allocator(), root));
}

test "runSearch keeps matches when some paths fail and errors only without matches" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var pool = r.r.exec.CmdPool.init(std.testing.allocator, std.testing.io, &env);
    defer pool.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: r.ToolContext = .{ .alloc = arena.allocator(), .io = std.testing.io, .base = .{
        .registry = undefined,
        .exec_pool = &pool,
        .self_id = undefined,
        .cwd = "/tmp",
    } };
    const call: r.ToolCall = .{ .id = "t", .name = "grep", .input = "{}" };
    const failure: SearchFailureContext = .{ .kind = "grep", .pattern = "p", .file_path = ".", .no_match_exit = 1, .empty_message = "none" };

    const partial = runSearch(ctx, call, &.{ "/bin/sh", "-c", "echo a:1:hit; echo 'b: Permission denied' >&2; exit 2" }, failure);
    try std.testing.expect(!partial.is_error);
    try std.testing.expect(std.mem.startsWith(u8, partial.content, "a:1:hit\n"));
    try std.testing.expect(std.mem.indexOf(u8, partial.content, "[Warning: some paths could not be searched:\nb: Permission denied]") != null);

    const failed = runSearch(ctx, call, &.{ "/bin/sh", "-c", "echo 'b: Permission denied' >&2; exit 2" }, failure);
    try std.testing.expect(failed.is_error);

    const empty = runSearch(ctx, call, &.{ "/bin/sh", "-c", "exit 1" }, failure);
    try std.testing.expectEqualStrings("none", empty.content);
}
