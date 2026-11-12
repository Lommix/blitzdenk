const r = @import("root.zig");
const std = @import("std");
const exec = @import("exec");

/// Sync-only bash. Schema and description carry no background or job text.
pub const BashTool = r.Tool{ .def = bashDef(false), .func = &runSync };

/// Bash with `run_in_background`. Exposed to the model as `bash`, pooled under
/// its own id so both variants can coexist.
pub const BashBgTool = r.Tool{ .id = "bash_bg", .def = bashDef(true), .func = &runBg };

/// Tool ids of the background bash set, exposed to Lua as `blitz.toolsets`.
pub const SET_BASH_BACKGROUND = [_][]const u8{ BashBgTool.id.?, ReadJobTool.def.name, KillJobTool.def.name };

fn bashDef(comptime background: bool) r.context.DefinitionMeta {
    const description =
        \\Execute a bash command in the current working directory.
        \\Returns stdout and stderr. Output is truncated to the last
    ++ " " ++ r.DISPLAY_CAP_TEXT ++
        \\ (whichever is hit first); the captured output is saved to a file whose path is reported when available.
        \\
        \\Result markers, one per line: [stderr], (no output), [exit code: N], [killed by signal: SIGTERM], [timed out after Nms; retry with a larger timeout], [stdout truncated: kept the last
    ++ " " ++ OUTPUT_CAP_TEXT ++
        \\], [stderr truncated: kept the last
    ++ " " ++ OUTPUT_CAP_TEXT ++
        \\].
        \\Verify the target path before delete or move commands. Use absolute paths and guard variables (${VAR:?}) in destructive scripts.
        \\Processes left running with `&` are killed when the command returns.
    ;
    const background_description =
        \\ For servers, watchers, and long builds use run_in_background: it returns a job id at once, and you get a reminder when the job exits. Do not poll or sleep while waiting for it. Read its merged stdout and stderr with read_job; some programs buffer output when it is not a terminal (use PYTHONUNBUFFERED=1 or `stdbuf -oL`). Stop a job with kill_job.
    ;
    const schema_head =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "Bash command to execute"},
        \\  "description": {"type": "string", "description": "Clear, concise description of what this command does in active voice, 5-10 words (shown in the UI). Examples: \"ls\" → \"List files in current directory\"; \"git status\" → \"Show working tree status\"; \"npm install\" → \"Install package dependencies\""},
        \\  "timeout": {"type": "number", "description": "Timeout in seconds (default 60s)
    ;
    const background_schema =
        \\. Ignored with run_in_background"},
        \\  "run_in_background": {"type": "boolean", "description": "Run detached and return at once with a job id"}
    ;
    const schema_tail =
        \\
        \\}, "required": ["command", "description"]}
    ;
    return .{
        .name = "bash",
        .description = description ++ if (background) background_description else "",
        .prompt_snippet = "Execute a bash command",
        .prompt_guidelines = "Check the [exit code: N] marker; investigate unexpected failures before moving on.",
        .parameters_schema = schema_head ++ (if (background) background_schema else "\"}") ++ schema_tail,
    };
}

const MAX_TIMEOUT_SECS = 2_147_483;
const TIMEOUT_RANGE_TEXT = std.fmt.comptimePrint("(0, {d}]", .{MAX_TIMEOUT_SECS});
const OUTPUT_CAP_TEXT = std.fmt.comptimePrint("{d}MB", .{exec.MAX_OUTPUT / (1024 * 1024)});

fn runSync(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    return run(ctx, call, false);
}

