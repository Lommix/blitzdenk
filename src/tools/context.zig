const std = @import("std");
const sdk = @import("blitz-sdk");
const exec = @import("exec");
const AgentId = @import("agent-id").AgentId;
const permissions = @import("permissions");
const agent_mod = @import("../agent.zig");
const registry_mod = @import("../agent_registry.zig");

pub const Display = struct {
    ctx: ?*anyopaque = null,
    status: ?*const fn (?*anyopaque, AgentId, []const u8, []const u8) void = null,
    child: ?*const fn (?*anyopaque, AgentId, []const u8, AgentId) void = null,
};

pub const Owner = struct {
    agent_id: AgentId,
    call_id: []const u8,
};

pub const BaseContext = struct {
    registry: *registry_mod.Registry,
    exec_pool: *exec.CmdPool,
    self_id: AgentId,
    cwd: []const u8,
    permissions: permissions.Handler = .{},
    display: Display = .{},
    app: ?*anyopaque = null,
    owner: ?Owner = null,

    pub fn routeCwd(self: BaseContext) []const u8 {
        return self.exec_pool.effectiveCwd(self.cwd);
    }

    pub fn routeIsRemote(self: BaseContext) bool {
        return self.exec_pool.ssh_active and self.exec_pool.ssh_target != null;
    }
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base: BaseContext,

    pub fn agent(self: Context) *agent_mod.Agent {
        return self.base.registry.get(self.base.self_id).?;
    }

    pub fn cancellation(self: Context) ?*sdk.CancellationToken {
        const current_agent = self.base.registry.get(self.base.self_id) orelse return null;
        const task = if (current_agent.task) |*value| value else return null;
        return &task.cancellation;
    }

    pub fn isCanceled(self: Context) bool {
        const token = self.cancellation() orelse return true;
        return token.isCancelled();
    }

    pub fn requestPermission(self: Context, call: sdk.ToolCall, payload: permissions.Payload) permissions.State {
        if (self.base.permissions.request == null) return .denied;
        var request = permissions.Request{
            .agent_id = self.base.self_id,
            .call_id = call.id,
            .tool_name = call.name,
            .tool_input = call.input,
            .payload = payload,
        };
        self.base.permissions.send(&request);
        request.event.wait(self.io) catch return .denied;
        if (self.isCanceled()) return .denied;
        return request.state;
    }

    pub fn setStatus(self: Context, call_id: []const u8, value: []const u8) void {
        if (self.base.display.status) |status| status(self.base.display.ctx, self.base.self_id, call_id, value);
    }

    pub fn setChild(self: Context, call_id: []const u8, child_id: AgentId) void {
        const target = self.owner(call_id);
        if (self.base.display.child) |child| child(self.base.display.ctx, target.agent_id, target.call_id, child_id);
    }

    pub fn owner(self: Context, call_id: []const u8) Owner {
        return self.base.owner orelse .{ .agent_id = self.base.self_id, .call_id = call_id };
    }
};

pub const ToolFn = *const fn (Context, sdk.ToolCall) sdk.ToolOutput;

pub const DefinitionMeta = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_schema: []const u8 = "{}",
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: ?[]const u8 = null,
    requires_vision: bool = false,
};

pub const Definition = struct {
    def: DefinitionMeta,
    func: ToolFn,
};

const Binding = struct {
    base: BaseContext,
    execute: ToolFn,
};

pub fn install(agent: *agent_mod.Agent, base: BaseContext, definitions: []const Definition) !void {
    try installInternal(agent, base, definitions, false);
}

pub fn installLive(agent: *agent_mod.Agent, base: BaseContext, definitions: []const Definition) !void {
    try installInternal(agent, base, definitions, true);
}

