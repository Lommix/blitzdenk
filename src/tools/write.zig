const r = @import("root.zig");
const std = @import("std");

pub const WriteTool = r.Tool{
    .def = .{
        .name = "write",
        .description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        .prompt_snippet = "Write content to a file",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "file_path": {"type": "string", "description": "Path to the file to write (relative or absolute)"},
        \\      "content": {"type": "string", "description": "Content to write to the file"}
        \\  },
        \\  "required": ["file_path", "content"]
        \\}
        ,
    },
    .func = &run,
};

const Args = struct {
    file_path: []const u8,
    content: []const u8,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const alloc = ctx.alloc;
    const args = std.json.parseFromSliceLeaky(Args, alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"file_path\": \"...\", \"content\": \"...\"}");

    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));

    var buf: [128]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&buf);
    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "write ");
    w.styled(.{ .fg = app.theme.muted }, args.file_path);
    r.setToolStatus(ctx, call, w.finish()) catch {};

    if (args.file_path.len == 0) return r.errResult(call, "path is empty");

    const resolved = std.fs.path.resolve(alloc, &.{ ctx.base.cwd, args.file_path }) catch
        return r.errResult(call, "failed to resolve path");

    const lock = &r.file_mutex;
    lock.lock(ctx.io) catch return r.errResult(call, "failed to lock file");
    defer lock.unlock(ctx.io);

    const before: ?[]const u8 = if (r.readFileCapped(ctx, resolved, r.r.exec.MAX_OUTPUT) catch null) |text|
        (if (text.len > 0) text else null)
    else
        null;

    const decision = ctx.requestPermission(call, .{ .diff = .{
        .before = null,
        .after = args.content,
        .path = args.file_path,
    } });
    switch (decision) {
        .approved => {},
        .denied => return r.errResult(call, "User declined write. Change the approach or ask the user before retrying."),
        .message => |txt| {
            const wrapped = std.fmt.allocPrint(
                ctx.alloc,
                "User declined write and left feedback: {s}\nChange the approach or ask the user before retrying.",
                .{txt},
            ) catch txt;
            return r.errResult(call, wrapped);
        },
        else => return r.errResult(call, "permission unresolved"),
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    r.atomicWrite(ctx.io, resolved, args.content) catch |err|
        return r.errResult(call, r.fsFailure(ctx, "failed to write", resolved, err));

    r.writeToolChangedStatus(ctx, call, "write", before, args.content, args.file_path);

    const msg = std.fmt.allocPrint(ctx.alloc, "Successfully wrote {d} bytes to {s}", .{ args.content.len, args.file_path }) catch
        "write failed";
    return r.okResult(call, msg);
}
