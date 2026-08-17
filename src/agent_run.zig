const std = @import("std");
const sdk = @import("blitz-sdk");
const log = std.log.scoped(.agent_stream);

pub const ProviderError = struct {
    status_code: u16,
    response_body: []const u8,
    is_retryable: bool,
    retry_after_ms: ?u64,
    will_retry: bool = false,
    attempt: u32 = 0,
};

pub const Event = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool: sdk.StreamChunk,
    tool_done: sdk.options.ToolCallInfo,
    step: sdk.options.StepInfo,
    provider_error: ProviderError,
    complete: *sdk.TextResult,
    failed: anyerror,
};

pub const EventQueue = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Event) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) EventQueue {
        return .{ .io = io, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *EventQueue) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn append(self: *EventQueue, event: Event) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.events.append(self.arena.allocator(), try cloneEvent(self.arena.allocator(), event));
    }

    pub fn drain(self: *EventQueue, max: usize, ctx: ?*anyopaque, handler: *const fn (?*anyopaque, Event) void) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const drained = @min(max, self.events.items.len);
        for (self.events.items[0..drained]) |event| handler(ctx, event);
        if (drained > 0) self.events.replaceRangeAssumeCapacity(0, drained, &.{});
        if (self.events.items.len == 0) {
            _ = self.arena.reset(.free_all);
            self.events = .empty;
        }
        return drained;
    }

    pub fn count(self: *EventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.events.items.len;
    }
};

