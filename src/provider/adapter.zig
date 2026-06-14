/// General purpose AI chat abstraction with tool calls.
/// Designed as a common intermediate representation castable to
/// OpenAI, Anthropic (Claude), and Google (Gemini) API specs.
const std = @import("std");
const http = @import("http.zig");
const openai = @import("openai.zig");
const anthropic = @import("anthropic.zig");
const Allocator = std.mem.Allocator;

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,
};

pub const TokenUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,

    pub fn add(self: *TokenUsage, other: TokenUsage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cached_tokens += other.cached_tokens;
        self.cache_creation_tokens += other.cache_creation_tokens;
    }
};

pub const Reasoning = struct {
    effort: []const u8, // "low", "medium", "high"
};

pub const Thinking = struct {
    type: []const u8, // "enabled", "disabled", "adaptive"
    budget_tokens: ?u32 = null, // required when type="enabled", min 1024
};

pub const Provider = enum { ollama, openai, anthropic };

pub const OllamaConfig = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop: ?[]const []const u8 = null,
};

pub const Model = struct {
    name: []const u8,
    //additional info?
};

pub fn getModels(cfg: *const Config, allocator: std.mem.Allocator, pool: *http.RequestPool, io: std.Io) ![]Model {
    const ModelEntry = struct {
        id: []const u8,
    };

    const ModelResponse = struct {
        data: ?[]const ModelEntry = null,
    };

    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{cfg.base_url});
    defer allocator.free(url);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.api_key});
    defer allocator.free(auth_value);

    const handle = try pool.fetch(url, .GET, null, &.{
        .{ .name = "Authorization", .value = auth_value },
    }, 10_000);
    defer pool.release(handle);

    while (!pool.isDone(handle)) {
        try io.sleep(.fromMilliseconds(50), .awake);
    }

    const body = try pool.collectBody(handle, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(ModelResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const entries = parsed.value.data orelse return &.{};
    const models = try allocator.alloc(Model, entries.len);
    for (entries, 0..) |entry, i| {
        models[i] = .{ .name = try allocator.dupe(u8, entry.id) };
    }

    return models;
}

pub const OpenAiConfig = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    reasoning: ?Reasoning = null,
    enable_thinking: ?bool = null, // novita extension; false silences kimi/minimax
    top_p: ?f32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,
};

pub const AnthropicConfig = struct {
    max_tokens: u32 = 8192 * 2,
    thinking: ?Thinking = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop: ?[]const []const u8 = null,
};

pub const ProviderConfig = union(Provider) {
    ollama: OllamaConfig,
    openai: OpenAiConfig,
    anthropic: AnthropicConfig,
};

pub const Config = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    provider: ProviderConfig,
};

pub const ImageContent = struct {
    media_type: []const u8,
    data: []const u8,
};

pub const ThinkingPart = struct {
    text: []const u8,
    signature: ?[]const u8 = null,
};

pub const ContentPart = union(enum) {
    text: []const u8,
    thinking: ThinkingPart,
    image: ImageContent,
    tool_call: ToolCall,
    tool_result: ToolResult,

    pub fn clone(self: *const ContentPart, gpa: std.mem.Allocator) !ContentPart {
        switch (self.*) {
            .text => |txt| return .{ .text = try gpa.dupe(u8, txt) },
            .thinking => |th| {
                return .{ .thinking = ThinkingPart{
                    .text = try gpa.dupe(u8, th.text),
                    .signature = if (th.signature) |s| try gpa.dupe(u8, s) else null,
                } };
            },
            .image => |img| {
                return .{ .image = ImageContent{
                    .data = try gpa.dupe(u8, img.data),
                    .media_type = try gpa.dupe(u8, img.media_type),
                } };
            },
            .tool_call => |call| {
                return .{ .tool_call = ToolCall{
                    .arguments = try gpa.dupe(u8, call.arguments),
                    .id = try gpa.dupe(u8, call.id),
                    .name = try gpa.dupe(u8, call.name),
                } };
            },
            .tool_result => |res| {
                return .{ .tool_result = ToolResult{
                    .call_id = try gpa.dupe(u8, res.call_id),
                    .content = try gpa.dupe(u8, res.content),
                    .is_error = res.is_error,
                    .name = try gpa.dupe(u8, res.name),
                } };
            },
        }
    }
};

pub const Role = enum { system, user, agent };

