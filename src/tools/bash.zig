const r = @import("root.zig");
const std = @import("std");
const exec = @import("exec");

const blocked_commands = [_][]const u8{
    "dd",         "mkfs",      "fdisk",    "parted",
    "shutdown",   "reboot",    "poweroff", "halt",
    "init",       "systemctl", "mount",    "umount",
    "iptables",   "nft",       "modprobe", "insmod",
    "rmmod",      "swapon",    "swapoff",  "losetup",
    "cryptsetup", "eval",      "exec",     "bash",
    "sh",         "zsh",       "fish",     "dash",
};

const approval_commands = [_][]const u8{
    "rm",      "mv",     "cp",      "chmod",
    "chown",   "chgrp",  "ln",      "mkdir",
    "rmdir",   "touch",  "install", "rsync",
    "curl",    "wget",   "pip",     "npm",
    "cargo",   "make",   "cmake",   "git",
    "docker",  "podman", "kill",    "pkill",
    "killall", "sudo",   "su",      "apt",
    "pacman",  "dnf",    "brew",    "sed",
    "awk",     "tee",
};

const Classification = enum {
    blocked,
    needs_approval,
    allowed,
    sudo,
};

pub const BashTool = r.Tool{
    .def = .{
        .name = "bash",
        .description =
        \\Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to first 1000 lines or 32KB (whichever is hit first). Optionally provide a timeout in seconds.
        ,
        .prompt_snippet = "Execute a bash command",
        .prompt_guidelines = "Prefer specialist tools over bash whenever available",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "Bash command to execute"},
        \\  "timeout": {"type": "number", "description": "Timeout in seconds (optional, no default timeout)"}
        \\}, "required": ["command"]}
        ,
    },
    .func = &run,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct {
        command: []const u8,
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

    const LIMIT = 100;
    const trunc = cleaned_command_str[0..@min(cleaned_command_str.len, LIMIT)];
    const dots = if (cleaned_command_str.len > LIMIT) ".." else "";

    r.setToolStatusPrint(ctx, call, "{s}{s}", .{ trunc, dots });

    const need_perm = switch (classifyCommand(args.command)) {
        .blocked => return r.errResult(call, "command is blocked for safety"),
        .needs_approval, .sudo => true,
        .allowed => false,
    };

    if (need_perm) {
        const decision = ctx.requestPermission(call.id, .always_check, .{ .call = .{
            .tool_name = call.name,
            .tool_arguments = call.input,
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
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    // Foreground with deadline race.
    const timeout_ms: i64 = blk: {
        const t = args.timeout orelse break :blk std.math.maxInt(i64);
        if (!std.math.isFinite(t) or t <= 0)
            return r.errResult(call, "timeout must be a positive number of seconds");
        break :blk timeoutToMs(t);
    };
    const res = runWithDeadline(ctx, .{
        .cwd = ctx.base.cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
    }, timeout_ms) catch |err| switch (err) {
        error.Timeout => {
            const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
            var status_buf: [r.STATUS_BUF]u8 = undefined;
            var w = r.tui.AnsiWriter.init(&status_buf);
            w.writeAll(cleaned_command_str[0..@min(cleaned_command_str.len, 248)]);
            w.writeAll("\n");
            w.styled(.{ .fg = app.theme.err }, "Timeout reached!");
            r.setToolStatus(ctx, call, w.finish()) catch {};
            return r.errResult(call,
                \\!Command Timeout reached! Process killed.
            );
        },
        error.Canceled => return r.errResult(call, "canceled"),
        else => return r.errResult(call, "exec failed"),
    };
    defer ctx.base.exec_pool.alloc.free(res.stdout);
    defer ctx.base.exec_pool.alloc.free(res.stderr);

    const content = formatBashResult(ctx.alloc, res.stdout, res.stderr, res.exit_code) catch
        return r.errResult(call, "oom");
    return r.okResult(call, r.truncateOutputToOwned(ctx.alloc, content, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES));
}

fn formatBashResult(
    alloc: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u8,
) ![]const u8 {
    if (exit_code) |code| {
        return std.fmt.allocPrint(alloc, "<bash exit_code=\"{d}\">\n<stdout>{s}</stdout>\n<stderr>{s}</stderr>\n</bash>", .{ code, stdout, stderr });
    }
    return std.fmt.allocPrint(alloc, "<bash>\n<stdout>{s}</stdout>\n<stderr>{s}</stderr>\n</bash>", .{ stdout, stderr });
}

const RunError = error{ Timeout, Canceled, ExecFailed };

/// Race a foreground exec future against a wall-clock deadline. On timeout,
/// the spawned process is killed and stdout/stderr are discarded. Polls both
/// the slot's done flag and the deadline at 25 ms intervals; cooperative
/// cancellation via ctx.isCanceled() also unwinds.
fn runWithDeadline(
    ctx: r.ToolContext,
    opts: exec.CmdPool.RunOpts,
    deadline_ms: i64,
) RunError!exec.CmdResult {
    const handle = ctx.base.exec_pool.runWithOpts(opts) catch return error.ExecFailed;
    const slot = &ctx.base.exec_pool.slots[@intFromEnum(handle)];

    const start_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
    while (true) {
        if (slot.done.load(.acquire)) {
            slot.future.await(ctx.io) catch {};
            const out = ctx.base.exec_pool.alloc.dupe(u8, slot.stdout.items) catch {
                ctx.base.exec_pool.release(handle);
                return error.ExecFailed;
            };
            const err = ctx.base.exec_pool.alloc.dupe(u8, slot.stderr.items) catch {
                ctx.base.exec_pool.alloc.free(out);
                ctx.base.exec_pool.release(handle);
                return error.ExecFailed;
            };
            const ty = slot.result_ty;
            ctx.base.exec_pool.release(handle);
            return .{ .stdout = out, .stderr = err, .ty = ty };
        }
        if (ctx.isCanceled()) {
            ctx.base.exec_pool.cancel(handle);
            return error.Canceled;
        }
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
        if (now_ms - start_ms > deadline_ms) {
            ctx.base.exec_pool.cancel(handle);
            return error.Timeout;
        }
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(25), .real) catch return error.Canceled;
    }
}

fn classifyCommand(cmd: []const u8) Classification {
    // Hard-block subshell syntax (bypasses command-level checks)
    if (isSudo(cmd)) return .sudo;
    if (containsSubshell(cmd)) return .needs_approval;

    // Classify each command in the pipeline
    var result: Classification = .allowed;
    var rest: []const u8 = cmd;
    while (rest.len > 0) {
        const segment, const remaining = nextSegment(rest);
        const trimmed = std.mem.trim(u8, segment, " \t\n\r");
        if (trimmed.len == 0) {
            rest = remaining;
            continue;
        }

        const name = blk: {
            for (trimmed, 0..) |c, i| {
                if (c == ' ' or c == '\t') break :blk trimmed[0..i];
            }
            break :blk trimmed;
        };

        const basename = std.fs.path.basename(name);

        if (isInList(basename, &blocked_commands)) return .blocked;
        if (isInList(basename, &approval_commands)) result = .needs_approval;

        rest = remaining;
    }

    // Check for redirects (needs approval, not blocked)
    if (result == .allowed and containsRedirects(cmd)) result = .needs_approval;

    return result;
}

fn timeoutToMs(secs: f64) i64 {
    const capped = @min(secs, 2_147_483);
    return @as(i64, @intFromFloat(capped * 1000));
}

fn isSudo(cmd: []const u8) bool {
    if (std.mem.find(u8, cmd, "sudo") != null) return true;
    return false;
}

fn containsSubshell(cmd: []const u8) bool {
    for (0..cmd.len) |i| {
        switch (cmd[i]) {
            '`' => return true,
            '$' => {
                if (i + 1 < cmd.len and cmd[i + 1] == '(') return true;
            },
            else => {},
        }
    }
    return false;
}

fn containsRedirects(cmd: []const u8) bool {
    for (cmd) |c| {
        if (c == '>' or c == '<') return true;
    }
    return false;
}

fn nextSegment(input: []const u8) struct { []const u8, []const u8 } {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '|' => {
                if (i + 1 < input.len and input[i + 1] == '|') {
                    return .{ input[0..i], if (i + 2 < input.len) input[i + 2 ..] else "" };
                }
                return .{ input[0..i], if (i + 1 < input.len) input[i + 1 ..] else "" };
            },
            '&' => {
                if (i + 1 < input.len and input[i + 1] == '&') {
                    return .{ input[0..i], if (i + 2 < input.len) input[i + 2 ..] else "" };
                }
            },
            ';' => {
                return .{ input[0..i], if (i + 1 < input.len) input[i + 1 ..] else "" };
            },
            else => {},
        }
    }
    return .{ input, "" };
}

fn isInList(name: []const u8, list: []const []const u8) bool {
    for (list) |cmd| {
        if (std.mem.eql(u8, name, cmd)) return true;
    }
    return false;
}
