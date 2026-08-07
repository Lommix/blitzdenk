const std = @import("std");
const r = @import("root.zig");

const SEARCH_TIMEOUT_MS = 10_000;
const MAX_CONTEXT_LINES = 100;

const CaseMode = enum {
    sensitive,
    insensitive,
};

pub const GlobTool = r.prv.tool.Tool{
    .def = .{
        .name = "glob",
        .description =
        \\Find files by path glob. Use this whenever you need to discover files by name, extension, or path shape; use grep instead when you need to search file contents.
        \\
        \\`pattern` is a gitignore-style glob matched against paths. Examples: `**/*.zig` finds Zig files recursively, `**/*.{zig,lua}` finds either extension using brace alternation, `src/**/test*.zig` finds matching tests below src, and `AGENTS.md` finds that filename at any depth. Use `additional_patterns` when unrelated globs should be ORed in one globally sorted search. Set `path` to narrow the directory being searched.
        \\
        \\Results respect ignore files and omit hidden files by default. `include_ignored` also enables hidden traversal so ignored hidden paths are not silently omitted. Results are sorted by path for stable output.
        \\
        \\Every field is data, not a shell fragment. Do not add `rg`, `find`, shell syntax, or pipes to any argument. Large results are truncated automatically.
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {"type": "string", "description": "Primary file-path glob to match, such as `**/*.zig`, `**/*.{zig,lua}`, or `AGENTS.md`. Brace groups are alternatives. This is a glob, not a regular expression."},
        \\    "additional_patterns": {"type": "array", "items": {"type": "string"}, "description": "Optional additional path globs ORed with `pattern` in the same search. Use this when brace alternatives cannot express the desired patterns; all results are sorted together."},
        \\    "path": {"type": "string", "default": ".", "description": "Directory to search, relative to the current working directory or absolute. Use the narrowest known directory for faster searches."},
        \\    "exclude": {"type": "array", "items": {"type": "string"}, "description": "Optional path globs to exclude, without a leading `!`, such as `vendor/**` or `**/*.generated.zig`."},
        \\    "case_mode": {"type": "string", "enum": ["sensitive", "insensitive"], "default": "sensitive", "description": "Whether path globs use case-sensitive matching. Set `insensitive` when filename case should not matter, independent of host filesystem behavior."},
        \\    "include_hidden": {"type": "boolean", "default": false, "description": "Include hidden files and directories. Ignore rules still apply unless `include_ignored` is also true."},
        \\    "include_ignored": {"type": "boolean", "default": false, "description": "Include files excluded by .gitignore, .ignore, and global ignore files, including hidden paths. Use sparingly because vendor/build trees can be large."},
        \\    "max_depth": {"type": "integer", "minimum": 0, "maximum": 1000, "description": "Maximum directory depth below `path`. A value of 1 includes only direct children; omit it for unlimited traversal."}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runGlob,
};

pub const GrepTool = r.prv.tool.Tool{
    .def = .{
        .name = "grep",
        .description =
        \\Search text inside files using ripgrep. Use this for definitions, references, error messages, configuration keys, and any other content search. Use glob instead when you only need filenames.
        \\
        \\`pattern` is a regular expression by default. Examples: `fn\s+render` finds function declarations, `TODO|FIXME` finds either word, and `literal.name` treats `.` as a wildcard. Set `fixed_strings` when punctuation must be matched literally or when you do not need regex syntax. Searches use smart case by default: lowercase patterns ignore case, while a pattern containing uppercase is case-sensitive.
        \\
        \\Narrow searches with `path` and `globs` whenever possible. Normal output includes file paths and line numbers. Use `context` when nearby lines matter.
        \\
        \\Every field is data, not a shell fragment. Do not add `rg`, shell quoting, or pipes to any argument. Large results are truncated automatically.
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {"type": "string", "description": "Regular expression to search for. Set `fixed_strings` to true to treat it as literal text instead."},
        \\    "path": {"type": "string", "default": ".", "description": "File or directory to search, relative to the current working directory or absolute. Use the narrowest known path for speed and relevance."},
        \\    "globs": {"type": "array", "items": {"type": "string"}, "description": "Optional file-path globs to include, relative to `path`, such as `*.zig` or `tui/**/*.zig`. A cwd-relative form beginning with `path` is also accepted. These filter files; they do not search their contents."},
        \\    "exclude": {"type": "array", "items": {"type": "string"}, "description": "Optional file-path globs to exclude, without a leading `!`, such as `vendor/**` or `**/fixtures/**`."},
        \\    "case_mode": {"type": "string", "enum": ["sensitive", "insensitive"], "description": "Explicit case override. Omit this field for smart case: lowercase patterns ignore case while patterns containing uppercase are case-sensitive."},
        \\    "fixed_strings": {"type": "boolean", "default": false, "description": "Treat the entire pattern as literal text instead of a regular expression. Prefer this for exact strings containing regex punctuation."},
        \\    "context": {"type": "integer", "minimum": 0, "maximum": 100, "default": 0, "description": "Number of lines to show before and after each match."},
        \\    "include_hidden": {"type": "boolean", "default": false, "description": "Search hidden files and directories. Ignore rules still apply unless `include_ignored` is also true."},
        \\    "include_ignored": {"type": "boolean", "default": false, "description": "Search files excluded by .gitignore, .ignore, and global ignore files, including hidden paths. Use sparingly because vendor/build trees can be large."}
        \\  },
        \\  "required": ["pattern"]
        \\}
        ,
    },
    .func = &runGrep,
};

