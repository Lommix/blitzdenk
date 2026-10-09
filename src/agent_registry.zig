const std = @import("std");
const sdk = @import("blitz-sdk");
const agent_mod = @import("agent.zig");
const agent_id = @import("agent-id");
const agent_run = @import("agent_run.zig");
const compact = @import("compact.zig");
const models = @import("models");
const log = std.log.scoped(.agent_registry);

pub const max_agents = agent_id.max_agents;
pub const AgentId = agent_id.AgentId;

pub const SlotState = enum(u8) {
    free,
    reserved,
    /// Live: running a task or parked while its children work.
    active,
    complete,
    failed,
};

pub const Slot = struct {
    state: std.atomic.Value(SlotState) = .init(.free),
    generation: u16 = 0,
    parent: ?u32 = null,
    finish_seq: u64 = 0,
    pinned: bool = false,
    agent: ?agent_mod.Agent = null,
    event: std.Io.Event = .unset,
    accounted_usage: sdk.Usage = .{},
};

pub const ModelUsage = struct {
    model: []const u8,
    usage: sdk.Usage,
};

pub const CompactRequestResult = enum {
    started,
    queued,
    running,
    empty,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    slots: [max_agents]Slot = [_]Slot{.{}} ** max_agents,
    finish_counter: u64 = 0,
    total_usage: sdk.Usage = .{},
    model_usage: std.StringArrayHashMapUnmanaged(sdk.Usage) = .{},
    pending_mutex: std.Io.Mutex = .{ .state = .init(.unlocked) },
    pending: std.ArrayListUnmanaged(agent_mod.Agent) = .empty,
    cache_key_buf: [40]u8 = undefined,
    cache_key_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Registry {
        var self = Registry{ .alloc = alloc, .io = io };
        const key = std.fmt.bufPrint(&self.cache_key_buf, "blitz-{d}", .{std.c.getpid()}) catch "";
        self.cache_key_len = key.len;
        return self;
    }

    pub fn deinit(self: *Registry) void {
        self.flush();
        for (&self.slots) |*slot| {
            self.accountUsage(slot);
            if (slot.agent) |*agent| {
                agent.deinit();
            }
        }
        var iterator = self.model_usage.iterator();
        while (iterator.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.model_usage.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn reset(self: *Registry) void {
        self.cancelAll();
        for (&self.slots, 0..) |*slot, index| {
            switch (slot.state.load(.acquire)) {
                .free, .reserved => continue,
                .active, .complete, .failed => {},
            }
            self.release(.{ .index = @intCast(index), .generation = slot.generation });
        }
    }

    pub fn resetUsage(self: *Registry) void {
        var iterator = self.model_usage.iterator();
        while (iterator.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.model_usage.clearRetainingCapacity();
        self.total_usage = .{};
    }

    pub fn reserve(self: *Registry, parent: ?AgentId) ?AgentId {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state.cmpxchgStrong(.free, .reserved, .acq_rel, .monotonic) == null) {
                slot.parent = if (parent) |id| id.pack() else null;
                slot.generation +%= 1;
                slot.event.reset();
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
        }
        // Registry full: claim the oldest unpinned finished slot as this
        // caller's reservation. The cmpxchg hands the slot to exactly one
        // evictor; a loser rescans (the raced slot is no longer finished).
        // The victim's agent is retired to the pending list — deinits only
        // happen on the app thread via flush(), never on reserving threads.
        var victim: ?usize = null;
        for (&self.slots, 0..) |*slot, index| {
            const value = slot.state.load(.acquire);
            if (value != .complete and value != .failed) continue;
            if (slot.pinned) continue;
            if (victim == null or slot.finish_seq < self.slots[victim.?].finish_seq) victim = index;
        }
        const index = victim orelse return null;
        const slot = &self.slots[index];
        if (slot.state.cmpxchgStrong(.complete, .reserved, .acq_rel, .monotonic) != null) {
            if (slot.state.cmpxchgStrong(.failed, .reserved, .acq_rel, .monotonic) != null) return self.reserve(parent);
        }
        self.retire(slot);
        slot.accounted_usage = .{};
        slot.finish_seq = 0;
        slot.parent = if (parent) |id| id.pack() else null;
        slot.generation +%= 1;
        slot.event.set(self.io);
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    fn retire(self: *Registry, slot: *Slot) void {
        var agent = slot.agent orelse return;
        slot.agent = null;
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        self.pending.append(self.alloc, agent) catch {
            // ponytail: OOM here leaks one dead agent; allocator failure is
            // already a degraded mode, no recovery path worth the code
            agent.deinit();
        };
    }

    /// Deinit agents retired by evictions. App thread only: once the evictor
    /// flipped the slot to .reserved, no observer can reach the retired agent
    /// through the registry anymore.
    pub fn flush(self: *Registry) void {
        self.pending_mutex.lockUncancelable(self.io);
        var batch = self.pending;
        self.pending = .empty;
        self.pending_mutex.unlock(self.io);
        for (batch.items) |*dead| dead.deinit();
        batch.deinit(self.alloc);
    }

    pub fn pin(self: *Registry, id: AgentId) void {
        const slot = self.slotFor(id) orelse return;
        slot.pinned = true;
    }

    pub fn activate(self: *Registry, id: AgentId, config: models.Config, options: agent_mod.InitOptions) !*agent_mod.Agent {
        const slot = self.reservedSlot(id) orelse return error.InvalidReservation;
        var agent = try agent_mod.Agent.init(self.alloc, self.io, config, options);
        errdefer agent.deinit();
        slot.parent = agent.parent;
        slot.agent = agent;
        slot.state.store(.active, .release);
        return &slot.agent.?;
    }

    pub fn restoreAt(self: *Registry, id: AgentId, config: models.Config, options: agent_mod.InitOptions) !*agent_mod.Agent {
        if (id.index >= max_agents) return error.SlotOutOfRange;
        const slot = &self.slots[id.index];
        if (slot.state.cmpxchgStrong(.free, .reserved, .acq_rel, .monotonic) != null) return error.SlotOccupied;
        slot.generation = id.generation;
        slot.event.reset();
        errdefer self.releaseReservation(id);
        return self.activate(id, config, options);
    }

    pub fn releaseReservation(self: *Registry, id: AgentId) void {
        const slot = self.slotFor(id) orelse return;
        if (slot.state.cmpxchgStrong(.reserved, .free, .acq_rel, .monotonic) == null) slot.event.set(self.io);
    }

    pub fn release(self: *Registry, id: AgentId) void {
        const slot = self.slotFor(id) orelse return;
        if (slot.state.load(.acquire) == .free) return;
        slot.event.set(self.io);
        self.accountUsage(slot);
        if (slot.agent) |*agent| {
            agent.deinit();
        }
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }

    pub fn get(self: *Registry, id: AgentId) ?*agent_mod.Agent {
        const slot = self.slotFor(id) orelse return null;
        return switch (slot.state.load(.acquire)) {
            .active, .complete, .failed => if (slot.agent) |*agent| agent else null,
            .free, .reserved => null,
        };
    }

    pub fn idForAgent(self: *Registry, target: *const agent_mod.Agent) ?AgentId {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.agent) |*agent| {
                if (agent == target) return .{ .index = @intCast(index), .generation = slot.generation };
            }
        }
        return null;
    }

    pub fn state(self: *Registry, id: AgentId) ?SlotState {
        const slot = self.slotFor(id) orelse return null;
        const value = slot.state.load(.acquire);
        return if (value == .free) null else value;
    }

    pub fn reap(self: *Registry, id: AgentId) bool {
        const slot = self.slotFor(id) orelse return false;
        const agent = if (slot.agent) |*value| value else return false;
        if (!agent.reap()) return false;
        const state_value: SlotState = switch (agent.status) {
            .complete => if (self.hasLiveChildren(id)) .active else .complete,
            .canceled => .complete,
            .failed => .failed,
            .idle, .running, .retrying, .compacting => .active,
        };
        const previous = slot.state.load(.acquire);
        slot.state.store(state_value, .release);
        if (state_value != .active and previous != state_value) {
            self.stampFinished(slot);
            self.accountUsage(slot);
            slot.event.set(self.io);
        }
        return true;
    }

    pub fn run(self: *Registry, id: AgentId, options_in: sdk.GenerateOptions) !void {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        const agent = if (slot.agent) |*value| value else return error.AgentNotFound;
        if (slot.state.load(.acquire) != .active) slot.event.reset();
        agent.reported_task_done = false;
        var options = options_in;
        if (options.cache_key == null) options.cache_key = self.cache_key_buf[0..self.cache_key_len];
        try agent.start(options);
        slot.state.store(.active, .release);
    }

    pub fn retry(self: *Registry, id: AgentId, options: sdk.GenerateOptions) !void {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        const agent = if (slot.agent) |*value| value else return error.AgentNotFound;
        if (slot.state.load(.acquire) == .active and agent.isBusy() and (agent.status != .retrying or agent.task != null or agent.compact_task != null)) return error.RunInProgress;
        var retry_options = options;
        retry_options.prompt = "";
        try self.run(id, retry_options);
    }

    pub fn retryDue(self: *Registry) void {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state.load(.acquire) != .active) continue;
            const agent = if (slot.agent) |*value| value else continue;
            if (!agent.retryDue()) continue;
            agent.retryNow() catch |err| {
                log.warn("auto retry for agent {d} failed: {s}", .{ index, @errorName(err) });
                agent.last_error = err;
                agent.status = .failed;
                slot.state.store(.failed, .release);
                self.stampFinished(slot);
                self.accountUsage(slot);
                slot.event.set(self.io);
            };
        }
    }

    pub fn wake(self: *Registry, id: AgentId, options: sdk.GenerateOptions) !void {
        try self.retry(id, options);
    }

    pub fn compact(self: *Registry, id: AgentId) !CompactRequestResult {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        const agent = if (slot.agent) |*value| value else return error.AgentNotFound;
        if (agent.compact_task != null) return .running;
        const running = agent.task != null;
        agent.requestCompaction(.external, running);
        if (running) return .queued;
        const started = try agent.startCompaction(self.cache_key_buf[0..self.cache_key_len]);
        if (started) {
            slot.event.reset();
            slot.state.store(.active, .release);
        }
        return if (started) .started else .empty;
    }

    pub fn drain(self: *Registry, id: AgentId, max: usize, ctx: ?*anyopaque, handler: *const fn (?*anyopaque, agent_run.Event) void) usize {
        const agent = self.get(id) orelse return 0;
        var drain_context = DrainContext{ .agent = agent, .ctx = ctx, .handler = handler };
        return agent.drain(max, &drain_context, observeEvent);
    }

    pub fn cancel(self: *Registry, id: AgentId) void {
        const agent = self.get(id) orelse return;
        agent.cancel();
    }

    pub fn cancelAll(self: *Registry) void {
        var depth: i32 = max_agents;
        while (depth >= 0) : (depth -= 1) self.cancelDepth(@intCast(depth));
    }

    pub fn wait(self: *Registry, id: AgentId) !SlotState {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        try slot.event.wait(self.io);
        return self.state(id) orelse error.AgentNotFound;
    }

    /// Reservations belong to the parent before the spawn command is applied.
    /// A parent's finished task orders its reservation writes before reap scans.
    pub fn hasLiveChildren(self: *const Registry, id: AgentId) bool {
        for (&self.slots) |*slot| {
            const value = slot.state.load(.acquire);
            if (value != .reserved and value != .active) continue;
            if (slot.parent == id.pack()) return true;
        }
        return false;
    }

    /// Read-only completion decision shared by result notices and rail anchors.
    /// Slot state alone cannot describe parked parents or revived descendants.
    pub fn subtreeDone(self: *const Registry, id: AgentId) bool {
        var visited = [_]bool{false} ** max_agents;
        return self.subtreeDoneVisit(id, &visited);
    }

    fn subtreeDoneVisit(self: *const Registry, id: AgentId, visited: *[max_agents]bool) bool {
        if (id.index >= max_agents) return true;
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation) return true;
        const value = slot.state.load(.acquire);
        if (value == .free) return true;
        // Validate the full ID before marking its slot: only the current
        // generation can be reached, and cycles inspect each agent once.
        if (visited[id.index]) return true;
        visited[id.index] = true;
        if (value == .reserved) return false;
        const agent = if (slot.agent) |*agent| agent else return true;
        if (agent.isBusy() or agent.status == .running or
            agent.queued_messages.items.len > 0 or
            agent.compaction.requested.load(.acquire) != .none) return false;

        for (&self.slots, 0..) |*child, index| {
            if (child.state.load(.acquire) == .free or child.parent != id.pack()) continue;
            if (!self.subtreeDoneVisit(.{ .index = @intCast(index), .generation = child.generation }, visited)) return false;
        }
        return true;
    }

    pub fn countActive(self: *const Registry) u32 {
        var count: u32 = 0;
        for (&self.slots) |*slot| {
            if (slot.state.load(.acquire) == .active) count += 1;
        }
        return count;
    }

    pub fn usage(self: *const Registry) sdk.Usage {
        var result = self.total_usage;
        for (&self.slots) |*slot| {
            if (slot.agent) |*agent| result.add(usageDifference(agent.usage, slot.accounted_usage));
        }
        return result;
    }

    pub fn usageByModel(self: *Registry, alloc: std.mem.Allocator) ![]ModelUsage {
        var by_model: std.StringArrayHashMapUnmanaged(sdk.Usage) = .empty;
        defer by_model.deinit(alloc);
        for (self.model_usage.keys(), self.model_usage.values()) |model, value| {
            try by_model.put(alloc, model, value);
        }
        for (&self.slots) |*slot| {
            const agent = if (slot.agent) |*value| value else continue;
            const added = usageDifference(agent.usage, slot.accounted_usage);
            if (std.meta.eql(added, .{})) continue;
            const model = agent.model.languageModel().modelId();
            const gop = try by_model.getOrPut(alloc, model);
            if (!gop.found_existing) {
                gop.key_ptr.* = alloc.dupe(u8, model) catch {
                    _ = by_model.pop();
                    return error.OutOfMemory;
                };
                gop.value_ptr.* = .{};
            }
            gop.value_ptr.*.add(added);
        }
        const result = try alloc.alloc(ModelUsage, by_model.count());
        for (by_model.keys(), by_model.values(), result) |model, value, *entry| entry.* = .{ .model = model, .usage = value };
        return result;
    }

    fn stampFinished(self: *Registry, slot: *Slot) void {
        slot.finish_seq = self.finish_counter;
        self.finish_counter +%= 1;
    }

    fn slotFor(self: *Registry, id: AgentId) ?*Slot {
        if (id.index >= max_agents) return null;
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation) return null;
        return slot;
    }

    fn reservedSlot(self: *Registry, id: AgentId) ?*Slot {
        const slot = self.slotFor(id) orelse return null;
        return if (slot.state.load(.acquire) == .reserved) slot else null;
    }

    fn accountUsage(self: *Registry, slot: *Slot) void {
        const agent = if (slot.agent) |*value| value else return;
        const added = usageDifference(agent.usage, slot.accounted_usage);
        if (added.total_tokens == 0 and added.input_tokens == 0 and added.output_tokens == 0 and added.reasoning_tokens == 0 and added.cache_read_tokens == 0 and added.cache_write_tokens == 0) return;
        self.total_usage.add(added);
        slot.accounted_usage = agent.usage;
        const model_name = agent.model.languageModel().modelId();
        const entry = self.model_usage.getOrPut(self.alloc, model_name) catch return;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.alloc.dupe(u8, model_name) catch {
                _ = self.model_usage.pop();
                return;
            };
            entry.value_ptr.* = .{};
        }
        entry.value_ptr.add(added);
    }

    fn cancelDepth(self: *Registry, depth: u16) void {
        for (&self.slots) |*slot| {
            if (slot.state.load(.acquire) != .active) continue;
            const agent = if (slot.agent) |*value| value else continue;
            if (agent.depth != depth) continue;
            agent.cancelAndWait();
            slot.state.store(.complete, .release);
            self.stampFinished(slot);
            self.accountUsage(slot);
            slot.event.set(self.io);
        }
    }

    const DrainContext = struct {
        agent: *agent_mod.Agent,
        ctx: ?*anyopaque,
        handler: *const fn (?*anyopaque, agent_run.Event) void,
    };

    fn observeEvent(ctx: ?*anyopaque, event: agent_run.Event) void {
        const drain_context: *DrainContext = @ptrCast(@alignCast(ctx.?));
        drain_context.handler(drain_context.ctx, event);
        drain_context.agent.observe(event) catch |err| {
            log.err("failed to observe {s} stream event: {s}", .{ @tagName(event), @errorName(err) });
            drain_context.agent.last_error = error.OutOfMemory;
            drain_context.agent.status = .failed;
        };
    }
};