fn installInternal(agent: *agent_mod.Agent, base: BaseContext, definitions: []const Definition, live: bool) !void {
    const alloc = agent.state_arena.allocator();
    const bindings = try alloc.alloc(Binding, definitions.len);
    const tools = try alloc.alloc(sdk.Tool, definitions.len);
    for (definitions, 0..) |definition, index| {
        bindings[index] = .{ .base = base, .execute = definition.func };
        tools[index] = .{
            .name = definition.def.name,
            .description = definition.def.description,
            .input_schema = definition.def.parameters_schema,
            .execute = trampoline,
            .execute_ctx = &bindings[index],
        };
    }
    if (live) try agent.setToolsLive(tools) else try agent.setTools(tools);
}

pub fn runWithOwner(tool: sdk.Tool, alloc: std.mem.Allocator, io: std.Io, call: sdk.ToolCall, owner: Owner) !sdk.ToolOutput {
    if (tool.execute != trampoline) return tool.run(alloc, io, call);
    const binding: *const Binding = @ptrCast(@alignCast(tool.execute_ctx.?));
    var base = binding.base;
    base.owner = owner;
    return binding.execute(.{ .alloc = alloc, .io = io, .base = base }, call);
}

fn trampoline(ctx: ?*anyopaque, alloc: std.mem.Allocator, io: std.Io, call: sdk.ToolCall) anyerror!sdk.ToolOutput {
    const binding: *Binding = @ptrCast(@alignCast(ctx.?));
    return binding.execute(.{ .alloc = alloc, .io = io, .base = binding.base }, call);
}

test "SDK tool trampoline preserves call context and output" {
    const Fixture = struct {
        fn execute(context: Context, call: sdk.ToolCall) sdk.ToolOutput {
            std.testing.expectEqualStrings("call", call.id) catch unreachable;
            std.testing.expectEqualStrings("{}", call.input) catch unreachable;
            std.testing.expect(context.base.registry.get(context.base.self_id) != null) catch unreachable;
            if (context.base.owner) |owner| {
                std.testing.expectEqual(context.base.self_id, owner.agent_id) catch unreachable;
                std.testing.expectEqualStrings("outer", owner.call_id) catch unreachable;
            }
            return .{ .content = if (context.base.owner) |target| target.call_id else "done", .exit_loop = true };
        }

        fn foreign(ctx: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: sdk.ToolCall) anyerror!sdk.ToolOutput {
            const value: *const u8 = @ptrCast(ctx.?);
            try std.testing.expectEqual(@as(u8, 98), value.*);
            return .{ .content = "foreign" };
        }
    };

    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var exec_pool = exec.CmdPool.init(std.testing.allocator, std.testing.io, &env);
    defer exec_pool.deinit();
    var registry = registry_mod.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve(null).?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{});
    try install(agent, .{
        .registry = &registry,
        .exec_pool = &exec_pool,
        .self_id = id,
        .cwd = "/tmp",
    }, &.{.{ .def = .{ .name = "test" }, .func = Fixture.execute }});
    const output = try agent.tools[0].run(std.testing.allocator, std.testing.io, .{ .id = "call", .name = "test", .input = "{}" });
    try std.testing.expectEqualStrings("done", output.content);
    try std.testing.expect(output.exit_loop);
    const owner = Owner{ .agent_id = id, .call_id = "outer" };
    const owned = try runWithOwner(agent.tools[0], std.testing.allocator, std.testing.io, .{ .id = "call", .name = "test", .input = "{}" }, owner);
    try std.testing.expectEqualStrings("outer", owned.content);
    const binding: *const Binding = @ptrCast(@alignCast(agent.tools[0].execute_ctx.?));
    try std.testing.expect(binding.base.owner == null);
    var foreign_context: u8 = 98;
    const foreign = try runWithOwner(.{ .name = "foreign", .execute = Fixture.foreign, .execute_ctx = &foreign_context }, std.testing.allocator, std.testing.io, .{ .id = "call", .name = "foreign", .input = "{}" }, owner);
    try std.testing.expectEqualStrings("foreign", foreign.content);
}
