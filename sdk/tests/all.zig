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
        fn exec(_: ?*anyopaque, input: []const u8) anyerror![]const u8 {
            return std.fmt.allocPrint(std.heap.page_allocator, "echo:{s}", .{input}) catch "echo";
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
        fn exec(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
            return "ok";
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
