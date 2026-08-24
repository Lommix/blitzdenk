const std = @import("std");
const sdk = @import("blitz-sdk");
const models = @import("models");
const agent_run = @import("agent_run.zig");
const compact = @import("compact.zig");
pub const state = @import("agent-state");

const PrepareHook = *const fn (?*anyopaque, sdk.options.PrepareStepInfo) anyerror!sdk.options.PrepareStepResult;
const ToolCallHook = *const fn (?*anyopaque, sdk.options.ToolCallInfo) void;
const StopHook = *const fn (?*anyopaque, sdk.options.StopInfo) bool;

const LifetimeHooks = struct {
    reminder: ?*const fn (?*anyopaque, *Agent) anyerror!?[]const u8 = null,
    reminder_ctx: ?*anyopaque = null,
    refresh_tools: ?*const fn (?*anyopaque, *Agent) anyerror!void = null,
    refresh_tools_ctx: ?*anyopaque = null,
};

const RunHooks = struct {
    prepare: ?PrepareHook = null,
    prepare_ctx: ?*anyopaque = null,
    tool_call: ?ToolCallHook = null,
    tool_call_ctx: ?*anyopaque = null,
    stop: ?StopHook = null,
    stop_ctx: ?*anyopaque = null,
};

pub const Status = enum {
    idle,
    running,
    retrying,
    compacting,
    complete,
    failed,
    canceled,
};

pub const Activity = enum { idle, thinking, writing, calling, retrying };

pub const Identity = struct {
    type_idx: u8 = 0,
    name: []const u8 = "",
    parent: ?u32 = null,
    depth: u16 = 0,
    cwd: []const u8 = "",
};

pub const InitOptions = struct {
    identity: Identity = .{},
    context_limit: u64 = 128 * 1024,
};

pub const Flags = struct {
    cwd_seen: bool = false,
    cancel: bool = false,
    overflow_recovery: bool = false,
};

