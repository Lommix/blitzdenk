const std = @import("std");
const sdk = @import("blitz-sdk");

test {
    std.testing.refAllDecls(sdk);
    _ = sdk.types;
    _ = sdk.model;
    _ = sdk.options;
    _ = sdk.errors;
    _ = sdk.auth;
    _ = sdk.schema;
    _ = sdk.generate;
    _ = sdk.embed;
    _ = sdk.provider;
}

test "provider chats deinit owned configuration" {
    const headers = [_]std.http.Header{.{ .name = "x-test", .value = "value" }};

    inline for (.{ sdk.openai.Chat, sdk.responses.Chat, sdk.anthropic.Chat, sdk.compat.Chat }) |Chat| {
        var chat = try Chat.init(std.testing.allocator, "model", .{
            .api_key = "key",
            .base_url = "https://example.com",
            .headers = &headers,
        });
        chat.deinit(std.testing.allocator);
    }
}

test "compat retains arbitrary OpenAI endpoints" {
    var chat = try sdk.compat.Chat.init(std.testing.allocator, "llama3", .{
        .base_url = "http://127.0.0.1:11434/v1",
        .api_key = "ollama",
    });
    defer chat.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("llama3", chat.languageModel().modelId());
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", chat.base_url);
}

test "sdk smoke: tool loop with fake model" {
    const types = sdk.types;
    const model = sdk.model;
    const complete = sdk.complete;

    const Fixture = struct {
        var calls: usize = 0;

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generateFn(
            _: *anyopaque,
            a: std.mem.Allocator,
            _: std.Io,
            params: model.GenerateParams,
            _: ?*std.http.Client,
            _: u32,
        ) anyerror!*model.GenerateResult {
            const result = try a.create(model.GenerateResult);
            calls += 1;
            if (calls == 1) {
                const tool_calls = try a.alloc(types.ToolCall, 1);
                tool_calls[0] = .{
                    .id = try a.dupe(u8, "c1"),
                    .name = try a.dupe(u8, "echo"),
                    .input = try a.dupe(u8, "{}"),
                };
                result.* = .{
                    .text = "",
                    .tool_calls = tool_calls,
                    .finish_reason = .tool_calls,
                    .usage = .{ .input_tokens = 5, .output_tokens = 2, .total_tokens = 7 },
                };
            } else {
                try std.testing.expectEqual(@as(usize, 3), params.messages.len);
                try std.testing.expectEqual(types.Role.user, params.messages[0].role);
                try std.testing.expectEqual(types.Role.assistant, params.messages[1].role);
                try std.testing.expectEqual(types.PartType.tool_call, std.meta.activeTag(params.messages[1].parts()[0]));
                try std.testing.expectEqual(types.Role.tool, params.messages[2].role);
                try std.testing.expectEqual(types.PartType.tool_result, std.meta.activeTag(params.messages[2].parts()[0]));
                try std.testing.expectEqual(types.PartType.image, std.meta.activeTag(params.messages[2].parts()[1]));
                try std.testing.expectEqualStrings("data:image/png;base64,aW1n", params.messages[2].parts()[1].image.url);
                result.* = .{ .text = try a.dupe(u8, "done"), .finish_reason = .stop };
            }
            return result;
        }

        fn stream(
            ctx: *anyopaque,
            a: std.mem.Allocator,
            io: std.Io,
            params: model.GenerateParams,
            client: ?*std.http.Client,
            retries: u32,
            _: *model.StreamContext,
        ) anyerror!*model.GenerateResult {
            return generateFn(ctx, a, io, params, client, retries);
        }
    };

    const FixtureTool = struct {
        fn exec(_: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, call: sdk.ToolCall) anyerror!sdk.ToolOutput {
            return .{
                .content = std.fmt.allocPrint(alloc, "echo:{s}", .{call.input}) catch "echo",
                .image = .{ .url = "data:image/png;base64,aW1n", .media_type = "image/png" },
            };
        }
    };

    var fixture: u8 = 0;
    const vtable = model.ModelVTable{
        .model_id = Fixture.modelId,
        .generate = Fixture.generateFn,
        .stream = Fixture.stream,
    };
    const chat = model.LanguageModel{ .ctx = &fixture, .vtable = &vtable };

    var tools = [_]types.Tool{
        .{ .name = "echo", .description = "echoes", .execute = FixtureTool.exec },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var result = try complete(arena.allocator(), io, chat, .{
        .prompt = "hi",
        .tools = &tools,
        .max_steps = 2,
    });
    defer result.deinit(arena.allocator());

    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.steps.len);
    try std.testing.expect(!result.steps_exhausted);
    try std.testing.expectEqual(@as(u64, 7), result.total_usage.total_tokens);
    try std.testing.expectEqualStrings("echo:{}", result.steps[0].tool_results[0].output);
    try std.testing.expectEqualStrings("data:image/png;base64,aW1n", result.steps[0].tool_results[0].image.?.url);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expectEqual(types.Role.user, result.messages[0].role);
    try std.testing.expectEqual(types.Role.assistant, result.messages[1].role);
    try std.testing.expectEqual(types.Role.tool, result.messages[2].role);
    try std.testing.expectEqual(types.Role.assistant, result.messages[3].role);
}

