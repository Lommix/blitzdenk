const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");
const http = @import("http.zig");
const log = std.log.scoped(.openai_stream);

pub const Config = adapter.Config;

// -- OpenAI request types --

const OaiToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

const OaiToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: OaiToolCallFunction,
};

const OaiMessage = struct {
    role: []const u8,
    content: ?std.json.Value = null,
    tool_calls: ?[]const OaiToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning_details: ?std.json.Value = null,
};

const OaiFunctionDef = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

const OaiToolDef = struct {
    type: []const u8 = "function",
    function: OaiFunctionDef,
};

const OaiStreamOptions = struct {
    include_usage: bool = true,
};

const OaiRequest = struct {
    model: []const u8,
    messages: []const OaiMessage,
    stream: bool,
    stream_options: ?OaiStreamOptions = null,
    tools: ?[]const OaiToolDef = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    enable_thinking: ?bool = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,
};

// -- OpenAI response types --

const OaiResponseToolCallFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const OaiResponseToolCall = struct {
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?OaiResponseToolCallFunction = null,
};

const OaiResponseMessage = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_calls: ?[]const OaiResponseToolCall = null,
    reasoning_content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    reasoning_details: ?std.json.Value = null,
};

const OaiChoice = struct {
    message: ?OaiResponseMessage = null,
    finish_reason: ?[]const u8 = null,
};

const OaiPromptTokensDetails = struct {
    cached_tokens: ?u64 = null,
};

const OaiUsage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    prompt_tokens_details: ?OaiPromptTokensDetails = null,
};

const OaiResponse = struct {
    choices: ?[]const OaiChoice = null,
    usage: ?OaiUsage = null,
};

fn roleToString(role: adapter.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .agent => "assistant",
    };
}

pub fn serializeRequest(allocator: Allocator, chat: *const adapter.Chat, config: Config, mode: adapter.CompletionMode) ![]u8 {
    var messages: std.ArrayList(OaiMessage) = .empty;
    var reasoning_parsed: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    const is_deepseek = std.ascii.indexOfIgnoreCase(config.model, "deepseek") != null;
    defer {
        for (messages.items) |m| {
            if (m.content) |c| {
                switch (c) {
                    .string => |s| {
                        if (s.len > 0) allocator.free(s);
                    },
                    else => {},
                }
            }
            if (m.reasoning_content) |reasoning| allocator.free(reasoning);
            if (m.tool_calls) |tcs| allocator.free(tcs);
        }
        messages.deinit(allocator);
        for (reasoning_parsed.items) |p| p.deinit();
        reasoning_parsed.deinit(allocator);
    }

    // Pre-pass: collect call_ids of any tool_call whose arguments don't parse
    // as a JSON object. These are the residue of past truncation events; both
    // the call and its matching tool_result must be skipped to keep the
    // transcript provider-acceptable.
    var skipped_ids: std.StringHashMapUnmanaged(void) = .{};
    defer skipped_ids.deinit(allocator);
    for (chat.messages.items) |msg| {
        for (msg.parts) |part| {
            switch (part) {
                .tool_call => |tc| {
                    var scratch = std.heap.ArenaAllocator.init(allocator);
                    defer scratch.deinit();
                    if (!isValidJsonObject(scratch.allocator(), tc.arguments)) {
                        try skipped_ids.put(allocator, tc.id, {});
                    }
                },
                else => {},
            }
        }
    }

    for (chat.messages.items) |msg| {
        for (msg.parts) |part| {
            switch (part) {
                .tool_result => |tr| {
                    if (skipped_ids.contains(tr.call_id)) continue;
                    try messages.append(allocator, .{
                        .role = "tool",
                        .content = .{ .string = try allocator.dupe(u8, tr.content) },
                        .tool_call_id = tr.call_id,
                    });
                },
                else => {},
            }
        }

        var tool_call_list: std.ArrayList(OaiToolCall) = .empty;
        defer tool_call_list.deinit(allocator);

        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);

        var reasoning_buf: std.ArrayList(u8) = .empty;
        defer reasoning_buf.deinit(allocator);

        var has_images = false;
        var content_parts: std.ArrayList(std.json.Value) = .empty;
        defer content_parts.deinit(allocator);

        var reasoning_details: ?std.json.Value = null;
        for (msg.parts) |part| {
            switch (part) {
                .text => |t| try text_buf.appendSlice(allocator, t),
                .image => has_images = true,
                .tool_call => |tc| {
                    if (skipped_ids.contains(tc.id)) continue;
                    try tool_call_list.append(allocator, .{
                        .id = tc.id,
                        .function = .{
                            .name = tc.name,
                            .arguments = tc.arguments,
                        },
                    });
                },
                .thinking => |th| {
                    if (msg.role != .agent) continue;
                    if (is_deepseek) try reasoning_buf.appendSlice(allocator, th.text);
                    if (reasoning_details == null) {
                        if (th.signature) |sig| {
                            const parsed = std.json.parseFromSlice(
                                std.json.Value,
                                allocator,
                                sig,
                                .{ .allocate = .alloc_always },
                            ) catch continue;
                            try reasoning_parsed.append(allocator, parsed);
                            reasoning_details = parsed.value;
                        }
                    }
                },
                .tool_result => {},
            }
        }

        var content: ?std.json.Value = null;

        if (has_images) {
            // Build array-of-objects content for vision API
            if (text_buf.items.len > 0) {
                var text_obj = std.json.ObjectMap.empty;
                try text_obj.put(allocator, "type", .{ .string = "text" });
                try text_obj.put(allocator, "text", .{ .string = try allocator.dupe(u8, text_buf.items) });
                try content_parts.append(allocator, .{ .object = text_obj });
            }
            for (msg.parts) |part| {
                switch (part) {
                    .image => |img| {
                        // Build data URI: "data:{media_type};base64,{data}"
                        const data_uri = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ img.media_type, img.data });

                        var url_obj = std.json.ObjectMap.empty;
                        try url_obj.put(allocator, "url", .{ .string = data_uri });

                        var img_obj = std.json.ObjectMap.empty;
                        try img_obj.put(allocator, "type", .{ .string = "image_url" });
                        try img_obj.put(allocator, "image_url", .{ .object = url_obj });

                        try content_parts.append(allocator, .{ .object = img_obj });
                    },
                    else => {},
                }
            }
            const items = try allocator.dupe(std.json.Value, content_parts.items);
            content = .{ .array = std.json.Array.fromOwnedSlice(allocator, items) };
        } else if (text_buf.items.len > 0) {
            content = .{ .string = try allocator.dupe(u8, text_buf.items) };
        }

        const tool_calls = if (tool_call_list.items.len > 0)
            try allocator.dupe(OaiToolCall, tool_call_list.items)
        else
            null;

        // Skip the follow-up message if this adapter message contained only
        // tool_results — those were already emitted above as "tool" messages.
        if (content == null and tool_calls == null) continue;

        // DeepSeek requires reasoning_content on assistant messages when tools
        // are present so it can continue the same reasoning chain after tool
        // results. For older messages without captured thinking, preserve the
        // field as an empty string rather than omitting it.
        const reasoning_content: ?[]const u8 = if (is_deepseek and msg.role == .agent)
            try allocator.dupe(u8, reasoning_buf.items)
        else
            null;

        try messages.append(allocator, .{
            .role = roleToString(msg.role),
            .content = content,
            .tool_calls = tool_calls,
            .reasoning_content = reasoning_content,
            .reasoning_details = reasoning_details,
        });
    }

    // Serialize tool definitions
    var tool_defs: ?[]const OaiToolDef = null;
    var tool_defs_buf: std.ArrayList(OaiToolDef) = .empty;
    defer tool_defs_buf.deinit(allocator);

    var parsed_schemas: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (parsed_schemas.items) |p| p.deinit();
        parsed_schemas.deinit(allocator);
    }

    if (chat.tools.items.len > 0) {
        for (chat.tools.items) |tool| {
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                tool.parameters_schema,
                .{ .allocate = .alloc_always },
            );
            try parsed_schemas.append(allocator, parsed);

            try tool_defs_buf.append(allocator, .{
                .function = .{
                    .name = tool.name,
                    .description = tool.description,
                    .parameters = parsed.value,
                },
            });
        }
        tool_defs = tool_defs_buf.items;
    }

    const req: OaiRequest = switch (config.provider) {
        .openai => |oc| .{
            .model = config.model,
            .messages = messages.items,
            .stream = mode == .streaming,
            .stream_options = if (mode == .streaming) .{} else null,
            .tools = tool_defs,
            .temperature = oc.temperature,
            .max_tokens = oc.max_tokens,
            .max_completion_tokens = oc.max_completion_tokens,
            .reasoning_effort = if (config.reasoning_effort) |e| @tagName(e) else null,
            .enable_thinking = oc.enable_thinking,
            .top_p = oc.top_p,
            .top_k = oc.top_k,
            .frequency_penalty = oc.frequency_penalty,
            .presence_penalty = oc.presence_penalty,
            .stop = oc.stop,
        },
        .ollama => |oc| .{
            .model = config.model,
            .messages = messages.items,
            .stream = mode == .streaming,
            .stream_options = if (mode == .streaming) .{} else null,
            .tools = tool_defs,
            .temperature = oc.temperature,
            .max_tokens = oc.max_tokens,
            .reasoning_effort = if (config.reasoning_effort) |e| @tagName(e) else null,
            .top_p = oc.top_p,
            .top_k = oc.top_k,
            .stop = oc.stop,
        },
        .response, .anthropic => return error.NotImplemented,
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    try std.json.Stringify.value(req, .{ .emit_null_optional_fields = false }, &buf.writer);
    return try buf.toOwnedSlice();
}

