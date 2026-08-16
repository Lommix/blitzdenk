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

pub const ProviderOptions = union(Kind) {
    ollama: OllamaOptions,
    openai: OpenAIOptions,
    response: ResponseOptions,
    anthropic: AnthropicOptions,
};

pub const Config = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    reasoning_effort: ?ReasoningEffort = null,
    provider: ProviderOptions,
};

pub const Model = union(Kind) {
    ollama: sdk.compat.Chat,
    openai: sdk.openai.Chat,
    response: sdk.responses.Chat,
    anthropic: sdk.anthropic.Chat,

    pub fn init(alloc: std.mem.Allocator, config: Config) !Model {
        return switch (config.provider) {
            .ollama => .{ .ollama = try sdk.compat.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
            }) },
            .openai => .{ .openai = try sdk.openai.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
            }) },
            .response => .{ .response = try sdk.responses.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
            }) },
            .anthropic => .{ .anthropic = try sdk.anthropic.Chat.init(alloc, config.model, .{
                .api_key = config.api_key,
                .base_url = config.base_url,
            }) },
        };
    }

    pub fn deinit(self: *Model, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*chat| chat.deinit(alloc),
        }
    }

    pub fn clone(self: *const Model, alloc: std.mem.Allocator) !Model {
        return switch (self.*) {
            .ollama => |chat| .{ .ollama = try sdk.compat.Chat.init(alloc, chat.model_id, .{
                .api_key = chat.api_key,
                .base_url = chat.base_url,
                .headers = chat.extra_headers,
            }) },
            .openai => |chat| .{ .openai = try sdk.openai.Chat.init(alloc, chat.model_id, .{
                .api_key = chat.api_key,
                .base_url = chat.base_url,
                .headers = chat.extra_headers,
            }) },
            .response => |chat| .{ .response = try sdk.responses.Chat.init(alloc, chat.model_id, .{
                .api_key = chat.api_key,
                .base_url = chat.base_url,
                .headers = chat.extra_headers,
            }) },
            .anthropic => |chat| .{ .anthropic = try sdk.anthropic.Chat.init(alloc, chat.model_id, .{
                .api_key = chat.api_key,
                .base_url = chat.base_url,
                .headers = chat.extra_headers,
            }) },
        };
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
        .provider = .{ .openai = .{} },
    });
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("model", model.languageModel().modelId());
    var cloned = try model.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("model", cloned.languageModel().modelId());
}
