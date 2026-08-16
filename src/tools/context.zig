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

pub const BaseContext = struct {
    registry: *registry_mod.Registry,
    exec_pool: *exec.CmdPool,
    self_id: AgentId,
    cwd: []const u8,
    permissions: permissions.Handler = .{},
    display: Display = .{},
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

    pub fn requestPermission(self: Context, call_id: []const u8, level: permissions.Level, payload: permissions.Payload) permissions.State {
        if (self.base.permissions.request == null) return .denied;
        var request = permissions.Request{
            .agent_id = self.base.self_id,
            .call_id = call_id,
            .level = level,
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
        if (self.base.display.child) |child| child(self.base.display.ctx, self.base.self_id, call_id, child_id);
    }
};

pub const ToolFn = *const fn (Context, sdk.ToolCall) sdk.ToolOutput;

pub const DefinitionMeta = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_schema: []const u8 = "{}",
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: ?[]const u8 = null,
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
    try agent.setTools(tools);
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
            return .{ .content = "done", .exit_loop = true };
        }
    };

    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    var exec_pool = exec.CmdPool.init(std.testing.allocator, std.testing.io, &env);
    defer exec_pool.deinit();
    var registry = registry_mod.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve().?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .provider = .{ .openai = .{} },
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
}
