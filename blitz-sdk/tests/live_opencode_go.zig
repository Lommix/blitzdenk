const std = @import("std");
const sdk = @import("blitz-sdk");

const base_url = "https://opencode.ai/zen/go/v1";

const WeatherTool = struct {
    fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
        return .{ .content = "{\"city\":\"Berlin\",\"temperature_c\":21,\"conditions\":\"clear\"}" };
    }
};

const tools = [_]sdk.Tool{.{
    .name = "get_weather",
    .description = "Get the current weather for a city",
    .input_schema =
    \\{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}
    ,
    .execute = WeatherTool.execute,
}};

fn runToolLoop(alloc: std.mem.Allocator, language_model: sdk.LanguageModel) !void {
    const result = try sdk.complete(alloc, std.testing.io, language_model, .{
        .prompt = "Call get_weather for Berlin exactly once, then answer with the returned weather.",
        .tools = &tools,
        .max_steps = 3,
        .timeout_ms = 30_000,
    });

    try std.testing.expect(result.steps.len >= 2);
    try std.testing.expect(result.steps[0].tool_calls.len == 1);
    try std.testing.expectEqualStrings("get_weather", result.steps[0].tool_calls[0].name);
    try std.testing.expect(result.text.len > 0);
    std.debug.print("\n{s}\n", .{result.text});
}

test "OpenCode Go Chat Completions tool loop" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    const key = env.get("OPENCODE_API_KEY") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chat = try sdk.compat.Chat.init(alloc, env.get("OPENCODE_CHAT_MODEL") orelse "mimo-v2.5", .{
        .api_key = key,
        .base_url = base_url,
    });
    try runToolLoop(alloc, chat.languageModel());
}

test "OpenCode Go Responses tool loop" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    const key = env.get("OPENCODE_API_KEY") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chat = try sdk.responses.Chat.init(alloc, env.get("OPENCODE_RESPONSES_MODEL") orelse "gpt-5.6-luna", .{
        .api_key = key,
        .base_url = base_url,
    });
    try runToolLoop(alloc, chat.languageModel());
}

test "OpenCode Go Anthropic Messages tool loop" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    const key = env.get("OPENCODE_API_KEY") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chat = try sdk.anthropic.Chat.init(alloc, env.get("OPENCODE_ANTHROPIC_MODEL") orelse "minimax-m2.5", .{
        .api_key = key,
        .base_url = base_url,
    });
    try runToolLoop(alloc, chat.languageModel());
}

const ReminderHook = struct {
    fn onReminder(_: ?*anyopaque, info: sdk.options.ReminderInfo) ?[]const u8 {
        if (info.step >= 2) return "REMINDER: answer in one sentence.";
        return null;
    }
};

test "OpenCode Go multi-turn user input with reminder hook" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    const key = env.get("OPENCODE_API_KEY") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var chat = try sdk.compat.Chat.init(std.testing.allocator, env.get("OPENCODE_CHAT_MODEL") orelse "mimo-v2.5", .{
        .api_key = key,
        .base_url = base_url,
    });

    defer chat.deinit(std.testing.allocator);
    const language_model = chat.languageModel();

    const hooks = sdk.Hooks{ .on_reminder = ReminderHook.onReminder };

    var first = try sdk.complete(alloc, std.testing.io, language_model, .{
        .prompt = "Call get_weather for Berlin, then tell me the temperature.",
        .tools = &tools,
        .max_steps = 3,
        .timeout_ms = 30_000,
        .hooks = hooks,
    });
    defer first.deinit(alloc);

    try std.testing.expect(first.steps.len >= 1);
    try std.testing.expect(first.text.len > 0);

    var messages = std.ArrayList(sdk.Message).empty;
    try messages.appendSlice(alloc, first.messages);
    try messages.append(alloc, sdk.UserMessage("Now answer the same question for Paris, in one sentence."));

    var second = try sdk.complete(alloc, std.testing.io, language_model, .{
        .messages = messages.items,
        .tools = &tools,
        .max_steps = 3,
        .timeout_ms = 30_000,
        .hooks = hooks,
    });
    defer second.deinit(alloc);

    try std.testing.expect(second.messages.len > first.messages.len);
    try std.testing.expect(second.text.len > 0);

    if (first.steps.len >= 2 or second.steps.len >= 2) {
        var found = false;
        for (second.messages) |msg| {
            if (std.mem.indexOf(u8, msg.text(), "REMINDER") != null) found = true;
        }
        try std.testing.expect(found);
    }
    std.debug.print("\n{s}\n", .{second.text});
}
