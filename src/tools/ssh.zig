const std = @import("std");
const r = @import("root.zig");
const prv = @import("provider");
const apt = prv.adapter;
const tc = prv.tool;

pub const EnterSshMode = tc.Tool{
    .def = .{
        .name = "enter_ssh",
        .description = "Enter ssh mode. All subsequent tool calls (read,write,edit,bash) run on the remote target.",
        .parameters_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .func = &enter_ssh_mode,
};

pub const ExitSshMode = tc.Tool{
    .def = .{
        .name = "exit_ssh",
        .description = "Exit ssh mode. All subsequent tool calls run locally.",
        .parameters_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .func = &exit_ssh_mode,
};

fn enter_ssh_mode(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    if (ctx.swarm.exec.ssh_target == null) {
        return r.errResult(call, "no ssh target set; user must run :ssh user@host:/cwd first");
    }

    ctx.updateToolStatus(call, "(Enter SSH Mode)", .{});

    ctx.swarm.exec.setSshActive(true);
    return r.okResult(call, "ssh mode enabled");
}

fn exit_ssh_mode(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    ctx.swarm.exec.setSshActive(false);
    ctx.updateToolStatus(call, "(Exit SSH Mode)", .{});
    return r.okResult(call, "ssh mode disabled");
}