pub const Message = struct {
    role: Role,
    parts: []ContentPart,

    pub fn fmt(self: @This(), w: *std.Io.Writer) !void {
        for (self.parts) |part| {
            switch (part) {
                .text => |txt| {
                    try w.print("[TEXT] {s}: {s}\n", .{ @tagName(self.role), txt });
                },
                .thinking => |th| {
                    try w.print("[THINK] {s}\n", .{th.text[0..@min(60, th.text.len)]});
                },
                .image => |img| {
                    try w.print("[IMG] {s} ({d} bytes)\n", .{ img.media_type, img.data.len });
                },
                .tool_call => |call| {
                    try w.print("[CALL] {s} with `{s}`\n", .{ call.name, call.arguments[0..@min(30, call.arguments.len)] });
                },
                .tool_result => |res| {
                    try w.print("[RES] {s}\n", .{res.content[0..@min(40, res.content.len)]});
                },
            }
        }
    }

    pub fn clone(self: *const Message, gpa: std.mem.Allocator) !Message {
        var msg: Message = undefined;

        msg.role = self.role;
        var parts = try gpa.alloc(ContentPart, self.parts.len);

        for (0..self.parts.len) |i| {
            parts[i] = try self.parts[i].clone(gpa);
        }

        msg.parts = parts;

        return msg;
    }
};

pub const ResponseResult = struct {
    message: Message,
    usage: ?TokenUsage = null,
};

pub const CompletionMode = enum {
    streaming,
    blocking,
};

