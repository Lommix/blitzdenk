const std = @import("std");
const types = @import("types.zig");

pub const CancellationToken = struct {
    event: std.Io.Event = .unset,

    pub fn cancel(self: *CancellationToken, io: std.Io) void {
        self.event.set(io);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.event.isSet();
    }

    pub fn check(self: *const CancellationToken) !void {
        if (self.isCancelled()) return error.Canceled;
    }

    pub fn wait(self: *CancellationToken, io: std.Io) !void {
        try self.event.wait(io);
    }

    pub fn waitUntilCanceled(self: *CancellationToken, io: std.Io) void {
        while (!self.isCancelled()) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch return;
    }
};

pub fn sleepCancellable(io: std.Io, duration_ms: u64, cancellation: ?*CancellationToken) !void {
    const token = cancellation orelse {
        std.Io.sleep(io, .fromMilliseconds(@intCast(duration_ms)), .awake) catch {};
        return;
    };
    if (token.isCancelled()) return error.Canceled;
    var remaining: u64 = duration_ms;
    while (remaining > 0) {
        const chunk: u64 = @min(remaining, 100);
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(chunk)), .clock = .awake } };
        if (token.event.waitTimeout(io, timeout)) {
            return error.Canceled;
        } else |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        }
        remaining -= chunk;
    }
}

pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    tool: []const u8,
};

pub const RequestInfo = struct {
    model: []const u8,
    message_count: usize,
    tool_count: usize,
    messages: []const types.Message = &.{},
};

pub const ResponseInfo = struct {
    latency_ms: u64,
    usage: types.Usage = .{},
    finish_reason: types.FinishReason = .other,
    status_code: u16 = 0,
    err: ?anyerror = null,
};

pub const ProviderErrorInfo = struct {
    status_code: u16,
    response_body: []const u8,
    is_retryable: bool,
    context_overflow: bool = false,
    retry_after_ms: ?u64 = null,
    will_retry: bool = false,
    attempt: u32 = 0,
};

pub const StepInfo = struct {
    number: usize,
    text: []const u8 = "",
    tool_calls: []const types.ToolCall = &.{},
    tool_results: []const types.ToolResult = &.{},
    finish_reason: types.FinishReason = .other,
    usage: types.Usage = .{},
};

pub const ToolStartInfo = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    step: usize,
    input: []const u8,
};

pub const ToolCallInfo = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    step: usize,
    input: []const u8 = "",
    output: []const u8 = "",
    is_error: bool = false,
    duration_ms: u64 = 0,
    err: ?anyerror = null,
};

pub const ReminderInfo = struct {
    step: usize,
    message_count: usize,
};

pub const PrepareStepInfo = struct {
    number: usize,
    messages: []const types.Message,
};

pub const PrepareStepResult = struct {
    messages: []const types.Message = &.{},
    replace: bool = false,
    tools: ?[]const types.Tool = null,
};

pub const StopInfo = struct {
    step: usize,
    messages: []const types.Message,
    tool_results: []const types.ToolResult,
};

pub const Hooks = struct {
    on_checkpoint: ?*const fn (ctx: ?*anyopaque, messages: []const types.Message) void = null,
    on_checkpoint_ctx: ?*anyopaque = null,

    on_prepare_step: ?*const fn (ctx: ?*anyopaque, info: PrepareStepInfo) anyerror!PrepareStepResult = null,
    on_prepare_step_ctx: ?*anyopaque = null,

    on_request: ?*const fn (ctx: ?*anyopaque, info: RequestInfo) void = null,
    on_request_ctx: ?*anyopaque = null,

    on_response: ?*const fn (ctx: ?*anyopaque, info: ResponseInfo) void = null,
    on_response_ctx: ?*anyopaque = null,

    on_provider_error: ?*const fn (ctx: ?*anyopaque, info: ProviderErrorInfo) void = null,
    on_provider_error_ctx: ?*anyopaque = null,

    on_step_finish: ?*const fn (ctx: ?*anyopaque, step: StepInfo) void = null,
    on_step_finish_ctx: ?*anyopaque = null,

    on_tool_call_start: ?*const fn (ctx: ?*anyopaque, info: ToolStartInfo) void = null,
    on_tool_call_start_ctx: ?*anyopaque = null,

    on_tool_call: ?*const fn (ctx: ?*anyopaque, info: ToolCallInfo) void = null,
    on_tool_call_ctx: ?*anyopaque = null,

    on_reminder: ?*const fn (ctx: ?*anyopaque, info: ReminderInfo) ?[]const u8 = null,
    on_reminder_ctx: ?*anyopaque = null,

    stop_when: ?*const fn (ctx: ?*anyopaque, info: StopInfo) bool = null,
    stop_when_ctx: ?*anyopaque = null,
};

