const std = @import("std");
const r = @import("root.zig");

pub const RipGrepTool = r.prv.tool.Tool{
    .def = .{
        .name = "ripgrep",
        .description =
        \\Ripgrep file and text search. Use this tool instead for any file and text related search task.
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "args": {"type": "string", "description": "the rg command string without `rg`"}
        \\  },
        \\  "required": ["args"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const Args = struct {
        args: []const u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");
    };

    r.setToolStatusPrint(ctx, call, "rg  {s}", .{
        args.args,
    });

    var buf: [255]u8 = undefined;
    const rg_str = std.fmt.bufPrint(&buf, "rg {s}", .{args.args}) catch "rg";

    const raw = ctx.swarm.exec.runAndWaitTimeout(.{
        .argv = &.{
            "sh",
            "-c",
            rg_str,
        },
    }, 10_000) catch
        return r.errResult(call, "failed to spawn command process");

    const result = raw.toOwned(ctx.alloc) catch
        return r.errResult(call, "failed to format rg output");

    return r.okResult(call, r.truncateOutputToOwned(ctx.alloc, result, r.MAX_DISPLAY_BYTES, r.MAX_DISPLAY_LINES));
}