fn runBg(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    return run(ctx, call, true);
}

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall, background: bool) r.r.sdk.ToolOutput {
    const Args = struct {
        command: []const u8,
        description: []const u8,
        timeout: ?f64 = null,
        run_in_background: bool = false,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("[BAD CMD] {s}", .{call.input});
        return r.errResult(call, "invalid arguments: \"command\" is required and must be a non-empty string");
    };

    if (args.command.len == 0) return r.errResult(call, "invalid arguments: \"command\" is required and must be a non-empty string");
    if (args.run_in_background and !background) return r.errResult(call, "run_in_background is not available; run the command in the foreground");

    // Replace full cwd paths with "." for cleaner output (stack buffer)
    var buf: [r.STATUS_BUF]u8 = undefined;
    const cleaned_command_str = if (ctx.base.cwd.len > 0)
        r.replaceAll(args.command, ctx.base.cwd, ".", &buf)
    else
        args.command;

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "bash ");
    w.styled(.{ .fg = app.theme.info }, args.description);
    w.writeAll(" ");
    w.styled(.{ .fg = app.theme.muted }, cleaned_command_str);

    r.setToolStatus(ctx, call, w.finish()) catch {};

    const description = std.fmt.allocPrint(
        ctx.alloc,
        "{s}\n\nRun: `{s}` ?",
        .{ args.description, args.command },
    ) catch args.description;

    const decision = ctx.requestPermission(call, .{ .call = .{
        .description = description,
    } });

    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined bash. Change the approach or ask the user before retrying."),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(
                ctx.alloc,
                "User declined bash command and left feedback: {s}\nChange the approach or ask the user before retrying.",
                .{txt},
            ) catch txt;
            return r.errResult(call, wrapped);
        },
        else => return r.errResult(call, "permission unresolved"),
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    if (args.run_in_background) return runBackground(ctx, call, app, args.command);

    // Foreground with deadline race.
    const timeout_ms: i64 = blk: {
        const t = args.timeout orelse break :blk 60_000;
        if (!std.math.isFinite(t) or t <= 0 or t > MAX_TIMEOUT_SECS)
            return r.errResult(call, std.fmt.allocPrint(ctx.alloc, "invalid timeout: {d}; expected seconds in " ++ TIMEOUT_RANGE_TEXT, .{t}) catch "invalid timeout");
        break :blk timeoutToMs(t);
    };
    const res = runWithDeadline(ctx, .{
        .cwd = ctx.base.cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
        .kill_process_group = true,
        .scrub_env = true,
    }, timeout_ms) catch |err| switch (err) {
        error.Canceled => return r.errResult(call, "canceled"),
        else => return r.errResult(call, "exec failed"),
    };
    defer ctx.base.exec_pool.alloc.free(res.stdout);
    defer ctx.base.exec_pool.alloc.free(res.stderr);

    const stderr = r.filterTransportStderr(ctx, res.stderr);
    const full = formatBashResult(ctx.alloc, res.stdout, stderr, res.exit_code, res.signal, res.ty == .timeout, timeout_ms, res.stdout_truncated, res.stderr_truncated) catch
        return r.errResult(call, "oom");

    const spill = if (r.isOversized(full, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES))
        r.writeSpillFile(ctx.base.exec_pool, ctx.alloc, call.id, full)
    else
        null;
    defer if (spill) |s| ctx.alloc.free(s);

    const truncated = r.truncateOutputToOwnedSpill(ctx.alloc, full, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES, spill);
    if (truncated.ptr != full.ptr) ctx.alloc.free(full);
    return r.okResult(call, truncated);
}

const MAX_JOB_COMMAND_BYTES = 200;
const DEFAULT_JOB_READ_LINES = 200;

fn runBackground(ctx: r.ToolContext, call: r.r.sdk.ToolCall, app: *r.r.app.App, command: []const u8) r.r.sdk.ToolOutput {
    const id = app.jobs.start(ctx.base.exec_pool, ctx.base.self_id, command, ctx.base.cwd) catch |err| switch (err) {
        error.TooManyJobs => return r.errResult(call, std.fmt.comptimePrint("too many running background jobs (max {d}); stop one with kill_job", .{r.r.jobs.MAX_JOBS})),
        else => return r.errResult(call, std.fmt.allocPrint(ctx.alloc, "failed to start background job: {s}", .{@errorName(err)}) catch "failed to start background job"),
    };
    const msg = std.fmt.allocPrint(
        ctx.alloc,
        "Started background job {d}. Read its output with read_job; you get a reminder when it exits. Stop it with kill_job.",
        .{id},
    ) catch return r.okResult(call, "Started background job.");
    return r.okResult(call, msg);
}

