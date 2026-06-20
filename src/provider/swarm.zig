const std = @import("std");
const r = @import("root.zig");
const apt = r.adapter;
const Agent = r.agent.Agent;
const tc = r.tool;
const http = r.http;
const Self = @This();

pub const MAX_AGENTS = 128;

pub const PermissionLevel = enum {
    minor, //may skip permission
    always_check, //may skip permission, but not on SSH
    dangerous, //never skip permission
};

pub const PermissionPayload = union(enum) {
    call: ToolCallPayload,
    diff: ToolDiff,
    ask: AskPayload,
    plan: PlanApprovalPayload,
};

pub const PermissionReq = struct {
    agent_id: AgentId,
    call_id: ?[]const u8 = null,
    state: PermissionState = .pending,
    level: PermissionLevel = .minor,
    payload: PermissionPayload,
    event: std.Io.Event = .unset,
};

pub const PermissionState = union(enum) {
    pending,
    approved,
    denied,
    choice: u8,
    message: []const u8,
};

///! the swarm vtable and hooks
pub const SwarmContextV = struct {
    ptr: *anyopaque,

    //async
    broadcast: *const fn (*anyopaque, BroadcastEntry) void,
    permission: *const fn (*anyopaque, *PermissionReq) void,
    cwd: *const fn (*anyopaque) []const u8,
    build_config: *const fn (*anyopaque, u8) anyerror!r.adapter.Config,

    //sync
    gen_system_reminders: *const fn (*anyopaque, *Agent) void,
    pop_queued_message: *const fn (*anyopaque, AgentId, std.mem.Allocator) ?[]const apt.ContentPart,

    pub fn cast(self: SwarmContextV, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ptr));
    }
};

// ----------------------------------
arena: std.heap.ArenaAllocator,
stream_allocator: std.mem.Allocator,
slots: [MAX_AGENTS]AgentSlot = [_]AgentSlot{.{}} ** MAX_AGENTS,

// let it own
pool: http.RequestPool,
exec: r.exec.CmdPool,
context: SwarmContextV,
last_run_timestamp: ?i64 = null,
token_stats: apt.TokenUsage = .{},

// ----------------------------------
pub const ToolDiff = struct {
    path: []const u8,
    before: ?[]const u8,
    after: []const u8,
};

pub const AgentId = packed struct {
    index: u16,
    generation: u16,

    pub fn pack(self: AgentId) u32 {
        return @bitCast(self);
    }

    pub fn unpack(val: u32) AgentId {
        return @bitCast(val);
    }
};

pub const SlotState = enum(u8) {
    free,
    reserved,
    active,
    complete,
    failed,
};

pub const AgentSlot = struct {
    state: std.atomic.Value(SlotState) = .init(.free),
    generation: u16 = 0,
    agent: Agent = undefined,
    parent_id: ?AgentId = null,
    time_elapsed: f32 = 0,
    /// Set when state transitions to .complete or .failed. Sub-agent
    /// tools wait on this instead of busy-polling slot.state.
    event: std.Io.Event = .unset,
};

pub fn reserveFreeSlot(self: *Self) ?AgentId {
    for (&self.slots, 0..) |*slot, i| {
        if (slot.state.cmpxchgStrong(.free, .reserved, .acq_rel, .monotonic) == null) {
            slot.generation +%= 1;
            return .{ .index = @intCast(i), .generation = slot.generation };
        }
    }
    return null;
}

pub fn finishReservation(self: *Self, id: AgentId) void {
    self.slots[id.index].state.store(.active, .release);
}

pub fn releaseReservation(self: *Self, id: AgentId) void {
    self.slots[id.index].state.store(.free, .release);
}

pub const BroadcastEntry = struct {
    agent_id: AgentId,
    role: apt.Role,
    parts: []const apt.ContentPart,
};

pub const ToolCallPayload = struct {
    tool_name: []const u8,
    tool_arguments: []const u8,
};

pub const AskPayload = struct {
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
};

pub const PlanApprovalPayload = struct {
    path: []const u8,
    plan_text: []const u8,
};

pub fn init(
    self: *Self,
    alloc: std.mem.Allocator,
    stream_allocator: std.mem.Allocator,
    io: std.Io,
    context: SwarmContextV,
    env: *const std.process.Environ.Map,
) !void {
    self.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .stream_allocator = stream_allocator,
        .pool = .{},
        .exec = r.exec.CmdPool.init(alloc, io, env),
        .context = context,
    };
    try self.pool.init(alloc, io);
}

pub fn reset(self: *Self) void {
    self.last_run_timestamp = null;
    for (&self.slots) |*slot| {
        const s = slot.state.load(.acquire);
        if (s == .free or s == .reserved) continue;

        slot.event.set(self.pool.io);
        slot.agent.deinit();
        slot.* = .{};
    }
    _ = self.arena.reset(.retain_capacity);
}

