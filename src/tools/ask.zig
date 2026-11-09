const r = @import("root.zig");
const ask_session = r.r.ask_session;
const permissions = r.r.permissions;

pub const AskTool = r.Tool{
    .def = .{
        .name = "ask",
        .description =
        \\Ask the user multiple-choice questions when you cannot resolve ambiguities on your own.
        \\Batch every currently unblocked, independent question into one call (max 4 questions); never batch
        \\questions whose answer depends on another question of the same call. Each question needs 1-8
        \\options with a short label and an optional one-sentence description. Set multi_select = true when several
        \\options apply together (needs at least 2 options; the user toggles several and cannot type a
        \\custom message). Put the recommended option first and suffix its label with "(recommended)";
        \\headless runs take the marked options automatically. Answers come back numbered, one line per
        \\question, in request order. Pressing esc cancels only the ask, not the agent run.
        \\
        ,
        .prompt_snippet = "Ask the user up to 4 independent questions in one call",
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "questions": {
        \\          "type": "array",
        \\          "minItems": 1,
        \\          "maxItems": 4,
        \\          "items": {
        \\              "type": "object",
        \\              "properties": {
        \\                  "header": {"type": "string", "description": "Very short label displayed as a chip/tag. Examples: 'Auth method', 'Library', 'Approach'."},
        \\                  "question": {"type": "string", "description": "The complete question to ask the user. Should be clear, specific, and end with a question mark."},
        \\                  "options": {
        \\                      "type": "array",
        \\                      "minItems": 1,
        \\                      "maxItems": 8,
        \\                      "items": {
        \\                          "type": "object",
        \\                          "properties": {
        \\                              "label": {"type": "string", "description": "Required, non-empty user-facing label: 1-5 words, plus an optional '(recommended)' suffix."},
        \\                              "description": {"type": "string", "description": "One short sentence explaining impact/tradeoff if selected. May be empty."}
        \\                          },
        \\                          "required": ["label"],
        \\                          "additionalProperties": false
        \\                      }
        \\                  },
        \\                  "multi_select": {"type": "boolean", "description": "Let the user toggle several options at once. Requires at least 2 options; no custom-message row. Default false."}
        \\              },
        \\              "required": ["header", "question", "options"],
        \\              "additionalProperties": false
        \\          }
        \\      }
        \\  },
        \\  "required": ["questions"]
        \\}
        ,
    },
    .func = &run,
};

const Args = struct {
    questions: []const permissions.Question = &.{},
};

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = r.parseArgs(Args, ctx.alloc, call) orelse
        return r.errResult(call, "invalid JSON arguments: expected {questions: [{header, question, options: [{label, description?}], multi_select?}]}");

    if (ask_session.validate(args.questions)) |violation| {
        const rule = ask_session.formatViolation(ctx.alloc, violation) catch
            return r.errResult(call, "out of memory");
        return r.errResult(call, rule);
    }

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    if (args.questions.len == 1) {
        w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "question ");
        w.styled(.{ .fg = app.theme.muted }, args.questions[0].question);
    } else {
        w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "ask ");
        w.styledPrint(.{ .fg = app.theme.muted }, "{d} questions", .{args.questions.len});
    }

    r.setToolStatus(ctx, call, w.finish()) catch {};

    switch (ctx.requestPermission(call, .{ .ask = .{ .questions = args.questions } })) {
        .answers => |answers| {
            defer answers.deinit();
            const text = ask_session.formatResult(ctx.alloc, args.questions, answers.slice()) catch
                return r.errResult(call, "out of memory");
            return r.okResult(call, text);
        },
        else => return r.errResult(call, "ask canceled"),
    }
}