pub const Agent = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    model: models.Model,
    metadata: std.heap.ArenaAllocator,
    tool_arena: std.heap.ArenaAllocator,
    error_arena: std.heap.ArenaAllocator,
    injection_arena: std.heap.ArenaAllocator,
    state_arena: std.heap.ArenaAllocator,
    injection_mutex: std.Io.Mutex = .init,
    queued_messages: std.ArrayList(sdk.Message) = .empty,
    tool_display: state.Locked(std.StringHashMapUnmanaged(state.ToolDisplay)) = .{},
    compaction: compact.State = .{},
    messages: ?agent_run.OwnedMessages = null,
    tools: []const sdk.Tool = &.{},
    flags: Flags = .{},
    type_idx: u8,
    name: []const u8,
    parent: ?u32,
    depth: u16,
    background: bool = false,
    cwd: []const u8,
    system_prompt: []const u8 = "",
    skill_catalog_digest: ?u64 = null,
    usage: sdk.Usage = .{},
    context_tokens: u64 = 0,
    context_limit: u64,
    status: Status = .idle,
    activity: Activity = .idle,
    last_error: ?anyerror = null,
    last_provider_error: ?agent_run.ProviderError = null,
    retry_count: u32 = 0,
    max_retries: u32 = 10,
    retry_delay_ms: u64 = 10_000,
    retry_at_ns: i128 = 0,
    run_started_ns: i128 = 0,
    run_ended_ns: i128 = 0,
    stream_started_ns: i128 = 0,
    stream_output_bytes: u64 = 0,
    tokens_per_second: f32 = 0,
    stop_requested: std.atomic.Value(bool) = .init(false),
    lifetime: LifetimeHooks = .{},
    run_hooks: RunHooks = .{},
    tools_dirty: std.atomic.Value(bool) = .init(false),
    task: ?agent_run.RunTask = null,
    compact_task: ?compact.Task = null,
    resume_options: ?agent_run.OwnedOptions = null,
    run_model: ?sdk.LanguageModel = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, config: models.Config, options: InitOptions) !Agent {
        var model = try models.Model.init(alloc, config);
        errdefer model.deinit(alloc);
        return initModel(alloc, io, model, options);
    }

    fn initModel(alloc: std.mem.Allocator, io: std.Io, model: models.Model, options: InitOptions) !Agent {
        var metadata = std.heap.ArenaAllocator.init(alloc);
        errdefer metadata.deinit();
        const name = try metadata.allocator().dupe(u8, options.identity.name);
        const cwd = try metadata.allocator().dupe(u8, options.identity.cwd);
        return .{
            .alloc = alloc,
            .io = io,
            .model = model,
            .metadata = metadata,
            .tool_arena = std.heap.ArenaAllocator.init(alloc),
            .error_arena = std.heap.ArenaAllocator.init(alloc),
            .injection_arena = std.heap.ArenaAllocator.init(alloc),
            .state_arena = .init(alloc),
            .type_idx = options.identity.type_idx,
            .name = name,
            .parent = options.identity.parent,
            .depth = options.identity.depth,
            .cwd = cwd,
            .context_limit = options.context_limit,
        };
    }

    pub fn fork(self: *const Agent, parent: u32) !Agent {
        var model = try self.model.clone(self.alloc);
        errdefer model.deinit(self.alloc);
        var child = try initModel(self.alloc, self.io, model, .{
            .identity = .{
                .type_idx = self.type_idx,
                .name = self.name,
                .parent = parent,
                .depth = self.depth + 1,
                .cwd = self.cwd,
            },
            .context_limit = self.context_limit,
        });
        errdefer child.deinit();
        try child.setSystemPrompt(self.system_prompt);
        var prior_messages = self.history();
        if (prior_messages.len > 0 and hasToolCall(prior_messages[prior_messages.len - 1])) prior_messages = prior_messages[0 .. prior_messages.len - 1];
        try child.setMessages(prior_messages);
        try child.setTools(self.tools);
        return child;
    }

    pub fn deinit(self: *Agent) void {
        if (self.resume_options) |*options| options.deinit();
        if (self.compact_task) |*task| task.deinit();
        if (self.task) |*task| task.deinit();
        if (self.messages) |*messages| messages.deinit();
        self.model.deinit(self.alloc);
        self.state_arena.deinit();
        self.injection_arena.deinit();
        self.error_arena.deinit();
        self.tool_arena.deinit();
        self.metadata.deinit();
        self.* = undefined;
    }

    pub fn setMessages(self: *Agent, messages: []const sdk.Message) !void {
        if (self.task != null) return error.RunInProgress;
        const owned = try agent_run.OwnedMessages.clone(self.alloc, messages);
        if (self.messages) |*previous| previous.deinit();
        self.messages = owned;
    }

    pub fn setSystemPrompt(self: *Agent, prompt: []const u8) !void {
        self.system_prompt = try self.metadata.allocator().dupe(u8, prompt);
    }

    pub fn setCwd(self: *Agent, cwd: []const u8) !void {
        self.cwd = try self.metadata.allocator().dupe(u8, cwd);
        self.flags.cwd_seen = false;
    }

    pub fn setTools(self: *Agent, tools: []const sdk.Tool) !void {
        if (self.task != null) return error.RunInProgress;
        try self.setToolsLive(tools);
    }

    pub fn setToolsLive(self: *Agent, tools: []const sdk.Tool) !void {
        _ = self.tool_arena.reset(.free_all);
        self.tools = &.{};
        const alloc = self.tool_arena.allocator();
        const cloned = try alloc.alloc(sdk.Tool, tools.len);
        for (tools, 0..) |tool, i| cloned[i] = .{
            .name = try alloc.dupe(u8, tool.name),
            .description = try alloc.dupe(u8, tool.description),
            .input_schema = try alloc.dupe(u8, tool.input_schema),
            .execute = tool.execute,
            .execute_ctx = tool.execute_ctx,
        };
        self.tools = cloned;
    }

    pub fn markToolsDirty(self: *Agent) void {
        self.tools_dirty.store(true, .release);
    }

    pub fn history(self: *const Agent) []const sdk.Message {
        return if (self.messages) |messages| messages.messages else &.{};
    }

    pub fn queueMessages(self: *Agent, messages: []const sdk.Message) !void {
        self.injection_mutex.lockUncancelable(self.io);
        defer self.injection_mutex.unlock(self.io);
        if (self.queued_messages.items.len == 0) {
            _ = self.injection_arena.reset(.free_all);
            self.queued_messages = .empty;
        }
        const alloc = self.injection_arena.allocator();
        const cloned = try agent_run.cloneMessages(alloc, messages);
        try self.queued_messages.appendSlice(alloc, cloned);
    }

    pub fn queueReminder(self: *Agent, text: []const u8) !void {
        try self.queueMessages(&.{sdk.UserMessage(text)});
    }

    pub fn start(self: *Agent, options: sdk.GenerateOptions) !void {
        if (self.resume_options) |*previous| previous.deinit();
        self.resume_options = try agent_run.OwnedOptions.clone(self.alloc, options);
        errdefer {
            self.resume_options.?.deinit();
            self.resume_options = null;
        }
        self.flags.overflow_recovery = false;
        try self.startModel(self.model.languageModel(), options);
    }

    pub fn requestCompaction(self: *Agent, reason: compact.Request, continue_after: bool) void {
        self.compaction.continue_after = continue_after;
        self.compaction.request(reason);
    }

    pub fn startCompaction(self: *Agent) !bool {
        if (self.task != null or self.compact_task != null) return error.RunInProgress;
        const estimate = compact.estimateNextRequestTokens(self.model.languageModel().modelId(), self.tools, self.history());
        self.context_tokens = estimate;
        if (!self.compaction.shouldStart(self.history().len, estimate, self.context_limit)) return false;
        const request = self.compaction.requested.swap(.none, .acq_rel);
        const force = request == .external;
        const cut_index = if (force) compact.computeForcedCutIndex(self.history()) else compact.computeCutIndex(self.history());
        if (cut_index == 0 and self.model != .response) return false;
        self.compaction.completed_continue_after = null;
        self.compaction.estimated_input_tokens = estimate;
        self.compact_task = compact.Task.init(self.alloc, self.io, &self.model, self.tools, self.history(), force);
        self.status = .compacting;
        self.compact_task.?.start();
        return true;
    }

    fn startModel(self: *Agent, model: sdk.LanguageModel, options: sdk.GenerateOptions) !void {
        if (self.task != null) return error.RunInProgress;
        self.run_model = model;
        _ = self.error_arena.reset(.free_all);
        self.last_error = null;
        self.last_provider_error = null;
        self.stop_requested.store(false, .release);
        self.flags.cancel = false;
        self.retry_at_ns = 0;
        self.run_started_ns = @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
        self.run_ended_ns = 0;
        self.endStream();
        var run_options = options;
        if (run_options.system.len == 0) run_options.system = self.system_prompt;
        if (run_options.prompt.len > 0) {
            try self.appendHistory(&.{sdk.UserMessage(run_options.prompt)});
            run_options.prompt = "";
        }
        run_options.messages = self.history();
        run_options.tools = self.tools;
        self.run_hooks = .{
            .prepare = run_options.hooks.on_prepare_step,
            .prepare_ctx = run_options.hooks.on_prepare_step_ctx,
            .tool_call = run_options.hooks.on_tool_call,
            .tool_call_ctx = run_options.hooks.on_tool_call_ctx,
            .stop = run_options.hooks.stop_when,
            .stop_ctx = run_options.hooks.stop_when_ctx,
        };
        run_options.hooks.on_prepare_step = prepareStep;
        run_options.hooks.on_prepare_step_ctx = self;
        run_options.hooks.on_tool_call = toolCall;
        run_options.hooks.on_tool_call_ctx = self;
        run_options.hooks.stop_when = stopWhen;
        run_options.hooks.stop_when_ctx = self;
        self.task = agent_run.RunTask.init(self.alloc, self.io, model, run_options) catch |err| {
            self.clearRunHooks();
            return err;
        };
        self.status = .running;
        self.task.?.start();
    }

    pub fn drain(self: *Agent, max: usize, ctx: ?*anyopaque, handler: *const fn (?*anyopaque, agent_run.Event) void) usize {
        if (self.task) |*task| return task.queue.drain(max, ctx, handler);
        return 0;
    }

    pub fn observe(self: *Agent, event: agent_run.Event) !void {
        switch (event) {
            .text => |text| {
                self.activity = .writing;
                self.recordOutput(text.len);
            },
            .reasoning => |reasoning| {
                self.activity = .thinking;
                self.recordOutput(reasoning.len);
            },
            .tool => |tool| {
                self.activity = .calling;
                self.recordOutput(tool.text.len + tool.tool_input.len + tool.tool_output.len);
            },
            .tool_done => {},
            .step => |step| {
                self.usage.add(step.usage);
                self.context_tokens = step.usage.input_tokens + step.usage.cache_read_tokens + step.usage.cache_write_tokens;
                self.endStream();
            },
            .provider_error => |provider_error| {
                self.endStream();
                _ = self.error_arena.reset(.free_all);
                self.last_provider_error = null;
                self.last_provider_error = .{
                    .status_code = provider_error.status_code,
                    .response_body = try self.error_arena.allocator().dupe(u8, provider_error.response_body),
                    .is_retryable = provider_error.is_retryable,
                    .retry_after_ms = provider_error.retry_after_ms,
                    .will_retry = provider_error.will_retry,
                    .attempt = provider_error.attempt,
                };
                if (provider_error.will_retry) {
                    self.status = .retrying;
                    self.activity = .retrying;
                }
            },
            .complete => {
                self.status = .complete;
                self.activity = .idle;
                self.tokens_per_second = 0;
                self.endStream();
            },
            .failed => |err| {
                self.last_error = err;
                self.status = if (err == error.Canceled) .canceled else .failed;
                self.tokens_per_second = 0;
                self.endStream();
            },
        }
    }

    pub fn reap(self: *Agent) bool {
        if (self.reapCompaction()) return true;
        const task = if (self.task) |*value| value else {
            if (self.status == .canceled) return true;
            return false;
        };
        if (!task.isFinished() or task.queue.count() != 0) return false;
        task.wait();
        const completed = task.result != null;
        const next_messages = if (completed) task.takeMessages() else null;
        const failure = task.failure;
        const is_overflow = if (failure) |err| err == error.ContextOverflow else false;
        const checkpoint = if (!completed) task.takeCheckpoint() else null;
        task.deinit();
        self.task = null;
        self.clearRunHooks();
        if (next_messages) |owned| {
            if (self.messages) |*previous| previous.deinit();
            self.messages = owned;
            self.status = .complete;
            self.last_error = null;
            self.last_provider_error = null;
            self.retry_count = 0;
            self.retry_at_ns = 0;
            self.flags.overflow_recovery = false;
            if (self.resume_options) |*options| options.deinit();
            self.resume_options = null;
        } else {
            const has_checkpoint = checkpoint != null;
            if (checkpoint) |owned| {
                if (self.messages) |*previous| previous.deinit();
                self.messages = owned;
            }
            if (is_overflow and !self.flags.overflow_recovery and has_checkpoint) {
                self.flags.overflow_recovery = true;
                self.requestCompaction(.auto, true);
                if (!(self.startCompaction() catch false)) {
                    self.last_error = error.ContextOverflow;
                    self.status = .failed;
                }
            } else if (failure) |err| {
                self.last_error = err;
                if (self.shouldAutoRetry(err)) {
                    self.scheduleRetry();
                    return true;
                }
                if (self.status != .canceled or !self.flags.cancel) self.status = .failed;
            }
        }
        return true;
    }

    pub fn shouldAutoRetry(self: *const Agent, failure: anyerror) bool {
        return !self.flags.cancel and self.willAutoRetry(failure);
    }

    pub fn willAutoRetry(self: *const Agent, failure: anyerror) bool {
        if (self.retry_count >= self.max_retries) return false;
        if (failure == error.Canceled or failure == error.NetworkError) return true;
        if (failure != error.RateLimited and failure != error.ApiError) return false;
        const provider_error = self.last_provider_error orelse return false;
        return provider_error.is_retryable;
    }

    pub fn retryDue(self: *const Agent) bool {
        if (self.status != .retrying or self.retry_at_ns == 0) return false;
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
        return now >= self.retry_at_ns;
    }

    pub fn retryNow(self: *Agent) !void {
        var options: sdk.GenerateOptions = .{};
        if (self.resume_options) |*opts| options = opts.value;
        options.prompt = "";
        const model = self.run_model orelse self.model.languageModel();
        try self.startModel(model, options);
    }

    fn scheduleRetry(self: *Agent) void {
        self.retry_count += 1;
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
        self.retry_at_ns = now + @as(i128, self.retry_delay_ms) * std.time.ns_per_ms;
        self.status = .retrying;
        self.activity = .retrying;
    }

    pub fn cancel(self: *Agent) void {
        self.flags.cancel = true;
        if (self.compact_task) |*task| task.cancel();
        if (self.task) |*task| task.cancel();
        self.status = .canceled;
    }

    pub fn cancelAndWait(self: *Agent) void {
        self.cancel();
        if (self.compact_task) |*task| {
            task.wait();
            _ = self.reapCompaction();
        }
        const task = if (self.task) |*value| value else return;
        task.wait();
        while (task.queue.drain(64, null, discardEvent) != 0) {}
        _ = self.reap();
    }

    pub fn requestStop(self: *Agent) void {
        self.stop_requested.store(true, .release);
    }

    pub fn contextPercent(self: *const Agent) u8 {
        if (self.context_limit == 0) return 0;
        return @intCast(@min(100, self.context_tokens * 100 / self.context_limit));
    }

    fn prepareStep(ctx: ?*anyopaque, info: sdk.options.PrepareStepInfo) anyerror!sdk.options.PrepareStepResult {
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        self.injection_mutex.lockUncancelable(self.io);
        defer self.injection_mutex.unlock(self.io);
        const upstream = if (self.run_hooks.prepare) |hook|
            try hook(self.run_hooks.prepare_ctx, info)
        else
            sdk.options.PrepareStepResult{};

        var base = upstream.messages;
        var replace = upstream.replace;
        if (!replace) {
            if (self.maybeCompactForStep(info.messages)) |compacted| {
                base = compacted;
                replace = true;
            }
        }

        var refreshed_tools: ?[]const sdk.Tool = null;
        if (self.tools_dirty.swap(false, .acq_rel)) {
            if (self.lifetime.refresh_tools) |hook| {
                hook(self.lifetime.refresh_tools_ctx, self) catch |err| {
                    std.log.scoped(.agent).warn("tool refresh failed: {s}", .{@errorName(err)});
                };
            }
            refreshed_tools = self.tools;
        }

        const reminder = if (info.number > 0)
            if (self.lifetime.reminder) |hook| try hook(self.lifetime.reminder_ctx, self) else null
        else
            null;
        if (self.queued_messages.items.len == 0 and reminder == null) {
            return .{ .messages = base, .replace = replace, .tools = refreshed_tools };
        }
        const alloc = self.injection_arena.allocator();
        const combined = try alloc.alloc(sdk.Message, base.len + self.queued_messages.items.len + @intFromBool(reminder != null));
        @memcpy(combined[0..base.len], base);
        @memcpy(combined[base.len..][0..self.queued_messages.items.len], self.queued_messages.items);
        if (reminder) |text| combined[combined.len - 1] = sdk.UserMessage(text);
        self.queued_messages.clearRetainingCapacity();
        return .{ .messages = combined, .replace = replace, .tools = refreshed_tools };
    }

    fn maybeCompactForStep(self: *Agent, messages: []const sdk.Message) ?[]const sdk.Message {
        const estimate = compact.estimateNextRequestTokens(self.model.languageModel().modelId(), self.tools, messages);
        self.context_tokens = estimate;
        if (!self.compaction.shouldStart(messages.len, estimate, self.context_limit)) return null;
        const request = self.compaction.requested.swap(.none, .acq_rel);
        const force = request == .external;
        const cut_index = if (force) compact.computeForcedCutIndex(messages) else compact.computeCutIndex(messages);
        if (self.model != .response and cut_index == 0) return null;

        self.status = .compacting;
        defer self.status = .running;

        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const cancellation = if (self.task) |*task| &task.cancellation else null;
        var outcome = switch (self.model) {
            .response => |*model| compact.compactResponses(scratch.allocator(), self.io, model, self.tools, messages, cancellation),
            inline else => |*model| compact.compactOrdinary(scratch.allocator(), self.io, model.languageModel(), messages, cancellation, force),
        } catch return null;
        defer outcome.deinit();

        const cloned = agent_run.cloneMessages(self.injection_arena.allocator(), outcome.messages.messages) catch return null;
        self.usage.add(outcome.usage);
        self.context_tokens = compact.estimateNextRequestTokens(self.model.languageModel().modelId(), self.tools, cloned);
        self.compaction.last_compacted_message_count = cloned.len;
        self.compaction.last_compacted_estimate = self.context_tokens;
        self.compaction.must_progress_past_message_count = cloned.len;
        self.compaction.resetInFlight();
        _ = self.compaction.completion_count.fetchAdd(1, .release);
        return cloned;
    }

    fn toolCall(ctx: ?*anyopaque, info: sdk.options.ToolCallInfo) void {
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        if (self.run_hooks.tool_call) |hook| hook(self.run_hooks.tool_call_ctx, info);
    }

    fn stopWhen(ctx: ?*anyopaque, info: sdk.options.StopInfo) bool {
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        if (self.run_hooks.stop) |hook| if (hook(self.run_hooks.stop_ctx, info)) return true;
        return self.stop_requested.load(.acquire);
    }

    fn clearRunHooks(self: *Agent) void {
        self.run_hooks = .{};
        self.stop_requested.store(false, .release);
    }

    fn reapCompaction(self: *Agent) bool {
        const task = if (self.compact_task) |*value| value else return false;
        if (!task.isFinished()) return false;
        const failure = task.failure;
        const outcome = task.takeOutcome();
        task.deinit();
        self.compact_task = null;
        if (outcome) |value| {
            self.compaction.completed_continue_after = self.compaction.continue_after;
            if (self.messages) |*previous| previous.deinit();
            self.messages = value.messages;
            self.usage.add(value.usage);
            self.context_tokens = compact.estimateNextRequestTokens(self.model.languageModel().modelId(), self.tools, self.history());
            self.compaction.last_compacted_message_count = self.history().len;
            self.compaction.last_compacted_estimate = self.context_tokens;
            self.compaction.must_progress_past_message_count = self.history().len;
            self.compaction.resetInFlight();
            _ = self.compaction.completion_count.fetchAdd(1, .release);
            const display = self.tool_display.lock(self.io);
            display.ptr.clearRetainingCapacity();
            display.unlock();
            self.status = .complete;
            self.last_error = null;
            if (self.compaction.completed_continue_after == true and self.resume_options != null) {
                var options = self.resume_options.?.value;
                options.prompt = "";
                self.startModel(self.model.languageModel(), options) catch |err| {
                    self.last_error = err;
                    self.status = .failed;
                };
            }
        } else if (failure) |err| {
            self.compaction.resetInFlight();
            self.last_error = err;
            self.status = if (err == error.Canceled) .canceled else .failed;
        }
        return true;
    }

    fn appendHistory(self: *Agent, messages: []const sdk.Message) !void {
        if (messages.len == 0) return;
        if (self.messages) |*owned| {
            const alloc = owned.arena.allocator();
            const appended = try agent_run.cloneMessages(alloc, messages);
            const combined = try alloc.alloc(sdk.Message, owned.messages.len + appended.len);
            @memcpy(combined[0..owned.messages.len], owned.messages);
            @memcpy(combined[owned.messages.len..], appended);
            owned.messages = combined;
        } else {
            self.messages = try agent_run.OwnedMessages.clone(self.alloc, messages);
        }
    }

    fn recordOutput(self: *Agent, bytes: usize) void {
        self.stream_output_bytes += bytes;
        const now: i128 = @intCast(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
        if (self.stream_started_ns == 0) self.stream_started_ns = now;
        const elapsed = now - self.stream_started_ns;
        const min_ns: i128 = std.time.ns_per_s / 50;
        if (elapsed < min_ns) return;
        const tokens = self.stream_output_bytes / 3;
        const rate: f64 = @as(f64, @floatFromInt(tokens)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(elapsed));
        if (self.tokens_per_second == 0) {
            self.tokens_per_second = @floatCast(rate);
        } else {
            self.tokens_per_second = @floatCast(rate + (self.tokens_per_second - rate) * 0.5);
        }
    }

    fn endStream(self: *Agent) void {
        self.stream_output_bytes = 0;
        self.stream_started_ns = 0;
        self.tokens_per_second = 0;
    }
};