pub fn complete(
    pool: *http.RequestPool,
    scratch: Allocator,
    chat: *const adapter.Chat,
    config: Config,
    options: adapter.CompletionOptions,
) !http.RequestPool.RequestHandle {
    const payload = try serializeRequest(scratch, chat, config, options.mode);
    defer scratch.free(payload);

    const url = try std.fmt.allocPrint(scratch, "{s}/chat/completions", .{config.base_url});
    defer scratch.free(url);

    const auth_value = try std.fmt.allocPrint(scratch, "Bearer {s}", .{config.api_key});
    defer scratch.free(auth_value);

    if (options.session_id) |sid| {
        return pool.fetch(url, .POST, payload, &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "x-session-affinity", .value = sid },
        }, options.timeout_ms);
    }
    return pool.fetch(url, .POST, payload, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_value },
    }, options.timeout_ms);
}

pub fn parseResponse(arena: Allocator, body: []const u8) !adapter.ResponseResult {
    const parsed = try std.json.parseFromSlice(OaiResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var parts: std.ArrayList(adapter.ContentPart) = .empty;
    var usage: ?adapter.TokenUsage = null;

    if (parsed.value.choices) |choices| {
        if (choices.len > 0) {
            const msg = choices[0].message orelse return error.EmptyResponse;

            if (msg.reasoning_content orelse msg.reasoning) |thinking| {
                if (thinking.len > 0) {
                    var signature: ?[]const u8 = null;
                    if (msg.reasoning_details) |rd| {
                        var buf: std.Io.Writer.Allocating = .init(arena);
                        try std.json.Stringify.value(rd, .{}, &buf.writer);
                        signature = try buf.toOwnedSlice();
                    }
                    try parts.append(arena, .{ .thinking = .{
                        .text = try arena.dupe(u8, thinking),
                        .signature = signature,
                    } });
                }
            }

            if (msg.content) |content| {
                try parts.append(arena, .{ .text = try arena.dupe(u8, content) });
            }

            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    const func = call.function orelse continue;
                    const args = func.arguments orelse "{}";
                    if (!isValidJsonObject(arena, args)) continue;
                    try parts.append(arena, .{ .tool_call = .{
                        .id = try arena.dupe(u8, call.id orelse ""),
                        .name = try arena.dupe(u8, func.name orelse ""),
                        .arguments = try arena.dupe(u8, args),
                    } });
                }
            }
        }
    }

    if (parsed.value.usage) |u| {
        const prompt = u.prompt_tokens orelse 0;
        const cached = if (u.prompt_tokens_details) |d| (d.cached_tokens orelse 0) else 0;
        usage = .{
            .input_tokens = prompt -| cached,
            .output_tokens = u.completion_tokens orelse 0,
            .cached_tokens = cached,
        };
    }

    if (parts.items.len == 0) return error.EmptyResponse;
    return .{
        .message = .{ .role = .agent, .parts = try parts.toOwnedSlice(arena) },
        .usage = usage,
    };
}

