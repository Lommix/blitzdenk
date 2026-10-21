const std = @import("std");
const r = @import("root.zig");

pub const SkillTool = r.Tool{
    .def = .{
        .name = "skill",
        .description = "Load the full instructions for a skill. Call it before acting on a task that names or clearly matches a skill in the session skill catalog.",
        .prompt_snippet = "Load a skill by name",
        .prompt_guidelines = "If the user names a skill, or the task clearly matches a skill's description, call the `skill` tool with the exact skill name before taking task actions. Load all applicable skills, then follow their full instructions. This catalog contains summaries only; do not infer or follow a skill's instructions until it has been loaded.",
        .parameters_schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"The exact skill name from the available skills list."}},"required":["name"]}
        ,
    },
    .func = &run,
};

fn run(ctx: r.ToolContext, call: r.ToolCall) r.ToolResult {
    const Args = struct {
        name: []const u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.input, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"name\": \"...\"}");

    if (args.name.len == 0) return r.errResult(call, "skill name is empty");

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    const entry = app.context_factory.skills.find(args.name) orelse return r.errResult(
        call,
        std.fmt.allocPrint(ctx.alloc, "skill \"{s}\" is unknown or no longer available", .{args.name}) catch "unknown skill",
    );

    if (!entry.meta.model_invocable) return r.errResult(
        call,
        std.fmt.allocPrint(ctx.alloc, "skill \"{s}\" is not available for model invocation", .{args.name}) catch "skill is not available for model invocation",
    );

    var status_buf: [r.STATUS_BUF]u8 = undefined;
    var status_writer = r.tui.AnsiWriter.init(&status_buf);
    status_writer.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "skill ");
    status_writer.styled(.{ .fg = app.theme.warn, .modifier = .{ .bold = true } }, entry.meta.name);
    r.setToolStatus(ctx, call, status_writer.finish()) catch {};

    const loaded = r.r.skills.loadSkill(ctx.io, ctx.alloc, entry) orelse return r.errResult(
        call,
        std.fmt.allocPrint(ctx.alloc, "failed to load skill \"{s}\"", .{args.name}) catch "failed to load skill",
    );
    defer ctx.alloc.free(loaded.raw);

    const body = std.mem.trim(u8, loaded.body, " \t\r\n");
    const rendered = renderSkillContent(ctx.alloc, entry.meta.name, body) catch
        return r.errResult(call, "failed to render skill");
    return r.okResult(call, rendered);
}

pub fn renderSkillContent(alloc: std.mem.Allocator, name: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "<skill_content name=\"{s}\">\n<skill_instructions>\n{s}\n</skill_instructions>\n</skill_content>", .{ name, body });
}

test "render skill content wraps trimmed body without frontmatter" {
    const raw = "---\nname: demo\ndescription: demo skill\n---\n\nbody line\n";
    const body = @import("../skills.zig").parseSkillBody(raw).?;
    const rendered = try renderSkillContent(std.testing.allocator, "demo", std.mem.trim(u8, body, " \t\r\n"));
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("<skill_content name=\"demo\">\n<skill_instructions>\nbody line\n</skill_instructions>\n</skill_content>", rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "description:") == null);
}
