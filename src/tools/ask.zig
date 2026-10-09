const r = @import("root.zig");
const std = @import("std");

pub const MAX_OPTIONS = 8;

pub const AskTool = r.Tool{
    .def = .{
        .name = "ask",
        .description =
        \\Ask the user a multiple-choice question when you cannot resolve an ambiguity on your own.
        \\Put the recommended option first and suffix its label with "(recommended)".
        \\
        ,
        .prompt_snippet = "Ask the user a question",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "header": {"type": "string", "description": "Very short label displayed as a chip/tag. Examples: 'Auth method', 'Library', 'Approach'."},
        \\      "question": {"type": "string", "description": "The complete question to ask the user. Should be clear, specific, and end with a question mark."},
        \\      "options": {
        \\          "type": "array",
        \\          "items": {
        \\              "type": "object",
        \\              "properties": {
        \\                  "label": {"type": "string", "description": "User-facing label (1-5 words)."},
        \\                  "description": {"type": "string", "description": "One short sentence explaining impact/tradeoff if selected."}
        \\              },
        \\              "required": ["label", "description"],
        \\              "additionalProperties": false
        \\          },
        \\          "description": "Provide 1-8 mutually exclusive choices. Do not include an 'Other' option; the UI always appends a custom-message row."
        \\      }
        \\  },
        \\  "required": ["header", "question", "options"]
        \\}
        ,
    },
    .func = &run,
};

pub const Option = struct {
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const Args = struct {
    header: []const u8,
    question: []const u8,
    options: []const Option,
};

fn optionRow(alloc: std.mem.Allocator, opt: Option) ?[]const u8 {
    const label = opt.label orelse "";
    const desc = opt.description orelse "";
    if (label.len == 0 and desc.len == 0) return null;
    if (label.len == 0) return desc;
    if (desc.len == 0) return label;
    return std.fmt.allocPrint(alloc, "{s} — {s}", .{ label, desc }) catch null;
}

fn choiceText(opt: Option) []const u8 {
    const label = opt.label orelse "";
    if (label.len > 0) return label;
    return opt.description orelse "";
}

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = r.parseArgs(Args, ctx.alloc, call) orelse
        return r.errResult(call, "invalid JSON arguments: expected {header, question, options} with options as [{label, description}]");

    if (args.options.len == 0) return r.errResult(call, "options must contain at least one entry");
    if (args.options.len > MAX_OPTIONS) return r.errResult(call, "too many options (max 8)");

    const rows = ctx.alloc.alloc([]const u8, args.options.len) catch
        return r.errResult(call, "out of memory");
    for (args.options, 0..) |opt, i| {
        rows[i] = optionRow(ctx.alloc, opt) orelse
            return r.errResult(call, "each option needs a label or a description");
    }

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "question ");
    w.styled(.{ .fg = app.theme.muted }, args.question);

    r.setToolStatus(ctx, call, w.finish()) catch {};

    const decision = ctx.requestPermission(call, .{ .ask = .{
        .header = args.header,
        .options = rows,
        .question = args.question,
    } });
    return switch (decision) {
        .choice => |i| r.okResult(call, choiceText(args.options[i])),
        .message => |msg| r.okResult(call, msg),
        else => r.errResult(call, "ask canceled"),
    };
}