// -- Streaming parser --
//
// OpenAI SSE: "data: {...}\n\n" lines, terminated by "data: [DONE]". Usage
// arrives in the final chunk (choices may be empty). Tool calls arrive as
// incremental deltas with an index; id+name appear once, arguments accrete.
//
// Ollama NDJSON: each line is a complete JSON object with message.content
// plus `done: true` on the last line. Shares tool_call/text accumulation.
//
// Both modes feed through an inline <think>...</think> splitter so local
// reasoning models surface thinking as a distinct part.

const OaiDeltaToolCall = struct {
    index: ?u32 = null,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    } = null,
};

const OaiDelta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    // DeepSeek/Qwen surface thinking text as `reasoning_content`;
    // OpenRouter uses `reasoning`. Treat both as thinking deltas.
    reasoning_content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    reasoning_details: ?std.json.Value = null,
    tool_calls: ?[]const OaiDeltaToolCall = null,
};

const OaiStreamChoice = struct {
    index: ?u32 = null,
    delta: ?OaiDelta = null,
    finish_reason: ?[]const u8 = null,
    message: ?OaiResponseMessage = null, // ollama
};

const OaiStreamChunk = struct {
    choices: ?[]const OaiStreamChoice = null,
    usage: ?OaiUsage = null,
    @"error": ?std.json.Value = null,
    // Ollama top-level fields:
    message: ?OaiResponseMessage = null,
    done: ?bool = null,
    prompt_eval_count: ?u64 = null,
    eval_count: ?u64 = null,
};

const ThinkMode = enum { outside, think, thinking, harmony };

const ToolAcc = struct {
    id: []u8 = &.{},
    name: []u8 = &.{},
    args: std.ArrayList(u8) = .empty,
    emitted: usize = 0,
    started: bool = false,
};

const PendingKind = enum { text, thinking };
const PendingDelta = struct { kind: PendingKind, data: []const u8 };
const OpenTag = struct {
    offset: usize,
    open: []const u8,
    mode: ThinkMode,
};

fn findOpenTag(s: []const u8, startup: bool) ?OpenTag {
    const tags = [_]struct { open: []const u8, mode: ThinkMode }{
        .{ .open = "<think>", .mode = .think },
        .{ .open = "<thinking>", .mode = .thinking },
    };
    var found: ?OpenTag = null;
    for (tags) |tag| {
        const offset = std.mem.indexOf(u8, s, tag.open) orelse continue;
        if (found == null or offset < found.?.offset) {
            found = .{ .offset = offset, .open = tag.open, .mode = tag.mode };
        }
    }
    if (startup and std.mem.startsWith(u8, s, " thinking")) {
        found = .{ .offset = 0, .open = " thinking", .mode = .harmony };
    }
    return found;
}

fn partialOpenSuffix(s: []const u8, startup: bool) usize {
    var keep = @max(
        StreamState.partialTagSuffix(s, "<think>"),
        StreamState.partialTagSuffix(s, "<thinking>"),
    );
    if (startup) keep = @max(keep, StreamState.partialTagSuffix(s, " thinking"));
    return keep;
}

fn closeTag(mode: ThinkMode) []const u8 {
    return switch (mode) {
        .outside => unreachable,
        .think => "</think>",
        .thinking => "</thinking>",
        .harmony => " response",
    };
}

