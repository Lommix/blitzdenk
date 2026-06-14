const std = @import("std");
const r = @import("root.zig");
const apt = r.adapter;
const cfg_mod = r.config;
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

// ----------------------------------
arena: std.heap.ArenaAllocator,
slots: [MAX_AGENTS]AgentSlot = [_]AgentSlot{.{}} ** MAX_AGENTS,
pool: *http.RequestPool,
exec: *r.exec.CmdPool,
cfg: *const cfg_mod.BlitzdenkCfg,
env: *const std.process.Environ.Map,
broadcast: std.ArrayListUnmanaged(BroadcastEntry) = .empty,
broadcast_dropped: u64 = 0,
cwd: []const u8,
// call_id -> req
permission_requests: std.StringHashMapUnmanaged(PermissionReq) = .{},

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
    alloc: std.mem.Allocator,
    pool: *http.RequestPool,
    exec: *r.exec.CmdPool,
    cfg: *const cfg_mod.BlitzdenkCfg,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
) !Self {
    var self: Self = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .pool = pool,
        .exec = exec,
        .cfg = cfg,
        .env = env,
        .cwd = cwd,
    };
    // Pre-reserve so concurrent inserts from worker threads do not rehash
    // and invalidate getPtr results held by the UI.
    try self.permission_requests.ensureTotalCapacity(self.arena.allocator(), tc.MAX_TOOL_CALLS_PER_REQ * MAX_AGENTS);
    return self;
}