fn discardEvent(_: ?*anyopaque, _: agent_run.Event) void {}

fn hasToolCall(message: sdk.Message) bool {
    if (message.role != .assistant) return false;
    for (message.parts()) |part| if (part == .tool_call) return true;
    return false;
}

test "agent owns SDK state and adopts completed history" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, alloc: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const result = try alloc.create(sdk.model.GenerateResult);
            result.* = .{
                .text = try alloc.dupe(u8, "done"),
                .finish_reason = .stop,
                .usage = .{ .input_tokens = 12, .output_tokens = 3, .total_tokens = 15 },
            };
            return result;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "worker", .cwd = "/tmp", .type_idx = 2 } });
    defer agent.deinit();
    try agent.setMessages(&.{sdk.UserMessage("old")});
    try agent.queueReminder("queued");
    var tool_name = [_]u8{ 'r', 'u', 'n' };
    try agent.setTools(&.{.{ .name = &tool_name }});
    tool_name[0] = 'x';
    try std.testing.expectEqualStrings("run", agent.tools[0].name);
    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var prompt = [_]u8{ 'n', 'e', 'w' };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = &prompt });
    prompt[0] = 'x';
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.complete, agent.status);
    try std.testing.expectEqual(@as(usize, 4), agent.history().len);
    try std.testing.expectEqualStrings("old", agent.history()[0].text());
    try std.testing.expectEqualStrings("new", agent.history()[1].text());
    try std.testing.expectEqualStrings("queued", agent.history()[2].text());
    try std.testing.expectEqualStrings("done", agent.history()[3].text());
    try std.testing.expectEqual(@as(u64, 15), agent.usage.total_tokens);
    try std.testing.expectEqualStrings("worker", agent.name);
    try std.testing.expectEqualStrings("/tmp", agent.cwd);
    Agent.toolCall(&agent, .{ .tool_call_id = "call", .tool_name = "run", .step = 1 });
    try std.testing.expect(!Agent.stopWhen(&agent, .{ .step = 1, .messages = &.{}, .tool_results = &.{} }));
}