fn writeJobState(alloc: std.mem.Allocator, body: *std.ArrayList(u8), exit_code: ?u8, signal: ?u32) !void {
    if (signal) |sig| {
        if (signalName(sig)) |name| {
            try body.print(alloc, "was killed by signal SIG{s}", .{name});
        } else {
            try body.print(alloc, "was killed by signal {d}", .{sig});
        }
    } else if (exit_code) |code| {
        try body.print(alloc, "exited with code {d}", .{code});
    } else {
        try body.appendSlice(alloc, "ended");
    }
}

fn appendClean(alloc: std.mem.Allocator, body: *std.ArrayList(u8), text: []const u8) !void {
    const clean = try alloc.alloc(u8, text.len);
    defer alloc.free(clean);
    try body.appendSlice(alloc, stripAnsi(text, clean));
}

/// Reminder text for a background job that exited.
pub fn formatJobNotice(alloc: std.mem.Allocator, done: r.r.jobs.Finished) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try body.print(alloc, "Background job {d} ", .{done.id});
    try writeJobState(alloc, &body, done.exit_code, done.signal);
    const command = done.command[0..@min(done.command.len, MAX_JOB_COMMAND_BYTES)];
    const ellipsis = if (command.len < done.command.len) "..." else "";
    try body.print(alloc, " after {d}s: `{s}{s}`. Use read_job for more output.\n", .{ @divTrunc(done.elapsed_ms, std.time.ms_per_s), command, ellipsis });
    try appendClean(alloc, &body, done.tail);
    return alloc.dupe(u8, body.items);
}

pub const ReadJobTool = r.Tool{
    .def = .{
        .name = "read_job",
        .description = "Read the merged stdout and stderr of a background bash job, running or exited. Output includes line numbers counted from the job start. Without offset, returns the last `limit` lines. The oldest lines are dropped once a job holds more than " ++ std.fmt.comptimePrint("{d}MB", .{r.r.jobs.LOG_CAP / (1024 * 1024)}) ++ ".",
        .prompt_snippet = "Read background bash job output",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "job_id": {"type": "integer", "description": "Job id returned by bash"},
        \\  "offset": {"type": "integer", "description": "Line number to start reading from (1-indexed). Omit to read the tail"},
        \\  "limit": {"type": "integer", "description": "Maximum number of lines to read (default 200)"}
        \\}, "required": ["job_id"]}
        ,
    },
    .func = &readJob,
};

fn readJob(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct { job_id: u32, offset: ?usize = null, limit: ?usize = null };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments: \"job_id\" is required; offset and limit must be positive integers");
    if (args.offset == 0 or args.limit == 0) return r.errResult(call, "invalid arguments: offset and limit start at 1");
    const limit = args.limit orelse DEFAULT_JOB_READ_LINES;

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    r.setToolStatusPrint(ctx, call, "read job {d}", .{args.job_id});
    const page = (app.jobs.read(ctx.base.exec_pool, ctx.alloc, args.job_id, args.offset, limit) catch
        return r.errResult(call, "oom")) orelse
        return r.errResult(call, std.fmt.allocPrint(ctx.alloc, "no job {d}", .{args.job_id}) catch "no such job");

    var body: std.ArrayList(u8) = .empty;
    body.print(ctx.alloc, "[job {d} ", .{args.job_id}) catch return r.errResult(call, "oom");
    switch (page.state) {
        .running => body.appendSlice(ctx.alloc, "running") catch return r.errResult(call, "oom"),
        .exited => |e| writeJobState(ctx.alloc, &body, e.exit_code, e.signal) catch return r.errResult(call, "oom"),
    }
    body.appendSlice(ctx.alloc, "]\n") catch return r.errResult(call, "oom");
    appendClean(ctx.alloc, &body, page.text) catch return r.errResult(call, "oom");
    return r.okResult(call, r.capOutput(ctx.base.exec_pool, ctx.alloc, call.id, body.items));
}

pub const KillJobTool = r.Tool{
    .def = .{
        .name = "kill_job",
        .description = "Stop a running background bash job. Kills its whole process group and returns its last output lines. The job is then gone; no reminder is sent.",
        .prompt_snippet = "Stop a background bash job",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "job_id": {"type": "integer", "description": "Job id returned by bash"}
        \\}, "required": ["job_id"]}
        ,
    },
    .func = &killJob,
};