pub const StreamState = struct {
    arena: Allocator,
    buf: std.ArrayList(u8) = .empty, // incoming byte buffer
    think_mode: ThinkMode = .outside,
    think_carry: std.ArrayList(u8) = .empty, // partial tag bytes held back
    think_carry_kind: PendingKind = .text,
    startup: bool = true, // only match the Harmony opener at stream start
    text_acc: std.ArrayList(u8) = .empty,
    thinking_acc: std.ArrayList(u8) = .empty,
    // novita: raw JSON of each reasoning_details segment, joined into an
    // array on finalize and stuffed in ThinkingPart.signature for replay.
    reasoning_details_acc: std.ArrayList([]const u8) = .empty,
    tools: std.ArrayList(ToolAcc) = .empty,
    pending_text_thinking: std.ArrayList(PendingDelta) = .empty,
    pending_cursor: usize = 0,
    pending_tool_deltas: std.ArrayList(adapter.Delta) = .empty,
    pending_tool_cursor: usize = 0,
    usage: ?adapter.TokenUsage = null,
    pending_usage: ?adapter.TokenUsage = null,
    term: TermState = .streaming,
    finish_reason: ?[]const u8 = null,

    pub const TermState = enum { streaming, pending_finish, done };

    pub fn init(arena: Allocator) StreamState {
        return .{ .arena = arena };
    }

    pub fn next(
        self: *StreamState,
        pool: *http.RequestPool,
        handle: http.RequestPool.RequestHandle,
        arena: Allocator,
        provider: adapter.Provider,
    ) !?adapter.Delta {
        while (true) {
            if (self.pending_cursor < self.pending_text_thinking.items.len) {
                const d = self.pending_text_thinking.items[self.pending_cursor];
                self.pending_cursor += 1;
                if (self.pending_cursor == self.pending_text_thinking.items.len) {
                    self.pending_text_thinking.clearRetainingCapacity();
                    self.pending_cursor = 0;
                }
                return switch (d.kind) {
                    .text => .{ .text_chunk = d.data },
                    .thinking => .{ .thinking_chunk = d.data },
                };
            }
            if (self.pending_tool_cursor < self.pending_tool_deltas.items.len) {
                const d = self.pending_tool_deltas.items[self.pending_tool_cursor];
                self.pending_tool_cursor += 1;
                if (self.pending_tool_cursor == self.pending_tool_deltas.items.len) {
                    self.pending_tool_deltas.clearRetainingCapacity();
                    self.pending_tool_cursor = 0;
                }
                return d;
            }
            if (self.pending_usage) |u| {
                self.pending_usage = null;
                return .{ .usage = u };
            }
            if (self.term == .pending_finish) {
                self.term = .done;
                return .finish;
            }
            if (self.term == .done) return null;

            if (try self.drainLine(arena, provider)) |d| return d;

            const chunk = try pool.nextChunk(handle);
            if (chunk) |bytes| {
                defer pool.dropChunk(bytes);
                try self.buf.appendSlice(arena, bytes);
                continue;
            }
            if (pool.isStreamDone(handle)) {
                // Some providers omit the trailing newline on the final SSE
                // line. Flush leftover bytes through the normal parser so a
                // tail tool-call fragment isn't silently dropped at finalize.
                if (self.buf.items.len > 0) {
                    try self.buf.append(arena, '\n');
                    if (try self.drainLine(arena, provider)) |d| return d;
                }
                self.term = .pending_finish;
                continue;
            }
            return error.WouldBlock;
        }
    }

    fn drainLine(self: *StreamState, arena: Allocator, provider: adapter.Provider) !?adapter.Delta {
        while (true) {
            const buf = self.buf.items;
            const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
            // Copy the line into arena before consuming from self.buf — the
            // rest-shift below aliases-mutates the same memory that `line`
            // would otherwise point into, corrupting reads.
            const line_copy = try arena.dupe(u8, buf[0..nl]);
            const rest = buf[nl + 1 ..];
            std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
            self.buf.items.len = rest.len;

            const line = std.mem.trimEnd(u8, line_copy, "\r");
            if (line.len == 0) continue; // SSE blank separator

            const payload = blk: {
                if (provider == .ollama) break :blk line;
                // OpenAI SSE: "data: {...}" or "data: [DONE]"
                if (!std.mem.startsWith(u8, line, "data:")) continue;
                const v = if (line.len > 5 and line[5] == ' ') line[6..] else line[5..];
                break :blk v;
            };

            if (std.mem.eql(u8, payload, "[DONE]")) {
                self.term = .pending_finish;
                continue;
            }

            const parsed = std.json.parseFromSlice(OaiStreamChunk, arena, payload, .{ .ignore_unknown_fields = true }) catch |err| {
                const snippet = payload[0..@min(payload.len, 400)];
                log.debug("sse parse failed: {s} payload={s}", .{ @errorName(err), snippet });
                continue;
            };
            defer parsed.deinit();

            if (try self.applyChunk(arena, parsed.value)) |d| return d;
        }
    }

    fn applyChunk(self: *StreamState, arena: Allocator, chunk: OaiStreamChunk) !?adapter.Delta {
        if (chunk.@"error") |provider_error| {
            var buf: std.Io.Writer.Allocating = .init(arena);
            try std.json.Stringify.value(provider_error, .{}, &buf.writer);
            return .{ .provider_error = try buf.toOwnedSlice() };
        }

        // Ollama-style: top-level message + done flag.
        if (chunk.message) |m| {
            if (m.content) |c| {
                if (c.len > 0) {
                    try self.pushText(arena, c);
                }
            }
            if (m.tool_calls) |calls| {
                for (calls) |tc| try self.pushToolCall(arena, tc);
            }
        }

        if (chunk.choices) |choices| {
            if (choices.len > 0) {
                const ch = choices[0];
                if (ch.finish_reason) |fr| {
                    if (self.finish_reason == null) self.finish_reason = try arena.dupe(u8, fr);
                }
                if (ch.delta) |d| {
                    if (d.reasoning_details) |rd| {
                        try self.captureReasoningDetails(arena, rd);
                    }
                    if (d.reasoning_content orelse d.reasoning) |r| {
                        try self.pushTagged(arena, r, .thinking);
                    }
                    if (d.content) |c| {
                        if (c.len > 0) try self.pushText(arena, c);
                    }
                    if (d.tool_calls) |calls| {
                        for (calls) |tc| try self.pushDeltaToolCall(arena, tc);
                    }
                }
                if (ch.message) |m| {
                    if (m.content) |c| try self.pushText(arena, c);
                    if (m.tool_calls) |calls| {
                        for (calls) |rtc| try self.pushToolCall(arena, rtc);
                    }
                }
            }
        }

        if (chunk.usage) |u| {
            // OpenAI `prompt_tokens` includes cached tokens; normalize to
            // uncached-only so `input + cached + cache_creation` equals true
            // prompt size across providers (matches Anthropic semantics).
            const prompt = u.prompt_tokens orelse 0;
            const cached = if (u.prompt_tokens_details) |d| (d.cached_tokens orelse 0) else 0;
            self.usage = .{
                .input_tokens = prompt -| cached,
                .output_tokens = u.completion_tokens orelse 0,
                .cached_tokens = cached,
            };
            self.pending_usage = self.usage;
        } else if (chunk.done orelse false) {
            if (chunk.prompt_eval_count != null or chunk.eval_count != null) {
                self.usage = .{
                    .input_tokens = chunk.prompt_eval_count orelse 0,
                    .output_tokens = chunk.eval_count orelse 0,
                    .cached_tokens = 0,
                };
                self.pending_usage = self.usage;
            }
            self.term = .pending_finish;
        }

        return null;
    }

    fn pushToolCall(self: *StreamState, arena: Allocator, tc: OaiResponseToolCall) !void {
        const func = tc.function orelse return;
        const id = try arena.dupe(u8, tc.id orelse "");
        const name = try arena.dupe(u8, func.name orelse "");
        const args = func.arguments orelse "";
        // A compat stream's final chunk sometimes repeats a call that was
        // already accumulated incrementally via delta.tool_calls. Reuse that
        // slot (the complete object's arguments win) instead of registering a
        // duplicate that would execute the tool twice.
        if (id.len > 0) {
            for (self.tools.items) |*t| {
                if (t.started and std.mem.eql(u8, t.id, id)) {
                    if (t.name.len == 0 and name.len > 0) t.name = name;
                    t.args.clearRetainingCapacity();
                    if (args.len > 0) try t.args.appendSlice(arena, args);
                    return;
                }
            }
        }
        try self.tools.append(arena, .{
            .id = id,
            .name = name,
            .args = blk: {
                var a: std.ArrayList(u8) = .empty;
                if (args.len > 0) try a.appendSlice(arena, args);
                break :blk a;
            },
            .emitted = args.len,
            .started = true,
        });
        try self.pending_tool_deltas.append(arena, .{ .tool_call_start = .{
            .id = id,
            .name = name,
            .arguments = args,
        } });
    }

    fn pushDeltaToolCall(self: *StreamState, arena: Allocator, tc: OaiDeltaToolCall) !void {
        const idx = tc.index orelse if (self.tools.items.len > 0)
            @as(u32, @intCast(self.tools.items.len - 1))
        else
            0;
        while (self.tools.items.len <= idx) try self.tools.append(arena, .{});
        const slot = &self.tools.items[idx];

        // First-seen delta for this index: record id+name, emit start.
        var emit_start = false;
        if (!slot.started) {
            if (tc.id) |id| slot.id = try arena.dupe(u8, id);
            if (tc.function) |f| {
                if (f.name) |n| slot.name = try arena.dupe(u8, n);
            }
            if (slot.id.len > 0 or slot.name.len > 0) {
                slot.started = true;
                emit_start = true;
            }
        } else {
            if (tc.id) |id| {
                if (slot.id.len == 0) slot.id = try arena.dupe(u8, id);
            }
            if (tc.function) |f| {
                if (f.name) |n| {
                    if (slot.name.len == 0) slot.name = try arena.dupe(u8, n);
                }
            }
        }

        // Accumulate args fragment (if any) regardless of whether this delta
        // also carries id/name. The first-seen delta commonly includes the
        // opening `{` of arguments; dropping it produces malformed JSON.
        if (tc.function) |f| {
            if (f.arguments) |args| {
                if (args.len > 0) {
                    // Some providers resend the whole accumulated arguments
                    // object with each delta (or a retry repeats a fragment).
                    // When the new value starts with everything we already
                    // have, it supersedes the old one — appending would yield
                    // malformed JSON like `{"a":1}{"a":1,"b":2}` at finalize.
                    if (slot.args.items.len > 0 and std.mem.startsWith(u8, args, slot.args.items)) {
                        slot.args.clearRetainingCapacity();
                    }
                    try slot.args.appendSlice(arena, args);
                }
            }
        }

        if (emit_start) {
            try self.pending_tool_deltas.append(arena, .{ .tool_call_start = .{
                .id = slot.id,
                .name = slot.name,
                .arguments = slot.args.items,
            } });
            slot.emitted = slot.args.items.len;
            return;
        }

        if (tc.function) |f| {
            if (f.arguments) |args| {
                if (args.len > 0) {
                    try self.pending_tool_deltas.append(arena, .{ .tool_input_delta = .{
                        .call_id = slot.id,
                        .json_fragment = try arena.dupe(u8, slot.args.items[slot.emitted..]),
                    } });
                    slot.emitted = slot.args.items.len;
                    return;
                }
            }
        }
    }

    fn composeReasoningDetails(self: *StreamState, arena: Allocator) !?[]const u8 {
        if (self.reasoning_details_acc.items.len == 0) return null;
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(arena, '[');
        for (self.reasoning_details_acc.items, 0..) |seg, i| {
            if (i > 0) try buf.append(arena, ',');
            try buf.appendSlice(arena, seg);
        }
        try buf.append(arena, ']');
        return try buf.toOwnedSlice(arena);
    }

    fn captureReasoningDetails(self: *StreamState, arena: Allocator, rd: std.json.Value) !void {
        // Per-line parse arena gets freed after applyChunk; stringify into
        // stream arena so segments survive until finalize.
        switch (rd) {
            .array => |arr| {
                for (arr.items) |seg| {
                    var buf: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(seg, .{}, &buf.writer);
                    const owned = try buf.toOwnedSlice();
                    try self.reasoning_details_acc.append(arena, owned);
                }
            },
            else => {
                var buf: std.Io.Writer.Allocating = .init(arena);
                try std.json.Stringify.value(rd, .{}, &buf.writer);
                const owned = try buf.toOwnedSlice();
                try self.reasoning_details_acc.append(arena, owned);
            },
        }
    }

    /// Push a fragment through the streaming thinking-tag splitter.
    /// Enqueues one PendingDelta per text/thinking segment (preserving order)
    /// into pending_text_thinking; the `next` loop drains them one at a time.
    fn pushText(self: *StreamState, arena: Allocator, content: []const u8) !void {
        try self.pushTagged(arena, content, .text);
    }

    fn pushTagged(self: *StreamState, arena: Allocator, content: []const u8, default_kind: PendingKind) !void {
        var work_buf: std.ArrayList(u8) = .empty;
        defer work_buf.deinit(arena);
        try work_buf.appendSlice(arena, self.think_carry.items);
        try work_buf.appendSlice(arena, content);
        self.think_carry.clearRetainingCapacity();

        var pos: usize = 0;
        const src = work_buf.items;
        while (pos < src.len) {
            if (self.think_mode == .outside) {
                if (findOpenTag(src[pos..], self.startup)) |tag| {
                    if (tag.offset > 0) try self.emitTagged(arena, default_kind, src[pos .. pos + tag.offset]);
                    pos += tag.offset + tag.open.len;
                    self.think_mode = tag.mode;
                    self.startup = false;
                    continue;
                }
                const suffix_keep = partialOpenSuffix(src[pos..], self.startup);
                const emit_end = src.len - suffix_keep;
                if (emit_end > pos) try self.emitTagged(arena, default_kind, src[pos..emit_end]);
                if (suffix_keep > 0) {
                    try self.think_carry.appendSlice(arena, src[emit_end..]);
                    self.think_carry_kind = default_kind;
                } else {
                    self.startup = false;
                }
                pos = src.len;
            } else {
                const close = closeTag(self.think_mode);
                const rel = std.mem.indexOf(u8, src[pos..], close);
                if (rel) |off| {
                    if (off > 0) try self.emitTagged(arena, .thinking, src[pos .. pos + off]);
                    pos += off + close.len;
                    self.think_mode = .outside;
                } else {
                    const suffix_keep = partialTagSuffix(src[pos..], close);
                    const emit_end = src.len - suffix_keep;
                    if (emit_end > pos) try self.emitTagged(arena, .thinking, src[pos..emit_end]);
                    if (suffix_keep > 0) {
                        try self.think_carry.appendSlice(arena, src[emit_end..]);
                        self.think_carry_kind = .thinking;
                    }
                    pos = src.len;
                }
            }
        }
    }

    fn emitTagged(self: *StreamState, arena: Allocator, kind: PendingKind, data: []const u8) !void {
        if (data.len == 0) return;
        const seg = try arena.dupe(u8, data);
        switch (kind) {
            .text => try self.text_acc.appendSlice(arena, seg),
            .thinking => try self.thinking_acc.appendSlice(arena, seg),
        }
        try self.pending_text_thinking.append(arena, .{ .kind = kind, .data = seg });
    }

    fn partialTagSuffix(s: []const u8, tag: []const u8) usize {
        // Largest k where s ends with tag[0..k]
        const max_k = @min(s.len, tag.len - 1);
        var k: usize = max_k;
        while (k > 0) : (k -= 1) {
            if (std.mem.endsWith(u8, s, tag[0..k])) return k;
        }
        return 0;
    }

    pub fn finalize(self: *StreamState, arena: Allocator) !adapter.ResponseResult {
        if (self.think_carry.items.len > 0) {
            const acc = if (self.think_mode == .outside and self.think_carry_kind == .text)
                &self.text_acc
            else
                &self.thinking_acc;
            try acc.appendSlice(self.arena, self.think_carry.items);
            self.think_carry.clearRetainingCapacity();
        }

        var parts: std.ArrayList(adapter.ContentPart) = .empty;
        if (self.thinking_acc.items.len > 0 and std.mem.indexOfNone(u8, self.thinking_acc.items, " \t\n\r") != null) {
            const sig = try self.composeReasoningDetails(arena);
            try parts.append(arena, .{ .thinking = .{
                .text = try arena.dupe(u8, self.thinking_acc.items),
                .signature = sig,
            } });
        }

        var text_buf: std.ArrayList(u8) = .empty;
        try text_buf.appendSlice(self.arena, self.text_acc.items);

        var tool_parts: std.ArrayList(adapter.ContentPart) = .empty;
        var dropped_calls: std.ArrayList(adapter.DroppedToolCall) = .empty;
        for (self.tools.items) |*t| {
            if (!t.started) continue;
            const raw_args = if (t.args.items.len == 0) "{}" else t.args.items;
            if (!isValidJsonObject(self.arena, raw_args)) {
                try dropped_calls.append(arena, .{ .id = t.id, .name = t.name });
                continue;
            }
            try tool_parts.append(arena, .{ .tool_call = .{
                .id = try arena.dupe(u8, t.id),
                .name = try arena.dupe(u8, t.name),
                .arguments = try arena.dupe(u8, raw_args),
            } });
        }

        if (dropped_calls.items.len > 0) {
            const note = try adapter.droppedToolCallNote(self.arena, dropped_calls.items);
            try text_buf.append(self.arena, '\n');
            try text_buf.appendSlice(self.arena, note);
        }

        try parts.append(arena, .{ .text = try arena.dupe(u8, text_buf.items) });
        try parts.appendSlice(arena, tool_parts.items);

        const owned = try parts.toOwnedSlice(arena);
        return .{
            .message = .{ .role = .agent, .parts = owned },
            .usage = self.usage,
            .dropped_tool_calls = @intCast(dropped_calls.items.len),
        };
    }
};

