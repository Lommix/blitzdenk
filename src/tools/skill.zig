const std = @import("std");
const r = @import("root.zig");

pub const LoadSkillTool = r.prv.tool.Tool{
    .def = .{
        .name = "load_skill",
        .description =
        \\Load a specialized skill into the chat context.
        \\
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "name": {"type": "string", "description": "the name of the skill"}
        \\  },
        \\  "required": ["name"]
        \\}
        ,
    },
    .func = &run,
};

fn run(ctx: r.prv.tool.ToolContext, call: r.prv.adapter.ToolCall) r.prv.adapter.ToolResult {
    const Args = struct {
        name: []const u8,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");
    };

    r.setToolStatusPrint(ctx, call, "loading skill `{s}`", .{args.name});
    const app = ctx.swarm.context.cast(r.r.app.App);

    if (app.context_factory.skill_dir) |dir| {
        var it = dir.iterate();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var header_buf: [4096]u8 = undefined;

        while (it.next(ctx.io) catch return r.errResult(call, "failed to read skill dir, inform the user")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const len = dir.realPathFile(ctx.io, entry.name, &path_buf) catch {
                return r.errResult(call, "skill not found, inform the user");
            };

            const path = path_buf[0..len];

            const skill = r.r.ContextFactory.loadSkillMeta(ctx.io, path, &header_buf) orelse {
                std.log.err("failed to load skill header for '{s}', inform the user", .{entry.name});
                continue;
            };

            if (std.mem.eql(u8, skill.name, args.name)) {
                const skill_content = r.r.ContextFactory.loadSkillContent(ctx.alloc, ctx.io, path) orelse {
                    return r.errResult(call, "failed to load skill, inform the user");
                };

                return r.okResult(call, skill_content);
            }
        }

        return r.errResult(call, "skill not found");
    }

    return r.errResult(call, "no skills available");
}
