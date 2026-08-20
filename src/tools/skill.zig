const r = @import("root.zig");
const std = @import("std");

pub const SkillTool = r.Tool{
    .def = .{
        .name = "skill",
        .description = "Load a skill on demand by name. Returns the skill instructions",
        .prompt_snippet = "Load a skill by name",
        .prompt_guidelines = "Load skills when the task matches their use case",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "name": {"type": "string", "description": "Skill name to load"}
        \\  },
        \\  "required": ["name"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const Args = struct { name: []const u8 };
    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"name\": \"...\"}");

    if (args.name.len == 0) return r.errResult(call, "skill name is empty");

    const app: *@import("../app.zig").App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    const entry = app.context_factory.skills.find(args.name) orelse
        return r.errResult(call, std.fmt.allocPrint(ctx.alloc, "unknown skill: {s}", .{args.name}) catch "unknown skill");

    if (!entry.meta.model_invocable) return r.errResult(call, "skill is not invocable by the model");

    const loaded = r.r.skills.loadSkill(app.io, ctx.alloc, entry) orelse
        return r.errResult(call, "failed to load skill");
    defer ctx.alloc.free(loaded.raw);

    var buf: [255]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&buf);
    w.writeAll("skill ");
    w.styled(.{ .fg = app.theme.warn, .modifier = .{ .bold = true } }, entry.meta.name);

    r.setToolStatus(ctx, call, w.finish()) catch {};

    const out = std.fmt.allocPrint(ctx.alloc, "<skill_content name=\"{s}\">\n<skill_instructions>\n{s}\n</skill_instructions>\n</skill_content>", .{ entry.meta.name, loaded.body }) catch
        return r.errResult(call, "out of memory");
    return r.okResult(call, out);
}