const GlobArgs = struct {
    pattern: []const u8,
    additional_patterns: []const []const u8 = &.{},
    path: []const u8 = ".",
    exclude: []const []const u8 = &.{},
    case_mode: CaseMode = .sensitive,
    include_hidden: bool = false,
    include_ignored: bool = false,
    max_depth: ?u32 = null,
};

const GrepArgs = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    globs: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    case_mode: ?CaseMode = null,
    fixed_strings: bool = false,
    context: u32 = 0,
    include_hidden: bool = false,
    include_ignored: bool = false,
};

fn runGlob(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const args = std.json.parseFromSliceLeaky(GlobArgs, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments for glob");

    if (validateCommon(args.pattern, args.path)) |msg| return r.errResult(call, msg);
    if (args.max_depth) |depth| {
        if (depth > 1000) return r.errResult(call, "max_depth must be between 0 and 1000");
    }

    r.setToolStatusPrint(ctx, call, "glob  {s}  {s}", .{ args.pattern, args.path });

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.alloc, &.{ "rg", "--files", "--sort=path" }) catch
        return r.errResult(call, "failed to build glob command");
    if (args.case_mode == .insensitive) argv.append(ctx.alloc, "--glob-case-insensitive") catch
        return r.errResult(call, "failed to build glob command");
    appendWalkOptions(ctx.alloc, &argv, args.include_hidden, args.include_ignored) catch
        return r.errResult(call, "failed to build glob command");
    if (args.max_depth) |depth| {
        const value = std.fmt.allocPrint(ctx.alloc, "{d}", .{depth}) catch
            return r.errResult(call, "failed to build glob command");
        argv.appendSlice(ctx.alloc, &.{ "--max-depth", value }) catch
            return r.errResult(call, "failed to build glob command");
    }
    appendIncludeGlob(ctx.alloc, &argv, ctx.cwd, args.path, args.pattern) catch
        return r.errResult(call, "failed to build glob command");
    for (args.additional_patterns) |pattern| {
        if (pattern.len == 0) return r.errResult(call, "additional_patterns must not contain an empty pattern");
        appendIncludeGlob(ctx.alloc, &argv, ctx.cwd, args.path, pattern) catch
            return r.errResult(call, "failed to build glob command");
    }
    appendHiddenExclusion(ctx.alloc, &argv, args.include_hidden, args.include_ignored) catch
        return r.errResult(call, "failed to build glob command");
    appendExcludes(ctx.alloc, &argv, ctx.cwd, args.path, args.exclude) catch
        return r.errResult(call, "failed to build glob command");
    appendSearchPath(ctx.alloc, &argv, args.path) catch
        return r.errResult(call, "failed to build glob command");

    return runSearch(ctx, call, argv.items, .{
        .kind = "glob",
        .pattern = args.pattern,
        .path = args.path,
        .empty_message = "No files matched.",
    });
}

