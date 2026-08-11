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
        \\Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to first 1000 lines or 32KB (whichever is hit first). Optionally provide a timeout in seconds. Set "run_in_background" to true to run the command in the background and poll it with read_process / stop it with cancel_process.
        ,
        .prompt_snippet = "Execute a bash command",
        .prompt_guidelines = "Use bash for operations without a dedicated tool (e.g. ls, rg, find, builds, tests).",
        .parameters_schema =
        \\{"type": "object", "properties": {
        \\  "command": {"type": "string", "description": "Bash command to execute"},
        \\  "timeout": {"type": "number", "description": "Timeout in seconds (optional, no default timeout)"},
        \\  "run_in_background": {"type": "boolean", "default": false, "description": "If true, spawn the command in the background and return immediately with a process id; poll with read_process, stop with cancel_process"}
        \\}, "required": ["command"]}
        ,
    },
    .func = &run,
};

pub const CancelBackgroundCommand = prv.tool.Tool{
    .def = .{
        .name = "cancel_process",
        .description = "cancel a background process which was spawned with the bash 'run_in_background' mode",
        .prompt_snippet = "Cancel a background process",
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
        .prompt_snippet = "Read a background process' output",
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
        timeout: ?f64 = null,
        run_in_background: bool = false,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("[BAD CMD] {s}", .{call.arguments});
        return r.errResult(call, "invalid JSON arguments: expected {\"command\": \"...\"}");
    };

    if (args.command.len == 0) return r.errResult(call, "empty command");

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
        const handle = ctx.swarm.exec.run(ctx.cwd, &.{ "/bin/sh", "-c", args.command }) catch
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
    const timeout_ms: i64 = blk: {
        const t = args.timeout orelse break :blk std.math.maxInt(i64);
        if (!std.math.isFinite(t) or t <= 0)
            return r.errResult(call, "timeout must be a positive number of seconds");
        break :blk timeoutToMs(t);
    };
    const res = runWithDeadline(ctx, .{
        .cwd = ctx.cwd,
        .argv = &.{ "/bin/sh", "-c", args.command },
    }, timeout_ms) catch |err| switch (err) {
        error.Timeout => {
            const app = ctx.swarm.context.cast(@import("../app.zig").App);
            r.setToolStatusParagraph(ctx, call, &.{
                &.{.{ .content = cleaned_command_str[0..@min(cleaned_command_str.len, 248)] }},
                &.{.{ .content = "Timeout reached!", .style = .{ .fg = app.theme.err } }},
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
