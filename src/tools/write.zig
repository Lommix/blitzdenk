const exec = @import("exec");
const r = @import("root.zig");
const std = @import("std");

pub const WriteTool = r.Tool{
    .def = .{
        .name = "write",
        .description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        .prompt_snippet = "Write content to a file",
        .prompt_guidelines = "Use write to create or fully overwrite files; use edit for targeted changes to existing files.",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "Path to the file to write (relative or absolute)"},
        \\      "content": {"type": "string", "description": "Content to write to the file"}
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
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const alloc = ctx.alloc;
    const args = std.json.parseFromSliceLeaky(Args, alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\", \"content\": \"...\"}");

    r.setToolStatusPrint(ctx, call, "write {s}", .{args.path});
    if (args.path.len == 0) return r.errResult(call, "path is empty");

    const resolved = std.fs.path.resolve(alloc, &.{ ctx.base.cwd, args.path }) catch
        return r.errResult(call, "failed to resolve path");

    const decision = ctx.requestPermission(call.id, .always_check, .{ .diff = .{
        .before = null,
        .after = args.content,
        .path = args.path,
    } });
    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined write"),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(
                ctx.alloc,
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
    defer ctx.base.exec_pool.alloc.free(res.stdout);
    defer ctx.base.exec_pool.alloc.free(res.stderr);

    if (res.ty != .success) {
        const msg = if (res.stderr.len > 0)
            alloc.dupe(u8, res.stderr) catch "write failed"
        else
            "write failed";
        return r.errResult(call, msg);
    }

    const msg = std.fmt.allocPrint(ctx.alloc, "Successfully wrote {d} bytes to {s}", .{ args.content.len, args.path }) catch
        "write failed";
    return r.okResult(call, msg);
}

fn runWrite(ctx: r.ToolContext, resolved: []const u8, content: []const u8) ?exec.CmdResult {
    if (std.fs.path.dirname(resolved)) |dir| {
        const cmd_str = std.fmt.allocPrint(ctx.alloc, "mkdir -p {s} && tee {s}", .{ dir, resolved }) catch
            return null;
        return ctx.base.exec_pool.runAndWait(.{
            .argv = &.{ "/bin/sh", "-c", cmd_str },
            .stdin_data = content,
        }) catch null;
    }
    return ctx.base.exec_pool.runAndWait(.{
        .argv = &.{ "tee", resolved },
        .stdin_data = content,
    }) catch null;
}
