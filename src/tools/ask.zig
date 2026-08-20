const r = @import("root.zig");
const std = @import("std");

pub const MAX_OPTIONS = 8;

pub const AskTool = r.Tool{
    .def = .{
        .name = "ask_user",
        .description =
        \\Ask the user a multiple-choice question when you cannot resolve an ambiguity on your own.
        \\Mark your recommended option with "(recommended)".
        \\
        ,
        .prompt_snippet = "Ask the user a question",
        .prompt_guidelines = "Call ask_user when the task is ambiguous.",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "header": {"type": "string", "description": "Very short label displayed as a chip/tag. Examples: 'Auth method', 'Library', 'Approach'."},
        \\      "question": {"type": "string", "description": "The complete question to ask the user. Should be clear, specific, and end with a question mark."},
        \\      "options": {"type": "array", "items": {"type": "string"}, "description": "1-8 short option strings the user can pick from. A custom-message option is always appended by the UI."}
        \\  },
        \\  "required": ["header", "question", "options"]
        \\}
        ,
    },
    .func = &run,
};

pub const Args = struct {
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = r.parseArgs(Args, ctx.alloc, call) orelse
        return r.errResult(call, "invalid JSON arguments: expected {header, question, options}");

    if (args.options.len == 0) return r.errResult(call, "options must contain at least one entry");
    if (args.options.len > MAX_OPTIONS) return r.errResult(call, "too many options (max 8)");

    r.setToolStatusPrint(ctx, call, "question {s}", .{args.question});

    const decision = ctx.requestPermission(call.id, .{ .ask = .{
        .header = args.header,
        .options = args.options,
        .question = args.question,
    } });
    return switch (decision) {
        .choice => |i| r.okResult(call, args.options[i]),
        .message => |msg| r.okResult(call, msg),
        else => r.errResult(call, "ask canceled"),
    };
}
