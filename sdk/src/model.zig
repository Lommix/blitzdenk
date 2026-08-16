const std = @import("std");
const types = @import("types.zig");
const options = @import("options.zig");

pub const GenerateParams = struct {
    messages: []const types.Message = &.{},
    system: []const u8 = "",
    tools: []const types.Tool = &.{},
    max_output_tokens: u32 = 0,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?u32 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    seed: ?i64 = null,
    stop_sequences: []const []const u8 = &.{},
    headers: []const std.http.Header = &.{},
    provider_options: ?std.json.Value = null,
    prompt_caching: bool = false,
    cache_ttl: ?[]const u8 = null,
    tool_choice: options.ToolChoice = .auto,
    response_format: ?types.ResponseFormat = null,
    timeout_ms: ?u64 = null,
};

pub const GenerateResult = struct {
    text: []const u8 = "",
    reasoning: []const u8 = "",
    tool_calls: []const types.ToolCall = &.{},
    finish_reason: types.FinishReason = .other,
    usage: types.Usage = .{},
    response: types.ResponseMetadata = .{},
    provider_metadata: ?std.json.Value = null,

    pub fn deinit(self: *GenerateResult, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.reasoning);
        for (self.tool_calls) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.input);
        }
        alloc.free(self.tool_calls);
        alloc.free(self.response.id);
        alloc.free(self.response.model);
        self.* = .{};
    }
};

pub const EmbedParams = struct {
    values: []const []const u8 = &.{},
    provider_options: ?std.json.Value = null,
    headers: []const std.http.Header = &.{},
    timeout_ms: ?u64 = null,
};

pub const ImageParams = struct {
    prompt: []const u8 = "",
    n: u32 = 1,
    size: []const u8 = "",
    aspect_ratio: []const u8 = "",
    provider_options: ?std.json.Value = null,
    headers: []const std.http.Header = &.{},
    timeout_ms: ?u64 = null,
};

pub const StreamContext = struct {
    emit: *const fn (ctx: ?*anyopaque, chunk: types.StreamChunk) void,
    emit_ctx: ?*anyopaque = null,

    pub fn send(self: *StreamContext, chunk: types.StreamChunk) void {
        self.emit(self.emit_ctx, chunk);
    }
};

pub const ModelVTable = struct {
    model_id: *const fn (ctx: *anyopaque) []const u8,
    generate: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*GenerateResult,
    stream: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
        sctx: *StreamContext,
    ) anyerror!*GenerateResult,
    embed: ?*const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: EmbedParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.EmbedResult = null,
    image: ?*const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: ImageParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.ImageResult = null,
};

pub const LanguageModel = struct {
    ctx: *anyopaque,
    vtable: *const ModelVTable,

    pub fn modelId(self: LanguageModel) []const u8 {
        return self.vtable.model_id(self.ctx);
    }

    pub fn generate(
        self: LanguageModel,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*GenerateResult {
        return self.vtable.generate(self.ctx, alloc, io, params, client, max_retries);
    }

    pub fn stream(
        self: LanguageModel,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
        sctx: *StreamContext,
    ) anyerror!*GenerateResult {
        return self.vtable.stream(self.ctx, alloc, io, params, client, max_retries, sctx);
    }

    pub fn embed(
        self: LanguageModel,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: EmbedParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.EmbedResult {
        const f = self.vtable.embed orelse return error.EmbeddingUnsupported;
        return f(self.ctx, alloc, io, params, client, max_retries);
    }

    pub fn image(
        self: LanguageModel,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: ImageParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.ImageResult {
        const f = self.vtable.image orelse return error.ImageUnsupported;
        return f(self.ctx, alloc, io, params, client, max_retries);
    }
};

pub const EmbeddingModel = LanguageModel;
pub const ImageModel = LanguageModel;

test "fake vtable callable" {
    const Fixture = struct {
        var calls: usize = 0;

        fn modelId(_: *anyopaque) []const u8 {
            return "fake-model";
        }

        fn generate(
            _: *anyopaque,
            alloc: std.mem.Allocator,
            _: std.Io,
            _: GenerateParams,
            _: ?*std.http.Client,
            _: u32,
        ) anyerror!*GenerateResult {
            calls += 1;
            const result = try alloc.create(GenerateResult);
            result.* = .{ .text = "hello", .finish_reason = .stop };
            return result;
        }

        fn stream(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: std.Io,
            _: GenerateParams,
            _: ?*std.http.Client,
            _: u32,
            _: *StreamContext,
        ) anyerror!*GenerateResult {
            return error.Unimplemented;
        }
    };

    var fixture: u8 = 0;
    const vtable = ModelVTable{
        .model_id = Fixture.modelId,
        .generate = Fixture.generate,
        .stream = Fixture.stream,
    };
    const lm = LanguageModel{ .ctx = &fixture, .vtable = &vtable };

    try std.testing.expectEqualStrings("fake-model", lm.modelId());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try lm.generate(arena.allocator(), undefined, .{}, null, 0);
    try std.testing.expectEqualStrings("hello", result.text);
    try std.testing.expectEqual(@as(usize, 1), Fixture.calls);
}
