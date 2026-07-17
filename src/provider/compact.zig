const std = @import("std");
const r = @import("root.zig");
const Agent = r.agent.Agent;
const apt = r.adapter;
const http = r.http;
const responses = r.responses;

const log = std.log.scoped(.compact);

const PROMPT =
    \\You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another agent that will resume the task.
    \\
    \\Include:
    \\- Current progress and key decisions made
    \\- Important context, constraints, or user preferences
    \\- What remains to be done (clear next steps)
    \\- Any critical data, examples, or references needed to continue
    \\
    \\Be concise, structured, and focused on helping the next agent seamlessly continue the work.
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
    const options: apt.CompletionOptions = .{
        .mode = .blocking,
        .session_id = &self.session_id,
        .timeout_ms = COMPACTION_TIMEOUT_MS,
    };
    self.compaction.pending_handle = switch (self.config.provider) {
        .response => responses.compact(self.pool, arena, &self.chat, self.config, options),
        else => blk: {
            var compact_chat = try buildCompactPrompt(arena, &self.chat);
            compact_chat.tools = .empty;
            break :blk apt.complete(self.pool, arena, &compact_chat, self.config, options);
        },
    } catch |err| switch (err) {
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
    var handle_released = false;
    defer if (!handle_released) self.pool.release(handle);

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

    var usage: ?apt.TokenUsage = null;
    var response_items: ?[]const []const u8 = null;
    var summary: ?[]const u8 = null;
    switch (self.config.provider) {
        .response => {
            const result = try responses.parseCompactResponse(arena, body);
            usage = result.usage;
            response_items = result.items;
        },
        else => {
            const result = try apt.parseCompletion(arena, self.config, body);
            usage = result.usage;
            summary = try extractSummaryText(arena, result.message.parts);
        },
    }

    if (usage) |value| {
        self.total_usage.add(value);
        if (self.swarm) |swarm| swarm.recordUsage(self.config.model, value);
    }

    self.pool.release(handle);
    handle_released = true;
    self.compaction.pending_handle = null;
    if (response_items) |items|
        try installResponseHistory(self, items)
    else
        try installCompactedHistory(self, summary.?);

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
    return estimate >= autoCompactLimit(self);
}

fn autoCompactLimit(self: *const Agent) u64 {
    return (@as(u64, self.context_limit) * AUTO_COMPACT_NUMERATOR) / AUTO_COMPACT_DENOMINATOR;
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
        for (msg.provider_items) |item| bytes += item.len;
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
    var next_arena = r.ThreadSafeArena.init(self.gpa, self.pool.io);
    errdefer next_arena.deinit();
    const alloc = next_arena.allocator();
    var next: apt.Chat = .{};

    for (self.chat.tools.items) |tool| try next.tools.append(alloc, .{
        .name = try alloc.dupe(u8, tool.name),
        .description = try alloc.dupe(u8, tool.description),
        .parameters_schema = try alloc.dupe(u8, tool.parameters_schema),
    });

    if (findSystemMessage(&self.chat)) |system| {
        try appendClonedMessage(&next, alloc, system);
    }

    var recent = std.ArrayList([]const u8).empty;
    var recent_tokens: u64 = 0;
    defer recent.deinit(alloc);

    var i = self.chat.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = self.chat.messages.items[i];
        if (msg.role != .user) continue;
        const text = try userMessageText(self.arena.allocator(), msg);
        if (text.len == 0 or isSummaryMessage(text)) continue;
        const tokens = approxTokens(text.len);
        if (recent_tokens + tokens > RECENT_USER_MAX_TOKENS) break;
        try recent.append(alloc, text);
        recent_tokens += tokens;
    }

    i = recent.items.len;
    while (i > 0) {
        i -= 1;
        try next.addMessage(alloc, .user, &.{.{ .text = try alloc.dupe(u8, recent.items[i]) }});
    }

    const summary_text = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ SUMMARY_PREFIX, summary });
    try next.addMessage(alloc, .user, &.{.{ .text = summary_text }});

    const next_tools = try self.tools.clone(alloc);
    const next_todos = try cloneTodos(self, alloc);
    const next_bg_tasks = try cloneBackgroundTasks(self, alloc);
    const next_bg_agents = try cloneBackgroundAgents(self, alloc);

    var old_arena = self.arena;
    self.arena = next_arena;
    self.chat = next;
    self.tools = next_tools;
    self.todo_list.value = next_todos;
    self.bg_tasks.value = next_bg_tasks;
    self.bg_agents.value = next_bg_agents;
    self.tool_display.value = .{};
    self.tool_call_runs = .{};
    self.tool_call_done = .{};
    self.loop_guard = .{};
    old_arena.deinit();

    const file_stats = self.file_stats.lock(self.pool.io);
    defer file_stats.unlock();
    file_stats.ptr.* = .{};
}