fn killJob(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct { job_id: u32 };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid arguments: \"job_id\" is required and must be a positive integer");

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    r.setToolStatusPrint(ctx, call, "kill job {d}", .{args.job_id});
    const killed = (app.jobs.kill(ctx.base.exec_pool, ctx.alloc, args.job_id) catch
        return r.errResult(call, "oom")) orelse
        return r.errResult(call, std.fmt.allocPrint(ctx.alloc, "no running job {d}", .{args.job_id}) catch "no such job");

    var body: std.ArrayList(u8) = .empty;
    body.print(ctx.alloc, "Killed job {d}.\n", .{args.job_id}) catch return r.errResult(call, "oom");
    appendClean(ctx.alloc, &body, killed.tail) catch return r.errResult(call, "oom");
    return r.okResult(call, body.items);
}

fn formatBashResult(
    alloc: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u8,
    signal: ?u32,
    timed_out: bool,
    timeout_ms: i64,
    stdout_truncated: bool,
    stderr_truncated: bool,
) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    const stdout_clean = try alloc.alloc(u8, stdout.len);
    defer alloc.free(stdout_clean);
    try body.appendSlice(alloc, stripAnsi(stdout, stdout_clean));

    if (stderr.len > 0) {
        const stderr_clean = try alloc.alloc(u8, stderr.len);
        defer alloc.free(stderr_clean);
        try appendMarker(alloc, &body, "[stderr]\n{s}", .{stripAnsi(stderr, stderr_clean)});
    }
    if (body.items.len == 0) try body.appendSlice(alloc, "(no output)");

    if (stdout_truncated) try appendMarker(alloc, &body, "[stdout truncated: kept the last " ++ OUTPUT_CAP_TEXT ++ "]", .{});
    if (stderr_truncated) try appendMarker(alloc, &body, "[stderr truncated: kept the last " ++ OUTPUT_CAP_TEXT ++ "]", .{});

    if (timed_out) {
        try appendMarker(alloc, &body, "[timed out after {d}ms; retry with a larger timeout]", .{timeout_ms});
    } else if (signal) |sig| {
        if (signalName(sig)) |name| {
            try appendMarker(alloc, &body, "[killed by signal: SIG{s}]", .{name});
        } else {
            try appendMarker(alloc, &body, "[killed by signal: {d}]", .{sig});
        }
    } else if (exit_code) |code| {
        if (code != 0) try appendMarker(alloc, &body, "[exit code: {d}]", .{code});
    }
    return alloc.dupe(u8, body.items);
}

fn signalName(sig: u32) ?[]const u8 {
    const named = std.enums.fromInt(std.posix.SIG, sig) orelse return null;
    return std.enums.tagName(std.posix.SIG, named);
}

fn stripAnsi(input: []const u8, out: []u8) []u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b) {
            if (i + 1 >= input.len) break;
            if (input[i + 1] == '[') {
                var j = i + 2;
                while (j < input.len and !(input[j] >= 0x40 and input[j] <= 0x7e)) : (j += 1) {}
                if (j >= input.len) break;
                i = j + 1;
                continue;
            }
            if (input[i + 1] == ']') {
                var j = i + 2;
                var end: ?usize = null;
                while (j < input.len) : (j += 1) {
                    if (input[j] == 0x07) {
                        end = j;
                        break;
                    }
                    if (input[j] == 0x1b and j + 1 < input.len and input[j + 1] == '\\') {
                        end = j + 1;
                        break;
                    }
                }
                if (end == null) break;
                i = end.? + 1;
                continue;
            }
            var j = i + 1;
            while (j < input.len and input[j] >= 0x20 and input[j] <= 0x2f) : (j += 1) {}
            if (j < input.len and input[j] >= 0x30 and input[j] <= 0x7e) j += 1;
            i = j;
            continue;
        }
        out[n] = input[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn appendMarker(alloc: std.mem.Allocator, body: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    if (body.items.len > 0 and body.items[body.items.len - 1] != '\n') try body.append(alloc, '\n');
    try body.print(alloc, fmt, args);
}

const RunError = error{ Canceled, OutOfMemory };

/// Race a foreground exec future against a wall-clock deadline. On timeout,
/// the child is killed and its partial stdout/stderr are returned. Polls both
/// the slot's done flag and the deadline at 25 ms intervals; cooperative
/// cancellation via ctx.isCanceled() also unwinds.
fn runWithDeadline(
    ctx: r.ToolContext,
    opts: exec.CmdPool.RunOpts,
    deadline_ms: i64,
) RunError!exec.CmdResult {
    const handle = ctx.base.exec_pool.runWithOpts(opts) catch return error.OutOfMemory;
    const slot = &ctx.base.exec_pool.slots[@backingInt(handle)];

    const start_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
    while (true) {
        if (slot.done.load(.acquire)) {
            return ctx.base.exec_pool.killAndCollect(handle);
        }
        if (ctx.isCanceled()) {
            ctx.base.exec_pool.cancel(handle);
            return error.Canceled;
        }
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
        if (now_ms - start_ms > deadline_ms) {
            return ctx.base.exec_pool.killAndCollect(handle);
        }
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(25), .real) catch {
            ctx.base.exec_pool.cancel(handle);
            return error.Canceled;
        };
    }
}

