const std = @import("std");
const sdk = @import("blitz-sdk");
const agent_mod = @import("agent.zig");
const agent_id = @import("agent-id");
const agent_run = @import("agent_run.zig");
const compact = @import("compact.zig");
const models = @import("models");
const report = @import("report.zig");
const log = std.log.scoped(.agent_registry);

pub const max_agents = agent_id.max_agents;
pub const AgentId = agent_id.AgentId;

pub const SlotState = enum(u8) {
    free,
    reserved,
    active,
    complete,
    failed,
};

pub const Slot = struct {
    state: std.atomic.Value(SlotState) = .init(.free),
    generation: u16 = 0,
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
    total_usage: sdk.Usage = .{},
    model_usage: std.StringArrayHashMapUnmanaged(sdk.Usage) = .{},
    report_enabled: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Registry {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        for (&self.slots) |*slot| {
            self.accountUsage(slot);
            self.writeReport(slot);
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

    pub fn reserve(self: *Registry) ?AgentId {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state.cmpxchgStrong(.free, .reserved, .acq_rel, .monotonic) == null) {
                slot.generation +%= 1;
                slot.event.reset();
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
        }
        return null;
    }

    pub fn activate(self: *Registry, id: AgentId, config: models.Config, options: agent_mod.InitOptions) !*agent_mod.Agent {
        const slot = self.reservedSlot(id) orelse return error.InvalidReservation;
        var agent = try agent_mod.Agent.init(self.alloc, self.io, config, options);
        errdefer agent.deinit();
        slot.agent = agent;
        slot.state.store(.active, .release);
        return &slot.agent.?;
    }

    pub fn fork(self: *Registry, parent_id: AgentId) !AgentId {
        const parent = self.get(parent_id) orelse return error.AgentNotFound;
        const id = self.reserve() orelse return error.RegistryFull;
        errdefer self.releaseReservation(id);
        const slot = self.reservedSlot(id).?;
        var child = try parent.fork(parent_id.pack());
        errdefer child.deinit();
        slot.agent = child;
        slot.state.store(.active, .release);
        return id;
    }

    pub fn activateFork(self: *Registry, id: AgentId, parent_id: AgentId) !*agent_mod.Agent {
        const parent = self.get(parent_id) orelse return error.AgentNotFound;
        const slot = self.reservedSlot(id) orelse return error.InvalidReservation;
        var child = try parent.fork(parent_id.pack());
        errdefer child.deinit();
        slot.agent = child;
        slot.state.store(.active, .release);
        return &slot.agent.?;
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
        self.writeReport(slot);
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
            .complete, .canceled => .complete,
            .failed => .failed,
            .idle, .running, .retrying, .compacting => .active,
        };
        slot.state.store(state_value, .release);
        if (state_value != .active) {
            self.accountUsage(slot);
            slot.event.set(self.io);
        }
        return true;
    }

    pub fn run(self: *Registry, id: AgentId, options: sdk.GenerateOptions) !void {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        const agent = if (slot.agent) |*value| value else return error.AgentNotFound;
        if (slot.state.load(.acquire) != .active) slot.event.reset();
        try agent.start(options);
        slot.state.store(.active, .release);
    }

    pub fn retry(self: *Registry, id: AgentId, options: sdk.GenerateOptions) !void {
        const slot = self.slotFor(id) orelse return error.AgentNotFound;
        const agent = if (slot.agent) |*value| value else return error.AgentNotFound;
        if (slot.state.load(.acquire) == .active and (agent.status != .retrying or agent.task != null)) return error.RunInProgress;
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
        const started = try agent.startCompaction();
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
            self.accountUsage(slot);
            slot.event.set(self.io);
        }
    }

    fn writeReport(self: *Registry, slot: *Slot) void {
        if (!self.report_enabled) return;
        const agent = if (slot.agent) |*value| value else return;
        if (agent.name.len == 0 or agent.history().len == 0) return;
        const slot_index = (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot);
        report.writeReleasedReport(self.io, self.alloc, agent.name, agent.model.languageModel().modelId(), slot_index, agent.history()) catch {};
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

test "registry keeps fixed generation-safe slots" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    var ids: [max_agents]AgentId = undefined;
    for (&ids) |*id| id.* = registry.reserve().?;
    try std.testing.expect(registry.reserve() == null);
    const stale = ids[0];
    registry.releaseReservation(stale);
    const reused = registry.reserve().?;
    try std.testing.expectEqual(stale.index, reused.index);
    try std.testing.expect(stale.generation != reused.generation);
    registry.releaseReservation(stale);
    try std.testing.expectEqual(SlotState.reserved, registry.state(reused).?);
}

test "registry reset preserves queued reservations" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const existing = registry.reserve().?;
    registry.slots[existing.index].state.store(.complete, .release);
    const queued = registry.reserve().?;
    registry.reset();
    try std.testing.expect(registry.state(existing) == null);
    try std.testing.expectEqual(SlotState.reserved, registry.state(queued).?);
    registry.releaseReservation(queued);
}

