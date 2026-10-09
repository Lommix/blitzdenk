const std = @import("std");
const sdk = @import("blitz-sdk");

pub const Kind = enum {
    ollama,
    openai,
    response,
    anthropic,
};

pub const ReasoningEffort = enum {
    none,
    low,
    medium,
    high,
    xhigh,
    max,
};

pub fn parseReasoningEffort(value: []const u8) ?ReasoningEffort {
    return std.meta.stringToEnum(ReasoningEffort, value);
}

pub const Thinking = struct {
    type: []const u8,
    budget_tokens: ?u32 = null,
};

pub const OllamaOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop: ?[]const []const u8 = null,
};

pub const OpenAIOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    enable_thinking: ?bool = null,
    thinking: ?Thinking = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,
};

pub const ResponseOptions = struct {
    temperature: ?f32 = null,
    max_output_tokens: ?u32 = null,
    top_p: ?f32 = null,
};

pub const AnthropicOptions = struct {
    max_tokens: u32 = 16_384,
    thinking: ?Thinking = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop: ?[]const []const u8 = null,
};

pub const ModelParams = union(Kind) {
    ollama: OllamaOptions,
    openai: OpenAIOptions,
    response: ResponseOptions,
    anthropic: AnthropicOptions,

    /// Copy all borrowed slices into the owner's arena. Superseded copies
    /// remain valid until that arena is destroyed.
    pub fn clone(self: ModelParams, arena: std.mem.Allocator) !ModelParams {
        var copied = self;
        switch (copied) {
            inline else => |*p| {
                if (comptime @hasField(@TypeOf(p.*), "thinking")) {
                    if (p.thinking) |*thinking| thinking.type = try arena.dupe(u8, thinking.type);
                }
                if (comptime @hasField(@TypeOf(p.*), "stop")) {
                    if (p.stop) |stops| {
                        const owned = try arena.alloc([]const u8, stops.len);
                        for (stops, 0..) |stop, i| owned[i] = try arena.dupe(u8, stop);
                        p.stop = owned;
                    }
                }
            },
        }
        return copied;
    }
};

pub fn wireEffort(effort: ReasoningEffort) []const u8 {
    return @tagName(effort);
}

pub fn applyParams(params: ModelParams, effort: ?ReasoningEffort, reasoning: bool, opts: *sdk.GenerateOptions) void {
    const wire = if (reasoning) if (effort) |value| wireEffort(value) else null else null;
    switch (params) {
        .openai => |p| {
            if (p.max_tokens) |value| opts.max_output_tokens = value;
            if (p.max_completion_tokens) |value| opts.max_completion_tokens = value;
            if (p.temperature) |value| opts.temperature = @floatCast(value);
            if (p.top_p) |value| opts.top_p = @floatCast(value);
            if (p.top_k) |value| opts.top_k = value;
            if (p.frequency_penalty) |value| opts.frequency_penalty = @floatCast(value);
            if (p.presence_penalty) |value| opts.presence_penalty = @floatCast(value);
            if (p.stop) |value| opts.stop_sequences = value;
            if (p.enable_thinking) |value| opts.enable_thinking = value;
            if (p.thinking) |value| opts.thinking = .{ .type = value.type, .budget_tokens = value.budget_tokens };
            if (wire) |value| opts.reasoning_effort = value;
        },
        .response => |p| {
            if (p.max_output_tokens) |value| opts.max_output_tokens = value;
            if (p.temperature) |value| opts.temperature = @floatCast(value);
            if (p.top_p) |value| opts.top_p = @floatCast(value);
            if (wire) |value| opts.reasoning_effort = value;
        },
        .anthropic => |p| {
            opts.max_output_tokens = p.max_tokens;
            if (p.temperature) |value| opts.temperature = @floatCast(value);
            if (p.top_p) |value| opts.top_p = @floatCast(value);
            if (p.top_k) |value| opts.top_k = value;
            if (p.stop) |value| opts.stop_sequences = value;
            if (p.thinking) |value| opts.thinking = .{ .type = value.type, .budget_tokens = value.budget_tokens };
        },
        .ollama => |p| {
            if (p.max_tokens) |value| opts.max_output_tokens = value;
            if (p.temperature) |value| opts.temperature = @floatCast(value);
            if (p.top_p) |value| opts.top_p = @floatCast(value);
            if (p.top_k) |value| opts.top_k = value;
            if (p.stop) |value| opts.stop_sequences = value;
        },
    }
}

pub const Config = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    reasoning_effort: ?ReasoningEffort = null,
    reasoning: bool = true,
    rate_limit: u32 = 0,
    replay_reasoning: bool = true,
    session_key_header: []const u8 = "",
    vision: bool = false,
    params: ModelParams,
};