fn runGrep(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const args = std.json.parseFromSliceLeaky(GrepArgs, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments for grep");

    if (validateCommon(args.pattern, args.path)) |msg| return r.errResult(call, msg);
    if (args.context > MAX_CONTEXT_LINES) {
        return r.errResult(call, "context must be between 0 and 100");
    }

    r.setToolStatusPrint(ctx, call, "grep  {s}  {s}", .{ args.pattern, args.path });

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.alloc, &.{ "rg", "--color=never", "--no-heading", "--line-number", "--with-filename" }) catch
        return r.errResult(call, "failed to build grep command");

    argv.append(ctx.alloc, if (args.case_mode) |case_mode| switch (case_mode) {
        .sensitive => "--case-sensitive",
        .insensitive => "--ignore-case",
    } else "--smart-case") catch return r.errResult(call, "failed to build grep command");

    if (args.fixed_strings) argv.append(ctx.alloc, "--fixed-strings") catch
        return r.errResult(call, "failed to build grep command");
    appendWalkOptions(ctx.alloc, &argv, args.include_hidden, args.include_ignored) catch
        return r.errResult(call, "failed to build grep command");

    for (args.globs) |glob| {
        if (glob.len == 0) return r.errResult(call, "globs must not contain an empty pattern");
        appendIncludeGlob(ctx.alloc, &argv, ctx.cwd, args.path, glob) catch
            return r.errResult(call, "failed to build grep command");
    }
    appendHiddenExclusion(ctx.alloc, &argv, args.include_hidden, args.include_ignored) catch
        return r.errResult(call, "failed to build grep command");
    appendExcludes(ctx.alloc, &argv, ctx.cwd, args.path, args.exclude) catch
        return r.errResult(call, "failed to build grep command");

    if (args.context > 0) {
        const value = std.fmt.allocPrint(ctx.alloc, "{d}", .{args.context}) catch
            return r.errResult(call, "failed to build grep command");
        argv.appendSlice(ctx.alloc, &.{ "--context", value }) catch
            return r.errResult(call, "failed to build grep command");
    }

    argv.appendSlice(ctx.alloc, &.{ "--regexp", args.pattern }) catch
        return r.errResult(call, "failed to build grep command");
    appendSearchPath(ctx.alloc, &argv, args.path) catch
        return r.errResult(call, "failed to build grep command");

    return runSearch(ctx, call, argv.items, .{
        .kind = "grep",
        .pattern = args.pattern,
        .path = args.path,
        .regex = !args.fixed_strings,
        .empty_message = "No matches found in searchable text. Binary data is not searched as ordinary text.",
    });
}

fn validateCommon(pattern: []const u8, path: []const u8) ?[]const u8 {
    if (pattern.len == 0) return "pattern is empty";
    if (path.len == 0) return "path is empty";
    return null;
}

fn appendWalkOptions(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    include_hidden: bool,
    include_ignored: bool,
) !void {
    if (include_hidden or include_ignored) try argv.append(alloc, "--hidden");
    if (include_ignored) try argv.append(alloc, "--no-ignore");
}

fn appendIncludeGlob(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    cwd: []const u8,
    path: []const u8,
    pattern: []const u8,
) !void {
    const resolved = try resolveGlobForSearchPath(alloc, cwd, path, pattern);
    try argv.appendSlice(alloc, &.{ "--glob", resolved });
}

/// Any explicit `--glob` makes ripgrep whitelist hidden paths. Restore the
/// documented default (omit hidden unless requested) with a trailing
/// exclusion glob: ripgrep applies globs last-match-wins, so it must come
/// after every include glob.
fn appendHiddenExclusion(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    include_hidden: bool,
    include_ignored: bool,
) !void {
    if (include_hidden or include_ignored) return;
    try argv.appendSlice(alloc, &.{ "--glob", "!**/.*" });
}

fn appendExcludes(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    cwd: []const u8,
    path: []const u8,
    excludes: []const []const u8,
) !void {
    for (excludes) |exclude| {
        if (exclude.len == 0) return error.EmptyExclude;
        const resolved = try resolveGlobForSearchPath(alloc, cwd, path, exclude);
        const negated = try std.fmt.allocPrint(alloc, "!{s}", .{resolved});
        try argv.appendSlice(alloc, &.{ "--glob", negated });

        // Ripgrep globs match files. Also exclude descendants so a bare
        // directory such as `zig-cache` prunes the whole subtree.
        const trimmed = std.mem.trimEnd(u8, exclude, "/");
        const descendant_pattern = try std.fmt.allocPrint(alloc, "{s}/**", .{trimmed});
        const resolved_descendants = try resolveGlobForSearchPath(alloc, cwd, path, descendant_pattern);
        const descendants = try std.fmt.allocPrint(alloc, "!{s}", .{resolved_descendants});
        try argv.appendSlice(alloc, &.{ "--glob", descendants });
    }
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
fn appendSearchPath(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), path: []const u8) !void {
    try argv.append(alloc, "--");
    if (!std.mem.eql(u8, path, ".")) try argv.append(alloc, path);
}