test "prepare step merges queued messages and reminder" {
    const Fixture = struct {
        fn reminder(_: ?*anyopaque, _: *Agent) anyerror!?[]const u8 {
            return "reminder";
        }
    };

    var agent = try Agent.init(std.testing.allocator, std.testing.io, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    agent.lifetime.reminder = Fixture.reminder;
    try agent.queueReminder("queued");

    const prepared = try Agent.prepareStep(&agent, .{ .number = 1, .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 2), prepared.messages.len);
    try std.testing.expectEqualStrings("queued", prepared.messages[0].text());
    try std.testing.expectEqualStrings("reminder", prepared.messages[1].text());
}

test "agent adopts compacted SDK history and preserves durable tool state" {
    var agent = try Agent.init(std.testing.allocator, std.testing.io, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const big = "x" ** 70_000;
    try agent.setMessages(&.{ sdk.SystemMessage("system"), sdk.UserMessage(big), sdk.UserMessage("recent") });
    var outcome = compact.Outcome{
        .messages = try compact.installSummary(std.testing.allocator, agent.history(), "summary"),
        .usage = .{ .input_tokens = 10, .output_tokens = 2, .total_tokens = 12 },
    };
    agent.compact_task = compact.Task.init(agent.alloc, agent.io, &agent.model, agent.tools, agent.history(), false);
    agent.compact_task.?.result = outcome;
    outcome = undefined;
    agent.compact_task.?.finished.store(true, .release);
    agent.compaction.continue_after = false;
    agent.status = .compacting;
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.complete, agent.status);
    try std.testing.expectEqual(@as(u64, 12), agent.usage.total_tokens);
    try std.testing.expectEqual(false, agent.compaction.completed_continue_after.?);
    try std.testing.expect(std.mem.endsWith(u8, agent.history()[agent.history().len - 1].text(), "summary"));
}

test "agent schedules auto retry on retryable provider failure and resets on success" {
    const Fixture = struct {
        calls: usize = 0,

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(ctx: *anyopaque, alloc: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls == 1) {
                params.on_provider_error.?(params.on_provider_error_ctx, .{
                    .status_code = 429,
                    .response_body = "rate limited",
                    .is_retryable = true,
                    .retry_after_ms = 1000,
                });
                return error.RateLimited;
            }
            const result = try alloc.create(sdk.model.GenerateResult);
            result.* = .{ .text = try alloc.dupe(u8, "done"), .finish_reason = .stop };
            return result;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture = Fixture{};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.retrying, agent.status);
    try std.testing.expectEqual(@as(u32, 1), agent.retry_count);
    try std.testing.expect(agent.retry_at_ns > 0);

    try agent.retryNow();
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.complete, agent.status);
    try std.testing.expectEqual(@as(u32, 0), agent.retry_count);
    try std.testing.expectEqual(@as(i128, 0), agent.retry_at_ns);
}

