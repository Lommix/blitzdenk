const r = @import("root.zig");
const std = @import("std");
const exec = @import("exec");

pub const BashTool = r.Tool{
    .def = .{
        .name = "bash",
        .description =
        \\Execute a bash command in the current working directory.
        \\Returns stdout and stderr. Output is truncated to the last 
        ++ r.DISPLAY_CAP_TEXT ++
            \\ (whichever is hit first); the captured output is saved to a file whose path is reported when available.
            \\
            \\Result markers, one per line: [stderr], (no output), [exit code: N], [killed by signal: SIGTERM], [timed out after Nms; retry with a larger timeout], [stdout truncated: kept the last 
        ++ OUTPUT_CAP_TEXT ++
            \\], [stderr truncated: kept the last 
        ++ OUTPUT_CAP_TEXT ++
            \\].
            \\Verify the target path before delete or move commands. Use absolute paths and guard variables (${VAR:?}) in destructive scripts.
        ,
        .prompt_snippet = "Execute a bash command",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "Bash command to execute"},
        \\  "description": {"type": "string", "description": "Clear, concise description of what this command does in active voice, 5-10 words (shown in the UI). Examples: \"ls\" → \"List files in current directory\"; \"git status\" → \"Show working tree status\"; \"npm install\" → \"Install package dependencies\""},
        \\  "timeout": {"type": "number", "description": "Timeout in seconds (default 60s)"}
        \\}, "required": ["command", "description"]}
        ,
    },
    .func = &run,
};

const MAX_TIMEOUT_SECS = 2_147_483;
const TIMEOUT_RANGE_TEXT = std.fmt.comptimePrint("(0, {d}]", .{MAX_TIMEOUT_SECS});
const OUTPUT_CAP_TEXT = std.fmt.comptimePrint("{d}MB", .{exec.MAX_OUTPUT / (1024 * 1024)});

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct {
        command: []const u8,
        description: []const u8,
        timeout: ?f64 = null,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("[BAD CMD] {s}", .{call.input});
        return r.errResult(call, "invalid arguments: \"command\" is required and must be a non-empty string");
    };

    if (args.command.len == 0) return r.errResult(call, "invalid arguments: \"command\" is required and must be a non-empty string");

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

    const full = formatBashResult(ctx.alloc, res.stdout, res.stderr, res.exit_code, res.signal, res.ty == .timeout, timeout_ms, res.stdout_truncated, res.stderr_truncated) catch
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
    inline for (std.meta.fields(std.posix.SIG)) |field| {
        if (@intFromEnum(named) == field.value) return field.name;
    }
    return null;
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
    const slot = &ctx.base.exec_pool.slots[@intFromEnum(handle)];

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

test "formatBashResult strips ansi and renders result markers" {
    const alloc = std.testing.allocator;

    const red = try formatBashResult(alloc, "\x1b[31mred\x1b[0m", "", 0, null, false, 60_000, false, false);
    defer alloc.free(red);
    try std.testing.expectEqualStrings("red", red);

    const term = try formatBashResult(alloc, "x", "", 0, @intFromEnum(std.posix.SIG.TERM), false, 60_000, false, false);
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