const SearchFailureContext = struct {
    kind: []const u8,
    pattern: []const u8,
    path: []const u8,
    regex: bool = false,
    empty_message: []const u8,
};

fn runSearch(
    ctx: r.prv.tool.ToolContext,
    call: r.prv.adapter.ToolCall,
    search_argv: []const []const u8,
    failure: SearchFailureContext,
) r.prv.adapter.ToolResult {
    const raw = ctx.swarm.exec.runAndWaitTimeout(.{
        .cwd = ctx.cwd,
        .argv = search_argv,
    }, SEARCH_TIMEOUT_MS) catch {
        const message = std.fmt.allocPrint(ctx.alloc, "{s} failed for pattern `{s}` in `{s}`: could not spawn search process", .{
            failure.kind, failure.pattern, failure.path,
        }) catch return r.errResult(call, "failed to spawn search process");
        return r.errResult(call, message);
    };
    defer ctx.swarm.exec.alloc.free(raw.stdout);
    defer ctx.swarm.exec.alloc.free(raw.stderr);

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
    const content = copyTruncated(ctx.alloc, output) catch
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
            failure.pattern, failure.path, detail,
        });
    }

    const detail = if (stderr.len == 0) "search process produced no error output" else std.mem.trimEnd(u8, stderr, "\r\n");
    if (exit_code) |code| {
        return std.fmt.allocPrint(alloc, "{s} failed for pattern `{s}` in `{s}` (exit code {d}): {s}", .{
            failure.kind, failure.pattern, failure.path, code, detail,
        });
    }
    return std.fmt.allocPrint(alloc, "{s} failed for pattern `{s}` in `{s}`: {s}", .{
        failure.kind, failure.pattern, failure.path, detail,
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
fn copyTruncated(alloc: std.mem.Allocator, borrowed: []const u8) ![]const u8 {
    const truncated = r.truncateOutputToOwned(alloc, borrowed, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES);
    return alloc.dupe(u8, truncated);
}

test "search argument validation" {
    try std.testing.expectEqualStrings("pattern is empty", validateCommon("", ".").?);
    try std.testing.expectEqualStrings("path is empty", validateCommon("x", "").?);
    try std.testing.expect(validateCommon("x", ".") == null);
}

test "search result owns process-backed content" {
    const source = try std.testing.allocator.dupe(u8, "rg: invalid glob\n");
    const content = try copyTruncated(std.testing.allocator, source);
    std.testing.allocator.free(source);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("rg: invalid glob\n", content);
}

test "default search path does not add dot prefix" {
    var default_argv: std.ArrayList([]const u8) = .empty;
    defer default_argv.deinit(std.testing.allocator);
    try appendSearchPath(std.testing.allocator, &default_argv, ".");
    try std.testing.expectEqualSlices([]const u8, &.{"--"}, default_argv.items);

    var nested_argv: std.ArrayList([]const u8) = .empty;
    defer nested_argv.deinit(std.testing.allocator);
    try appendSearchPath(std.testing.allocator, &nested_argv, "src");
    try std.testing.expectEqualSlices([]const u8, &.{ "--", "src" }, nested_argv.items);
}

test "search globs resolve relative to narrowed path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("src/tui/**/*.zig", try resolveGlobForSearchPath(alloc, "/repo", "src", "tui/**/*.zig"));
    try std.testing.expectEqualStrings("src/**/*.zig", try resolveGlobForSearchPath(alloc, "/repo", "src", "**/*.zig"));
    try std.testing.expectEqualStrings("src/app.zig", try resolveGlobForSearchPath(alloc, "/repo", "src", "src/app.zig"));
    try std.testing.expectEqualStrings("*.zig", try resolveGlobForSearchPath(alloc, "/repo", "src", "*.zig"));
    try std.testing.expectEqualStrings("src/*.zig", try resolveGlobForSearchPath(alloc, "/repo", ".", "./src/*.zig"));
    try std.testing.expectEqualStrings("src/**/*.zig", try resolveGlobForSearchPath(alloc, "/repo", "/repo/src", "**/*.zig"));
    try std.testing.expectEqualStrings("src/**/*.zig", try resolveGlobForSearchPath(alloc, "/repo", "/repo/src", "/repo/src/**/*.zig"));

    try std.testing.expectEqualStrings("**", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "**"));
    try std.testing.expectEqualStrings("**/codex/**", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "codex/**"));
    try std.testing.expectEqualStrings("**/*.zig", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "**/*.zig"));

    try std.testing.expectEqualStrings("**/src/**/*.zig", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "src/**/*.zig"));
    try std.testing.expectEqualStrings("**/docs/*.md", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "docs/*.md"));
    try std.testing.expectEqualStrings("**/*/*.zig", try resolveGlobForSearchPath(alloc, "/home/lommix/Projects/zig/blitzdenk", "/home/lommix/Projects/vendor", "*/*.zig"));
    try std.testing.expectEqualStrings("**/codex/**", try resolveGlobForSearchPath(alloc, "/repo", "..", "codex/**"));
    try std.testing.expectEqualStrings("AGENTS.md", try resolveGlobForSearchPath(alloc, "/repo", "..", "AGENTS.md"));
    try std.testing.expectEqualStrings("**/*.zig", try resolveGlobForSearchPath(alloc, "/repo", "..", "**/*.zig"));
}