test "agent fails after exhausting the auto retry budget" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            params.on_provider_error.?(params.on_provider_error_ctx, .{
                .status_code = 429,
                .response_body = "rate limited",
                .is_retryable = true,
                .retry_after_ms = 1000,
            });
            return error.RateLimited;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture: u8 = 0;
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    agent.max_retries = 2;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.retrying, agent.status);
    try std.testing.expectEqual(@as(u32, 1), agent.retry_count);

    try agent.retryNow();
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.retrying, agent.status);
    try std.testing.expectEqual(@as(u32, 2), agent.retry_count);

    try agent.retryNow();
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.failed, agent.status);
    try std.testing.expectEqual(error.RateLimited, agent.last_error.?);
}

test "cancel during the retry wait completes the agent" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            params.on_provider_error.?(params.on_provider_error_ctx, .{
                .status_code = 429,
                .response_body = "rate limited",
                .is_retryable = true,
                .retry_after_ms = 1000,
            });
            return error.RateLimited;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture: u8 = 0;
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.retrying, agent.status);

    agent.cancel();
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.canceled, agent.status);
}

test "non-provider failures do not auto retry after a retryable provider error" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            params.on_provider_error.?(params.on_provider_error_ctx, .{
                .status_code = 429,
                .response_body = "rate limited",
                .is_retryable = true,
                .retry_after_ms = 1000,
            });
            return error.InvalidResponse;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture: u8 = 0;
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.failed, agent.status);
    try std.testing.expectEqual(error.InvalidResponse, agent.last_error.?);
    try std.testing.expectEqual(@as(u32, 0), agent.retry_count);
}