fn isValidJsonObject(arena: Allocator, s: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, s, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

test "openai request stream mode is caller selected" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chat: adapter.Chat = .{};
    try chat.addMessage(arena, .user, &.{.{ .text = "hello" }});

    const cfg: adapter.Config = .{
        .api_key = "test",
        .model = "model",
        .base_url = "https://example.test/v1",
        .provider = .{ .openai = .{} },
    };

    const payload = try serializeRequest(testing.allocator, &chat, cfg, .blocking);
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    const obj = parsed.value.object;
    try testing.expectEqual(false, obj.get("stream").?.bool);
    try testing.expect(obj.get("stream_options") == null);
}

test "deepseek request replays raw reasoning_content for assistant messages" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chat: adapter.Chat = .{};
    try chat.addMessage(arena, .agent, &.{
        .{ .thinking = .{ .text = "inspect " } },
        .{ .thinking = .{ .text = "the file" } },
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"src/main.zig\"}" } },
    });
    try chat.addMessage(arena, .user, &.{
        .{ .tool_result = .{ .call_id = "call_1", .name = "read", .content = "contents" } },
    });
    try chat.addMessage(arena, .agent, &.{.{ .text = "done" }});

    const deepseek_cfg: adapter.Config = .{
        .api_key = "test",
        .model = "Vendor/DeepSeek-V4-Pro",
        .base_url = "https://example.test/v1",
        .provider = .{ .openai = .{} },
    };
    const deepseek_payload = try serializeRequest(testing.allocator, &chat, deepseek_cfg, .streaming);
    defer testing.allocator.free(deepseek_payload);

    const deepseek_parsed = try std.json.parseFromSlice(std.json.Value, arena, deepseek_payload, .{});
    const deepseek_messages = deepseek_parsed.value.object.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 3), deepseek_messages.len);
    try testing.expectEqualStrings(
        "inspect the file",
        deepseek_messages[0].object.get("reasoning_content").?.string,
    );
    try testing.expectEqualStrings(
        "",
        deepseek_messages[2].object.get("reasoning_content").?.string,
    );

    const other_cfg: adapter.Config = .{
        .api_key = "test",
        .model = "qwen3-thinking",
        .base_url = "https://example.test/v1",
        .provider = .{ .openai = .{} },
    };
    const other_payload = try serializeRequest(testing.allocator, &chat, other_cfg, .streaming);
    defer testing.allocator.free(other_payload);

    const other_parsed = try std.json.parseFromSlice(std.json.Value, arena, other_payload, .{});
    const other_messages = other_parsed.value.object.get("messages").?.array.items;
    try testing.expect(other_messages[0].object.get("reasoning_content") == null);
    try testing.expect(other_messages[2].object.get("reasoning_content") == null);
}

