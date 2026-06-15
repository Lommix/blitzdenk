const r = @import("root.zig");
const prv = @import("provider");
const std = @import("std");

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

const MAX_DISPLAY_BYTES = 50 * 1024;
const MAX_DISPLAY_LINES = 2000;

const Classification = enum {
    blocked,
    needs_approval,
    allowed,
    sudo,
};

pub const BashTool = prv.tool.Tool{
    .def = .{
        .name = "bash",
        .description =
        \\Executes a given bash command and returns its output.
        \\
        \\IMPORTANT: Avoid using this tool to run cat, tee, sed commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:
        \\Read files: Use read (NOT cat/head/tail)
        \\Edit files: Use edit (NOT sed/awk)
        \\Write files: Use write (NOT 'echo >..' or 'cat <<EOF')
        \\
        \\Communication: Output text directly (NOT echo/printf)
        \\The working directory persists between commands, but shell state does not. The shell environment is initialized from the user's profile (bash or zsh).
        \\While the bash tool can do similar things, it’s better to use the built-in tools as they provide a better user experience and make it easier to review tool calls and give permission.
        \\
        \\# Instructions
        \\
        \\If your command will create new directories or files, first use this tool to run `ls` to verify the parent directory exists and is the correct location.
        \\Always quote file paths that contain spaces with double quotes in your command (e.g., cd "path with spaces/file.txt")
        \\Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it.
        \\You may specify an optional timeout in milliseconds up to 60 seconds. By default, your command will timeout after 1 minute.
        \\
        \\If the commands are independent and can run in parallel, make multiple bash tool calls in a single message. Example: if you need to run "git status" and "git diff", send a single message with two bash tool calls in parallel.
        \\If the commands depend on each other and must run sequentially, use a single bash call with '&&' to chain them together.`,
        \\Use ';' only when you need to run commands sequentially but don't care if earlier commands fail.
        \\DO NOT use newlines to separate commands (newlines are ok in quoted strings).
        \\
        \\You can use the `run_in_background` parameter to run the command in the background. Only use this if you don't need the result immediately and are OK being notified when the command completes later.
        \\You do not need to check the output right away - you'll be notified when it finishes. You do not need to use '&' at the end of the command when using this parameter.
        ,
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "The shell command to execute"},
        \\  "timout_ms": {"type": "number", "default": 30000, "description": "Cancel command after X milliseconds. Ignored by 'run_in_background'"},
        \\  "run_in_background": {"type": "boolean", "default": false, "description": "Set to true to run this command in the background. Use Read to read the output later. You MUST use this instead of '&' for background processes!"}
        \\}, "required": ["command"]}
        ,
    },
    .func = &run,
};

pub const CancelBackgroundCommand = prv.tool.Tool{
    .def = .{
        .name = "cancel_background_process",
        .description = "cancel a background process which was spawned with the bash 'run_in_background' mode",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "path": {"type": "string", "description": "the background command path"}
        \\}, "required": ["path"]}
        ,
    },
    .func = &run_cancel,
};

fn run_cancel(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    ctx.updateToolStatus(call, "(Stopping Process)", .{});

    const Args = struct {
        path: []const u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");
    };

    ctx.updateToolStatus(call, "(Stopping Process) {s}", .{args.path});

    // Snapshot the handle to cancel under lock, then perform the cancel
    // (which may block) outside the lock.
    const handle: ?Handle = blk: {
        const g = ctx.agent().bg_tasks.lock(ctx.io);
        defer g.unlock();
        const items = g.ptr.list.items;
        for (0..items.len) |i| {
            const rev = items.len - i - 1;
            if (std.mem.eql(u8, items[rev].path, args.path)) {
                const h = items[rev].handle;
                _ = g.ptr.list.swapRemove(rev);
                break :blk h;
            }
        }
        break :blk null;
    };

    if (handle) |h| {
        ctx.swarm.exec.cancel(h);
        return r.okResult(call, "Command cancel successfull");
    }

    return r.errResult(call, "No background command for this path found");
}

pub const BackgroundTask = prv.agent.BackgroundTask;
pub const BackgroundTaskList = prv.agent.BackgroundTaskList;

const Handle = prv.exec.CmdPool.Handle;

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        command: []const u8,
        run_in_background: bool = false,
        timout_ms: i64 = 30_000,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("[BAD CMD] {s}", .{call.arguments});
        return r.errResult(call, "invalid JSON arguments: expected {\"command\": \"...\"}");
    };

    if (args.command.len == 0) return r.errResult(call, "empty command");

    // NOTE: quick rg pattern fix
    if (containsUnquotedDollar(args.command) and isRgCommand(args.command)) {
        return r.errResult(call, "rg pattern contains unquoted `$`. Shell expands `$var` before rg sees it, silently corrupting the regex. Single-quote the pattern: `rg 'pattern'`");
    }

    ctx.updateToolStatus(call, "(Bash) {s}", .{args.command[0..@min(args.command.len, 248)]});

    const need_perm = switch (classifyCommand(args.command)) {
        .blocked => return r.errResult(call, "command is blocked for safety"),
        .needs_approval, .sudo => true,
        .allowed => false,
    };

    if (need_perm) {
        const decision = ctx.requestPerm(call.id, .always_check, .{ .call = .{
            .tool_name = call.name,
            .tool_arguments = call.arguments,
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

    if (args.run_in_background) {
        const handle = ctx.swarm.exec.run(ctx.cwd, &.{ "/bin/sh", "-c", args.command }) catch
            return r.errResult(call, "failed to spawn command process");

        const path = std.fmt.allocPrint(ctx.alloc, "./blitz/bg/{s}.output", .{call.id}) catch
            return r.errResult(call, "oom");
        {
            const g = ctx.agent().bg_tasks.lock(ctx.io);
            defer g.unlock();
            g.ptr.list.append(ctx.alloc, .{
                .handle = handle,
                .command = args.command,
                .path = path,
            }) catch {};
        }

        const text = std.fmt.allocPrint(ctx.alloc, "Command running in background. Output is being written to file: {s}", .{path}) catch return r.errResult(call, "oom");
        return r.okResult(call, text);
    }

    // Foreground with deadline race.
    const res = runWithDeadline(ctx, .{
        .cwd = ctx.cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
    }, args.timout_ms) catch |err| switch (err) {
        error.Timeout => {
            ctx.appendToolLog(call, "Timeout reached!");
            return r.errResult(call,
                \\!Command Timeout reached! Process killed.
            );
        },
        error.Canceled => return r.errResult(call, "canceled"),
        else => return r.errResult(call, "exec failed"),
    };
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

    const response = ctx.alloc.alloc(u8, res.stderr.len + res.stdout.len) catch return r.errResult(call, "oom");
    @memcpy(response[0..res.stdout.len], res.stdout);
    @memcpy(response[res.stdout.len..], res.stderr);
    return r.okResult(call, r.truncateOutput(ctx.alloc, response, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES));
}

const RunError = error{ Timeout, Canceled, ExecFailed };

/// Race a foreground exec future against a wall-clock deadline. On timeout,
/// the spawned process is killed and stdout/stderr are discarded. Polls both
/// the slot's done flag and the deadline at 25 ms intervals; cooperative
/// cancellation via ctx.isCanceled() also unwinds.
fn runWithDeadline(
    ctx: prv.tool.ToolContext,
    opts: prv.exec.CmdPool.RunOpts,
    deadline_ms: i64,
) RunError!prv.exec.CmdResult {
    const handle = ctx.swarm.exec.runWithOpts(opts) catch return error.ExecFailed;
    const slot = &ctx.swarm.exec.slots[@intFromEnum(handle)];

    const start_ms = prv.http.nowMs(ctx.io);
    while (true) {
        if (slot.done.load(.acquire)) {
            slot.future.await(ctx.io) catch {};
            const out = ctx.swarm.exec.alloc.dupe(u8, slot.stdout.items) catch {
                ctx.swarm.exec.release(handle);
                return error.ExecFailed;
            };
            const err = ctx.swarm.exec.alloc.dupe(u8, slot.stderr.items) catch {
                ctx.swarm.exec.alloc.free(out);
                ctx.swarm.exec.release(handle);
                return error.ExecFailed;
            };
            const ty = slot.result_ty;
            ctx.swarm.exec.release(handle);
            return .{ .stdout = out, .stderr = err, .ty = ty };
        }
        if (ctx.isCanceled()) {
            ctx.swarm.exec.cancel(handle);
            return error.Canceled;
        }
        if (prv.http.nowMs(ctx.io) - start_ms > deadline_ms) {
            ctx.swarm.exec.cancel(handle);
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

fn isRgCommand(cmd: []const u8) bool {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    return std.mem.startsWith(u8, trimmed, "rg") or std.mem.startsWith(u8, trimmed, "ripgrep");
}

fn containsUnquotedDollar(cmd: []const u8) bool {
    var in_single: bool = false;
    var in_double: bool = false;
    for (cmd) |c| {
        switch (c) {
            '\'' => {
                if (!in_double) in_single = !in_single;
            },
            '"' => {
                if (!in_single) in_double = !in_double;
            },
            '$' => {
                if (!in_single and !in_double) return true;
            },
            else => {},
        }
    }
    return false;
}

fn isInList(name: []const u8, list: []const []const u8) bool {
    for (list) |cmd| {
        if (std.mem.eql(u8, name, cmd)) return true;
    }
    return false;
}
