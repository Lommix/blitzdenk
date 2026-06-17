const std = @import("std");
const r = @import("root.zig");
const Swarm = @import("swarm.zig");
const apt = r.adapter;
const http = r.http;
const tc = r.tool;
const compact = r.compact;

const log = std.log.scoped(.agent);

pub const ToolCallDisplay = struct {
    // main status text
    status_text: std.ArrayList(u8) = .empty,
    log: std.ArrayList([]const u8) = .empty,
    child_id: ?Swarm.AgentId = null,
};

pub const AgentPermissionLevel = enum {
    read,
    write,
};

pub const TickResult = enum { idle, pending, complete, failed };
pub const State = enum {
    idle,
    compacting,
    sending_request,
    waiting_response,
    streaming_response,
    executing_tools,
    complete,
    retry_timeout,
    awaiting_pool_slot,
    failed,
};

// Per-agent tool state. Owned by the agent (lives in its arena), mutated by
// tool coroutines, peeked at by the UI thread via tryLock. Defined here so
// agent.zig holds typed fields directly instead of a type-erased map.

pub const FileStat = struct {
    last_read: i64,
    last_write: i64,
};
pub const FileStats = std.StringHashMapUnmanaged(FileStat);

pub const BackgroundTask = struct {
    handle: r.exec.CmdPool.Handle,
    command: []const u8,
    path: []const u8,
};

pub const BackgroundTaskList = struct {
    list: std.ArrayList(BackgroundTask) = .empty,
};

pub const BackgroundAgentStatus = enum { running, complete, failed };

pub const BackgroundAgent = struct {
    agent_id: Swarm.AgentId,
    description: []const u8,
    status: BackgroundAgentStatus,
};

pub const BackgroundAgentList = struct {
    list: std.ArrayList(BackgroundAgent) = .empty,
};

pub const TaskState = enum {
    pending,
    in_progress,
    done,

    pub fn fromString(s: []const u8) ?TaskState {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done")) return .done;
        return null;
    }

    pub fn toString(self: TaskState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .done => "done",
        };
    }

    pub fn icon(self: TaskState) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .done => "[x]",
        };
    }
};

pub const Task = struct {
    id: u32,
    subject: []const u8,
    description: []const u8,
    state: TaskState,
};

pub const TaskList = struct {
    pub const max_tasks = 64;
    tasks: [max_tasks]Task = undefined,
    count: usize = 0,
    next_id: u32 = 1,

    pub fn findById(self: *TaskList, id: u32) ?*Task {
        for (self.tasks[0..self.count]) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }
};

pub fn Guard(comptime T: type) type {
    return struct {
        ptr: *T,
        mu: *std.Io.Mutex,
        io: std.Io,

        pub fn unlock(self: @This()) void {
            self.mu.unlock(self.io);
        }
    };
}

pub fn Locked(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T = if (@hasDecl(T, "empty")) .empty else .{},
        mu: std.Io.Mutex = .init,

        pub fn lock(self: *Self, io: std.Io) Guard(T) {
            self.mu.lockUncancelable(io);
            return .{ .ptr = &self.value, .mu = &self.mu, .io = io };
        }

        pub fn tryLock(self: *Self, io: std.Io) ?Guard(T) {
            if (!self.mu.tryLock()) return null;
            return .{ .ptr = &self.value, .mu = &self.mu, .io = io };
        }
    };
}

pub const LoopGuard = struct {
    counts: std.AutoHashMapUnmanaged(u64, u32) = .{},
    warnings: std.StringHashMapUnmanaged(WarningLevel) = .{},

    pub const FIRST_WARNING_AT = 3;
    pub const BLOCK_AT = 6;

    pub const WarningLevel = enum {
        rethink,
        force_rethink,
    };

    pub fn clear(self: *LoopGuard) void {
        self.counts.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();
    }

    pub fn record(self: *LoopGuard, alloc: std.mem.Allocator, call: apt.ToolCall) !u32 {
        const key = callHash(call);
        if (self.counts.getPtr(key)) |count| {
            count.* += 1;
            return count.*;
        }

        try self.counts.put(alloc, key, 1);
        return 1;
    }

    pub fn warningForCount(count: u32) ?WarningLevel {
        if (count >= BLOCK_AT) return .force_rethink;
        if (count == FIRST_WARNING_AT) return .rethink;
        return null;
    }

    fn callHash(call: apt.ToolCall) u64 {
        var hasher = std.hash.Wyhash.init(0);

        var name_len: u64 = call.name.len;
        hasher.update(std.mem.asBytes(&name_len));
        hasher.update(call.name);

        var arguments_len: u64 = call.arguments.len;
        hasher.update(std.mem.asBytes(&arguments_len));
        hasher.update(call.arguments);

        return hasher.final();
    }
};