fn installResponseHistory(self: *Agent, items: []const []const u8) !void {
    var next_arena = r.ThreadSafeArena.init(self.gpa, self.pool.io);
    errdefer next_arena.deinit();
    const alloc = next_arena.allocator();
    var next: apt.Chat = .{};

    for (self.chat.tools.items) |tool| try next.tools.append(alloc, .{
        .name = try alloc.dupe(u8, tool.name),
        .description = try alloc.dupe(u8, tool.description),
        .parameters_schema = try alloc.dupe(u8, tool.parameters_schema),
    });
    if (findSystemMessage(&self.chat)) |system| try appendClonedMessage(&next, alloc, system);

    const cloned = try alloc.alloc([]const u8, items.len);
    for (items, 0..) |item, i| cloned[i] = try alloc.dupe(u8, item);
    try next.messages.append(alloc, .{
        .role = .agent,
        .parts = &.{},
        .provider_items = cloned,
    });

    const next_tools = try self.tools.clone(alloc);
    const next_todos = try cloneTodos(self, alloc);
    const next_bg_tasks = try cloneBackgroundTasks(self, alloc);
    const next_bg_agents = try cloneBackgroundAgents(self, alloc);

    var old_arena = self.arena;
    self.arena = next_arena;
    self.chat = next;
    self.tools = next_tools;
    self.todo_list.value = next_todos;
    self.bg_tasks.value = next_bg_tasks;
    self.bg_agents.value = next_bg_agents;
    self.tool_display.value = .{};
    self.tool_call_runs = .{};
    self.tool_call_done = .{};
    self.loop_guard = .{};
    old_arena.deinit();

    const file_stats = self.file_stats.lock(self.pool.io);
    defer file_stats.unlock();
    file_stats.ptr.* = .{};
}

fn appendClonedMessage(chat: *apt.Chat, alloc: std.mem.Allocator, message: apt.Message) !void {
    const cloned = try message.clone(alloc);
    try chat.messages.append(alloc, cloned);
}

fn cloneTodos(self: *Agent, alloc: std.mem.Allocator) !r.agent.TodoList {
    const guard = self.todo_list.lock(self.pool.io);
    defer guard.unlock();
    var next = guard.ptr.*;
    for (next.todos[0..next.count]) |*todo| {
        todo.subject = try alloc.dupe(u8, todo.subject);
        todo.description = try alloc.dupe(u8, todo.description);
    }
    return next;
}

fn cloneBackgroundTasks(self: *Agent, alloc: std.mem.Allocator) !r.agent.BackgroundTaskList {
    const guard = self.bg_tasks.lock(self.pool.io);
    defer guard.unlock();
    var next: r.agent.BackgroundTaskList = .{};
    for (guard.ptr.list.items) |task| try next.list.append(alloc, .{
        .handle = task.handle,
        .command = try alloc.dupe(u8, task.command),
        .path = try alloc.dupe(u8, task.path),
    });
    return next;
}

