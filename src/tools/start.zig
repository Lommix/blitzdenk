const std = @import("std");
const r = @import("root.zig");

pub const StartMcpTool = r.r.tools.Tool{
    .def = .{
        .name = "start_mcp",
        .description = "Start one configured MCP server by name and add its tools to this session.",
        .prompt_snippet = "Start an MCP server",
        .parameters_schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Configured MCP name"}},"required":["name"]}
        ,
    },
    .func = &startMcp,
};

const StartArgs = struct {
    name: []const u8,
};

fn startMcp(ctx: r.r.tools.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = std.json.parseFromSliceLeaky(StartArgs, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments");

    r.setToolStatusPrint(ctx, call, "start MCP {s}", .{args.name});
    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    app.lua_vm.vm_mu.lockUncancelable(ctx.io);
    defer app.lua_vm.vm_mu.unlock(ctx.io);
    if (!app.lua_vm.hasMcp(args.name)) {
        const msg = std.fmt.allocPrint(ctx.alloc, "unknown MCP name: {s}", .{args.name}) catch "unknown MCP name";
        return r.errResult(call, msg);
    }
    app.cmd_queue.append(ctx.io, .{ .start_mcp = .{ .name = args.name } }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "failed to queue MCP reload: {s}", .{@errorName(err)}) catch "failed to queue MCP reload";
        return r.errResult(call, msg);
    };
    return r.okResult(call, "MCP start requested; tools will be available on the next turn");
}