test "starting a reserved agent preserves an existing waiter" {
    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: agent_run.Event) void {}
    };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve().?;
    var waiting = std.Io.async(io, Registry.wait, .{ &registry, id });
    while (@atomicLoad(std.Io.Event, &registry.slots[id.index].event, .acquire) != .waiting) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    _ = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    try registry.run(id, .{ .max_steps = 0 });
    while (registry.state(id) == .active) {
        _ = registry.drain(id, 64, null, Fixture.discard);
        _ = registry.reap(id);
        if (registry.state(id) == .active) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(SlotState.complete, try waiting.await(io));
    registry.release(id);
}

test "registry owns and forks SDK agents" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const parent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "parent", .cwd = "/tmp" } });
    try parent.setMessages(&.{sdk.UserMessage("hello")});
    try parent.setTools(&.{.{ .name = "read" }});
    const child_id = try registry.fork(id);
    const child = registry.get(child_id).?;
    try std.testing.expectEqual(id.pack(), child.parent.?);
    try std.testing.expectEqual(@as(u16, 1), child.depth);
    try std.testing.expectEqualStrings("hello", child.history()[0].text());
    try std.testing.expectEqualStrings("read", child.tools[0].name);
    parent.usage = .{ .input_tokens = 5, .output_tokens = 2, .total_tokens = 7 };
    registry.release(id);
    try std.testing.expect(registry.get(id) == null);
    try std.testing.expect(registry.get(child_id) != null);
    try std.testing.expectEqual(@as(u64, 7), registry.usage().total_tokens);
    const by_model = try registry.usageByModel(std.testing.allocator);
    defer std.testing.allocator.free(by_model);
    try std.testing.expectEqual(@as(usize, 1), by_model.len);
    try std.testing.expectEqualStrings("model", by_model[0].model);
    try std.testing.expectEqual(@as(u64, 7), by_model[0].usage.total_tokens);
}

test "usageByModel includes live unaccounted slot usage" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const parent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "parent", .cwd = "/tmp" } });
    parent.usage = .{ .input_tokens = 5, .output_tokens = 2, .total_tokens = 7 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const by_model = try registry.usageByModel(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), by_model.len);
    try std.testing.expectEqualStrings("model", by_model[0].model);
    try std.testing.expectEqual(@as(u64, 5), by_model[0].usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), by_model[0].usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 7), by_model[0].usage.total_tokens);
}

test "registry reports empty explicit idle compaction without history" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    try std.testing.expectEqual(CompactRequestResult.empty, try registry.compact(id));
    try std.testing.expectEqual(compact.Request.none, agent.compaction.requested.load(.acquire));
    try std.testing.expectEqual(agent_mod.Status.idle, agent.status);
}

test "registry reports and completes standalone compaction" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    const big = "x" ** 70_000;
    try agent.setMessages(&.{ sdk.UserMessage(big), sdk.UserMessage("recent") });
    agent.compact_task = compact.Task.init(agent.alloc, agent.io, &agent.model, agent.tools, agent.history(), false);
    agent.compact_task.?.result = .{
        .messages = try compact.installSummary(std.testing.allocator, agent.history(), "summary"),
        .usage = .{},
    };
    agent.compact_task.?.finished.store(true, .release);
    agent.compaction.continue_after = false;
    agent.status = .compacting;
    try std.testing.expectEqual(CompactRequestResult.running, try registry.compact(id));
    try std.testing.expectEqual(compact.Request.none, agent.compaction.requested.load(.acquire));
    try std.testing.expect(registry.reap(id));
    try std.testing.expectEqual(SlotState.complete, registry.state(id).?);
    try std.testing.expectEqual(agent_mod.Status.complete, agent.status);
}

test "registry queues explicit compaction while agent runs" {
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    try registry.run(id, .{ .max_steps = 0 });
    try std.testing.expectEqual(CompactRequestResult.queued, try registry.compact(id));
    try std.testing.expectEqual(compact.Request.external, agent.compaction.requested.load(.acquire));
    try std.testing.expect(agent.compaction.continue_after);
    try std.testing.expect(agent.compact_task == null);
}

test "registry retry is allowed while an agent is retrying" {
    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: agent_run.Event) void {}
    };

    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    agent.status = agent_mod.Status.retrying;
    try registry.retry(id, .{ .max_steps = 0 });
    while (registry.state(id) == .active) {
        _ = registry.drain(id, 64, null, Fixture.discard);
        _ = registry.reap(id);
        if (registry.state(id) == .active) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(SlotState.complete, registry.state(id).?);
    registry.release(id);
}

test "registry completes a canceled retry-waiting agent" {
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    agent.status = agent_mod.Status.retrying;
    agent.cancel();
    try std.testing.expect(registry.reap(id));
    try std.testing.expectEqual(SlotState.complete, registry.state(id).?);
    registry.release(id);
}