test "sdk smoke: reminder hook injects user message" {
    const types = sdk.types;
    const model = sdk.model;
    const complete = sdk.complete;

    const Fixture = struct {
        var calls: usize = 0;

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generateFn(
            _: *anyopaque,
            a: std.mem.Allocator,
            _: std.Io,
            params: model.GenerateParams,
            _: ?*std.http.Client,
            _: u32,
        ) anyerror!*model.GenerateResult {
            const result = try a.create(model.GenerateResult);
            calls += 1;
            if (calls == 1) {
                const tool_calls = try a.alloc(types.ToolCall, 1);
                tool_calls[0] = .{
                    .id = try a.dupe(u8, "c1"),
                    .name = try a.dupe(u8, "echo"),
                    .input = try a.dupe(u8, "{}"),
                };
                result.* = .{ .text = "", .tool_calls = tool_calls, .finish_reason = .tool_calls };
            } else {
                try std.testing.expectEqual(@as(usize, 4), params.messages.len);
                try std.testing.expectEqual(types.Role.user, params.messages[3].role);
                try std.testing.expectEqualStrings("REMINDER", params.messages[3].text());
                result.* = .{ .text = try a.dupe(u8, "done"), .finish_reason = .stop };
            }
            return result;
        }

        fn stream(
            ctx: *anyopaque,
            a: std.mem.Allocator,
            io: std.Io,
            params: model.GenerateParams,
            client: ?*std.http.Client,
            retries: u32,
            _: *model.StreamContext,
        ) anyerror!*model.GenerateResult {
            return generateFn(ctx, a, io, params, client, retries);
        }
    };

    const ReminderHook = struct {
        fn onReminder(_: ?*anyopaque, info: sdk.options.ReminderInfo) ?[]const u8 {
            if (info.step >= 2) return "REMINDER";
            return null;
        }
    };

    const FixtureTool = struct {
        fn exec(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            return .{ .content = "ok" };
        }
    };

    var fixture: u8 = 0;
    const vtable = model.ModelVTable{
        .model_id = Fixture.modelId,
        .generate = Fixture.generateFn,
        .stream = Fixture.stream,
    };
    const chat = model.LanguageModel{ .ctx = &fixture, .vtable = &vtable };

    var tools = [_]types.Tool{
        .{ .name = "echo", .description = "echoes", .execute = FixtureTool.exec },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var result = try complete(arena.allocator(), io, chat, .{
        .prompt = "hi",
        .tools = &tools,
        .max_steps = 2,
        .hooks = .{ .on_reminder = ReminderHook.onReminder },
    });
    defer result.deinit(arena.allocator());

    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqual(@as(usize, 5), result.messages.len);
    try std.testing.expectEqual(types.Role.user, result.messages[3].role);
    try std.testing.expectEqualStrings("REMINDER", result.messages[3].text());
}

test "sdk cancellation interrupts a running model" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generateFn(
            _: *anyopaque,
            _: std.mem.Allocator,
            io: std.Io,
            params: sdk.model.GenerateParams,
            _: ?*std.http.Client,
            _: u32,
        ) anyerror!*sdk.model.GenerateResult {
            const token = params.cancellation.?;
            try token.wait(io);
            try token.check();
            return error.UnexpectedResult;
        }

        fn stream(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            io: std.Io,
            params: sdk.model.GenerateParams,
            client: ?*std.http.Client,
            retries: u32,
            _: *sdk.model.StreamContext,
        ) anyerror!*sdk.model.GenerateResult {
            return generateFn(ctx, alloc, io, params, client, retries);
        }

        fn cancel(token: *sdk.CancellationToken, io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            token.cancel(io);
        }
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{
        .model_id = Fixture.modelId,
        .generate = Fixture.generateFn,
        .stream = Fixture.stream,
    };
    const chat = sdk.LanguageModel{ .ctx = &fixture, .vtable = &vtable };
    var token = sdk.CancellationToken{};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var cancel = std.Io.async(io, Fixture.cancel, .{ &token, io });
    defer cancel.cancel(io);

    try std.testing.expectError(error.Canceled, sdk.complete(std.testing.allocator, io, chat, .{
        .prompt = "hi",
        .cancellation = &token,
    }));
}