pub fn reset(self: *Self) void {
    self.broadcast.clearRetainingCapacity();
    self.broadcast_dropped = 0;
    self.last_run_timestamp = null;
    self.wakeAllPermissions();
    self.permission_requests = .{};
    for (&self.slots) |*slot| {
        const s = slot.state.load(.acquire);
        if (s == .free or s == .reserved) continue;

        slot.event.set(self.pool.io);
        slot.agent.arena.deinit();
        slot.* = .{};
    }
    _ = self.arena.reset(.retain_capacity);
    self.permission_requests.ensureTotalCapacity(self.arena.allocator(), tc.MAX_TOOL_CALLS_PER_REQ * MAX_AGENTS) catch {};
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
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
    effort: cfg_mod.EffortLevel,
    parent_id: ?AgentId,
    agent_type_idx: u8,
    mode_type_idx: u8,
) !AgentId {
    const id = self.reserveFreeSlot() orelse return error.SwarmFull;
    errdefer self.releaseReservation(id);

    const slot = &self.slots[id.index];
    slot.parent_id = parent_id;

    const config = self.cfg.buildConfig(effort, self.env) orelse return error.ConfigBuildFailed;
    slot.agent = Agent.new(
        config,
        self.pool,
        self.arena.allocator(),
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
    effort: cfg_mod.EffortLevel,
    parent_id: ?AgentId,
    agent_type_idx: u8,
    mode_type_idx: u8,
) !void {
    const slot = &self.slots[idx.index];
    if (slot.generation != idx.generation) return error.AgentSlotGenerationMissmatch;

    const config = self.cfg.buildConfig(effort, self.env) orelse return error.ConfigBuildFailed;
    slot.agent = Agent.new(
        config,
        self.pool,
        self.arena.allocator(),
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

pub fn runAgent(self: *Self, id: AgentId, parts: []const apt.ContentPart) !void {
    const slot = self.getSlot(id) orelse return error.InvalidAgentId;
    slot.time_elapsed = 0;
    slot.agent.run(parts);
    slot.state.store(.active, .release);
}

pub fn retryAgent(self: *Self, id: AgentId) void {
    const slot = self.getSlot(id) orelse return;
    if (slot.state.load(.acquire) == .active) return;
    slot.time_elapsed = 0;
    slot.agent.retry();
    slot.state.store(.active, .release);
}

pub fn tickAll(self: *Self, ctx: r.agent.AgentContext) bool {
    var running = false;
    const dt = self.progress_time();
    for (&self.slots) |*slot| {
        if (slot.state.load(.acquire) != .active) continue;
        slot.time_elapsed += dt;
        const result = slot.agent.tick(dt, ctx);
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
            slot.agent.arena.deinit();
            slot.* = .{};
        }
    }

    self.wakeAllPermissions();
    self.permission_requests.clearRetainingCapacity();
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
        slot.agent.arena.deinit();
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
    return slot.state.load(.acquire);
}

pub fn countActive(self: *const Self) u32 {
    var count: u32 = 0;
    for (&self.slots) |*s| {
        if (s.state.load(.acquire) == .active) count += 1;
    }
    return count;
}

pub const PermissionEntry = struct {
    call_id: []const u8,
    req: *PermissionReq,
};

pub fn nextPendingPermission(self: *Self) ?PermissionEntry {
    var it = self.permission_requests.iterator();
    while (it.next()) |en| {
        if (en.value_ptr.state == .pending) return .{
            .call_id = en.key_ptr.*,
            .req = en.value_ptr,
        };
    }
    return null;
}

pub fn requestPermission(self: *Self, call_id: []const u8, req: PermissionReq) !void {
    try self.permission_requests.put(self.arena.allocator(), call_id, req);
}

/// Set permission state and wake any worker blocked on the request's event.
/// `.message` payloads are duped into the swarm arena so the worker can read
/// them after the UI's input buffer is reused.
pub fn resolvePermission(self: *Self, call_id: []const u8, state: PermissionState) void {
    if (self.permission_requests.getPtr(call_id)) |req| {
        req.state = switch (state) {
            .message => |m| blk: {
                const owned = self.arena.allocator().dupe(u8, m) catch break :blk .denied;
                break :blk .{ .message = owned };
            },
            else => state,
        };
        req.event.set(self.pool.io);
    }
}

/// Wake every pending permission's event. Used during reset/cancel so
/// blocked workers observe their cancel flag and unwind.
pub fn wakeAllPermissions(self: *Self) void {
    var it = self.permission_requests.iterator();
    while (it.next()) |en| en.value_ptr.event.set(self.pool.io);
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
    const alloc = self.arena.allocator();
    const duped_parts = deepCopyParts(alloc, parts) catch return;
    // Ring buffer: drop oldest entry once we reach cap. broadcast_dropped is
    // bumped so consumers tracking absolute ids can rebase their cursor.
    if (self.broadcast.items.len >= MAX_AGENTS) {
        _ = self.broadcast.orderedRemove(0);
        self.broadcast_dropped +%= 1;
    }
    self.broadcast.append(alloc, .{
        .agent_id = agent_id,
        .role = role,
        .parts = duped_parts,
    }) catch return;
}

pub fn getBroadcast(self: *const Self) []const BroadcastEntry {
    return self.broadcast.items;
}

/// Absolute id for the first live entry in the ring.
pub fn broadcastBaseId(self: *const Self) u64 {
    return self.broadcast_dropped;
}

fn deepCopyParts(alloc: std.mem.Allocator, parts: []const apt.ContentPart) ![]const apt.ContentPart {
    const duped = try alloc.alloc(apt.ContentPart, parts.len);
    for (parts, 0..) |part, i| {
        duped[i] = switch (part) {
            .text => |txt| .{ .text = try alloc.dupe(u8, txt) },
            .thinking => |th| .{ .thinking = .{
                .text = try alloc.dupe(u8, th.text),
                .signature = if (th.signature) |s| try alloc.dupe(u8, s) else null,
            } },
            .image => |img| .{ .image = .{
                .media_type = try alloc.dupe(u8, img.media_type),
                .data = try alloc.dupe(u8, img.data),
            } },
            .tool_call => |call| .{ .tool_call = .{
                .id = try alloc.dupe(u8, call.id),
                .name = try alloc.dupe(u8, call.name),
                .arguments = try alloc.dupe(u8, call.arguments),
            } },
            .tool_result => |res| .{ .tool_result = .{
                .call_id = try alloc.dupe(u8, res.call_id),
                .name = try alloc.dupe(u8, res.name),
                .content = try alloc.dupe(u8, res.content),
                .is_error = res.is_error,
            } },
        };
    }
    return duped;
}