pub const Model = union(Kind) {
    ollama: sdk.compat.Chat,
    openai: sdk.openai.Chat,
    response: sdk.responses.Chat,
    anthropic: sdk.anthropic.Chat,

    pub fn init(alloc: std.mem.Allocator, config: Config) !Model {
        return switch (config.params) {
            .ollama => .{ .ollama = try sdk.compat.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
                .rate_limit = config.rate_limit,
                .replay_reasoning = config.replay_reasoning,
                .session_key_header = config.session_key_header,
            }) },
            .openai => .{ .openai = try sdk.openai.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
                .rate_limit = config.rate_limit,
                .replay_reasoning = config.replay_reasoning,
                .session_key_header = config.session_key_header,
            }) },
            .response => .{ .response = try sdk.responses.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
                .rate_limit = config.rate_limit,
                .session_key_header = config.session_key_header,
            }) },
            .anthropic => .{ .anthropic = try sdk.anthropic.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
                .rate_limit = config.rate_limit,
                .session_key_header = config.session_key_header,
            }) },
        };
    }

    pub fn deinit(self: *Model, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*chat| chat.deinit(alloc),
        }
    }

    /// Release runtime resources when the configuration is owned by an arena.
    pub fn deinitClient(self: *Model) void {
        switch (self.*) {
            inline else => |*chat| {
                if (chat.client) |client| {
                    const alloc = client.allocator;
                    client.deinit();
                    alloc.destroy(client);
                    chat.client = null;
                }
            },
        }
    }

    pub fn languageModel(self: *Model) sdk.LanguageModel {
        return switch (self.*) {
            inline else => |*chat| chat.languageModel(),
        };
    }
};

test "models own sdk provider chats" {
    var model = try Model.init(std.testing.allocator, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    });
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("model", model.languageModel().modelId());
    try std.testing.expect(model.openai.replay_reasoning);
}

test "replay_reasoning reaches the sdk chat" {
    for ([_]ModelParams{ .{ .openai = .{} }, .{ .ollama = .{} } }) |params| {
        var model = try Model.init(std.testing.allocator, .{
            .api_key = "key",
            .model = "model",
            .base_url = "https://example.com/v1",
            .replay_reasoning = true,
            .params = params,
        });
        defer model.deinit(std.testing.allocator);
        const chat_replays = switch (model) {
            inline else => |*chat| chat.replay_reasoning,
        };
        try std.testing.expect(chat_replays);
    }
}

test "model params copy nested slices for every provider" {
    for ([_]Kind{ .openai, .anthropic, .ollama, .response }) |kind| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var thinking_type = "enabled".*;
        var stop_text = "stop".*;
        var stops = [_][]const u8{&stop_text};
        const params: ModelParams = switch (kind) {
            .openai => .{ .openai = .{ .thinking = .{ .type = &thinking_type, .budget_tokens = 2048 }, .stop = &stops, .max_completion_tokens = 8192 } },
            .anthropic => .{ .anthropic = .{ .thinking = .{ .type = &thinking_type, .budget_tokens = 2048 }, .stop = &stops, .max_tokens = 8192 } },
            .ollama => .{ .ollama = .{ .stop = &stops, .max_tokens = 8192 } },
            .response => .{ .response = .{ .max_output_tokens = 8192 } },
        };
        const copied = try params.clone(arena.allocator());
        @memset(&thinking_type, 'x');
        @memset(&stop_text, 'x');
        stops[0] = "changed";
        var opts: sdk.GenerateOptions = .{};
        applyParams(copied, null, false, &opts);
        if (kind != .response) try std.testing.expectEqualStrings("stop", opts.stop_sequences[0]);
        if (kind == .openai or kind == .anthropic) {
            try std.testing.expectEqualStrings("enabled", opts.thinking.?.type);
            try std.testing.expectEqual(@as(?u32, 2048), opts.thinking.?.budget_tokens);
        }
        if (kind == .openai) {
            try std.testing.expectEqual(@as(?u32, 8192), opts.max_completion_tokens);
        } else {
            try std.testing.expectEqual(@as(u32, 8192), opts.max_output_tokens);
        }
    }
}

test "reasoning models preserve every configured effort" {
    for ([_]ModelParams{ .{ .openai = .{} }, .{ .response = .{} } }) |params| {
        inline for (std.meta.fields(ReasoningEffort)) |field| {
            var opts: sdk.GenerateOptions = .{};
            applyParams(params, @field(ReasoningEffort, field.name), true, &opts);
            try std.testing.expectEqualStrings(field.name, opts.reasoning_effort);
        }
        var opts: sdk.GenerateOptions = .{};
        applyParams(params, .max, false, &opts);
        try std.testing.expectEqualStrings("", opts.reasoning_effort);
        applyParams(params, null, true, &opts);
        try std.testing.expectEqualStrings("", opts.reasoning_effort);
    }
}