test "openai stream assembles every parallel tool call delta" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{
        .{
            .index = 0,
            .id = "call_grep",
            .function = .{ .name = "grep", .arguments = "{\"pattern\":\"" },
        },
        .{
            .index = 1,
            .id = "call_read",
            .function = .{ .name = "read", .arguments = "{\"path\":\"" },
        },
    };
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    var endings = [_]OaiDeltaToolCall{
        .{ .index = 0, .function = .{ .arguments = "report\"}" } },
        .{ .index = 1, .function = .{ .arguments = "src/report.zig\"}" } },
    };
    var ending_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &endings } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &ending_choices }) == null);

    // Both calls in both chunks must be processed before the parser yields.
    // Previously each loop returned after index 0 and discarded index 1.
    try testing.expectEqual(@as(usize, 4), stream.pending_tool_deltas.items.len);

    const result = try stream.finalize(arena);
    var calls: [2]adapter.ToolCall = undefined;
    var call_count: usize = 0;
    for (result.message.parts) |part| switch (part) {
        .tool_call => |call| {
            calls[call_count] = call;
            call_count += 1;
        },
        else => {},
    };

    try testing.expectEqual(@as(usize, 2), call_count);
    try testing.expectEqualStrings("call_grep", calls[0].id);
    try testing.expectEqualStrings("grep", calls[0].name);
    try testing.expectEqualStrings("{\"pattern\":\"report\"}", calls[0].arguments);
    try testing.expectEqualStrings("call_read", calls[1].id);
    try testing.expectEqualStrings("read", calls[1].name);
    try testing.expectEqualStrings("{\"path\":\"src/report.zig\"}", calls[1].arguments);
}