test "include ignored also traverses hidden paths" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    try appendWalkOptions(std.testing.allocator, &argv, false, true);
    try std.testing.expectEqualSlices([]const u8, &.{ "--hidden", "--no-ignore" }, argv.items);
}

test "hidden paths are re-excluded after include globs unless requested" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    try appendHiddenExclusion(std.testing.allocator, &argv, false, false);
    try std.testing.expectEqualSlices([]const u8, &.{ "--glob", "!**/.*" }, argv.items);

    var argv_hidden: std.ArrayList([]const u8) = .empty;
    defer argv_hidden.deinit(std.testing.allocator);
    try appendHiddenExclusion(std.testing.allocator, &argv_hidden, true, false);
    try std.testing.expectEqualSlices([]const u8, &.{}, argv_hidden.items);

    var argv_ignored: std.ArrayList([]const u8) = .empty;
    defer argv_ignored.deinit(std.testing.allocator);
    try appendHiddenExclusion(std.testing.allocator, &argv_ignored, false, true);
    try std.testing.expectEqualSlices([]const u8, &.{}, argv_ignored.items);
}

test "bare directory excludes include descendants relative to path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;

    try appendExcludes(alloc, &argv, "/repo", "src", &.{"zig-cache"});
    const expected: []const []const u8 = &.{
        "--glob",
        "!zig-cache",
        "--glob",
        "!src/zig-cache/**",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "search errors add context and simplify regex parse failures" {
    const regex_error = try formatSearchError(std.testing.allocator, .{
        .kind = "grep",
        .pattern = "fn render(self:",
        .path = "src",
        .regex = true,
        .empty_message = "unused",
    }, 2, "rg: regex parse error:\n    fn render(self:\n             ^\nerror: unclosed group\n");
    defer std.testing.allocator.free(regex_error);
    try std.testing.expectEqualStrings(
        "invalid regular expression `fn render(self:` for path `src`: unclosed group",
        regex_error,
    );

    const io_error = try formatSearchError(std.testing.allocator, .{
        .kind = "glob",
        .pattern = "**/*.zig",
        .path = "missing",
        .empty_message = "unused",
    }, 2, "rg: missing: No such file or directory\n");
    defer std.testing.allocator.free(io_error);
    try std.testing.expectEqualStrings(
        "glob failed for pattern `**/*.zig` in `missing` (exit code 2): rg: missing: No such file or directory",
        io_error,
    );
}

test "search schemas and defaults parse" {
    const glob_schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, GlobTool.def.parameters_schema, .{});
    defer glob_schema.deinit();
    const grep_schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, GrepTool.def.parameters_schema, .{});
    defer grep_schema.deinit();

    const grep_args = try std.json.parseFromSlice(GrepArgs, std.testing.allocator, "{\"pattern\":\"needle\"}", .{});
    defer grep_args.deinit();
    try std.testing.expect(grep_args.value.case_mode == null);
    try std.testing.expect(!grep_args.value.fixed_strings);
    try std.testing.expectEqual(@as(u32, 0), grep_args.value.context);
}
