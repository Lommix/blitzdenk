const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

pub const WriteTool = prv.tool.Tool{
    .def = .{
        .name = "write",
        .description = "Create or overwrite a file with the given content. If the file exists it will be replaced entirely. Parent directories are created automatically.",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "Path to the file (relative to cwd or absolute)"},
        \\      "content": {"type": "string", "description": "The full content to write to the file"}
        \\  },
        \\  "required": ["path", "content"]
        \\}
        ,
    },
    .func = &run,
};

const Args = struct {
    path: []const u8,
    content: []const u8,
    is_plan: bool = false,
};

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    if (ctx.agent().permission_level != .write) {
        return r.errResult(call, "Subagents must not write/edit/plan. Instead write a report back to the user");
    }

    const alloc = ctx.alloc;

    const args = std.json.parseFromSliceLeaky(Args, alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\", \"content\": \"...\"}");

    ctx.updateToolStatus(call, "write {s}", .{args.path});
    if (args.path.len == 0) return r.errResult(call, "path is empty");

    const resolved = std.fs.path.resolve(alloc, &.{ ctx.cwd, args.path }) catch
        return r.errResult(call, "failed to resolve path");

    const decision = ctx.requestPerm(call.id, .always_check, .{ .diff = .{
        .before = null,
        .after = args.content,
        .path = args.path,
    } });
    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined write"),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(ctx.alloc,
                "User declined write and left feedback: {s}",
                .{txt},
            ) catch txt;
            return r.errResult(call, wrapped);
        },
        else => return r.errResult(call, "permission unresolved"),
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    const res = runWrite(ctx, resolved, args.content) orelse
        return r.errResult(call, "failed to start process");
    defer ctx.swarm.exec.alloc.free(res.stdout);
    defer ctx.swarm.exec.alloc.free(res.stderr);

    if (res.ty != .success) {
        const msg = if (res.stderr.len > 0)
            alloc.dupe(u8, res.stderr) catch "write failed"
        else
            "write failed";
        return r.errResult(call, msg);
    }

    // Register written file in FileStats so subsequent edit calls don't block
    {
        var ts: std.posix.timespec = undefined;
        const now = if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) == 0)
            ts.sec
        else
            0;

        const g = ctx.agent().file_stats.lock(ctx.io);
        defer g.unlock();
        const look = g.ptr.getOrPut(ctx.alloc, resolved) catch unreachable;
        look.value_ptr.* = .{ .last_read = now, .last_write = now };
    }

    return r.okResult(call, "file written successfully");
}

fn runWrite(ctx: prv.tool.ToolContext, resolved: []const u8, content: []const u8) ?prv.exec.CmdResult {
    if (std.fs.path.dirname(resolved)) |dir| {
        const cmd_str = std.fmt.allocPrint(ctx.alloc, "mkdir -p {s} && tee {s}", .{ dir, resolved }) catch
            return null;
        return ctx.swarm.exec.runAndWait(.{
            .argv = &.{ "/bin/sh", "-c", cmd_str },
            .stdin_data = content,
        }) catch null;
    }
    return ctx.swarm.exec.runAndWait(.{
        .argv = &.{ "tee", resolved },
        .stdin_data = content,
    }) catch null;
}