fn cloneBackgroundAgents(self: *Agent, alloc: std.mem.Allocator) !r.agent.BackgroundAgentList {
    const guard = self.bg_agents.lock(self.pool.io);
    defer guard.unlock();
    var next: r.agent.BackgroundAgentList = .{};
    for (guard.ptr.list.items) |agent| try next.list.append(alloc, .{
        .agent_id = agent.agent_id,
        .description = try alloc.dupe(u8, agent.description),
        .status = agent.status,
    });
    return next;
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

test "compaction rotates the agent arena without an API request" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var pool: http.RequestPool = .{};
    try pool.init(gpa.allocator(), testing.io);
    defer pool.deinit();

    var agent = Agent.new(.{
        .api_key = "test",
        .model = "test",
        .base_url = "https://example.test",
        .provider = .{ .openai = .{} },
    }, &pool, gpa.allocator(), 0, 0);
    defer agent.deinit();

    const old_alloc = agent.arena.allocator();
    try agent.chat.addMessage(old_alloc, .system, &.{.{ .text = "system" }});
    try agent.chat.addMessage(old_alloc, .user, &.{.{ .text = "keep me" }});
    try agent.chat.addTool(old_alloc, .{
        .name = try old_alloc.dupe(u8, "dynamic"),
        .description = try old_alloc.dupe(u8, "dynamic tool"),
        .parameters_schema = try old_alloc.dupe(u8, "{\"type\":\"object\"}"),
    });
    _ = try old_alloc.alloc(u8, 1024 * 1024);
    const before = gpa.total_requested_bytes;

    try installCompactedHistory(&agent, "summary");

    try testing.expect(gpa.total_requested_bytes < before);
    try testing.expectEqual(@as(usize, 3), agent.chat.messages.items.len);
    try testing.expectEqualStrings("system", agent.chat.messages.items[0].parts[0].text);
    try testing.expectEqualStrings("keep me", agent.chat.messages.items[1].parts[0].text);
    try testing.expect(std.mem.endsWith(u8, agent.chat.messages.items[2].parts[0].text, "summary"));
    const schema = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        agent.chat.tools.items[0].parameters_schema,
        .{},
    );
    defer schema.deinit();
}

test "auto compaction ignores maximum output tokens" {
    const testing = std.testing;
    var pool: http.RequestPool = .{};
    try pool.init(testing.allocator, testing.io);
    defer pool.deinit();

    var agent = Agent.new(.{
        .api_key = "test",
        .model = "test",
        .base_url = "https://example.test",
        .provider = .{ .openai = .{ .max_tokens = 32_000 } },
    }, &pool, testing.allocator, 0, 0);
    defer agent.deinit();

    const alloc = agent.arena.allocator();
    for (0..4) |_| try agent.chat.addMessage(alloc, .user, &.{.{ .text = "" }});
    agent.context_limit = 100_000;

    try testing.expect(!shouldStart(&agent, 89_999));
    try testing.expect(shouldStart(&agent, 90_000));
}

test "responses compaction installs canonical output and rotates arena" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var pool: http.RequestPool = .{};
    try pool.init(gpa.allocator(), testing.io);
    defer pool.deinit();
    var agent = Agent.new(.{
        .api_key = "test",
        .model = "test",
        .base_url = "https://example.test",
        .provider = .{ .response = .{} },
    }, &pool, gpa.allocator(), 0, 0);
    defer agent.deinit();

    const alloc = agent.arena.allocator();
    try agent.chat.addMessage(alloc, .system, &.{.{ .text = "system" }});
    _ = try alloc.alloc(u8, 1024 * 1024);
    const before = gpa.total_requested_bytes;
    try installResponseHistory(&agent, &.{
        "{\"type\":\"message\",\"role\":\"user\",\"content\":\"retained\"}",
        "{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}",
    });

    try testing.expect(gpa.total_requested_bytes < before);
    try testing.expectEqual(@as(usize, 2), agent.chat.messages.items.len);
    try testing.expectEqualStrings("system", agent.chat.messages.items[0].parts[0].text);
    try testing.expectEqual(@as(usize, 2), agent.chat.messages.items[1].provider_items.len);
    try testing.expect(std.mem.indexOf(u8, agent.chat.messages.items[1].provider_items[1], "opaque") != null);
}