fn usageDifference(value: sdk.Usage, previous: sdk.Usage) sdk.Usage {
    return .{
        .input_tokens = value.input_tokens -| previous.input_tokens,
        .output_tokens = value.output_tokens -| previous.output_tokens,
        .total_tokens = value.total_tokens -| previous.total_tokens,
        .reasoning_tokens = value.reasoning_tokens -| previous.reasoning_tokens,
        .cache_read_tokens = value.cache_read_tokens -| previous.cache_read_tokens,
        .cache_write_tokens = value.cache_write_tokens -| previous.cache_write_tokens,
    };
}

test "reap fires once per run for a finished retained agent" {
    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: agent_run.Event) void {}
    };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve(null).?;
    _ = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{});
    try registry.run(id, .{ .max_steps = 0 });
    while (registry.state(id) == .active) {
        _ = registry.drain(id, 64, null, Fixture.discard);
        _ = registry.reap(id);
        if (registry.state(id) == .active) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(SlotState.complete, registry.state(id).?);
    try std.testing.expect(registry.get(id) != null);
    try std.testing.expect(!registry.get(id).?.reported_task_done);
    try std.testing.expect(!registry.reap(id));

    const agent = registry.get(id).?;
    agent.status = .canceled;
    try std.testing.expect(registry.reap(id));
    try std.testing.expect(registry.reap(id));

    try registry.run(id, .{ .max_steps = 0 });
    try std.testing.expect(!registry.get(id).?.reported_task_done);
    try std.testing.expectEqual(SlotState.active, registry.state(id).?);

    registry.release(id);
    try std.testing.expect(registry.state(id) == null);
}