pub const RunTask = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    queue: EventQueue,
    cancellation: sdk.CancellationToken = .{},
    provider_error_seen: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    model: sdk.LanguageModel,
    options: sdk.GenerateOptions,
    checkpoint_hook: ?*const fn (?*anyopaque, []const sdk.Message) void = null,
    checkpoint_hook_ctx: ?*anyopaque = null,
    tool_call_hook: ?*const fn (?*anyopaque, sdk.options.ToolCallInfo) void = null,
    tool_call_hook_ctx: ?*anyopaque = null,
    result: ?*sdk.TextResult = null,
    checkpoint: ?OwnedMessages = null,
    failure: ?anyerror = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, model: sdk.LanguageModel, options: sdk.GenerateOptions) !RunTask {
        var self = RunTask{
            .alloc = alloc,
            .io = io,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .queue = EventQueue.init(alloc, io),
            .model = model,
            .options = .{},
        };
        errdefer self.deinit();
        self.options = try cloneOptions(self.arena.allocator(), options);
        return self;
    }

    pub fn start(self: *RunTask) void {
        self.provider_error_seen.store(false, .release);
        self.finished.store(false, .release);
        self.failure = null;
        self.future = std.Io.async(self.io, run, .{self});
    }

    pub fn isFinished(self: *const RunTask) bool {
        return self.finished.load(.acquire);
    }

    pub fn cancel(self: *RunTask) void {
        self.cancellation.cancel(self.io);
    }

    pub fn wait(self: *RunTask) void {
        if (self.future) |*future| future.await(self.io);
        self.future = null;
    }

    pub fn deinit(self: *RunTask) void {
        self.cancel();
        self.wait();
        self.queue.deinit();
        if (self.checkpoint) |*checkpoint| checkpoint.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn takeMessages(self: *RunTask) ?OwnedMessages {
        self.wait();
        const result = self.result orelse return null;
        var arena = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.alloc);
        const messages = result.messages;
        result.messages = &.{};
        result.deinit(arena.allocator());
        arena.allocator().destroy(result);
        self.result = null;
        return .{ .arena = arena, .messages = messages };
    }

    pub fn takeCheckpoint(self: *RunTask) ?OwnedMessages {
        const checkpoint = self.checkpoint;
        self.checkpoint = null;
        return checkpoint;
    }

    fn run(self: *RunTask) void {
        defer self.finished.store(true, .release);
        var options = self.options;
        options.cancellation = &self.cancellation;
        options.stream = .{
            .on_text = onText,
            .on_text_ctx = self,
            .on_reasoning = onReasoning,
            .on_reasoning_ctx = self,
            .on_tool_call = onTool,
            .on_tool_call_ctx = self,
        };
        options.hooks.on_step_finish = onStep;
        options.hooks.on_step_finish_ctx = self;
        self.tool_call_hook = options.hooks.on_tool_call;
        self.tool_call_hook_ctx = options.hooks.on_tool_call_ctx;
        options.hooks.on_tool_call = onToolDone;
        options.hooks.on_tool_call_ctx = self;
        options.hooks.on_provider_error = onProviderError;
        options.hooks.on_provider_error_ctx = self;
        const checkpoint_hook = options.hooks.on_checkpoint;
        const checkpoint_hook_ctx = options.hooks.on_checkpoint_ctx;
        options.hooks.on_checkpoint = onCheckpoint;
        options.hooks.on_checkpoint_ctx = self;
        self.checkpoint_hook = checkpoint_hook;
        self.checkpoint_hook_ctx = checkpoint_hook_ctx;
        var result = sdk.streamText(self.arena.allocator(), self.io, self.model, options) catch |err| {
            self.failure = err;
            log.warn("stream failed: {s}", .{@errorName(err)});
            if (!self.provider_error_seen.load(.acquire)) self.queue.append(.{ .failed = err }) catch |queue_err| {
                log.err("dropped stream failure event {s}: {s}", .{ @errorName(err), @errorName(queue_err) });
            };
            return;
        };
        const owned = self.arena.allocator().create(sdk.TextResult) catch {
            result.deinit(self.arena.allocator());
            self.queue.append(.{ .failed = error.OutOfMemory }) catch |err| {
                log.err("dropped out-of-memory stream failure event: {s}", .{@errorName(err)});
            };
            return;
        };
        owned.* = result;
        self.result = owned;
        self.queue.append(.{ .complete = owned }) catch |err| {
            log.err("dropped stream completion event: {s}", .{@errorName(err)});
        };
    }

    fn onText(ctx: ?*anyopaque, delta: []const u8) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        self.queue.append(.{ .text = delta }) catch |err| {
            log.err("dropped text stream chunk ({d} bytes): {s}", .{ delta.len, @errorName(err) });
        };
    }

    fn onReasoning(ctx: ?*anyopaque, delta: []const u8) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        self.queue.append(.{ .reasoning = delta }) catch |err| {
            log.err("dropped reasoning stream chunk ({d} bytes): {s}", .{ delta.len, @errorName(err) });
        };
    }

    fn onTool(ctx: ?*anyopaque, chunk: sdk.StreamChunk) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        self.queue.append(.{ .tool = chunk }) catch |err| {
            log.err("dropped tool stream chunk type={s} id={s} name={s} input_bytes={d}: {s}", .{
                @tagName(chunk.type), chunk.tool_call_id, chunk.tool_name, chunk.tool_input.len, @errorName(err),
            });
        };
    }

    fn onToolDone(ctx: ?*anyopaque, info: sdk.options.ToolCallInfo) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        if (self.tool_call_hook) |hook| hook(self.tool_call_hook_ctx, info);
        self.queue.append(.{ .tool_done = info }) catch |err| {
            log.err("dropped tool done event id={s} name={s}: {s}", .{ info.tool_call_id, info.tool_name, @errorName(err) });
        };
    }

    fn onStep(ctx: ?*anyopaque, step: sdk.options.StepInfo) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        self.queue.append(.{ .step = step }) catch |err| {
            log.err("dropped step event step={d} calls={d} results={d}: {s}", .{ step.number, step.tool_calls.len, step.tool_results.len, @errorName(err) });
        };
    }

    fn onProviderError(ctx: ?*anyopaque, info: sdk.options.ProviderErrorInfo) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        if (info.context_overflow) {
            self.provider_error_seen.store(true, .release);
            return;
        }
        if (!info.will_retry) self.provider_error_seen.store(true, .release);
        self.queue.append(.{ .provider_error = .{
            .status_code = info.status_code,
            .response_body = info.response_body,
            .is_retryable = info.is_retryable,
            .retry_after_ms = info.retry_after_ms,
            .will_retry = info.will_retry,
            .attempt = info.attempt,
        } }) catch |err| {
            log.err("dropped provider error event status={d}: {s}", .{ info.status_code, @errorName(err) });
        };
    }

    fn onCheckpoint(ctx: ?*anyopaque, messages: []const sdk.Message) void {
        const self: *RunTask = @ptrCast(@alignCast(ctx.?));
        if (self.checkpoint_hook) |hook| hook(self.checkpoint_hook_ctx, messages);
        const checkpoint = OwnedMessages.clone(self.alloc, messages) catch return;
        if (self.checkpoint) |*previous| previous.deinit();
        self.checkpoint = checkpoint;
    }
};

