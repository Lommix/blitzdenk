const std = @import("std");
const r = @import("root.zig");

const SEARCH_TIMEOUT_MS = 10_000;
const MAX_CONTEXT_LINES = 100;

pub const GlobTool = r.Tool{
    .def = .{
        .name = "glob",
        .description =
        \\Find files by path glob. Use this whenever you need to discover files by name, extension, or path shape; use grep when you need to search file contents.
        \\
        \\`pattern` is a gitignore-style glob matched against paths, e.g. `**/*.zig` or `src/**/*.zig`. `file_path` narrows the directory being searched. Results respect ignore files, are sorted by path, and are truncated to
        ++ r.DISPLAY_CAP_TEXT ++
            \\.
            \\
            \\Every field is data, not a shell fragment. Do not add `rg`, `find`, shell syntax, or pipes to any argument.
        ,
        .prompt_snippet = "Find files by glob",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {"type": "string", "description": "Glob pattern to match files, e.g. `**/*.zig` or `src/**/*.zig`"},
        \\    "file_path": {"type": "string", "default": ".", "description": "Directory to search in, relative to the current working directory or absolute"}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runGlob,
};

pub const GrepTool = r.Tool{
    .def = .{
        .name = "grep",
        .description =
        \\Search file contents for patterns. Use this for definitions, references, error messages, configuration keys, and any other content search; use glob when you only need filenames.
        \\
        \\`pattern` is a regular expression by default; set `literal` when punctuation must be matched literally. `file_path` narrows the search, `glob` filters files, and `context` includes surrounding lines. Results respect .gitignore, include file paths and line numbers, and are truncated to
        ++ r.DISPLAY_CAP_TEXT ++
            \\.
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
        \\    "context": {"type": "number", "minimum": 0, "maximum": 100, "default": 0, "description": "Number of lines to show before and after each match (default: 0)"}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runGrep,
};

const GlobArgs = struct {
    pattern: []const u8,
    file_path: []const u8 = ".",
};

const GrepArgs = struct {
    pattern: []const u8,
    file_path: []const u8 = ".",
    glob: ?[]const u8 = null,
    ignoreCase: bool = false,
    literal: bool = false,
    context: u32 = 0,
};

fn statusSearch(ctx: r.ToolContext, call: r.r.sdk.ToolCall, label: []const u8, pattern: []const u8, path: []const u8) void {
    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, label);
    w.styled(.{ .fg = app.theme.muted }, pattern);
    w.styled(.{ .fg = app.theme.muted, .modifier = .{ .bold = true } }, path);

    r.setToolStatus(ctx, call, w.finish()) catch {};
}

fn runGlob(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = std.json.parseFromSliceLeaky(GlobArgs, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments for glob");

    if (validateCommon(args.pattern, args.file_path)) |msg| return r.errResult(call, msg);

    statusSearch(ctx, call, "glob ", args.pattern, args.file_path);

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.alloc, &.{ "rg", "--files", "--sort=path" }) catch
        return r.errResult(call, "failed to build glob command");
    argv.append(ctx.alloc, "--hidden") catch
        return r.errResult(call, "failed to build glob command");
    appendIncludeGlob(ctx.alloc, &argv, ctx.base.cwd, args.file_path, args.pattern) catch
        return r.errResult(call, "failed to build glob command");
    appendSearchPath(ctx.alloc, &argv, args.file_path) catch
        return r.errResult(call, "failed to build glob command");

    return runSearch(ctx, call, argv.items, .{
        .kind = "glob",
        .pattern = args.pattern,
        .file_path = args.file_path,
        .empty_message = "No files matched.",
    });
}

fn runGrep(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = std.json.parseFromSliceLeaky(GrepArgs, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments for grep");

    if (validateCommon(args.pattern, args.file_path)) |msg| return r.errResult(call, msg);
    if (args.context > MAX_CONTEXT_LINES) {
        return r.errResult(call, "context must be between 0 and 100");
    }

    statusSearch(ctx, call, "grep ", args.pattern, args.file_path);

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.alloc, &.{ "rg", "--color=never", "--no-heading", "--line-number", "--with-filename" }) catch
        return r.errResult(call, "failed to build grep command");

    if (args.ignoreCase) argv.append(ctx.alloc, "--ignore-case") catch
        return r.errResult(call, "failed to build grep command");
    if (args.literal) argv.append(ctx.alloc, "--fixed-strings") catch
        return r.errResult(call, "failed to build grep command");

    if (args.glob) |glob| {
        if (glob.len == 0) return r.errResult(call, "glob must not be empty");
        appendIncludeGlob(ctx.alloc, &argv, ctx.base.cwd, args.file_path, glob) catch
            return r.errResult(call, "failed to build grep command");
    }
    argv.append(ctx.alloc, "--hidden") catch
        return r.errResult(call, "failed to build grep command");

    if (args.context > 0) {
        const value = std.fmt.allocPrint(ctx.alloc, "{d}", .{args.context}) catch
            return r.errResult(call, "failed to build grep command");
        argv.appendSlice(ctx.alloc, &.{ "--context", value }) catch
            return r.errResult(call, "failed to build grep command");
    }

    argv.appendSlice(ctx.alloc, &.{ "--regexp", args.pattern }) catch
        return r.errResult(call, "failed to build grep command");
    appendSearchPath(ctx.alloc, &argv, args.file_path) catch
        return r.errResult(call, "failed to build grep command");

    return runSearch(ctx, call, argv.items, .{
        .kind = "grep",
        .pattern = args.pattern,
        .file_path = args.file_path,
        .regex = !args.literal,
        .empty_message = "No matches found.",
    });
}

fn validateCommon(pattern: []const u8, file_path: []const u8) ?[]const u8 {
    if (pattern.len == 0) return "pattern is empty";
    if (file_path.len == 0) return "path is empty";
    return null;
}

fn appendIncludeGlob(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    cwd: []const u8,
    file_path: []const u8,
    pattern: []const u8,
) !void {
    const resolved = try resolveGlobForSearchPath(alloc, cwd, file_path, pattern);
    try argv.appendSlice(alloc, &.{ "--glob", resolved });
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

/// Omitting the default `.` operand keeps ripgrep's paths relative without a
/// leading `./`, consistently across glob and grep output.
fn appendSearchPath(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), file_path: []const u8) !void {
    try argv.append(alloc, "--");
    if (!std.mem.eql(u8, file_path, ".")) try argv.append(alloc, file_path);
}

const SearchFailureContext = struct {
    kind: []const u8,
    pattern: []const u8,
    file_path: []const u8,
    regex: bool = false,
    empty_message: []const u8,
};

fn runSearch(
    ctx: r.ToolContext,
    call: r.r.sdk.ToolCall,
    search_argv: []const []const u8,
    failure: SearchFailureContext,
) r.r.sdk.ToolOutput {
    const raw = ctx.base.exec_pool.runAndWaitTimeout(.{
        .cwd = ctx.base.cwd,
        .argv = search_argv,
    }, SEARCH_TIMEOUT_MS) catch {
        const message = std.fmt.allocPrint(ctx.alloc, "{s} failed for pattern `{s}` in `{s}`: could not spawn search process", .{
            failure.kind, failure.pattern, failure.file_path,
        }) catch return r.errResult(call, "failed to spawn search process");
        return r.errResult(call, message);
    };
    defer ctx.base.exec_pool.alloc.free(raw.stdout);
    defer ctx.base.exec_pool.alloc.free(raw.stderr);

    if (raw.ty == .timeout) return r.errResult(call, "search timed out after 10 seconds; narrow path or globs and retry");
    // Ripgrep exit code 1 means the search completed successfully but found
    // nothing. It is not a process failure (exit code 2 is).
    if (raw.exit_code == 1) return r.okResult(call, failure.empty_message);
    if (raw.ty == .failed) {
        const content = formatSearchError(ctx.alloc, failure, raw.exit_code, raw.stderr) catch
            return r.errResult(call, "failed to format search error");
        return r.errResult(call, content);
    }
    if (raw.stdout.len == 0 and raw.stderr.len == 0) return r.okResult(call, failure.empty_message);

    const output: []const u8 = if (raw.stderr.len == 0)
        raw.stdout
    else
        std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ raw.stdout, raw.stderr }) catch
            return r.errResult(call, "failed to format search output");
    const content = copyTruncatedSpill(ctx, call.id, output) catch
        return r.errResult(call, "failed to format search output");

    return r.okResult(call, content);
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

    const detail = if (stderr.len == 0) "search process produced no error output" else std.mem.trimEnd(u8, stderr, "\r\n");
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
    const detail_start = start + marker.len;
    const remaining = stderr[detail_start..];
    const end = std.mem.indexOfAny(u8, remaining, "\r\n") orelse remaining.len;
    return remaining[0..end];
}

/// Process output is owned by CmdPool and freed before the ToolResult is
/// committed. Always make a final agent-owned copy: truncateOutputToOwned may
/// legally return its input unchanged when no truncation or UTF-8 repair is
/// needed.
fn copyTruncatedSpill(ctx: r.ToolContext, call_id: []const u8, borrowed: []const u8) ![]const u8 {
    const spill = if (r.isOversized(borrowed, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES))
        r.writeSpillFile(ctx.base.exec_pool, ctx.alloc, call_id, borrowed)
    else
        null;
    defer if (spill) |s| ctx.alloc.free(s);
    const truncated = r.truncateOutputToOwnedSpill(ctx.alloc, borrowed, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES, spill);
    return ctx.alloc.dupe(u8, truncated);
}