pub const StreamCallbacks = struct {
    on_text: ?*const fn (ctx: ?*anyopaque, delta: []const u8) void = null,
    on_text_ctx: ?*anyopaque = null,

    on_reasoning: ?*const fn (ctx: ?*anyopaque, delta: []const u8) void = null,
    on_reasoning_ctx: ?*anyopaque = null,

    on_tool_call: ?*const fn (ctx: ?*anyopaque, chunk: types.StreamChunk) void = null,
    on_tool_call_ctx: ?*anyopaque = null,

    on_step_finish: ?*const fn (ctx: ?*anyopaque, step: StepInfo) void = null,
    on_step_finish_ctx: ?*anyopaque = null,

    on_finish: ?*const fn (ctx: ?*anyopaque, result: *const types.TextResult) void = null,
    on_finish_ctx: ?*anyopaque = null,

    on_error: ?*const fn (ctx: ?*anyopaque, err: anyerror) void = null,
    on_error_ctx: ?*anyopaque = null,
};

pub const GenerateOptions = struct {
    system: []const u8 = "",
    prompt: []const u8 = "",
    messages: []const types.Message = &.{},
    tools: []const types.Tool = &.{},

    max_steps: usize = 1,
    sequential_tool_execution: bool = false,
    tool_choice: ToolChoice = .auto,

    max_output_tokens: u32 = 0,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?u32 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    seed: ?i64 = null,
    stop_sequences: []const []const u8 = &.{},

    max_retries: u32 = 2,
    timeout_ms: ?u64 = null,
    headers: []const std.http.Header = &.{},
    provider_options: ?std.json.Value = null,
    prompt_caching: bool = false,
    cache_ttl: ?[]const u8 = null,

    schema_name: []const u8 = "response",
    explicit_schema: ?[]const u8 = null,

    client: ?*std.http.Client = null,
    cancellation: ?*CancellationToken = null,

    hooks: Hooks = .{},
    stream: StreamCallbacks = .{},
};

pub const EmbedOptions = struct {
    provider_options: ?std.json.Value = null,
    max_parallel_calls: usize = 4,
    max_retries: u32 = 2,
    timeout_ms: ?u64 = null,
    headers: []const std.http.Header = &.{},
    client: ?*std.http.Client = null,
    cancellation: ?*CancellationToken = null,
};

pub const ImageOptions = struct {
    prompt: []const u8 = "",
    n: u32 = 1,
    size: []const u8 = "",
    aspect_ratio: []const u8 = "",
    provider_options: ?std.json.Value = null,
    max_retries: u32 = 2,
    timeout_ms: ?u64 = null,
    headers: []const std.http.Header = &.{},
    client: ?*std.http.Client = null,
    cancellation: ?*CancellationToken = null,
};

test "generate options defaults" {
    const o = GenerateOptions{};
    try std.testing.expectEqual(@as(usize, 1), o.max_steps);
    try std.testing.expectEqual(@as(u32, 2), o.max_retries);
    try std.testing.expect(o.client == null);
    try std.testing.expect(!o.sequential_tool_execution);
}

test "embed options defaults" {
    const o = EmbedOptions{};
    try std.testing.expectEqual(@as(usize, 4), o.max_parallel_calls);
    try std.testing.expectEqual(@as(u32, 2), o.max_retries);
}