pub const OwnedMessages = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const sdk.Message,

    pub fn clone(alloc: std.mem.Allocator, messages: []const sdk.Message) !OwnedMessages {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const cloned = try cloneMessages(arena.allocator(), messages);
        return .{ .arena = arena, .messages = cloned };
    }

    pub fn deinit(self: *OwnedMessages) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn cloneEvent(alloc: std.mem.Allocator, event: Event) !Event {
    return switch (event) {
        .text => |value| .{ .text = try alloc.dupe(u8, value) },
        .reasoning => |value| .{ .reasoning = try alloc.dupe(u8, value) },
        .tool => |value| .{ .tool = .{
            .type = value.type,
            .text = try alloc.dupe(u8, value.text),
            .tool_call_id = try alloc.dupe(u8, value.tool_call_id),
            .tool_name = try alloc.dupe(u8, value.tool_name),
            .tool_input = try alloc.dupe(u8, value.tool_input),
            .tool_output = try alloc.dupe(u8, value.tool_output),
            .number = value.number,
            .finish_reason = value.finish_reason,
            .usage = value.usage,
            .response = if (value.response) |response| .{
                .id = try alloc.dupe(u8, response.id),
                .model = try alloc.dupe(u8, response.model),
            } else null,
            .err = value.err,
        } },
        .tool_done => |value| .{ .tool_done = .{
            .tool_call_id = try alloc.dupe(u8, value.tool_call_id),
            .tool_name = try alloc.dupe(u8, value.tool_name),
            .step = value.step,
            .input = try alloc.dupe(u8, value.input),
            .output = try alloc.dupe(u8, value.output),
            .is_error = value.is_error,
            .duration_ms = value.duration_ms,
            .err = value.err,
        } },
        .step => |value| .{ .step = .{
            .number = value.number,
            .text = try alloc.dupe(u8, value.text),
            .tool_calls = try cloneToolCalls(alloc, value.tool_calls),
            .tool_results = try cloneToolResults(alloc, value.tool_results),
            .finish_reason = value.finish_reason,
            .usage = value.usage,
        } },
        .provider_error => |value| .{ .provider_error = .{
            .status_code = value.status_code,
            .response_body = try alloc.dupe(u8, value.response_body),
            .is_retryable = value.is_retryable,
            .retry_after_ms = value.retry_after_ms,
            .will_retry = value.will_retry,
            .attempt = value.attempt,
        } },
        .complete => |value| .{ .complete = value },
        .failed => |value| .{ .failed = value },
    };
}

fn cloneToolCalls(alloc: std.mem.Allocator, values: []const sdk.ToolCall) ![]const sdk.ToolCall {
    const cloned = try alloc.alloc(sdk.ToolCall, values.len);
    for (values, 0..) |value, i| cloned[i] = .{
        .id = try alloc.dupe(u8, value.id),
        .name = try alloc.dupe(u8, value.name),
        .input = try alloc.dupe(u8, value.input),
    };
    return cloned;
}

fn cloneToolResults(alloc: std.mem.Allocator, values: []const sdk.ToolResult) ![]const sdk.ToolResult {
    const cloned = try alloc.alloc(sdk.ToolResult, values.len);
    for (values, 0..) |value, i| cloned[i] = .{
        .tool_call_id = try alloc.dupe(u8, value.tool_call_id),
        .tool_name = try alloc.dupe(u8, value.tool_name),
        .output = try alloc.dupe(u8, value.output),
        .is_error = value.is_error,
        .exit_loop = value.exit_loop,
        .image = if (value.image) |image| .{
            .url = try alloc.dupe(u8, image.url),
            .media_type = try alloc.dupe(u8, image.media_type),
        } else null,
    };
    return cloned;
}

