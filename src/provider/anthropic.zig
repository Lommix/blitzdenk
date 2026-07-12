const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");
const http = @import("http.zig");

pub const Config = adapter.Config;

// -- Anthropic request types --

const AntOutputConfig = struct {
    effort: []const u8,
};

const AntImageSource = struct {
    type: []const u8 = "base64",
    media_type: []const u8,
    data: []const u8,
};

const AntCacheControl = struct {
    type: []const u8 = "ephemeral",
};

const AntContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    // thinking fields
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    // image fields
    source: ?AntImageSource = null,
    // tool_use fields
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
    // tool_result fields
    tool_use_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    is_error: ?bool = null,
    // cache breakpoint
    cache_control: ?AntCacheControl = null,
};

const AntMessage = struct {
    role: []const u8,
    content: []const AntContentBlock,
};

const AntToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    cache_control: ?AntCacheControl = null,
};

const AntSystemBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
    cache_control: ?AntCacheControl = null,
};

const AntRequest = struct {
    model: []const u8,
    max_tokens: u32,
    stream: bool,
    system: ?[]const AntSystemBlock = null,
    messages: []const AntMessage,
    tools: ?[]const AntToolDef = null,
    thinking: ?adapter.Thinking = null,
    output_config: ?AntOutputConfig = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,
};

// -- Anthropic response types --

const AntResponseContent = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const AntUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
};

const AntResponse = struct {
    content: ?[]const AntResponseContent = null,
    usage: ?AntUsage = null,
};

