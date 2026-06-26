const std = @import("std");
const r = @import("root.zig");

pub const StartMcpTool = r.prv.tool.Tool{
    .def = .{
        .name = "start_mcp",
        .description = "Start one configured MCP server by name and add its tools to this session.",
        .parameters_schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Configured MCP name"}},"required":["name"]}
        ,
    },
    .func = &startMcp,
};

pub const StartLspTool = r.prv.tool.Tool{
    .def = .{
        .name = "start_lsp",
        .description = "Start one configured LSP server by name and add the lsp tool to this session.",
        .parameters_schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Configured LSP name"}},"required":["name"]}
        ,
    },
    .func = &startLsp,
};

const StartArgs = struct {
    name: []const u8,
};

fn startMcp(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const args = std.json.parseFromSliceLeaky(StartArgs, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments");

    r.setToolStatusPrint(ctx, call, "start MCP {s}", .{args.name});
    const app = ctx.swarm.context.cast(r.r.app.App);
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

fn startLsp(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const args = std.json.parseFromSliceLeaky(StartArgs, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments");

    r.setToolStatusPrint(ctx, call, "start LSP {s}", .{args.name});
    const app = ctx.swarm.context.cast(r.r.app.App);
    app.lua_vm.vm_mu.lockUncancelable(ctx.io);
    defer app.lua_vm.vm_mu.unlock(ctx.io);
    if (!app.lua_vm.hasLsp(args.name)) {
        const msg = std.fmt.allocPrint(ctx.alloc, "unknown LSP name: {s}", .{args.name}) catch "unknown LSP name";
        return r.errResult(call, msg);
    }
    app.cmd_queue.append(ctx.io, .{ .start_lsp = .{ .name = args.name } }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "failed to queue LSP reload: {s}", .{@errorName(err)}) catch "failed to queue LSP reload";
        return r.errResult(call, msg);
    };
    return r.okResult(call, "LSP start requested; lsp will be available on the next turn");
}