pub const CompletionOptions = struct {
    mode: CompletionMode = .streaming,
    session_id: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

pub const Delta = union(enum) {
    text_chunk: []const u8,
    thinking_chunk: []const u8,
    tool_call_start: ToolCall,
    tool_input_delta: struct { call_id: []const u8, json_fragment: []const u8 },
    usage: TokenUsage,
    finish,
};

pub const Stream = struct {
    pool: *http.RequestPool,
    handle: http.RequestPool.RequestHandle,
    arena: Allocator,
    impl: Impl,

    pub const Impl = union(Provider) {
        ollama: openai.StreamState,
        openai: openai.StreamState,
        anthropic: anthropic.StreamState,
    };

    pub fn next(self: *Stream) !?Delta {
        return switch (self.impl) {
            .ollama => |*s| s.next(self.pool, self.handle, self.arena, .ollama),
            .openai => |*s| s.next(self.pool, self.handle, self.arena, .openai),
            .anthropic => |*s| s.next(self.pool, self.handle, self.arena),
        };
    }

    pub fn finalize(self: *Stream) !ResponseResult {
        return switch (self.impl) {
            .ollama, .openai => |*s| s.finalize(self.arena),
            .anthropic => |*s| s.finalize(self.arena),
        };
    }
};

pub fn openStream(
    pool: *http.RequestPool,
    handle: http.RequestPool.RequestHandle,
    arena: Allocator,
    provider: Provider,
) Stream {
    return .{
        .pool = pool,
        .handle = handle,
        .arena = arena,
        .impl = switch (provider) {
            .ollama => .{ .ollama = openai.StreamState.init(arena) },
            .openai => .{ .openai = openai.StreamState.init(arena) },
            .anthropic => .{ .anthropic = anthropic.StreamState.init(arena) },
        },
    };
}

pub const Chat = struct {
    // deep copy required
    messages: std.ArrayList(Message) = .empty,
    // shallow copy allowed
    tools: std.ArrayList(ToolDef) = .empty,

    pub fn reset(self: *Chat) void {
        self.messages = .empty;
        self.tools = .empty;
    }

    pub fn clone(self: *const Chat, gpa: std.mem.Allocator) !Chat {
        var chat: Chat = .{
            .tools = try self.tools.clone(gpa),
        };

        for (self.messages.items) |*msg| {
            try chat.messages.append(gpa, try msg.clone(gpa));
        }

        return chat;
    }

    pub fn addMessage(self: *Chat, alloc: Allocator, role: Role, parts: []const ContentPart) !void {
        const duped = try alloc.alloc(ContentPart, parts.len);
        @memcpy(duped, parts);
        try self.messages.append(alloc, .{
            .role = role,
            .parts = duped,
        });
    }

    pub fn addToolCalls(self: *Chat, alloc: Allocator, calls: []const ToolCall) !void {
        const parts = try alloc.alloc(ContentPart, calls.len);
        for (calls, 0..) |call, i| {
            parts[i] = .{ .tool_call = call };
        }
        try self.messages.append(alloc, .{
            .role = .agent,
            .parts = parts,
        });
    }

    pub fn addToolResults(
        self: *Chat,
        alloc: Allocator,
        results: []const ToolResult,
        inject_user_note: ?[]const u8,
    ) !void {
        const len: u32 = @as(u32, @intCast(results.len)) + if (inject_user_note == null) @as(u32, 0) else @as(u32, 1);
        const parts = try alloc.alloc(ContentPart, len);

        for (results, 0..) |result, i| {
            parts[i] = .{ .tool_result = .{
                .call_id = try alloc.dupe(u8, result.call_id),
                .name = try alloc.dupe(u8, result.name),
                .content = try alloc.dupe(u8, result.content),
                .is_error = result.is_error,
            } };
        }

        if (inject_user_note) |note| {
            parts[len - 1] = .{ .text = note };
        }

        try self.messages.append(alloc, .{
            .role = .user,
            .parts = parts,
        });
    }

    pub fn addTool(self: *Chat, alloc: Allocator, tool: ToolDef) !void {
        try self.tools.append(alloc, tool);
    }

    pub fn setSystemPrompt(self: *Chat, alloc: Allocator, prompt: []const u8) !void {
        const parts = try alloc.alloc(ContentPart, 1);
        parts[0] = .{ .text = prompt };
        for (self.messages.items) |*msg| {
            if (msg.role == .system) {
                msg.parts = parts;
                return;
            }
        }
        try self.addMessage(alloc, .system, parts);
    }

    pub fn lastMessage(self: *const Chat) ?Message {
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
    }

    pub fn countUserMessage(self: *const Chat) u32 {
        var c: u32 = 0;
        blk: for (self.messages.items) |*msg| {
            if (msg.role != .user) continue;
            for (msg.parts) |p| {
                if (p == .text) {
                    c += 1;
                    continue :blk;
                }
            }
        }
        return c;
    }

    /// Append an empty message to hold a streaming response. Returns the
    /// index for subsequent append* calls. Parts start as an empty slice
    /// and grow via appendTextChunk / appendThinkingChunk.
    pub fn beginStreamingMessage(self: *Chat, alloc: Allocator, role: Role) !usize {
        try self.messages.append(alloc, .{ .role = role, .parts = &.{} });
        return self.messages.items.len - 1;
    }

    pub fn appendTextChunk(self: *Chat, alloc: Allocator, idx: usize, s: []const u8) !void {
        try self.appendChunk(alloc, idx, s, false);
    }

    pub fn appendThinkingChunk(self: *Chat, alloc: Allocator, idx: usize, s: []const u8) !void {
        try self.appendChunk(alloc, idx, s, true);
    }

    fn appendChunk(self: *Chat, alloc: Allocator, idx: usize, s: []const u8, is_thinking: bool) !void {
        if (s.len == 0) return;
        const msg = &self.messages.items[idx];
        // Coalesce into the last part if same kind.
        if (msg.parts.len > 0) {
            const last = &@constCast(msg.parts)[msg.parts.len - 1];
            switch (last.*) {
                .text => |existing| if (!is_thinking) {
                    const merged = try alloc.alloc(u8, existing.len + s.len);
                    @memcpy(merged[0..existing.len], existing);
                    @memcpy(merged[existing.len..], s);

                    alloc.free(existing);

                    last.* = .{ .text = merged };
                    return;
                },
                .thinking => |existing| if (is_thinking) {
                    const merged = try alloc.alloc(u8, existing.text.len + s.len);
                    @memcpy(merged[0..existing.text.len], existing.text);
                    @memcpy(merged[existing.text.len..], s);

                    alloc.free(existing.text);

                    last.* = .{ .thinking = .{ .text = merged, .signature = existing.signature } };
                    return;
                },
                else => {},
            }
        }
        // New part — grow the parts slice by one.
        const new_parts = try alloc.alloc(ContentPart, msg.parts.len + 1);
        @memcpy(new_parts[0..msg.parts.len], msg.parts);
        new_parts[msg.parts.len] = if (is_thinking)
            .{ .thinking = .{ .text = try alloc.dupe(u8, s) } }
        else
            .{ .text = try alloc.dupe(u8, s) };
        msg.parts = new_parts;
    }

    /// Replace the streaming message's parts with the canonical finalized slice
    /// from the provider aggregator (captures tool_call arguments and any
    /// parts that were only partially visible during streaming).
    pub fn finalizeStreamingMessage(
        self: *Chat,
        alloc: Allocator,
        idx: usize,
        parts: []const ContentPart,
    ) !void {
        const duped = try alloc.alloc(ContentPart, parts.len);
        @memcpy(duped, parts);
        self.messages.items[idx].parts = duped;
    }
};

pub fn complete(
    pool: *http.RequestPool,
    scratch: Allocator,
    chat: *const Chat,
    cfg: Config,
    options: CompletionOptions,
) !http.RequestPool.RequestHandle {
    return switch (cfg.provider) {
        .openai, .ollama => openai.complete(pool, scratch, chat, cfg, options),
        .anthropic => anthropic.complete(pool, scratch, chat, cfg, options),
    };
}

pub fn parseCompletion(
    arena: Allocator,
    cfg: Config,
    body: []const u8,
) !ResponseResult {
    return switch (cfg.provider) {
        .openai, .ollama => openai.parseResponse(arena, body),
        .anthropic => anthropic.parseResponse(arena, body),
    };
}