pub fn serializeRequest(allocator: Allocator, chat: *const adapter.Chat, config: Config, mode: adapter.CompletionMode) ![]u8 {
    var messages: std.ArrayList(AntMessage) = .empty;
    defer {
        for (messages.items) |m| {
            for (m.content) |block| {
                if (block.text) |t| allocator.free(t);
                if (block.thinking) |t| allocator.free(t);
                if (block.content) |c| allocator.free(c);
            }
            allocator.free(m.content);
        }
        messages.deinit(allocator);
    }

    // Extract system prompt
    var system_text: ?[]const u8 = null;

    // Pre-pass: collect call_ids of any tool_call whose arguments don't parse
    // as a JSON object. The matching tool_use block and its tool_result must
    // both be skipped — Anthropic 400s on malformed input or orphaned results.
    var skipped_ids: std.StringHashMapUnmanaged(void) = .{};
    defer skipped_ids.deinit(allocator);
    for (chat.messages.items) |msg| {
        for (msg.parts) |part| {
            switch (part) {
                .tool_call => |tc| {
                    var scratch = std.heap.ArenaAllocator.init(allocator);
                    defer scratch.deinit();
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        scratch.allocator(),
                        tc.arguments,
                        .{},
                    ) catch {
                        try skipped_ids.put(allocator, tc.id, {});
                        continue;
                    };
                    if (parsed.value != .object) {
                        try skipped_ids.put(allocator, tc.id, {});
                    }
                },
                else => {},
            }
        }
    }

    for (chat.messages.items) |msg| {
        if (msg.role == .system) {
            for (msg.parts) |part| {
                switch (part) {
                    .text => |t| {
                        system_text = t;
                    },
                    else => {},
                }
            }
            continue;
        }

        var content_blocks: std.ArrayList(AntContentBlock) = .empty;
        defer content_blocks.deinit(allocator);

        for (msg.parts) |part| {
            switch (part) {
                .text => |t| {
                    try content_blocks.append(allocator, .{
                        .type = "text",
                        .text = try allocator.dupe(u8, t),
                    });
                },
                .thinking => |th| {
                    try content_blocks.append(allocator, .{
                        .type = "thinking",
                        .thinking = try allocator.dupe(u8, th.text),
                        .signature = th.signature,
                    });
                },
                .image => |img| {
                    try content_blocks.append(allocator, .{
                        .type = "image",
                        .source = .{
                            .media_type = img.media_type,
                            .data = img.data,
                        },
                    });
                },
                .tool_call => |tc| {
                    if (skipped_ids.contains(tc.id)) continue;
                    const input_val = try std.json.parseFromSlice(
                        std.json.Value,
                        allocator,
                        tc.arguments,
                        .{ .allocate = .alloc_always },
                    );
                    // We leak the parsed wrapper but arena will clean up
                    try content_blocks.append(allocator, .{
                        .type = "tool_use",
                        .id = tc.id,
                        .name = tc.name,
                        .input = input_val.value,
                    });
                },
                .tool_result => |tr| {
                    if (skipped_ids.contains(tr.call_id)) continue;
                    try content_blocks.append(allocator, .{
                        .type = "tool_result",
                        .tool_use_id = tr.call_id,
                        .content = try allocator.dupe(u8, tr.content),
                        .is_error = if (tr.is_error) true else null,
                    });
                },
            }
        }

        if (content_blocks.items.len == 0) continue;

        const role: []const u8 = switch (msg.role) {
            .agent => "assistant",
            .user => "user",
            .system => unreachable,
        };

        try messages.append(allocator, .{
            .role = role,
            .content = try allocator.dupe(AntContentBlock, content_blocks.items),
        });
    }

    // Merge consecutive same-role messages (Anthropic requires strict alternation)
    var merged: std.ArrayList(AntMessage) = .empty;
    defer {
        for (merged.items) |m| allocator.free(m.content);
        merged.deinit(allocator);
    }

    for (messages.items) |msg| {
        if (merged.items.len > 0 and
            std.mem.eql(u8, merged.items[merged.items.len - 1].role, msg.role))
        {
            // Merge content blocks
            const prev = &merged.items[merged.items.len - 1];
            const combined = try allocator.alloc(AntContentBlock, prev.content.len + msg.content.len);
            @memcpy(combined[0..prev.content.len], prev.content);
            @memcpy(combined[prev.content.len..], msg.content);
            allocator.free(prev.content);
            prev.content = combined;
        } else {
            try merged.append(allocator, .{
                .role = msg.role,
                .content = try allocator.dupe(AntContentBlock, msg.content),
            });
        }
    }

    // Serialize tool definitions
    var tool_defs: ?[]const AntToolDef = null;
    var tool_defs_buf: std.ArrayList(AntToolDef) = .empty;
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
                .name = tool.name,
                .description = tool.description,
                .input_schema = parsed.value,
            });
        }
        tool_defs_buf.items[tool_defs_buf.items.len - 1].cache_control = .{};
        tool_defs = tool_defs_buf.items;
    }

    // Mark the last content block of the second-to-last message so chat
    // history up to the prior turn is cached, but the fresh final turn
    // stays outside the breakpoint.
    if (merged.items.len >= 2) {
        const target = &merged.items[merged.items.len - 2];
        if (target.content.len > 0) {
            const mutable = try allocator.dupe(AntContentBlock, target.content);
            allocator.free(target.content);
            mutable[mutable.len - 1].cache_control = .{};
            target.content = mutable;
        }
    }

    // Wrap system prompt in a block array so a cache_control marker can
    // attach to it.
    var system_blocks_buf: [1]AntSystemBlock = undefined;
    var system_blocks: ?[]const AntSystemBlock = null;
    if (system_text) |txt| {
        system_blocks_buf[0] = .{ .text = txt, .cache_control = .{} };
        system_blocks = system_blocks_buf[0..1];
    }

    const ac = switch (config.provider) {
        .anthropic => |c| c,
        else => return error.NotImplemented,
    };

    const req: AntRequest = .{
        .model = config.model,
        .max_tokens = ac.max_tokens,
        .stream = mode == .streaming,
        .system = system_blocks,
        .messages = merged.items,
        .tools = tool_defs,
        .thinking = ac.thinking,
        .output_config = if (config.reasoning_effort) |e| AntOutputConfig{ .effort = @tagName(e) } else null,
        .temperature = ac.temperature,
        .top_p = ac.top_p,
        .top_k = ac.top_k,
        .stop_sequences = ac.stop,
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

    const url = try std.fmt.allocPrint(scratch, "{s}/messages", .{config.base_url});
    defer scratch.free(url);

    return pool.fetch(url, .POST, payload, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-api-key", .value = config.api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    }, options.timeout_ms);
}

pub fn parseResponse(arena: Allocator, body: []const u8) !adapter.ResponseResult {
    const parsed = try std.json.parseFromSlice(AntResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var parts: std.ArrayList(adapter.ContentPart) = .empty;
    var usage: ?adapter.TokenUsage = null;

    if (parsed.value.content) |content| {
        for (content) |block| {
            const btype = block.type orelse "";
            if (std.mem.eql(u8, btype, "text")) {
                try parts.append(arena, .{ .text = try arena.dupe(u8, block.text orelse "") });
            } else if (std.mem.eql(u8, btype, "thinking")) {
                try parts.append(arena, .{ .thinking = .{
                    .text = try arena.dupe(u8, block.thinking orelse ""),
                    .signature = if (block.signature) |sig| try arena.dupe(u8, sig) else null,
                } });
            } else if (std.mem.eql(u8, btype, "tool_use")) {
                var buf: std.Io.Writer.Allocating = .init(arena);
                const input = block.input orelse std.json.Value{ .object = std.json.ObjectMap.empty };
                try std.json.Stringify.value(input, .{}, &buf.writer);
                const args = try buf.toOwnedSlice();
                if (!isValidJsonObject(arena, args)) continue;
                try parts.append(arena, .{ .tool_call = .{
                    .id = try arena.dupe(u8, block.id orelse ""),
                    .name = try arena.dupe(u8, block.name orelse ""),
                    .arguments = args,
                } });
            }
        }
    }

    if (parsed.value.usage) |u| {
        usage = .{
            .input_tokens = u.input_tokens orelse 0,
            .output_tokens = u.output_tokens orelse 0,
            .cached_tokens = u.cache_read_input_tokens orelse 0,
            .cache_creation_tokens = u.cache_creation_input_tokens orelse 0,
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
// Anthropic streams SSE events with "event:" + "data: {...}" lines separated
// by blank lines. Event types we care about:
//   message_start, content_block_start, content_block_delta,
//   content_block_stop, message_delta, message_stop, ping
// Delta payloads carry text_delta, thinking_delta, or input_json_delta.

const BlockKind = enum { text, thinking, tool_use };

const BlockAcc = struct {
    kind: BlockKind,
    text: std.ArrayList(u8) = .empty, // for text / thinking
    signature: ?[]u8 = null, // thinking signature (final delta)
    tool_id: []u8 = &.{},
    tool_name: []u8 = &.{},
    tool_input: std.ArrayList(u8) = .empty,
};

pub const StreamState = struct {
    arena: Allocator,
    sse_buf: std.ArrayList(u8) = .empty, // raw bytes awaiting event boundary
    event_name: std.ArrayList(u8) = .empty, // current event name
    event_data: std.ArrayList(u8) = .empty, // accumulated data lines
    blocks: std.ArrayList(BlockAcc) = .empty,
    usage: ?adapter.TokenUsage = null,
    pending_usage: ?adapter.TokenUsage = null,
    term: TermState = .streaming,
    stop_reason: ?[]const u8 = null,

    pub const TermState = enum { streaming, pending_finish, done };

    pub fn init(arena: Allocator) StreamState {
        return .{ .arena = arena };
    }

    /// Pump chunks and parse one delta. Returns null when stream is exhausted.
    pub fn next(
        self: *StreamState,
        pool: *http.RequestPool,
        handle: http.RequestPool.RequestHandle,
        arena: Allocator,
    ) !?adapter.Delta {
        while (true) {
            if (self.pending_usage) |u| {
                self.pending_usage = null;
                return .{ .usage = u };
            }
            if (self.term == .pending_finish) {
                self.term = .done;
                return .finish;
            }
            if (self.term == .done) return null;

            // Try to emit a delta from buffered events.
            if (try self.drainEvent(arena)) |d| return d;

            // Need more bytes.
            const chunk = try pool.nextChunk(handle);
            if (chunk) |bytes| {
                defer pool.dropChunk(bytes);
                try self.sse_buf.appendSlice(arena, bytes);
                continue;
            }
            if (pool.isStreamDone(handle)) {
                // Stream exhausted without an explicit message_stop — treat as finish.
                self.term = .pending_finish;
                continue;
            }
            return error.WouldBlock;
        }
    }

    /// Parse the next SSE event from sse_buf (delimited by \n\n). Consumes
    /// it and dispatches. Returns a Delta if the event produced one, else null.
    fn drainEvent(self: *StreamState, arena: Allocator) !?adapter.Delta {
        while (true) {
            const buf = self.sse_buf.items;
            const sep = std.mem.indexOf(u8, buf, "\n\n") orelse return null;
            const raw = buf[0..sep];

            // Parse event + data lines.
            self.event_name.clearRetainingCapacity();
            self.event_data.clearRetainingCapacity();
            var line_it = std.mem.splitScalar(u8, raw, '\n');
            while (line_it.next()) |line_raw| {
                const line = std.mem.trimEnd(u8, line_raw, "\r");
                if (std.mem.startsWith(u8, line, "event:")) {
                    const v = std.mem.trim(u8, line[6..], " \t");
                    try self.event_name.appendSlice(arena, v);
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    const v = if (line.len > 5 and line[5] == ' ') line[6..] else line[5..];
                    if (self.event_data.items.len > 0) try self.event_data.append(arena, '\n');
                    try self.event_data.appendSlice(arena, v);
                }
            }

            // Remove consumed bytes (including "\n\n").
            const consumed = sep + 2;
            const rest = buf[consumed..];
            std.mem.copyForwards(u8, self.sse_buf.items[0..rest.len], rest);
            self.sse_buf.items.len = rest.len;

            const delta = try self.dispatch(arena);
            if (delta) |d| return d;
            // else: event produced no delta (ping, message_start, etc.) — keep draining.
        }
    }

    fn dispatch(self: *StreamState, arena: Allocator) !?adapter.Delta {
        const name = self.event_name.items;
        const data = self.event_data.items;
        if (name.len == 0 or data.len == 0) return null;

        if (std.mem.eql(u8, name, "content_block_start")) {
            return try self.handleBlockStart(arena, data);
        } else if (std.mem.eql(u8, name, "content_block_delta")) {
            return try self.handleBlockDelta(arena, data);
        } else if (std.mem.eql(u8, name, "content_block_stop")) {
            return null;
        } else if (std.mem.eql(u8, name, "message_delta")) {
            return try self.handleMessageDelta(arena, data);
        } else if (std.mem.eql(u8, name, "message_stop")) {
            self.term = .pending_finish;
            return null;
        } else if (std.mem.eql(u8, name, "message_start")) {
            return try self.handleMessageStart(arena, data);
        } else if (std.mem.eql(u8, name, "error")) {
            return error.ProviderStreamError;
        }
        return null;
    }

    const BlockStartEnvelope = struct {
        type: ?[]const u8 = null,
        index: ?u32 = null,
        content_block: ?AntResponseContent = null,
    };

    fn handleBlockStart(self: *StreamState, arena: Allocator, data: []const u8) !?adapter.Delta {
        const parsed = try std.json.parseFromSlice(BlockStartEnvelope, arena, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const block = parsed.value.content_block orelse return null;
        const idx = parsed.value.index orelse @as(u32, @intCast(self.blocks.items.len));
        // Grow blocks list to index.
        while (self.blocks.items.len <= idx) {
            try self.blocks.append(arena, .{ .kind = .text });
        }
        const btype = block.type orelse "text";
        if (std.mem.eql(u8, btype, "text")) {
            self.blocks.items[idx] = .{ .kind = .text };
            return null;
        } else if (std.mem.eql(u8, btype, "thinking")) {
            self.blocks.items[idx] = .{ .kind = .thinking };
            return null;
        } else if (std.mem.eql(u8, btype, "tool_use")) {
            const id = try arena.dupe(u8, block.id orelse "");
            const name = try arena.dupe(u8, block.name orelse "");
            self.blocks.items[idx] = .{
                .kind = .tool_use,
                .tool_id = id,
                .tool_name = name,
            };
            return .{ .tool_call_start = .{ .id = id, .name = name, .arguments = "" } };
        }
        return null;
    }

    const DeltaPayload = struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
        signature: ?[]const u8 = null,
    };

    const BlockDeltaEnvelope = struct {
        type: ?[]const u8 = null,
        index: ?u32 = null,
        delta: ?DeltaPayload = null,
    };

    fn handleBlockDelta(self: *StreamState, arena: Allocator, data: []const u8) !?adapter.Delta {
        const parsed = try std.json.parseFromSlice(BlockDeltaEnvelope, arena, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const d = parsed.value.delta orelse return null;
        const idx = parsed.value.index orelse 0;
        if (idx >= self.blocks.items.len) return null;
        const block = &self.blocks.items[idx];
        const dtype = d.type orelse "";

        if (std.mem.eql(u8, dtype, "text_delta")) {
            const t = d.text orelse return null;
            try block.text.appendSlice(arena, t);
            return .{ .text_chunk = try arena.dupe(u8, t) };
        } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
            const t = d.thinking orelse return null;
            try block.text.appendSlice(arena, t);
            return .{ .thinking_chunk = try arena.dupe(u8, t) };
        } else if (std.mem.eql(u8, dtype, "signature_delta")) {
            if (d.signature) |s| block.signature = try arena.dupe(u8, s);
            return null;
        } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
            const frag = d.partial_json orelse return null;
            try block.tool_input.appendSlice(arena, frag);
            return .{ .tool_input_delta = .{
                .call_id = block.tool_id,
                .json_fragment = try arena.dupe(u8, frag),
            } };
        }
        return null;
    }

    const MessageDeltaEnvelope = struct {
        type: ?[]const u8 = null,
        delta: ?struct {
            stop_reason: ?[]const u8 = null,
        } = null,
        usage: ?AntUsage = null,
    };

    fn handleMessageDelta(self: *StreamState, arena: Allocator, data: []const u8) !?adapter.Delta {
        const parsed = try std.json.parseFromSlice(MessageDeltaEnvelope, arena, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.delta) |d| {
            if (d.stop_reason) |sr| {
                if (self.stop_reason == null) self.stop_reason = try arena.dupe(u8, sr);
            }
        }
        if (parsed.value.usage) |u| {
            var acc = self.usage orelse adapter.TokenUsage{};
            acc.output_tokens = u.output_tokens orelse acc.output_tokens;
            if (u.input_tokens) |it| acc.input_tokens = it;
            if (u.cache_read_input_tokens) |cr| acc.cached_tokens = cr;
            if (u.cache_creation_input_tokens) |cc| acc.cache_creation_tokens = cc;
            self.usage = acc;
            self.pending_usage = acc;
        }
        return null;
    }

    const MessageStartEnvelope = struct {
        type: ?[]const u8 = null,
        message: ?struct {
            usage: ?AntUsage = null,
        } = null,
    };

    fn handleMessageStart(self: *StreamState, arena: Allocator, data: []const u8) !?adapter.Delta {
        const parsed = try std.json.parseFromSlice(MessageStartEnvelope, arena, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.message) |m| {
            if (m.usage) |u| {
                self.usage = .{
                    .input_tokens = u.input_tokens orelse 0,
                    .output_tokens = u.output_tokens orelse 0,
                    .cached_tokens = u.cache_read_input_tokens orelse 0,
                    .cache_creation_tokens = u.cache_creation_input_tokens orelse 0,
                };
                self.pending_usage = self.usage;
            }
        }
        return null;
    }

    pub fn finalize(self: *StreamState, arena: Allocator) !adapter.ResponseResult {
        var parts: std.ArrayList(adapter.ContentPart) = .empty;
        var dropped: u32 = 0;
        for (self.blocks.items) |*b| {
            switch (b.kind) {
                .text => {
                    try parts.append(arena, .{ .text = try arena.dupe(u8, b.text.items) });
                },
                .thinking => {
                    // Always preserve thinking blocks — Anthropic requires the
                    // signature chain to be replayed verbatim on the next turn
                    // when tool_use is involved. Dropping any block (even if
                    // text is empty) invalidates the chain → 400 from API.
                    try parts.append(arena, .{ .thinking = .{
                        .text = try arena.dupe(u8, b.text.items),
                        .signature = if (b.signature) |signature| try arena.dupe(u8, signature) else null,
                    } });
                },
                .tool_use => {
                    const raw_args = if (b.tool_input.items.len == 0) "{}" else b.tool_input.items;
                    // Drop malformed tool_use. Truncation (stop_reason
                    // "max_tokens") cuts mid-input_json_delta, leaving partial
                    // JSON. Replaying it provokes a 400; thinking-block
                    // signatures stay valid because earlier blocks already
                    // received content_block_stop.
                    if (!isValidJsonObject(self.arena, raw_args)) {
                        dropped += 1;
                        continue;
                    }
                    try parts.append(arena, .{ .tool_call = .{
                        .id = try arena.dupe(u8, b.tool_id),
                        .name = try arena.dupe(u8, b.tool_name),
                        .arguments = try arena.dupe(u8, raw_args),
                    } });
                },
            }
        }

        if (dropped > 0) {
            const reason = self.stop_reason orelse "unknown";
            const note = try std.fmt.allocPrint(
                arena,
                "[response truncated: {d} tool call(s) dropped due to malformed arguments (stop_reason={s}). Retry with a smaller change.]",
                .{ dropped, reason },
            );
            try parts.append(arena, .{ .text = note });
        }

        const owned = try parts.toOwnedSlice(arena);
        return .{
            .message = .{ .role = .agent, .parts = owned },
            .usage = self.usage,
        };
    }
};

fn isValidJsonObject(arena: Allocator, s: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, s, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

test "anthropic request stream mode is caller selected" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chat: adapter.Chat = .{};
    try chat.addMessage(arena, .user, &.{.{ .text = "hello" }});

    const cfg: adapter.Config = .{
        .api_key = "test",
        .model = "model",
        .base_url = "https://example.test",
        .provider = .{ .anthropic = .{} },
    };

    const payload = try serializeRequest(testing.allocator, &chat, cfg, .blocking);
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    try testing.expectEqual(false, parsed.value.object.get("stream").?.bool);
}