test "stream connection failures schedule auto retry" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            return error.Canceled;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture: u8 = 0;
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    agent.max_retries = 1;
    try std.testing.expect(agent.willAutoRetry(error.NetworkError));
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.retrying, agent.status);
    try std.testing.expectEqual(@as(u32, 1), agent.retry_count);
    try std.testing.expect(agent.retry_at_ns > 0);

    try agent.retryNow();
    agent.task.?.wait();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.failed, agent.status);
    try std.testing.expectEqual(error.Canceled, agent.last_error.?);
}

test "explicit cancel does not auto retry on stream failure" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            return error.Canceled;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture: u8 = 0;
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{ .prompt = "hi" });
    agent.task.?.wait();
    agent.cancel();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.canceled, agent.status);
    try std.testing.expectEqual(@as(u32, 0), agent.retry_count);
}

test "explicit cancel adopts the latest valid request checkpoint" {
    const Fixture = struct {
        calls: usize = 0,

        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(ctx: *anyopaque, alloc: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls == 2) return error.Canceled;
            const calls = try alloc.alloc(sdk.ToolCall, 1);
            calls[0] = .{
                .id = try alloc.dupe(u8, "call_1"),
                .name = try alloc.dupe(u8, "test"),
                .input = try alloc.dupe(u8, "{}"),
            };
            const result = try alloc.create(sdk.model.GenerateResult);
            result.* = .{ .tool_calls = calls, .finish_reason = .tool_calls };
            return result;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }

        fn tool(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            return .{ .content = "tool output" };
        }

        fn collect(ctx: ?*anyopaque, event: agent_run.Event) void {
            const agent: *Agent = @ptrCast(@alignCast(ctx.?));
            agent.observe(event) catch unreachable;
        }
    };

    var fixture = Fixture{};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    var agent = try Agent.init(std.testing.allocator, io_state.io(), .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    defer agent.deinit();
    try agent.setTools(&.{.{ .name = "test", .execute = Fixture.tool }});
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    try agent.startModel(.{ .ctx = &fixture, .vtable = &vtable }, .{
        .prompt = "prompt",
        .max_steps = 3,
    });
    agent.task.?.wait();
    agent.cancel();
    while (agent.drain(2, &agent, Fixture.collect) != 0) {}
    try std.testing.expect(agent.reap());
    try std.testing.expectEqual(Status.canceled, agent.status);
    try std.testing.expectEqual(@as(usize, 3), agent.history().len);
    try std.testing.expectEqualStrings("prompt", agent.history()[0].text());
    try std.testing.expectEqual(sdk.Role.assistant, agent.history()[1].role);
    try std.testing.expectEqualStrings("tool output", agent.history()[2].parts()[0].tool_result.output);
}