pub const OwnedOptions = struct {
    arena: std.heap.ArenaAllocator,
    value: sdk.GenerateOptions,

    pub fn clone(alloc: std.mem.Allocator, value: sdk.GenerateOptions) !OwnedOptions {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const cloned = try cloneOptions(arena.allocator(), value);
        return .{ .arena = arena, .value = cloned };
    }

    pub fn deinit(self: *OwnedOptions) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn cloneOptions(alloc: std.mem.Allocator, value: sdk.GenerateOptions) !sdk.GenerateOptions {
    var cloned = value;
    cloned.system = try alloc.dupe(u8, value.system);
    cloned.prompt = try alloc.dupe(u8, value.prompt);
    cloned.messages = value.messages;
    cloned.tools = try cloneTools(alloc, value.tools);
    const stops = try alloc.alloc([]const u8, value.stop_sequences.len);
    for (value.stop_sequences, 0..) |stop, i| stops[i] = try alloc.dupe(u8, stop);
    cloned.stop_sequences = stops;
    const headers = try alloc.alloc(std.http.Header, value.headers.len);
    for (value.headers, 0..) |header, i| headers[i] = .{
        .name = try alloc.dupe(u8, header.name),
        .value = try alloc.dupe(u8, header.value),
    };
    cloned.headers = headers;
    cloned.provider_options = if (value.provider_options) |options| try cloneJson(alloc, options) else null;
    cloned.cache_ttl = if (value.cache_ttl) |ttl| try alloc.dupe(u8, ttl) else null;
    cloned.schema_name = try alloc.dupe(u8, value.schema_name);
    cloned.explicit_schema = if (value.explicit_schema) |schema| try alloc.dupe(u8, schema) else null;
    return cloned;
}

pub fn cloneMessages(alloc: std.mem.Allocator, values: []const sdk.Message) ![]const sdk.Message {
    const cloned = try alloc.alloc(sdk.Message, values.len);
    for (values, 0..) |value, i| {
        const parts = try alloc.alloc(sdk.Part, value.parts().len);
        for (value.parts(), 0..) |part, j| parts[j] = try clonePart(alloc, part);
        cloned[i] = .{ .role = value.role, .content = parts };
    }
    return cloned;
}

fn clonePart(alloc: std.mem.Allocator, value: sdk.Part) !sdk.Part {
    return switch (value) {
        .text => |text| .{ .text = try alloc.dupe(u8, text) },
        .reasoning => |reasoning| .{ .reasoning = .{
            .text = try alloc.dupe(u8, reasoning.text),
            .signature = try alloc.dupe(u8, reasoning.signature),
        } },
        .image => |image| .{ .image = .{
            .url = try alloc.dupe(u8, image.url),
            .media_type = try alloc.dupe(u8, image.media_type),
            .detail = try alloc.dupe(u8, image.detail),
        } },
        .tool_call => |call| .{ .tool_call = .{
            .id = try alloc.dupe(u8, call.id),
            .name = try alloc.dupe(u8, call.name),
            .input = try alloc.dupe(u8, call.input),
        } },
        .tool_result => |result| .{ .tool_result = .{
            .id = try alloc.dupe(u8, result.id),
            .name = try alloc.dupe(u8, result.name),
            .output = try alloc.dupe(u8, result.output),
            .is_error = result.is_error,
            .exit_loop = result.exit_loop,
        } },
        .file => |file| .{ .file = .{
            .url = try alloc.dupe(u8, file.url),
            .media_type = try alloc.dupe(u8, file.media_type),
            .filename = try alloc.dupe(u8, file.filename),
        } },
        .provider_data => |data| .{ .provider_data = .{
            .provider = try alloc.dupe(u8, data.provider),
            .data = try alloc.dupe(u8, data.data),
        } },
    };
}

fn cloneTools(alloc: std.mem.Allocator, values: []const sdk.Tool) ![]const sdk.Tool {
    const cloned = try alloc.alloc(sdk.Tool, values.len);
    for (values, 0..) |value, i| cloned[i] = .{
        .name = try alloc.dupe(u8, value.name),
        .description = try alloc.dupe(u8, value.description),
        .input_schema = try alloc.dupe(u8, value.input_schema),
        .execute = value.execute,
        .execute_ctx = value.execute_ctx,
    };
    return cloned;
}

fn cloneJson(alloc: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{ .number_string = try alloc.dupe(u8, item) },
        .string => |item| .{ .string = try alloc.dupe(u8, item) },
        .array => |items| blk: {
            var cloned = std.json.Array.init(alloc);
            for (items.items) |item| try cloned.append(try cloneJson(alloc, item));
            break :blk .{ .array = cloned };
        },
        .object => |items| blk: {
            var cloned: std.json.ObjectMap = .empty;
            var iterator = items.iterator();
            while (iterator.next()) |entry| try cloned.put(
                alloc,
                try alloc.dupe(u8, entry.key_ptr.*),
                try cloneJson(alloc, entry.value_ptr.*),
            );
            break :blk .{ .object = cloned };
        },
    };
}