fn timeoutToMs(secs: f64) i64 {
    return @as(i64, @intFromFloat(secs * 1000));
}

test "bash variants share text and only the background one exposes jobs" {
    const sync = BashTool.def;
    const bg = BashBgTool.def;
    try std.testing.expectEqualStrings(sync.name, bg.name);
    try std.testing.expect(std.mem.startsWith(u8, bg.description, sync.description));
    try std.testing.expect(std.mem.indexOf(u8, sync.description, "to the last " ++ r.DISPLAY_CAP_TEXT ++ " (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sync.description, "[stdout truncated: kept the last " ++ OUTPUT_CAP_TEXT ++ "]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sync.description, "run_in_background") == null);
    try std.testing.expect(std.mem.indexOf(u8, sync.parameters_schema, "run_in_background") == null);
    try std.testing.expect(std.mem.indexOf(u8, bg.parameters_schema, "run_in_background") != null);
    inline for (.{ sync.parameters_schema, bg.parameters_schema }) |schema| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
        parsed.deinit();
    }
}

test "formatBashResult strips ansi and renders result markers" {
    const alloc = std.testing.allocator;

    const red = try formatBashResult(alloc, "\x1b[31mred\x1b[0m", "", 0, null, false, 60_000, false, false);
    defer alloc.free(red);
    try std.testing.expectEqualStrings("red", red);

    const term = try formatBashResult(alloc, "x", "", 0, @backingInt(std.posix.SIG.TERM), false, 60_000, false, false);
    defer alloc.free(term);
    try std.testing.expectEqualStrings("x\n[killed by signal: SIGTERM]", term);

    const cut = try formatBashResult(alloc, "x", "", 0, null, false, 60_000, true, false);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("x\n[stdout truncated: kept the last " ++ OUTPUT_CAP_TEXT ++ "]", cut);

    const esc = try formatBashResult(alloc, "a\x1bMb", "", 0, null, false, 60_000, false, false);
    defer alloc.free(esc);
    try std.testing.expectEqualStrings("ab", esc);

    const serr = try formatBashResult(alloc, "x", "y", 0, null, false, 60_000, false, true);
    defer alloc.free(serr);
    try std.testing.expectEqualStrings("x\n[stderr]\ny\n[stderr truncated: kept the last " ++ OUTPUT_CAP_TEXT ++ "]", serr);

    const slow = try formatBashResult(alloc, "x", "", 0, null, true, 5_000, false, false);
    defer alloc.free(slow);
    try std.testing.expectEqualStrings("x\n[timed out after 5000ms; retry with a larger timeout]", slow);
}

test "formatJobNotice reports the exit and a clean tail" {
    const alloc = std.testing.allocator;
    const notice = try formatJobNotice(alloc, .{
        .id = 4,
        .owner = .{ .index = 0, .generation = 0 },
        .command = "npm run dev",
        .exit_code = 1,
        .signal = null,
        .elapsed_ms = 41_500,
        .tail = "[lines 1-1 of 1]\n     1\t\x1b[31mError\x1b[0m: boom\n",
    });
    defer alloc.free(notice);
    try std.testing.expectEqualStrings(
        "Background job 4 exited with code 1 after 41s: `npm run dev`. Use read_job for more output.\n" ++
            "[lines 1-1 of 1]\n     1\tError: boom\n",
        notice,
    );
}
