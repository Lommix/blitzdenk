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
            \\ (whichever is hit first); the full output is saved to a file whose path is reported when available.
            \\
        ,
        .prompt_snippet = "Execute a bash command",
        .prompt_guidelines = "Prefer specialist tools over bash whenever available",
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
        return r.errResult(call, "invalid JSON arguments: expected {\"command\": \"...\"}");
    };

    if (args.command.len == 0) return r.errResult(call, "empty command");

    // Replace full cwd paths with "." for cleaner output (stack buffer)
    var buf: [512]u8 = undefined;
    const cleaned_command_str = if (ctx.base.cwd.len > 0)
        r.replaceAll(args.command, ctx.base.cwd, ".", &buf)
    else
        args.command;

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [255]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    w.styled(.{ .modifier = .{ .bold = true } }, "bash ");
    w.styled(.{ .fg = app.theme.info }, args.description);
    w.writeAll(" ");
    w.styled(.{ .fg = app.theme.muted }, cleaned_command_str);

    r.setToolStatus(ctx, call, w.finish()) catch {};

    const description = std.fmt.allocPrint(
        ctx.alloc,
        "{s}\n\nRun: `{s}` ?",
        .{ args.description, args.command },
    ) catch args.description;

    const decision = ctx.requestPermission(call.id, .{ .call = .{
        .description = description,
    } });

    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined bash"),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(
                ctx.alloc,
                "User declined bash command and left feedback: {s}",
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
        if (!std.math.isFinite(t) or t <= 0)
            return r.errResult(call, "timeout must be a positive number of seconds");
        break :blk timeoutToMs(t);
    };
    const res = runWithDeadline(ctx, .{
        .cwd = ctx.base.cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
    }, timeout_ms) catch |err| switch (err) {
        error.Canceled => return r.errResult(call, "canceled"),
        else => return r.errResult(call, "exec failed"),
    };
    defer ctx.base.exec_pool.alloc.free(res.stdout);
    defer ctx.base.exec_pool.alloc.free(res.stderr);

    const full = formatBashResult(ctx.alloc, res.stdout, res.stderr, res.exit_code, res.signal, res.ty == .timeout, timeout_ms) catch
        return r.errResult(call, "oom");

    const spill = if (r.isOversized(full, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES))
        r.writeSpillFile(ctx.base.app, ctx.io, ctx.alloc, call.id, full)
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
) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, stdout);
    if (stderr.len > 0) {
        try appendMarker(alloc, &body, "[stderr]\n{s}", .{stderr});
    }
    if (body.items.len == 0) try body.appendSlice(alloc, "(no output)");

    if (timed_out) {
        try appendMarker(alloc, &body, "[timed out after {d}ms]", .{timeout_ms});
    } else if (signal) |sig| {
        try appendMarker(alloc, &body, "[killed by signal: {d}]", .{sig});
    } else if (exit_code) |code| {
        if (code != 0) try appendMarker(alloc, &body, "[exit code: {d}]", .{code});
    }
    return alloc.dupe(u8, body.items);
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
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(25), .real) catch return error.Canceled;
    }
}

fn timeoutToMs(secs: f64) i64 {
    const capped = @min(secs, 2_147_483);
    return @as(i64, @intFromFloat(capped * 1000));
}

test "formatBashResult combines stdout and stderr" {
    const out = try formatBashResult(std.testing.allocator, "hello\n", "oops\n", null, null, false, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n[stderr]\noops\n", out);
}

test "formatBashResult empty streams yield no output" {
    const out = try formatBashResult(std.testing.allocator, "", "", null, null, false, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("(no output)", out);
}

test "formatBashResult exit code marker" {
    const out = try formatBashResult(std.testing.allocator, "", "", 7, null, false, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "[exit code: 7]"));
}

test "formatBashResult signal marker and no exit marker" {
    const out = try formatBashResult(std.testing.allocator, "", "", null, 9, false, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "[killed by signal: 9]"));
    try std.testing.expect(std.mem.indexOf(u8, out, "exit code") == null);
}

test "formatBashResult timed out marker" {
    const out = try formatBashResult(std.testing.allocator, "", "", null, null, true, 1000);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "[timed out after 1000ms]"));
}