const loop_guard_rethink_warning =
    "<system_warning>Loop guard: You have called the same tool with identical arguments 3 times. Pause and rethink the approach before repeating it. Consider a different tool, different arguments, or reporting the current findings.</system_warning>";

const loop_guard_force_rethink_warning =
    "<system_warning>Looping error: You have called the same tool with identical arguments 6 times. The tool call was not run. Stop repeating this call, identify why it is not making progress, choose a different approach, or report the blocker/current findings to the user.</system_warning>";

// Fat and juicy
pub const Agent = struct {
    pub const MAX_TOOL_CALLS = tc.MAX_TOOL_CALLS_PER_REQ;
    pub const TIMEOUT_DURATION = 3;
    pub const MAX_RETRIES = 3;
    pub const REQUEST_TIMEOUT_MS: u32 = 60_000;
    pub const MAX_DELTAS_PER_TICK: u32 = 32;
    pub const POOL_BACKOFF_SECONDS: f32 = 0.2;

    /// Cap on deltas consumed per tick so the TUI gets a frame even under
    /// high-throughput streams.
    arena: r.ThreadSafeArena,
    chat: apt.Chat = .{},
    pool: *http.RequestPool,
    config: apt.Config,
    tools: std.ArrayList(tc.Tool) = .empty,
    mode_idx: u8 = 0,
    type_idx: u8 = 0,
    state: State = .idle,
    pending_handle: ?http.RequestPool.RequestHandle = null,
    stream: ?apt.Stream = null,
    iteration: u32 = 0,
    max_iterations: u32 = 100,
    last_error: ?anyerror = null,
    swarm: ?*Swarm = null,
    swarm_id: ?Swarm.AgentId = null,
    depth: u16 = 0,
    file_stats: Locked(FileStats) = .{},
    bg_tasks: Locked(BackgroundTaskList) = .{},
    bg_agents: Locked(BackgroundAgentList) = .{},
    task_list: Locked(TaskList) = .{},
    retry_count: u32 = 0,
    timeout: f32 = 0,
    session_id: [32]u8,
    last_input_context_size: u32 = 0, // track total context size
    context_limit: u32 = 128 * 1024, // everything above 128k context is dump
    compaction: compact.State = .{},
    in_flight_usage: apt.TokenUsage = .{}, // streaming usage
    total_usage: apt.TokenUsage = .{}, // accumulated across turns
    approx_output_bytes: u64 = 0, // byte counter for token approximation
    /// In-flight tool fn coroutines, keyed by call.id. Pointer-stable so
    /// ToolContext.cancel pointers survive map growth.
    tool_call_runs: std.StringHashMapUnmanaged(*tc.RunningTool) = .{},
    /// Settled tool results awaiting commit, keyed by call.id.
    tool_call_done: std.StringHashMapUnmanaged(apt.ToolResult) = .{},
    tool_display_status: std.array_hash_map.String(ToolCallDisplay) = .empty,
    tool_display_mutex: std.Io.Mutex = .init,
    max_allowed_tool_calls: u32 = 64,
    tool_call_count: u32 = 0,
    permission_level: AgentPermissionLevel = .read,
    flags: packed struct {
        force_full_reminder: bool = false,
        is_fork: bool = false,
        turn_has_reminder: bool = false,
        is_thinking: bool = false,
    } = .{},
    loop_guard: LoopGuard = .{},

    pub fn new(
        config: apt.Config,
        pool: *http.RequestPool,
        gpa: std.mem.Allocator,
        agent_type_idx: u8,
        mode_type_idx: u8,
    ) Agent {
        var sid_bytes: [16]u8 = undefined;
        pool.io.random(&sid_bytes);

        return Agent{
            .arena = r.ThreadSafeArena.init(gpa, pool.io),
            .pool = pool,
            .config = config,
            .session_id = std.fmt.bytesToHex(sid_bytes, .lower),
            .type_idx = agent_type_idx,
            .mode_idx = mode_type_idx,
        };
    }

    pub fn reset(self: *Agent) void {
        // Drain any in-flight tool futures before freeing arena memory.
        self.cancel();
        self.chat = .{};
        self.tools = .empty;
        self.state = .idle;
        self.iteration = 0;
        self.last_error = null;
        self.file_stats = .{};
        self.bg_tasks = .{};
        self.bg_agents = .{};
        self.task_list = .{};
        self.retry_count = 0;
        self.timeout = 0;
        self.last_input_context_size = 0;
        self.compaction = .{};
        self.in_flight_usage = .{};
        self.tool_call_runs = .{};
        self.tool_call_done = .{};
        self.tool_display_status = .empty;
        self.tool_call_count = 0;
        self.max_allowed_tool_calls = 64;
        self.loop_guard = .{};
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn setTools(self: *Agent, tools: []const tc.Tool) !void {
        self.chat.tools.items.len = 0;
        self.tools.clearRetainingCapacity();

        const alloc = self.arena.allocator();
        for (tools) |tool| {
            try self.tools.append(alloc, tool);
            try self.chat.addTool(alloc, tool.def);
        }
    }

    pub fn setSystemPrompt(self: *Agent, prompt: []const u8) !void {
        try self.chat.setSystemPrompt(self.arena.allocator(), prompt);
    }

    pub fn deinit(self: *const Agent) void {
        self.arena.deinit();
    }

    pub fn runWithMsg(self: *Agent, parts: []const apt.ContentPart) void {
        self.chat.addMessage(self.arena.allocator(), .user, parts) catch {};
        self.run();
    }

    pub fn run(self: *Agent) void {
        self.state = .sending_request;
        self.iteration = 0;
        self.retry_count = 0;
        self.last_error = null;
        self.loop_guard.clear();
    }

    pub fn retry(self: *Agent) void {
        self.state = .sending_request;
        self.retry_count = 0;
        self.last_error = null;
    }

    pub fn requestCompaction(self: *Agent) void {
        if ((self.state == .idle or self.state == .complete) and
            self.compaction.must_progress_past_message_count != 0 and
            self.chat.messages.items.len <= self.compaction.must_progress_past_message_count)
        {
            return;
        }
        compact.request(self, .external);
        if (self.state == .idle or self.state == .complete) {
            self.compaction.continue_after = false;
            self.state = .sending_request;
        }
    }

    pub fn tick(self: *Agent, dt: f32, ctx: r.Swarm.SwarmContextV) TickResult {
        switch (self.state) {
            .idle => return .idle,
            .compacting => {
                const continue_after = self.compaction.continue_after;
                const done = compact.poll(self) catch |err| return self.fail(err);
                if (done) {
                    if (continue_after) {
                        self.state = .sending_request;
                    } else if (self.popQueuedParts(ctx)) |queued_parts| {
                        self.chat.addMessage(self.arena.allocator(), .user, queued_parts) catch |err| return self.fail(err);
                        self.iteration = 0;
                        self.retry_count = 0;
                        self.last_error = null;
                        self.state = .sending_request;
                    } else {
                        self.state = .complete;
                    }
                }
                return .pending;
            },
            .retry_timeout => {
                if (self.retry_count >= MAX_RETRIES) return self.fail(self.last_error orelse error.TimeoutReached);

                self.timeout += dt;
                if (self.timeout > TIMEOUT_DURATION) {
                    self.timeout = 0;
                    self.state = .sending_request;
                }

                return .pending;
            },
            .sending_request => {
                while (self.popQueuedParts(ctx)) |queued_parts| {
                    self.chat.addMessage(self.arena.allocator(), .user, queued_parts) catch |err| return self.fail(err);
                    self.iteration = 0;
                    self.retry_count = 0;
                    self.last_error = null;
                }

                if (compact.maybeStart(self) catch |err| return self.fail(err)) {
                    return .pending;
                }

                if (!self.flags.turn_has_reminder) {
                    ctx.gen_system_reminders(ctx.ptr, self);
                    self.flags.turn_has_reminder = true;
                }

                self.pending_handle = apt.complete(
                    self.pool,
                    self.arena.allocator(),
                    &self.chat,
                    self.config,
                    .{
                        .mode = .streaming,
                        .session_id = &self.session_id,
                        .timeout_ms = REQUEST_TIMEOUT_MS,
                    },
                ) catch |err| switch (err) {
                    // Pool is full — this is backpressure, not failure. Wait
                    // and retry without consuming a retry budget.
                    error.PoolExhausted => {
                        self.state = .awaiting_pool_slot;
                        self.timeout = 0;
                        return .pending;
                    },
                    else => return self.fail(err),
                };
                self.state = .waiting_response;
                return .pending;
            },
            .awaiting_pool_slot => {
                self.timeout += dt;
                if (self.timeout >= POOL_BACKOFF_SECONDS) {
                    self.timeout = 0;
                    self.state = .sending_request;
                }
                return .pending;
            },
            .waiting_response => {
                const handle = self.pending_handle.?;
                if (!self.pool.headersReady(handle)) return .pending;

                self.startStreaming() catch |err| {
                    if (self.pending_handle) |h| {
                        self.pool.cancel(h);
                        self.pending_handle = null;
                    }
                    if (self.retry_count < MAX_RETRIES) {
                        self.retry_count += 1;
                        self.last_error = err;
                        self.state = .retry_timeout;
                        self.timeout = 0;
                        return .pending;
                    }
                    return self.fail(err);
                };
                return .pending;
            },
            .streaming_response => {
                const outcome = self.pumpStream(ctx) catch |err| {
                    if (self.pending_handle) |h| {
                        self.pool.cancel(h);
                        self.pending_handle = null;
                    }
                    self.stream = null;
                    if (self.retry_count < MAX_RETRIES) {
                        self.retry_count += 1;
                        self.last_error = err;
                        self.state = .retry_timeout;
                        self.timeout = 0;
                        return .pending;
                    }
                    return self.fail(err);
                };
                self.retry_count = 0;
                return outcome;
            },
            .executing_tools => {
                const all_settled = self.tickToolCalls(ctx) catch |err| return self.fail(err);
                if (all_settled) {
                    const should_exit = self.commitSettledResults(ctx) catch |err| return self.fail(err);
                    self.flags.turn_has_reminder = false;

                    if (should_exit) {
                        self.state = .complete;
                        return .complete;
                    }

                    self.iteration += 1;
                    if (self.iteration >= self.max_iterations) {
                        self.state = .failed;
                        self.last_error = error.MaxIterationsReached;
                        return .failed;
                    }

                    self.state = .sending_request;
                }
                return .pending;
            },
            .complete => return .complete,
            .failed => return .failed,
        }
    }

    /// 0 - 100%
    pub fn getContextPercent(self: *const Agent) f32 {
        const cs: f32 = @floatFromInt(self.last_input_context_size);
        const limit: f32 = @floatFromInt(self.context_limit);

        return (cs / limit) * 100;
    }

    fn fail(self: *Agent, err: ?anyerror) TickResult {
        self.last_error = err;
        self.state = .failed;
        return .failed;
    }

    pub fn cancel(self: *Agent) void {
        if (self.pending_handle) |h| {
            self.pool.cancel(h);
            self.pending_handle = null;
        }
        if (self.compaction.pending_handle) |h| {
            self.pool.cancel(h);
            self.compaction.resetInFlight();
        }
        self.stream = null;

        // Mark all running tools as canceled, wake any pending permission
        // events so their workers observe the cancel flag and unwind, then
        // drain each future so the worker thread exits before we proceed.
        var rit = self.tool_call_runs.iterator();
        while (rit.next()) |en| en.value_ptr.*.cancel.store(true, .release);

        // cleanup somewhere
        // if (self.swarm) |sw| sw.wakeAllPermissions();

        var dit = self.tool_call_runs.iterator();
        while (dit.next()) |en| _ = en.value_ptr.*.fut.cancel(self.pool.io);
        self.tool_call_runs.clearRetainingCapacity();
        self.tool_call_done.clearRetainingCapacity();
        self.loop_guard.warnings.clearRetainingCapacity();

        if (self.state == .streaming_response and self.chat.messages.items.len > 0) {
            _ = self.chat.messages.pop();
        }

        self.in_flight_usage = .{};
        self.compaction.resetInFlight();
        self.state = .complete;
    }

    fn startStreaming(self: *Agent) !void {
        const handle = self.pending_handle.?;
        const status = self.pool.getStatus(handle) catch |err| {
            const alloc = self.arena.allocator();
            const msg = std.fmt.allocPrint(alloc, "Request error: {s}", .{@errorName(err)}) catch "Request error";
            self.chat.addMessage(alloc, .user, &.{.{ .text = msg }}) catch {};
            self.pool.cancel(handle);
            self.pending_handle = null;
            return err;
        };
        const status_code: u16 = @intFromEnum(status);

        if (status_code < 200 or status_code >= 300) {
            // Drain body for error diagnostics.
            const alloc = self.arena.allocator();
            const body = self.pool.collectBody(handle, alloc) catch &.{};
            const snippet = body[0..@min(body.len, 2048)];
            log.warn("http {d} from provider: {s}", .{ status_code, snippet });
            const msg = std.fmt.allocPrint(alloc, "API Error (HTTP {d}): {s}", .{ status_code, snippet }) catch "API Error";
            self.chat.addMessage(alloc, .user, &.{.{ .text = msg }}) catch {};
            self.pool.cancel(handle);
            self.pending_handle = null;
            return error.EmptyResponse;
        }

        const arena = self.arena.allocator();
        _ = try self.chat.beginStreamingMessage(arena, .agent);
        self.stream = apt.openStream(self.pool, handle, arena, std.meta.activeTag(self.config.provider));
        self.flags.is_thinking = false;
        self.in_flight_usage = .{};
        self.approx_output_bytes = 0;
        self.state = .streaming_response;
    }

    /// Index of the in-progress streaming message. Valid while state is
    /// .streaming_response; the message is always the last appended.
    pub fn streamingMessageIndex(self: *const Agent) ?usize {
        if (self.state != .streaming_response) return null;
        if (self.chat.messages.items.len == 0) return null;
        return self.chat.messages.items.len - 1;
    }

    fn pumpStream(self: *Agent, ctx: Swarm.SwarmContextV) !TickResult {
        const arena = self.arena.allocator();
        if (self.stream == null) return error.NoStream;
        const stream = &self.stream.?;
        const msg_idx = self.chat.messages.items.len - 1;

        var consumed: u32 = 0;
        while (consumed < MAX_DELTAS_PER_TICK) : (consumed += 1) {
            const maybe = stream.next() catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => |e| return e,
            };
            const delta = maybe orelse {
                // Stream exhausted without explicit finish. Treat as finish.
                return self.finishStream(ctx);
            };

            switch (delta) {
                .text_chunk => |t| {
                    try self.chat.appendTextChunk(arena, msg_idx, t);
                    self.approx_output_bytes += t.len;
                    self.in_flight_usage.output_tokens = self.approx_output_bytes / 3;
                    self.flags.is_thinking = false;
                },
                .thinking_chunk => |t| {
                    try self.chat.appendThinkingChunk(arena, msg_idx, t);
                    self.approx_output_bytes += t.len;
                    self.in_flight_usage.output_tokens = self.approx_output_bytes / 3;
                    self.flags.is_thinking = true;
                },
                .tool_call_start, .tool_input_delta => {
                    // Nothing to render incrementally — final parts come from finalize.
                },
                .usage => |u| {
                    self.in_flight_usage = u;
                    // True prompt size = uncached + cache_read + cache_creation.
                    // Anthropic reports `input_tokens` as uncached-only once cache hits,
                    // so using it alone makes CTX% appear to shrink across turns.
                    const total = u.input_tokens + u.cached_tokens + u.cache_creation_tokens;
                    self.last_input_context_size = @intCast(@min(total, std.math.maxInt(u32)));
                },
                .finish => return self.finishStream(ctx),
            }
        }
        return .pending;
    }

    fn finishStream(self: *Agent, _: Swarm.SwarmContextV) !TickResult {
        self.flags.is_thinking = false;
        const arena = self.arena.allocator();
        if (self.stream == null) return error.NoStream;
        const stream = &self.stream.?;
        const msg_idx = self.chat.messages.items.len - 1;

        const result = try stream.finalize();
        try self.chat.finalizeStreamingMessage(arena, msg_idx, result.message.parts);

        if (self.swarm) |swarm| {
            // Prefer finalize's authoritative usage; fall back to last in-flight
            // value if the provider didn't report it on close.
            const final_usage = result.usage orelse self.in_flight_usage;
            self.total_usage.add(final_usage);
            swarm.token_stats.add(final_usage);
            if (self.swarm_id) |id| {
                swarm.recordBroadcast(id, result.message.role, result.message.parts);
            }
        }
        self.in_flight_usage = .{};
        self.stream = null;

        if (self.pending_handle) |h| {
            self.pool.cancel(h);
            self.pending_handle = null;
        }

        var has_tool_calls = false;
        for (result.message.parts) |part| {
            switch (part) {
                .tool_call => {
                    has_tool_calls = true;
                    break;
                },
                else => {},
            }
        }

        if (has_tool_calls) {
            self.state = .executing_tools;
            return .pending;
        }

        self.state = .complete;
        return .complete;
    }

    fn popQueuedParts(self: *Agent, ctx: Swarm.SwarmContextV) ?[]const apt.ContentPart {
        return ctx.pop_queued_message(ctx.ptr, self.swarm_id.?, self.arena.allocator());
    }

    fn appendPartsToLastMessage(self: *Agent, parts: []const apt.ContentPart) !void {
        if (parts.len == 0) return;
        if (self.chat.messages.items.len == 0) return error.NoMessage;

        const alloc = self.arena.allocator();
        const msg = &self.chat.messages.items[self.chat.messages.items.len - 1];
        const appended = try alloc.alloc(apt.ContentPart, msg.parts.len + parts.len);
        @memcpy(appended[0..msg.parts.len], msg.parts);
        @memcpy(appended[msg.parts.len..], parts);
        msg.parts = appended;
    }

    fn runToolWrapper(
        func: tc.ToolFn,
        ctx: tc.ToolContext,
        call: apt.ToolCall,
        done: *std.atomic.Value(bool),
    ) apt.ToolResult {
        defer done.store(true, .release);
        return func(ctx, call);
    }

    fn tickToolCalls(self: *Agent, ctx: Swarm.SwarmContextV) !bool {
        _ = ctx; // autofix
        const last_msg = self.chat.lastMessage() orelse {
            self.state = .failed;
            return error.NoMessage;
        };

        const swarm = self.swarm orelse return error.NoSwarm;
        const self_id = self.swarm_id orelse return error.NoSwarm;
        const alloc = self.arena.allocator();

        var all_settled = true;

        for (last_msg.parts) |part| {
            const call = switch (part) {
                .tool_call => |c| c,
                else => continue,
            };

            // Already settled this turn?
            if (self.tool_call_done.contains(call.id)) continue;

            // Already running?
            if (self.tool_call_runs.get(call.id)) |slot| {
                if (slot.done.load(.acquire)) {
                    const result = slot.fut.await(self.pool.io);
                    // TODO: emit event_bus.tool_call_complete — needs event bus accessible from Agent
                    try self.tool_call_done.put(alloc, call.id, result);
                    _ = self.tool_call_runs.remove(call.id);
                } else {
                    all_settled = false;
                }
                continue;
            }

            const loop_count = try self.loop_guard.record(alloc, call);
            if (LoopGuard.warningForCount(loop_count)) |warning| {
                try self.loop_guard.warnings.put(alloc, call.id, warning);
                if (warning == .force_rethink) {
                    try self.tool_call_done.put(alloc, call.id, .{
                        .call_id = call.id,
                        .name = call.name,
                        .content = loop_guard_force_rethink_warning,
                        .is_error = true,
                    });
                    continue;
                }
            }

            // Tool-call budget gate.
            if (self.tool_call_count >= self.max_allowed_tool_calls) {
                std.log.debug("[TOOLCALL_LIMIT REACHED]", .{});
                try self.tool_call_done.put(alloc, call.id, .{
                    .call_id = call.id,
                    .name = call.name,
                    .content = "!TOOL CALL LIMIT REACHED! Report your current findings back to the user",
                    .is_error = true,
                });
                continue;
            }

            const tool = self.findTool(call.name) orelse {
                try self.tool_call_done.put(alloc, call.id, .{
                    .call_id = call.id,
                    .name = call.name,
                    .content = "Unknown tool",
                    .is_error = true,
                });
                continue;
            };

            const slot = try alloc.create(tc.RunningTool);
            slot.* = .{ .fut = .{ .any_future = null, .result = undefined } };
            const tool_ctx = tc.ToolContext{
                .alloc = alloc,
                .io = self.pool.io,
                .swarm = swarm,
                .self_id = self_id,
                .cancel = &slot.cancel,
                .cwd = swarm.context.cwd(swarm.context.ptr),
            };
            slot.fut = std.Io.async(self.pool.io, runToolWrapper, .{ tool.func, tool_ctx, call, &slot.done });
            // TODO: emit event_bus.tool_call_started — needs event bus accessible from Agent
            try self.tool_call_runs.put(alloc, call.id, slot);
            self.tool_call_count += 1;
            all_settled = false;
        }

        return all_settled;
    }

    fn commitSettledResults(self: *Agent, ctx: Swarm.SwarmContextV) !bool {
        const last_msg = self.chat.lastMessage() orelse return false;
        var results: [MAX_TOOL_CALLS]apt.ToolResult = undefined;
        var count: u32 = 0;
        var exit_loop = false;

        for (last_msg.parts) |part| {
            switch (part) {
                .tool_call => |call| {
                    if (self.tool_call_done.get(call.id)) |result| {
                        if (count < MAX_TOOL_CALLS) {
                            if (result.exit_loop) exit_loop = true;
                            results[count] = result;
                            count += 1;
                        }
                    }
                },
                else => {},
            }
        }

        if (count == 0) return false;

        self.broadcastToolResults(results[0..count]);
        try self.chat.addToolResults(self.arena.allocator(), results[0..count], self.loopGuardWarningForResults(results[0..count]));
        self.tool_call_done.clearRetainingCapacity();
        self.loop_guard.warnings.clearRetainingCapacity();

        if (self.popQueuedParts(ctx)) |queued_parts| {
            try self.appendPartsToLastMessage(queued_parts);
        }

        if (self.tool_call_count >= self.max_allowed_tool_calls) {
            try self.appendPartsToLastMessage(&.{
                .{ .text = "<system_warning>!TOOL CALL LIMIT REACHED! Report your current findings back to the user</system_warning>" },
            });
        }

        return exit_loop;
    }

    fn loopGuardWarningForResults(self: *Agent, results: []const apt.ToolResult) ?[]const u8 {
        var selected: ?LoopGuard.WarningLevel = null;

        for (results) |result| {
            const warning = self.loop_guard.warnings.get(result.call_id) orelse continue;
            if (warning == .force_rethink) return loop_guard_force_rethink_warning;
            selected = warning;
        }

        return switch (selected orelse return null) {
            .rethink => loop_guard_rethink_warning,
            .force_rethink => loop_guard_force_rethink_warning,
        };
    }

    fn broadcastToolResults(self: *Agent, results: []const apt.ToolResult) void {
        const swarm = self.swarm orelse return;
        const id = self.swarm_id orelse return;
        var parts: [MAX_TOOL_CALLS]apt.ContentPart = undefined;
        for (results, 0..) |res, i| {
            parts[i] = .{ .tool_result = res };
        }
        swarm.recordBroadcast(id, .user, parts[0..results.len]);
    }

    fn findTool(self: *Agent, name: []const u8) ?tc.Tool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.def.name, name)) return tool;
        }
        return null;
    }
};