test "openai stream continues tool arg deltas that omit index" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{.{ .index = 0, .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"" } }};
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    // Argument-only delta with no `index` — previously opened a fresh slot,
    // leaving the real call with truncated JSON arguments.
    var continuations = [_]OaiDeltaToolCall{.{ .function = .{ .arguments = "src/main.zig\"}" } }};
    var cont_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &continuations } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &cont_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(usize, 2), result.message.parts.len);
    try testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", result.message.parts[1].tool_call.arguments);
}

test "openai stream replaces fully resent tool arguments" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{.{ .index = 0, .id = "call_1", .function = .{ .name = "grep", .arguments = "{\"pattern\":\"report\"" } }};
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    // Provider resends the full accumulated object; appending would produce
    // `{"pattern":"report"}{"pattern":"report","case":true}` → malformed.
    var resends = [_]OaiDeltaToolCall{.{ .index = 0, .function = .{ .arguments = "{\"pattern\":\"report\",\"case\":true}" } }};
    var resend_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &resends } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &resend_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(usize, 2), result.message.parts.len);
    try testing.expectEqualStrings("{\"pattern\":\"report\",\"case\":true}", result.message.parts[1].tool_call.arguments);
}

test "openai stream dedupes final complete tool call against delta slot" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{.{ .index = 0, .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"" } }};
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    // Final chunk repeats the call as a complete message object.
    const final_tc = OaiResponseToolCall{ .id = "call_1", .function = .{ .name = "read", .arguments = "{\"path\":\"src/main.zig\"}" } };
    var final_choices = [_]OaiStreamChoice{.{ .message = .{ .role = "assistant", .tool_calls = &[_]OaiResponseToolCall{final_tc} }, .finish_reason = "tool_calls" }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &final_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(usize, 2), result.message.parts.len);
    try testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", result.message.parts[1].tool_call.arguments);
}

test "openai stream drops invalid-args tool call and reports it" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    // Start a tool call with a truncated arguments fragment (no closing brace).
    var starts = [_]OaiDeltaToolCall{.{ .index = 0, .id = "call_trunc", .function = .{ .name = "grep", .arguments = "{\"pattern\":\"foo\"" } }};
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);
    // Stream ends without completing the JSON — finish_reason "length".
    var finish_choices = [_]OaiStreamChoice{.{ .finish_reason = "length" }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &finish_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(u32, 1), result.dropped_tool_calls);
    var found = false;
    var note_found = false;
    for (result.message.parts) |part| switch (part) {
        .tool_call => found = true,
        .text => |t| {
            if (std.mem.indexOf(u8, t, "had invalid arguments and was not executed") != null) note_found = true;
        },
        else => {},
    };
    try testing.expect(!found);
    try testing.expect(note_found);
}

test "openai stream keeps valid calls and drops invalid calls in a mixed stream" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{
        .{ .index = 0, .id = "call_valid", .function = .{ .name = "read", .arguments = "{\"path\":\"src/main.zig\"}" } },
        .{ .index = 1, .id = "call_trunc", .function = .{ .name = "grep", .arguments = "{\"pattern\":\"foo\"" } },
    };
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(u32, 1), result.dropped_tool_calls);
    var calls: [1]adapter.ToolCall = undefined;
    var call_count: usize = 0;
    var note_found = false;
    for (result.message.parts) |part| switch (part) {
        .tool_call => |call| {
            calls[call_count] = call;
            call_count += 1;
        },
        .text => |t| {
            if (std.mem.indexOf(u8, t, "had invalid arguments and was not executed") != null) note_found = true;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), call_count);
    try testing.expectEqualStrings("call_valid", calls[0].id);
    try testing.expectEqualStrings("read", calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", calls[0].arguments);
    try testing.expect(note_found);
}

test "openai serialize skips invalid-args tool_call and its tool_result together" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chat: adapter.Chat = .{};
    try chat.addMessage(arena, .agent, &.{
        .{ .tool_call = .{ .id = "call_bad", .name = "grep", .arguments = "{\"pattern\":\"foo\"" } },
        .{ .tool_call = .{ .id = "call_ok", .name = "read", .arguments = "{\"path\":\"src/main.zig\"}" } },
    });
    try chat.addMessage(arena, .user, &.{
        .{ .tool_result = .{ .call_id = "call_bad", .name = "grep", .content = "invalid json", .is_error = true } },
        .{ .tool_result = .{ .call_id = "call_ok", .name = "read", .content = "contents" } },
    });

    const cfg: adapter.Config = .{
        .api_key = "test",
        .model = "model",
        .base_url = "https://example.test/v1",
        .provider = .{ .openai = .{} },
    };
    const payload = try serializeRequest(testing.allocator, &chat, cfg, .blocking);
    defer testing.allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "call_ok") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "call_bad") == null);
}

test "openai stream reports zero dropped_tool_calls when all args valid" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    var starts = [_]OaiDeltaToolCall{.{ .index = 0, .id = "call_ok", .function = .{ .name = "read", .arguments = "{\"path\":\"src/main.zig\"}" } }};
    var start_choices = [_]OaiStreamChoice{.{ .delta = .{ .tool_calls = &starts } }};
    try testing.expect(try stream.applyChunk(arena, .{ .choices = &start_choices }) == null);

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(u32, 0), result.dropped_tool_calls);
}

