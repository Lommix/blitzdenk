const std = @import("std");
const r = @import("root.zig");

const apt = r.adapter;
const inbuilt = r.inbuilt;

const Agent = r.agent.Agent;
const Swarm = r.Swarm;

pub const MAX_TOOL_CALLS_PER_REQ = 32;

pub const ToolFn = *const fn (ToolContext, apt.ToolCall) apt.ToolResult;

pub const Tool = struct {
    def: apt.ToolDef,
    func: ToolFn,
};

/// Slot for an in-flight tool fn coroutine. The agent driver allocates one
/// per tool call from the agent arena (so the pointer is stable for the
/// ToolContext.cancel reference), spawns runToolWrapper via std.Io.async,
/// and polls `done` from tickToolCalls.
pub const RunningTool = struct {
    fut: std.Io.Future(apt.ToolResult),
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const ToolContext = struct {
    pool: *r.http.RequestPool,
    alloc: std.mem.Allocator,
    io: std.Io,
    config: apt.Config,
    swarm: *Swarm,
    self_id: Swarm.AgentId,
    cwd: []const u8,
    interface: r.agent.AgentContext,

    // TODO: cleanup user context
    cfg: *const r.config.BlitzCloudCfg,
    // app_ptr: *anyopaque,

    /// Set by the agent driver when this tool's future is being canceled.
    /// Tools (and Lua bridge fns) check this between blocking calls and
    /// abort with a failure result. Owned by the corresponding RunningTool.
    cancel: *std.atomic.Value(bool),

    pub fn agent(ctx: ToolContext) *Agent {
        return ctx.swarm.getAgent(ctx.self_id).?;
    }

    pub fn isCanceled(self: ToolContext) bool {
        return self.cancel.load(.acquire);
    }

    /// Enqueue a permission request and block on its event until the UI
    /// resolves it. Returns the final PermissionState. Returns .denied on
    /// cancellation or oom.
    pub fn requestPerm(
        self: ToolContext,
        call_id: []const u8,
        level: Swarm.PermissionLevel,
        payload: Swarm.PermissionPayload,
    ) Swarm.PermissionState {
        self.swarm.requestPermission(call_id, .{
            .agent_id = self.self_id,
            .level = level,
            .payload = payload,
        }) catch return .denied;
        const req = self.swarm.permission_requests.getPtr(call_id) orelse return .denied;
        req.event.wait(self.io) catch return .denied;
        if (self.isCanceled()) return .denied;
        return req.state;
    }

    pub fn setToolChild(self: ToolContext, call: apt.ToolCall, child_id: Swarm.AgentId) void {
        const ag = self.agent();
        ag.tool_display_mutex.lock(self.io) catch return;
        defer ag.tool_display_mutex.unlock(self.io);

        const en = ag.tool_display_status.getOrPut(self.alloc, call.id) catch return;
        if (!en.found_existing) en.value_ptr.* = .{};
        en.value_ptr.child_id = child_id;
    }

    pub fn updateToolStatus(self: ToolContext, call: apt.ToolCall, comptime fmt: []const u8, args: anytype) void {
        const ag = self.agent();

        ag.tool_display_mutex.lock(self.io) catch return;
        defer ag.tool_display_mutex.unlock(self.io);

        const en = ag.tool_display_status.getOrPut(self.alloc, call.id) catch return;
        if (!en.found_existing) en.value_ptr.* = .{};
        en.value_ptr.status_text.clearRetainingCapacity();
        en.value_ptr.status_text.print(self.alloc, fmt, args) catch return;
    }

    pub fn appendToolLog(self: ToolContext, call: apt.ToolCall, entry: []const u8) void {
        const ag = self.agent();
        const en = ag.tool_display_status.getOrPut(self.alloc, call.id) catch return;
        if (!en.found_existing) en.value_ptr.* = .{};
        en.value_ptr.log.append(self.alloc, entry) catch return;
    }
};

pub fn extractChildResult(swarm: *Swarm, child_id: Swarm.AgentId) []const u8 {
    const child_agent = swarm.getAgent(child_id) orelse return "child agent not found";
    const last_msg = child_agent.chat.lastMessage() orelse return "child produced no output";
    for (last_msg.parts) |part| {
        switch (part) {
            .text => |txt| return txt,
            else => {},
        }
    }
    return "child produced no text output";
}