test "run task queues owned SDK events with a drain limit" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, a: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const result = try a.create(sdk.model.GenerateResult);
            result.* = .{ .text = try a.dupe(u8, "done"), .finish_reason = .stop };
            return result;
        }

        fn stream(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, stream_ctx: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            stream_ctx.send(.{ .type = .reasoning, .text = "plan" });
            stream_ctx.send(.{ .type = .text, .text = "done" });
            return generate(ctx, a, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: Event) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            _ = event;
            count.* += 1;
        }
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var task = try RunTask.init(std.testing.allocator, io_state.io(), .{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    defer task.deinit();
    task.start();
    task.wait();
    try std.testing.expectEqual(@as(usize, 4), task.queue.count());
    var count: usize = 0;
    try std.testing.expectEqual(@as(usize, 2), task.queue.drain(2, &count, Fixture.collect));
    try std.testing.expectEqual(@as(usize, 2), task.queue.count());
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "run task does not duplicate provider failures" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            params.on_provider_error.?(params.on_provider_error_ctx, .{
                .status_code = 429,
                .response_body = "rate limited",
                .is_retryable = true,
                .retry_after_ms = 1000,
            });
            return error.RateLimited;
        }

        fn stream(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, a, io, params, client, retries);
        }
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var task = try RunTask.init(std.testing.allocator, io_state.io(), .{ .ctx = &fixture, .vtable = &vtable }, .{});
    defer task.deinit();
    task.start();
    task.wait();
    try std.testing.expectEqual(@as(usize, 1), task.queue.count());
}

test "run task retains the latest SDK checkpoint on context overflow" {
    const Fixture = struct {
        calls: usize = 0,

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(ctx: *anyopaque, alloc: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls == 2) {
                params.on_provider_error.?(params.on_provider_error_ctx, .{
                    .status_code = 400,
                    .response_body = "context length exceeded",
                    .is_retryable = false,
                    .context_overflow = true,
                });
                return error.ContextOverflow;
            }
            const calls = try alloc.alloc(sdk.ToolCall, 1);
            calls[0] = .{
                .id = try alloc.dupe(u8, "call_1"),
                .name = try alloc.dupe(u8, "test"),
                .input = try alloc.dupe(u8, "{}"),
            };
            const result = try alloc.create(sdk.model.GenerateResult);
            result.* = .{ .tool_calls = calls, .finish_reason = .tool_calls };
            return result;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn tool(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            return .{ .content = "tool output" };
        }

        fn collect(ctx: ?*anyopaque, event: Event) void {
            const saw_result: *bool = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .step => |step| if (step.tool_results.len == 1) {
                    saw_result.* = true;
                },
                else => {},
            }
        }
    };

    var fixture = Fixture{};
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var task = try RunTask.init(std.testing.allocator, io_state.io(), .{ .ctx = &fixture, .vtable = &vtable }, .{
        .prompt = "prompt",
        .max_steps = 3,
        .tools = &.{.{ .name = "test", .execute = Fixture.tool }},
    });
    defer task.deinit();
    task.start();
    task.wait();
    try std.testing.expectEqual(error.ContextOverflow, task.failure.?);
    try std.testing.expectEqual(@as(usize, 2), task.queue.count());
    var saw_result = false;
    _ = task.queue.drain(2, &saw_result, Fixture.collect);
    try std.testing.expect(saw_result);
    var checkpoint = task.takeCheckpoint().?;
    defer checkpoint.deinit();
    try std.testing.expectEqual(@as(usize, 3), checkpoint.messages.len);
    try std.testing.expectEqualStrings("prompt", checkpoint.messages[0].text());
    try std.testing.expectEqual(sdk.Role.assistant, checkpoint.messages[1].role);
    try std.testing.expectEqualStrings("tool output", checkpoint.messages[2].parts()[0].tool_result.output);
}

test "completed messages outlive the run task" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, a: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const result = try a.create(sdk.model.GenerateResult);
            result.* = .{ .text = try a.dupe(u8, "done"), .finish_reason = .stop };
            return result;
        }

        fn stream(ctx: *anyopaque, a: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, a, io, params, client, retries);
        }

        fn discard(_: ?*anyopaque, _: Event) void {}
    };

    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var task = try RunTask.init(std.testing.allocator, io_state.io(), .{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    task.start();
    task.wait();
    _ = task.queue.drain(8, null, Fixture.discard);
    var messages = task.takeMessages().?;
    task.deinit();
    defer messages.deinit();
    try std.testing.expectEqual(@as(usize, 2), messages.messages.len);
    try std.testing.expectEqualStrings("done", messages.messages[1].text());
}
