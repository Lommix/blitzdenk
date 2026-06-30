const std = @import("std");
const r = @import("root.zig");
const Agent = r.agent.Agent;
const apt = r.adapter;
const http = r.http;

const log = std.log.scoped(.compact);

const PROMPT =
    \\You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.
    \\
    \\Include:
    \\- Current progress and key decisions made
    \\- Important context, constraints, or user preferences
    \\- What remains to be done (clear next steps)
    \\- Any critical data, examples, or references needed to continue
    \\
    \\Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    \\
;

const SUMMARY_PREFIX =
    \\Another agent started to solve this problem and produced a summary of its thinking process.
    \\You also have access to the state of the tools that were used by that agent.
    \\Use this to build on the work that has already been done and avoid duplicating work.
    \\Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:
    \\
;

const AUTO_COMPACT_NUMERATOR: u64 = 9;
const AUTO_COMPACT_DENOMINATOR: u64 = 10;
const RECENT_USER_MAX_TOKENS: u64 = 20_000;
const COMPACTION_TIMEOUT_MS: u32 = 5 * 60_000;

pub const Reason = enum {
    auto,
    external,
};

pub const State = struct {
    requested: bool = false,
    reason: Reason = .auto,
    pending_handle: ?http.RequestPool.RequestHandle = null,
    estimated_input_tokens: u64 = 0,
    last_compacted_message_count: usize = 0,
    last_compacted_estimate: u64 = 0,
    must_progress_past_message_count: usize = 0,
    continue_after: bool = true,

    pub fn resetInFlight(self: *State) void {
        self.pending_handle = null;
        self.estimated_input_tokens = 0;
        self.continue_after = true;
    }
};

pub fn request(self: *Agent, reason: Reason) void {
    self.compaction.requested = true;
    self.compaction.reason = reason;
}

pub fn maybeStart(self: *Agent) !bool {
    const estimate = estimateNextRequestTokens(self);
    self.last_input_context_size = @intCast(@min(estimate, std.math.maxInt(u32)));

    if (!shouldStart(self, estimate)) return false;
    if (!self.compaction.requested) self.compaction.continue_after = true;

    const arena = self.arena.allocator();
    var compact_chat = try buildCompactPrompt(arena, &self.chat);
    compact_chat.tools = .empty;

    self.compaction.pending_handle = apt.complete(
        self.pool,
        arena,
        &compact_chat,
        self.config,
        .{
            .mode = .blocking,
            .session_id = &self.session_id,
            .timeout_ms = COMPACTION_TIMEOUT_MS,
        },
    ) catch |err| switch (err) {
        error.PoolExhausted => {
            self.state = .awaiting_pool_slot;
            self.timeout = 0;
            return true;
        },
        else => |e| return e,
    };

    self.compaction.requested = false;
    self.compaction.estimated_input_tokens = estimate;
    self.state = .compacting;
    log.debug("started context compaction estimate={d} limit={d}", .{ estimate, self.context_limit });
    return true;
}

pub fn poll(self: *Agent) !bool {
    const handle = self.compaction.pending_handle orelse return true;
    if (!self.pool.isDone(handle)) return false;

    defer self.compaction.resetInFlight();
    defer self.pool.release(handle);

    if (self.pool.timedOut(handle)) return error.TimeoutReached;

    const status = self.pool.getStatus(handle) catch |err| return err;
    const status_code: u16 = @intFromEnum(status);

    const arena = self.arena.allocator();
    const body = try self.pool.collectBody(handle, arena);
    if (status_code < 200 or status_code >= 300) {
        const snippet = body[0..@min(body.len, 2048)];
        log.warn("compact http {d} from provider: {s}", .{ status_code, snippet });
        return error.CompactionRequestFailed;
    }

    const result = try apt.parseCompletion(arena, self.config, body);
    const summary = try extractSummaryText(arena, result.message.parts);
    try installCompactedHistory(self, summary);

    if (result.usage) |usage| {
        self.total_usage.add(usage);
        if (self.swarm) |swarm| swarm.token_stats.add(usage);
    }

    const estimate = estimateNextRequestTokens(self);
    self.last_input_context_size = @intCast(@min(estimate, std.math.maxInt(u32)));
    self.compaction.last_compacted_message_count = self.chat.messages.items.len;
    self.compaction.last_compacted_estimate = estimate;
    self.compaction.must_progress_past_message_count = self.chat.messages.items.len;
    log.debug("finished context compaction estimate_after={d}", .{estimate});
    return true;
}

fn shouldStart(self: *const Agent, estimate: u64) bool {
    if (self.compaction.pending_handle != null) return true;
    if (self.compaction.must_progress_past_message_count != 0 and
        self.chat.messages.items.len <= self.compaction.must_progress_past_message_count)
    {
        return false;
    }
    if (self.compaction.requested) return true;
    if (self.chat.messages.items.len <= 3) return false;
    if (self.compaction.last_compacted_message_count == self.chat.messages.items.len and
        self.compaction.last_compacted_estimate >= autoCompactLimit(self))
    {
        return false;
    }
    return estimate + maxCompletionTokens(self) >= autoCompactLimit(self);
}

fn autoCompactLimit(self: *const Agent) u64 {
    return (@as(u64, self.context_limit) * AUTO_COMPACT_NUMERATOR) / AUTO_COMPACT_DENOMINATOR;
}

fn maxCompletionTokens(self: *const Agent) u64 {
    return switch (self.config.provider) {
        .anthropic => |cfg| cfg.max_tokens,
        .openai => |cfg| cfg.max_completion_tokens orelse cfg.max_tokens orelse 8192,
        .ollama => |cfg| cfg.max_tokens orelse 8192,
    };
}

