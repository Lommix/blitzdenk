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
        \\Find files: Use glob (NOT find/ls/rg pipelines)
        \\Search file contents: Use grep (NOT grep/rg pipelines)
        \\Edit files: Use edit (NOT sed/awk)
        \\Write files: Use write ('echo >..' or 'cat <<EOF' is FORBIDDEN!)
        \\While the bash tool can do similar things, it’s better to use the built-in tools as they provide a better user experience and make it easier to review tool calls and give permission.
        \\
        \\# Instructions
        \\
        \\If your command will create new directories or files, first use this tool to run `ls` to verify the parent directory exists and is the correct location.
        \\Always quote file paths that contain spaces with double quotes in your command.
        \\You may specify an optional timeout in milliseconds up to 60 seconds. By default, your command will timeout after 1 minute.
        \\
        \\If the commands are independent and can run in parallel, make multiple bash tool calls in a single message. Example: if you need to run "git status" and "git diff", send a single message with two bash tool calls in parallel.
        \\If the commands depend on each other and must run sequentially, use a single bash call with '&&' to chain them together.`,
        \\Use ';' only when you need to run commands sequentially but don't care if earlier commands fail.
        \\DO NOT use newlines to separate commands (newlines are ok in quoted strings).
        \\Use the `workdir` parameter to run a command in a different directory; it defaults to the current cwd. Avoid `cd <dir> && cmd` — prefer `workdir`.
        \\
        \\You can use the `run_in_background` parameter to run the command in the background. Only use this if you don't need the result immediately and are OK being notified when the command completes later.
        \\You do not need to check the output right away - you'll be notified when it finishes. You do not need to use '&' at the end of the command when using this parameter.
        ,
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "Command to run directly in the current cwd. Example: use `zig build`, not `cd . && zig build`."},
        \\  "workdir": {"type": "string", "description": "The working directory to run the command in. Defaults to the current cwd"},
        \\  "timeout_ms": {"type": "number", "default": 30000, "description": "Cancel command after X milliseconds. Ignored by 'run_in_background'"},
        \\  "run_in_background": {"type": "boolean", "default": false, "description": "Set to true to run this command in the background. Use read_process to read the current output later. You MUST use this instead of '&' for background processes!"}
        \\}, "required": ["command"]}
        ,
    },
    .func = &run,
};

pub const CancelBackgroundCommand = prv.tool.Tool{
    .def = .{
        .name = "cancel_process",
        .description = "cancel a background process which was spawned with the bash 'run_in_background' mode",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "id": {"type": "number", "description": "the background process id"}
        \\}, "required": ["id"]}
        ,
    },
    .func = &run_cancel,
};

pub const ReadProcessTool = prv.tool.Tool{
    .def = .{
        .name = "read_process",
        .description =
        \\Reads the current stdout/stderr of a background command spawned with the bash 'run_in_background' mode.
        \\Returns the output so far, even while the process is still running.
        ,
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "id": {"type": "number", "description": "the background process id"}
        \\}, "required": ["id"]}
        ,
    },
    .func = &run_read_process,
};

/// Reverse-scan for the newest background task with this id, returning its
/// handle. The returned handle stays valid until the task is removed.
fn findHandle(ctx: prv.tool.ToolContext, id: u8) ?Handle {
    const g = ctx.agent().bg_tasks.lock(ctx.io);
    defer g.unlock();
    const items = g.ptr.list.items;
    for (0..items.len) |i| {
        const rev = items.len - i - 1;
        if (@as(u8, @intFromEnum(items[rev].handle)) == id)
            return items[rev].handle;
    }
    return null;
}

fn run_cancel(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    r.setToolStatusPrint(ctx, call, "(Stopping Process)", .{});

    const Args = struct {
        id: u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return r.errResult(call, "invalid JSON arguments: expected {\"id\" : <process id>}");
    };

    r.setToolStatusPrint(ctx, call, "(Stopping Process) {d}", .{args.id});

    const handle = findHandle(ctx, args.id) orelse
        return r.errResult(call, "No background command for this id found");

    // Drop the task entry under lock, then cancel (which may block) outside.
    {
        const g = ctx.agent().bg_tasks.lock(ctx.io);
        defer g.unlock();
        const items = g.ptr.list.items;
        for (0..items.len) |i| {
            if (items[i].handle == handle) {
                _ = g.ptr.list.swapRemove(i);
                break;
            }
        }
    }

    ctx.swarm.exec.cancel(handle);
    return r.okResult(call, "Command cancel successfull");
}

fn run_read_process(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        id: u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return r.errResult(call, "invalid JSON arguments: expected {\"id\": <process id>}");
    };

    const handle = findHandle(ctx, args.id) orelse
        return r.errResult(call, "No background command for this id found");

    r.setToolStatusPrint(ctx, call, "(Reading Process) {d}", .{args.id});

    if (ctx.swarm.exec.poll(handle)) |maybe_res| {
        if (maybe_res) |res| {
            defer ctx.swarm.exec.alloc.free(res.stdout);
            defer ctx.swarm.exec.alloc.free(res.stderr);
            const content = formatBashResult(ctx.alloc, res.stdout, res.stderr, res.exit_code) catch "failed to read command pipe";
            return r.okResult(call, r.truncateOutputToOwned(ctx.alloc, content, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES));
        }
    } else |_| {
        return r.errResult(call, "failed to read command output");
    }

    const slot = &ctx.swarm.exec.slots[@intFromEnum(handle)];
    slot.output_lock.lockUncancelable(ctx.swarm.exec.io);
    defer slot.output_lock.unlock(ctx.swarm.exec.io);
    const content = std.fmt.allocPrint(
        ctx.alloc,
        "<bash status=\"running\">\n<stdout>{s}</stdout>\n<stderr>{s}</stderr>\n</bash>",
        .{ slot.stdout.items, slot.stderr.items },
    ) catch "failed to read command pipe";
    return r.okResult(call, r.truncateOutputToOwned(ctx.alloc, content, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES));
}

pub const BackgroundTask = prv.agent.BackgroundTask;
pub const BackgroundTaskList = prv.agent.BackgroundTaskList;

const Handle = prv.exec.CmdPool.Handle;

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        command: []const u8,
        workdir: ?[]const u8 = null,
        run_in_background: bool = false,
        timeout_ms: i64 = 30_000,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("[BAD CMD] {s}", .{call.arguments});
        return r.errResult(call, "invalid JSON arguments: expected {\"command\": \"...\"}");
    };

    if (args.command.len == 0) return r.errResult(call, "empty command");

    const run_cwd = if (args.workdir) |wd| (std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, wd }) catch
        return r.errResult(call, "invalid workdir")) else ctx.cwd;

    // NOTE: quick rg pattern fix
    if (containsUnquotedDollar(args.command) and isRgCommand(args.command)) {
        return r.errResult(call, "rg pattern contains unquoted `$`. Shell expands `$var` before rg sees it, silently corrupting the regex. Single-quote the pattern: `rg 'pattern'`");
    }

    // Replace full cwd paths with "." for cleaner output (stack buffer)
    var buf: [512]u8 = undefined;
    const cleaned_command_str = if (ctx.cwd.len > 0)
        r.replaceAll(args.command, ctx.cwd, ".", &buf)
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
        const handle = ctx.swarm.exec.run(run_cwd, &.{ "/bin/sh", "-c", args.command }) catch
            return r.errResult(call, "failed to spawn command process");

        const id: u8 = @intFromEnum(handle);
        {
            const g = ctx.agent().bg_tasks.lock(ctx.io);
            defer g.unlock();
            g.ptr.list.append(ctx.alloc, .{
                .handle = handle,
                .command = args.command,
            }) catch {};
        }

        const text = std.fmt.allocPrint(ctx.alloc, "Command running in background. Process ID: {d}", .{id}) catch return r.errResult(call, "oom");
        return r.okResult(call, text);
    }

    // Foreground with deadline race.
    const res = runWithDeadline(ctx, .{
        .cwd = run_cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
    }, args.timeout_ms) catch |err| switch (err) {
        error.Timeout => {
            r.setToolStatusParagraph(ctx, call, &.{
                &.{.{ .content = cleaned_command_str[0..@min(cleaned_command_str.len, 248)] }},
                &.{.{ .content = "Timeout reached!", .style = .{ .fg = .red } }},
            }) catch {};
            return r.errResult(call,
                \\!Command Timeout reached! Process killed.
            );
        },
        error.Canceled => return r.errResult(call, "canceled"),
        else => return r.errResult(call, "exec failed"),
    };
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

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
