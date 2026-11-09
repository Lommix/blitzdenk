const r = @import("root.zig");
const root = r.r;
const std = @import("std");

pub const MAX_OPTIONS = root.ask_session.MAX_OPTIONS;
pub const MAX_QUESTIONS = root.ask_session.MAX_QUESTIONS;

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

pub const Args = root.ask_session.Args;
pub const Option = root.ask_session.ArgOption;

fn run(ctx: r.ToolContext, call: r.r.sdk.ToolCall) r.r.sdk.ToolOutput {
    const args = r.parseArgs(Args, ctx.alloc, call) orelse
        return r.errResult(call, "invalid JSON arguments: expected {questions: [{header, question, options: [{label, description?}], multi_select?}]}");

    if (root.ask_session.validateArgs(args)) |violation| {
        const rule = root.ask_session.formatViolation(ctx.alloc, violation) orelse
            return r.errResult(call, "out of memory");
        return r.errResult(call, rule);
    }

    const questions = root.ask_session.payloadQuestions(ctx.alloc, args) orelse
        return r.errResult(call, "out of memory");

    const app: *r.r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var sgr_buf: [r.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&sgr_buf);

    const arg_questions = root.ask_session.argQuestionList(args);
    if (arg_questions.len == 1) {
        w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "question ");
        w.styled(.{ .fg = app.theme.muted }, root.ask_session.argQuestion(arg_questions[0]));
    } else {
        w.styled(.{ .modifier = .{ .bold = true }, .fg = app.theme.text_hl }, "ask ");
        w.styledPrint(.{ .fg = app.theme.muted }, "{d} questions", .{arg_questions.len});
    }

    r.setToolStatus(ctx, call, w.finish()) catch {};

    const decision = ctx.requestPermission(call, .{ .ask = .{ .questions = questions } });
    switch (decision) {
        .answers => |answers| {
            const text = root.ask_session.formatResult(ctx.alloc, args, answers) orelse
                return r.errResult(call, "ask answers did not match the questions");
            return r.okResult(call, text);
        },
        else => return r.errResult(call, "ask canceled"),
    }
}