pub fn estimateNextRequestTokens(self: *const Agent) u64 {
    var bytes: u64 = 0;
    bytes += self.config.model.len;

    for (self.chat.tools.items) |tool| {
        bytes += tool.name.len;
        bytes += tool.description.len;
        bytes += tool.parameters_schema.len;
    }

    for (self.chat.messages.items) |msg| {
        bytes += @tagName(msg.role).len + 8;
        for (msg.parts) |part| bytes += partBytes(part);
    }

    return approxTokens(bytes);
}

fn partBytes(part: apt.ContentPart) u64 {
    return switch (part) {
        .text => |text| text.len,
        .thinking => |thinking| thinking.text.len + if (thinking.signature) |sig| sig.len else 0,
        .image => |img| img.data.len + img.media_type.len,
        .tool_call => |call| call.id.len + call.name.len + call.arguments.len,
        .tool_result => |result| result.call_id.len + result.name.len + result.content.len + 16,
    };
}

fn approxTokens(bytes: u64) u64 {
    return @max(1, (bytes + 2) / 3);
}

fn buildCompactPrompt(alloc: std.mem.Allocator, chat: *const apt.Chat) !apt.Chat {
    var compact_chat: apt.Chat = .{};

    if (findSystemMessage(chat)) |system| {
        try compact_chat.addMessage(alloc, .system, system.parts);
    }

    var transcript: std.Io.Writer.Allocating = .init(alloc);
    errdefer transcript.deinit();
    try transcript.writer.writeAll(PROMPT);
    try transcript.writer.writeAll("\n\n<conversation>\n");

    // TODO:prune old tool calls?
    // reserach some criteria for a filter
    for (chat.messages.items) |msg| {
        if (msg.role == .system) continue;
        try transcript.writer.print("\n[{s}]\n", .{@tagName(msg.role)});
        for (msg.parts) |part| {
            try writePartForSummary(&transcript.writer, part);
        }
    }

    try transcript.writer.writeAll("\n</conversation>\n");
    const text = try transcript.toOwnedSlice();
    try compact_chat.addMessage(alloc, .user, &.{.{ .text = text }});
    return compact_chat;
}

fn writePartForSummary(w: *std.Io.Writer, part: apt.ContentPart) !void {
    switch (part) {
        .text => |text| try w.print("{s}\n", .{text}),
        .thinking => |thinking| try w.print("[thinking]\n{s}\n", .{thinking.text}),
        .image => |img| try w.print("[image {s}, {d} bytes]\n", .{ img.media_type, img.data.len }),
        .tool_call => |call| try w.print("[tool_call {s}]\n{s}\n", .{ call.name, call.arguments }),
        .tool_result => |result| {
            switch (result.comp_strat) {
                .keep, .summarize => {
                    try w.print("[tool_result {s}{s}]\n{s}\n", .{ result.name, if (result.is_error) " error" else "", result.content });
                },
                .truncate => {
                    const kb = result.content.len / 1024;
                    try w.print("[tool_result {s}{s}]\n<truncated tool result. original: {d} kb>\n", .{ result.name, if (result.is_error) " error" else "", kb });
                },
            }
        },
    }
}

fn installCompactedHistory(self: *Agent, summary: []const u8) !void {
    const alloc = self.arena.allocator();
    var next: apt.Chat = .{ .tools = self.chat.tools };

    if (findSystemMessage(&self.chat)) |system| {
        try next.addMessage(alloc, .system, system.parts);
    }

    var recent = std.ArrayList([]const u8).empty;
    var recent_tokens: u64 = 0;
    defer recent.deinit(alloc);

    var i = self.chat.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = self.chat.messages.items[i];
        if (msg.role != .user) continue;
        const text = try userMessageText(alloc, msg);
        if (text.len == 0 or isSummaryMessage(text)) continue;
        const tokens = approxTokens(text.len);
        if (recent_tokens + tokens > RECENT_USER_MAX_TOKENS) break;
        try recent.append(alloc, text);
        recent_tokens += tokens;
    }

    i = recent.items.len;
    while (i > 0) {
        i -= 1;
        try next.addMessage(alloc, .user, &.{.{ .text = recent.items[i] }});
    }

    const summary_text = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ SUMMARY_PREFIX, summary });
    try next.addMessage(alloc, .user, &.{.{ .text = summary_text }});

    self.chat = next;

    const file_stats = self.file_stats.lock(self.pool.io);
    defer file_stats.unlock();
    file_stats.ptr.* = .{};
}

fn extractSummaryText(alloc: std.mem.Allocator, parts: []const apt.ContentPart) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (out.written().len > 0) try out.writer.writeByte('\n');
                try out.writer.writeAll(text);
            },
            else => {},
        }
    }

    if (out.written().len == 0) return try alloc.dupe(u8, "(no summary available)");
    return try out.toOwnedSlice();
}

fn userMessageText(alloc: std.mem.Allocator, msg: apt.Message) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    for (msg.parts) |part| {
        switch (part) {
            .text => |text| {
                if (out.written().len > 0) try out.writer.writeByte('\n');
                try out.writer.writeAll(text);
            },
            else => {},
        }
    }

    if (out.written().len == 0) return "";
    return try out.toOwnedSlice();
}

fn isSummaryMessage(text: []const u8) bool {
    return std.mem.startsWith(u8, text, SUMMARY_PREFIX);
}

fn findSystemMessage(chat: *const apt.Chat) ?apt.Message {
    for (chat.messages.items) |msg| {
        if (msg.role == .system) return msg;
    }
    return null;
}
