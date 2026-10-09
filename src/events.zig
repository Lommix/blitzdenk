const std = @import("std");
const r = @import("root.zig");
const AgentId = r.AgentId;

pub const AppEvent = union(enum) {
    session_reset,
    agent_created: struct { id: AgentId, name: []const u8, depth: u16 },
    agent_started: struct { id: AgentId, fresh: bool },
    agent_complete: AgentId,
    agent_failed: struct { id: AgentId, err: []const u8 },
    agent_cancelled: AgentId,
    compaction_started: AgentId,
    compaction_complete: AgentId,
    user_message_sent: []const u8,
    mcp_tools_reloaded,
    permission_requested: u64,
};

pub const AppEventTag = @typeInfo(AppEvent).@"union".tag_type.?;

/// One hook invocation handed to a background thread. Owns a deep copy
/// of the event payload; the thread frees it.
pub const HookCall = struct {
    bus: *EventBus,
    app: *r.app.App,
    event: AppEvent,
};

pub const EventBus = struct {
    active: std.EnumSet(AppEventTag) = .{},
    active_mu: std.Io.Mutex = .init,
    pending_hooks: std.atomic.Value(u32) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),
    /// Cancelled by shutdown so a listener stuck in a Lua loop cannot
    /// hang exit; runEventHook installs it as the sandbox VM cancel token.
    hook_cancel: r.sdk.CancellationToken = .{},

    pub fn emit(self: *EventBus, app: *r.app.App, event: AppEvent) bool {
        if (self.shutting_down.load(.acquire)) return false;

        self.active_mu.lockUncancelable(app.io);
        const has_listeners = self.active.contains(std.meta.activeTag(event));
        self.active_mu.unlock(app.io);
        if (!has_listeners) return false;

        const owned = dupEvent(app.gpa, event) catch return false;
        const call = app.gpa.create(HookCall) catch {
            freeEvent(app.gpa, owned);
            return false;
        };
        call.* = .{ .bus = self, .app = app, .event = owned };

        _ = self.pending_hooks.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, hookThreadMain, .{call}) catch {
            self.finishHook(call);
            return false;
        };
        thread.detach();
        return true;
    }

    pub fn willDeliver(self: *EventBus, io: std.Io, event_type: AppEventTag) bool {
        self.active_mu.lockUncancelable(io);
        defer self.active_mu.unlock(io);
        return self.active.contains(event_type);
    }

    fn finishHook(self: *EventBus, call: *HookCall) void {
        freeEvent(call.app.gpa, call.event);
        call.app.gpa.destroy(call);
        _ = self.pending_hooks.fetchSub(1, .acq_rel);
    }

    fn hookThreadMain(call: *HookCall) void {
        defer call.bus.finishHook(call);
        r.lua.runEventHook(call.app, call.event);
        switch (call.event) {
            .permission_requested => |ticket| call.app.finishLuaPermission(ticket),
            else => {},
        }
    }

    pub fn addTag(self: *EventBus, io: std.Io, event_type: AppEventTag) void {
        self.active_mu.lockUncancelable(io);
        defer self.active_mu.unlock(io);
        self.active.insert(event_type);
    }

    pub fn clear(self: *EventBus, io: std.Io) void {
        self.active_mu.lockUncancelable(io);
        defer self.active_mu.unlock(io);
        self.active = .{};
    }

    /// Stop spawning hooks and wake every awaiter blocked on an agent slot.
    /// The main loop no longer reaps after this point, so slot events are
    /// set directly. Call before joinPending.
    pub fn shutdown(self: *EventBus, app: *r.app.App) void {
        self.shutting_down.store(true, .release);
        self.hook_cancel.cancel(app.io);
        for (&app.registry.slots) |*slot| {
            if (slot.state.load(.acquire) == .free) continue;
            slot.event.set(app.io);
        }
    }

    /// Wait until every spawned hook thread finished. Call after shutdown.
    pub fn joinPending(self: *EventBus, io: std.Io) void {
        while (self.pending_hooks.load(.acquire) > 0) {
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
    }
};

pub fn dupEvent(alloc: std.mem.Allocator, event: AppEvent) !AppEvent {
    return switch (event) {
        .session_reset, .mcp_tools_reloaded => event,
        .agent_created => |payload| .{ .agent_created = .{
            .id = payload.id,
            .name = try alloc.dupe(u8, payload.name),
            .depth = payload.depth,
        } },
        .agent_started => event,
        .agent_complete => event,
        .agent_failed => |payload| .{ .agent_failed = .{
            .id = payload.id,
            .err = try alloc.dupe(u8, payload.err),
        } },
        .agent_cancelled => event,
        .compaction_started => event,
        .compaction_complete => event,
        .user_message_sent => |text| .{ .user_message_sent = try alloc.dupe(u8, text) },
        .permission_requested => event,
    };
}

pub fn freeEvent(alloc: std.mem.Allocator, event: AppEvent) void {
    switch (event) {
        .agent_created => |payload| alloc.free(payload.name),
        .agent_failed => |payload| alloc.free(payload.err),
        .user_message_sent => |text| alloc.free(text),
        else => {},
    }
}