const WaitingTest = struct {
    fn activate(registry: *Registry, parent: ?AgentId) !AgentId {
        const id = registry.reserve(parent).?;
        _ = try registry.activate(id, .{
            .api_key = "key",
            .model = "model",
            .base_url = "https://example.com/v1",
            .params = .{ .openai = .{} },
        }, .{ .identity = .{ .parent = if (parent) |pid| pid.pack() else null } });
        return id;
    }

    fn discard(_: ?*anyopaque, _: agent_run.Event) void {}

    fn finishTurn(registry: *Registry, id: AgentId) !void {
        try registry.run(id, .{ .max_steps = 0 });
        registry.get(id).?.task.?.wait();
        while (registry.drain(id, 64, null, discard) != 0) {}
        try std.testing.expect(registry.reap(id));
    }

    fn expectWaiting(registry: *Registry, id: AgentId) !void {
        try std.testing.expectEqual(SlotState.active, registry.state(id).?);
        try std.testing.expect(!registry.slots[id.index].event.isSet());
        try std.testing.expect(!registry.get(id).?.reported_task_done);
        try std.testing.expect(!registry.get(id).?.isBusy());
        try std.testing.expect(!registry.reap(id));
    }
};

test "reap waits for live children and completes nested agents bottom up" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const root = try WaitingTest.activate(&registry, null);
    const parent = try WaitingTest.activate(&registry, root);
    const child = try WaitingTest.activate(&registry, parent);
    // A waiting turn must leave even an existing finish stamp untouched.
    registry.slots[parent.index].finish_seq = 99;
    try WaitingTest.finishTurn(&registry, parent);
    try WaitingTest.finishTurn(&registry, root);
    try WaitingTest.expectWaiting(&registry, parent);
    try WaitingTest.expectWaiting(&registry, root);
    try std.testing.expectEqual(@as(u64, 99), registry.slots[parent.index].finish_seq);
    try std.testing.expectEqual(@as(u64, 0), registry.finish_counter);

    try WaitingTest.finishTurn(&registry, child);
    try std.testing.expectEqual(SlotState.complete, registry.state(child).?);
    try WaitingTest.expectWaiting(&registry, parent);
    try WaitingTest.finishTurn(&registry, parent);
    try std.testing.expectEqual(SlotState.complete, registry.state(parent).?);
    try WaitingTest.finishTurn(&registry, root);
    try std.testing.expectEqual(SlotState.complete, registry.state(root).?);
    try std.testing.expect(registry.slots[child.index].finish_seq < registry.slots[parent.index].finish_seq);
    try std.testing.expect(registry.slots[parent.index].finish_seq < registry.slots[root.index].finish_seq);
    try std.testing.expectEqual(@as(u64, 3), registry.finish_counter);
}