pub fn deinit(self: *Self) void {
    for (&self.slots) |*slot| {
        const state = slot.state.load(.acquire);
        if (state != .free and state != .reserved) slot.agent.deinit();
    }
    self.arena.deinit();
    self.pool.deinit();
    self.exec.deinit();
}

pub fn usage(self: *const Self) apt.TokenUsage {
    var u = apt.TokenUsage{};
    u.add(self.token_stats);

    for (&self.slots) |*s| {
        if (s.state.load(.acquire) == .active) u.add(s.agent.in_flight_usage);
    }

    return u;
}

pub fn forkAgent(
    self: *Self,
    agent_id: AgentId,
) !AgentId {
    const parent_slot = self.getSlot(agent_id) orelse return error.AgentNotFound;

    const id = self.reserveFreeSlot() orelse return error.SwarmFull;
    errdefer self.releaseReservation(id);

    const slot = &self.slots[id.index];

    slot.agent = Agent.new(
        parent_slot.agent.config,
        parent_slot.agent.pool,
        self.arena.allocator(),
        self.stream_allocator,
        parent_slot.agent.type_idx,
        parent_slot.agent.mode_idx,
    );

    slot.agent.chat = try parent_slot.agent.chat.clone(slot.agent.arena.allocator());
    slot.agent.tools = try parent_slot.agent.tools.clone(slot.agent.arena.allocator());

    // cleanup dangeling tool calls
    if (slot.agent.chat.messages.items.len > 0) {
        const last = slot.agent.chat.messages.items[slot.agent.chat.messages.items.len - 1];
        if (last.role == .agent) {
            for (last.parts) |part| {
                if (part == .tool_call) {
                    _ = slot.agent.chat.messages.pop();
                    break;
                }
            }
        }
    }

    slot.agent.swarm = self;
    slot.agent.flags.is_fork = true;
    slot.agent.swarm_id = id;
    slot.parent_id = agent_id;
    slot.agent.depth = parent_slot.agent.depth + 1;
    self.finishReservation(id);

    return id;
}

pub fn forkAgentInSlot(
    self: *Self,
    src_slot: AgentId,
    dst_slot: AgentId,
) !void {
    const parent_slot = self.getSlot(src_slot) orelse return error.AgentNotFound;
    const slot = &self.slots[dst_slot.index];

    slot.agent = Agent.new(
        parent_slot.agent.config,
        parent_slot.agent.pool,
        self.arena.allocator(),
        self.stream_allocator,
        parent_slot.agent.type_idx,
        parent_slot.agent.mode_idx,
    );

    slot.agent.chat = try parent_slot.agent.chat.clone(slot.agent.arena.allocator());
    slot.agent.tools = try parent_slot.agent.tools.clone(slot.agent.arena.allocator());

    // cleanup dangeling tool calls
    if (slot.agent.chat.messages.items.len > 0) {
        const last = slot.agent.chat.messages.items[slot.agent.chat.messages.items.len - 1];
        if (last.role == .agent) {
            for (last.parts) |part| {
                if (part == .tool_call) {
                    _ = slot.agent.chat.messages.pop();
                    break;
                }
            }
        }
    }

    slot.agent.swarm = self;
    slot.agent.flags.is_fork = true;
    slot.agent.swarm_id = dst_slot;
    slot.parent_id = src_slot;
    slot.agent.depth = parent_slot.agent.depth + 1;
}

pub fn newAgent(
    self: *Self,
    parent_id: ?AgentId,
    agent_type_idx: u8,
    mode_type_idx: u8,
) !AgentId {
    const id = self.reserveFreeSlot() orelse return error.SwarmFull;
    errdefer self.releaseReservation(id);

    const slot = &self.slots[id.index];
    slot.parent_id = parent_id;

    const config = try self.context.build_config(self.context.ptr, agent_type_idx);
    slot.agent = Agent.new(
        config,
        &self.pool,
        self.arena.allocator(),
        self.stream_allocator,
        agent_type_idx,
        mode_type_idx,
    );

    slot.agent.swarm = self;
    slot.agent.swarm_id = id;
    slot.parent_id = parent_id;

    if (parent_id) |pid| {
        slot.agent.depth = (self.getSlot(pid) orelse return error.InvalidParent).agent.depth + 1;
    } else {
        slot.agent.depth = 0;
    }

    self.finishReservation(id);
    return id;
}