test "openai stream keeps tagged reasoning as thinking across schema fields" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stream = StreamState.init(arena);
    const chunks = [_]OaiDelta{
        .{ .reasoning_content = "<thin" },
        .{ .reasoning_content = "king>private " },
        .{ .content = "tail</thin" },
        .{ .content = "king>answer" },
    };
    for (chunks) |delta| {
        var choices = [_]OaiStreamChoice{.{ .delta = delta }};
        try testing.expect(try stream.applyChunk(arena, .{ .choices = &choices }) == null);
    }

    const result = try stream.finalize(arena);
    try testing.expectEqual(@as(usize, 2), result.message.parts.len);
    try testing.expectEqualStrings("private tail", result.message.parts[0].thinking.text);
    try testing.expectEqualStrings("answer", result.message.parts[1].text);

    var normal = StreamState.init(arena);
    var combined = [_]OaiStreamChoice{.{ .delta = .{ .reasoning_content = "plan", .content = "answer" } }};
    _ = try normal.applyChunk(arena, .{ .choices = &combined });
    const normal_result = try normal.finalize(arena);
    try testing.expectEqualStrings("plan", normal_result.message.parts[0].thinking.text);
    try testing.expectEqualStrings("answer", normal_result.message.parts[1].text);
}

test "openai stream surfaces provider error payload" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, "{\"message\":\"model unavailable\"}", .{});
    defer parsed.deinit();
    var stream = StreamState.init(arena);
    const delta = (try stream.applyChunk(arena, .{ .@"error" = parsed.value })) orelse return error.TestUnexpectedResult;

    switch (delta) {
        .provider_error => |body| try testing.expect(std.mem.indexOf(u8, body, "model unavailable") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "reasoning_details round-trip: stream capture then replay in request" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- Phase 1: simulate streaming response with reasoning_details deltas --
    var stream = StreamState.init(arena);

    const seg1_json = "{\"type\":\"reasoning.text\",\"format\":\"openai-responses-v1\",\"text\":\"think\"}";
    const seg2_json = "{\"type\":\"reasoning.text\",\"format\":\"openai-responses-v1\",\"text\":\"more\"}";

    const seg1_parsed = try std.json.parseFromSlice(std.json.Value, arena, seg1_json, .{});
    const seg2_parsed = try std.json.parseFromSlice(std.json.Value, arena, seg2_json, .{});

    var seg1_arr_items = [_]std.json.Value{seg1_parsed.value};
    var seg2_arr_items = [_]std.json.Value{seg2_parsed.value};
    const rd1: std.json.Value = .{ .array = std.json.Array.fromOwnedSlice(arena, &seg1_arr_items) };
    const rd2: std.json.Value = .{ .array = std.json.Array.fromOwnedSlice(arena, &seg2_arr_items) };

    const choice1 = OaiStreamChoice{ .delta = .{
        .reasoning_content = "think",
        .reasoning_details = rd1,
    } };
    const choice2 = OaiStreamChoice{ .delta = .{
        .reasoning_content = "more",
        .reasoning_details = rd2,
    } };
    const choice3 = OaiStreamChoice{ .delta = .{ .content = "answer" } };

    var choices_buf1 = [_]OaiStreamChoice{choice1};
    var choices_buf2 = [_]OaiStreamChoice{choice2};
    var choices_buf3 = [_]OaiStreamChoice{choice3};

    _ = try stream.applyChunk(arena, .{ .choices = &choices_buf1 });
    _ = try stream.applyChunk(arena, .{ .choices = &choices_buf2 });
    _ = try stream.applyChunk(arena, .{ .choices = &choices_buf3 });

    const result = try stream.finalize(arena);

    // Find thinking part with signature.
    var thinking_sig: ?[]const u8 = null;
    var thinking_text: ?[]const u8 = null;
    for (result.message.parts) |p| switch (p) {
        .thinking => |th| {
            thinking_text = th.text;
            thinking_sig = th.signature;
        },
        else => {},
    };
    try testing.expect(thinking_text != null);
    try testing.expectEqualStrings("thinkmore", thinking_text.?);
    try testing.expect(thinking_sig != null);

    // Signature must parse as a 2-element array of objects.
    const sig_parsed = try std.json.parseFromSlice(std.json.Value, arena, thinking_sig.?, .{});
    try testing.expect(sig_parsed.value == .array);
    try testing.expectEqual(@as(usize, 2), sig_parsed.value.array.items.len);
    try testing.expect(sig_parsed.value.array.items[0] == .object);
    try testing.expectEqualStrings(
        "reasoning.text",
        sig_parsed.value.array.items[0].object.get("type").?.string,
    );

    // -- Phase 2: feed thinking part back into a Chat and serialize --
    var chat: adapter.Chat = .{};
    const parts = try arena.alloc(adapter.ContentPart, 2);
    parts[0] = .{ .thinking = .{
        .text = thinking_text.?,
        .signature = thinking_sig.?,
    } };
    parts[1] = .{ .text = "answer" };
    try chat.messages.append(arena, .{ .role = .agent, .parts = parts });

    const cfg: adapter.Config = .{
        .api_key = "test",
        .model = "qwen3-thinking",
        .base_url = "https://api.novita.ai/openai/v1",
        .provider = .{ .openai = .{} },
    };

    const payload = try serializeRequest(testing.allocator, &chat, cfg, .streaming);
    defer testing.allocator.free(payload);

    // Parse the request body and verify reasoning_details survived.
    const req_parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    const messages_arr = req_parsed.value.object.get("messages").?.array;
    try testing.expectEqual(@as(usize, 1), messages_arr.items.len);
    const msg = messages_arr.items[0].object;
    try testing.expectEqualStrings("assistant", msg.get("role").?.string);
    const rd_out = msg.get("reasoning_details") orelse return error.MissingReasoningDetails;
    try testing.expect(rd_out == .array);
    try testing.expectEqual(@as(usize, 2), rd_out.array.items.len);
    try testing.expectEqualStrings(
        "more",
        rd_out.array.items[1].object.get("text").?.string,
    );
}