test "sdk prepares messages and stops after tool results" {
    const Fixture = struct {
        var calls: usize = 0;

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generateFn(
            _: *anyopaque,
            a: std.mem.Allocator,
            _: std.Io,
            params: sdk.model.GenerateParams,
            _: ?*std.http.Client,
            _: u32,
        ) anyerror!*sdk.model.GenerateResult {
            calls += 1;
            try std.testing.expectEqual(@as(usize, 2), params.messages.len);
            try std.testing.expectEqualStrings("queued", params.messages[1].text());
            const result = try a.create(sdk.model.GenerateResult);
            const tool_calls = try a.alloc(sdk.ToolCall, 1);
            tool_calls[0] = .{
                .id = try a.dupe(u8, "c1"),
                .name = try a.dupe(u8, "exit"),
                .input = try a.dupe(u8, "{}"),
            };
            result.* = .{ .tool_calls = tool_calls, .finish_reason = .tool_calls };
            return result;
        }

        fn stream(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            io: std.Io,
            params: sdk.model.GenerateParams,
            client: ?*std.http.Client,
            retries: u32,
            _: *sdk.model.StreamContext,
        ) anyerror!*sdk.model.GenerateResult {
            return generateFn(ctx, alloc, io, params, client, retries);
        }
    };

    const Hooks = struct {
        fn prepare(_: ?*anyopaque, info: sdk.options.PrepareStepInfo) anyerror!sdk.options.PrepareStepResult {
            if (info.number != 1) return .{};
            return .{ .messages = &.{sdk.UserMessage("queued")} };
        }

        fn stop(_: ?*anyopaque, info: sdk.options.StopInfo) bool {
            return info.tool_results.len == 1 and std.mem.eql(u8, info.tool_results[0].tool_name, "exit");
        }
    };

    const Tool = struct {
        fn execute(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            return .{ .content = "done" };
        }
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{
        .model_id = Fixture.modelId,
        .generate = Fixture.generateFn,
        .stream = Fixture.stream,
    };
    const chat = sdk.LanguageModel{ .ctx = &fixture, .vtable = &vtable };
    const tools = [_]sdk.Tool{.{ .name = "exit", .execute = Tool.execute }};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var result = try sdk.complete(std.testing.allocator, io_state.io(), chat, .{
        .prompt = "hi",
        .tools = &tools,
        .max_steps = 5,
        .hooks = .{
            .on_prepare_step = Hooks.prepare,
            .stop_when = Hooks.stop,
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), Fixture.calls);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expectEqual(sdk.Role.tool, result.messages[3].role);
}

test "sdk cancellation interrupts tool execution" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generateFn(_: *anyopaque, a: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const result = try a.create(sdk.model.GenerateResult);
            const calls = try a.alloc(sdk.ToolCall, 1);
            calls[0] = .{ .id = try a.dupe(u8, "c1"), .name = try a.dupe(u8, "slow"), .input = try a.dupe(u8, "{}") };
            result.* = .{ .tool_calls = calls, .finish_reason = .tool_calls };
            return result;
        }

        fn stream(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generateFn(ctx, a, io, params, client, retries);
        }

        fn tool(ctx: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            const io: *std.Io = @ptrCast(@alignCast(ctx.?));
            try std.Io.sleep(io.*, .fromSeconds(60), .awake);
            return .{ .content = "late" };
        }

        fn cancel(token: *sdk.CancellationToken, io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            token.cancel(io);
        }
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generateFn, .stream = Fixture.stream };
    const chat = sdk.LanguageModel{ .ctx = &fixture, .vtable = &vtable };
    var token = sdk.CancellationToken{};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var io = io_state.io();
    const tools = [_]sdk.Tool{.{ .name = "slow", .execute = Fixture.tool, .execute_ctx = &io }};
    var cancel = std.Io.async(io, Fixture.cancel, .{ &token, io });
    defer cancel.cancel(io);

    try std.testing.expectError(error.Canceled, sdk.complete(std.testing.allocator, io, chat, .{
        .prompt = "hi",
        .tools = &tools,
        .max_steps = 2,
        .cancellation = &token,
    }));
}