pub fn newAgentInSlot(
    self: *Self,
    idx: AgentId,
    parent_id: ?AgentId,
    agent_type_idx: u8,
    mode_type_idx: u8,
) !void {
    const slot = &self.slots[idx.index];
    if (slot.generation != idx.generation) return error.AgentSlotGenerationMissmatch;

    const config = try self.context.build_config(self.context.ptr, agent_type_idx);
    slot.agent = Agent.new(
        config,
        &self.pool,
        self.arena.allocator(),
        self.stream_allocator,
        agent_type_idx,
        mode_type_idx,
    );

    slot.agent.swarm = self;
    slot.agent.swarm_id = idx;
    slot.parent_id = parent_id;

    if (parent_id) |pid| {
        slot.agent.depth = (self.getSlot(pid) orelse return error.InvalidParent).agent.depth + 1;
    } else {
        slot.agent.depth = 0;
    }
}

pub fn runAgent(self: *Self, id: AgentId) !void {
    const slot = self.getSlot(id) orelse return error.InvalidAgentId;
    slot.time_elapsed = 0;
    slot.agent.run();
    slot.state.store(.active, .release);
}

pub fn runAgentWithMsg(self: *Self, id: AgentId, parts: []const apt.ContentPart) !void {
    const slot = self.getSlot(id) orelse return error.InvalidAgentId;
    slot.time_elapsed = 0;
    slot.agent.runWithMsg(parts);
    slot.state.store(.active, .release);
}

pub fn retryAgent(self: *Self, id: AgentId) void {
    const slot = self.getSlot(id) orelse return;
    if (slot.state.load(.acquire) == .active) return;
    slot.time_elapsed = 0;
    slot.agent.retry();
    slot.state.store(.active, .release);
}

pub fn tickAll(self: *Self) bool {
    var running = false;
    const dt = self.progress_time();
    for (&self.slots) |*slot| {
        if (slot.state.load(.acquire) != .active) continue;
        slot.time_elapsed += dt;
        const result = slot.agent.tick(dt, self.context);
        switch (result) {
            .complete => {
                slot.state.store(.complete, .release);
                slot.event.set(self.pool.io);
            },
            .failed => {
                slot.state.store(.failed, .release);
                slot.event.set(self.pool.io);
            },
            else => running = true,
        }
    }
    return running;
}

pub fn cancelAll(self: *Self) void {
    self.pool.cancelAll();
    self.exec.cancelAll();

    for (&self.slots) |*slot| {
        if (slot.state.load(.acquire) != .active) continue;
        if (slot.agent.depth == 0) {
            slot.agent.cancel();
            slot.state.store(.complete, .release);
            slot.event.set(self.pool.io);
        } else {
            slot.agent.cancel();
            slot.event.set(self.pool.io);
            slot.agent.deinit();
            slot.* = .{};
        }
    }
}

fn progress_time(self: *Self) f32 {
    const now_us: i64 = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(self.pool.io, .real).raw.nanoseconds, std.time.ns_per_us));
    if (self.last_run_timestamp) |last_stamp| {
        const delta_micro: f64 = @floatFromInt(now_us - last_stamp);
        const delta_sec = delta_micro / (1000 * 1000);

        self.last_run_timestamp = now_us;
        return @floatCast(delta_sec);
    }

    self.last_run_timestamp = now_us;
    return 0;
}

pub fn releaseAgent(self: *Self, id: AgentId) void {
    const slot = &self.slots[id.index];
    if (slot.generation != id.generation) return;
    if (slot.state.load(.acquire) != .free) {
        slot.event.set(self.pool.io);
        slot.agent.deinit();
    }
    const gen = slot.generation;
    slot.* = .{ .generation = gen };
}

pub fn getAgent(self: *Self, id: AgentId) ?*Agent {
    const slot = self.getSlot(id) orelse return null;
    return &slot.agent;
}

pub fn getSlotState(self: *Self, id: AgentId) ?SlotState {
    if (id.index >= MAX_AGENTS) return null;
    const slot = &self.slots[id.index];
    if (slot.generation != id.generation) return null;
    const state = slot.state.load(.acquire);
    if (state == .free) return null;
    return state;
}

pub fn countActive(self: *const Self) u32 {
    var count: u32 = 0;
    for (&self.slots) |*s| {
        if (s.state.load(.acquire) == .active) count += 1;
    }
    return count;
}

pub fn getSlot(self: *Self, id: AgentId) ?*AgentSlot {
    if (id.index >= MAX_AGENTS) return null;
    const slot = &self.slots[id.index];
    if (slot.generation != id.generation) return null;
    const s = slot.state.load(.acquire);
    if (s == .free) return null;
    return slot;
}

pub fn recordBroadcast(self: *Self, agent_id: AgentId, role: apt.Role, parts: []const apt.ContentPart) void {
    // TODO: emit event_bus.agent_broadcast — needs event bus threaded through swarm
    self.context.broadcast(self.context.ptr, .{
        .agent_id = agent_id,
        .role = role,
        .parts = parts,
    });
}

// stack allocated, breaks when agent is canceled/crash/etc
pub fn requestPermission(self: *const Self, req: *PermissionReq) void {
    self.context.permission(self.context.ptr, req);
}
