const std = @import("std");
const prv = @import("provider");
const r = @import("root.zig");

const log = std.log.scoped(.mcp);

pub const PROTOCOL_VERSION = "2025-11-25";
pub const MAX_LINE = 4 * 1024 * 1024;

pub const ServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    tools_prefix: []const u8,
    enabled_agents: r.ContextFactory.AgentType.Set,
};

pub const RegisteredTool = struct {
    tool: prv.tool.Tool,
    flags: r.ContextFactory.ToolFlags,
};

const ToolBinding = struct {
    exported_name: []const u8,
    remote_name: []const u8,
    client_index: usize,
};

pub const Manager = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    clients: std.ArrayList(Client) = .empty,
    bindings: std.ArrayList(ToolBinding) = .empty,
    tools: std.ArrayList(RegisteredTool) = .empty,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Manager {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Manager) void {
        self.clear();
        if (active_manager == self) active_manager = null;
        self.clients.deinit(self.alloc);
        self.bindings.deinit(self.alloc);
        self.tools.deinit(self.alloc);
    }

    pub fn clear(self: *Manager) void {
        for (self.clients.items) |*client| client.deinit();
        for (self.tools.items) |tool| {
            self.alloc.free(tool.tool.def.description);
            self.alloc.free(tool.tool.def.parameters_schema);
        }
        for (self.bindings.items) |binding| {
            self.alloc.free(binding.exported_name);
            self.alloc.free(binding.remote_name);
        }
        self.clients.clearRetainingCapacity();
        self.bindings.clearRetainingCapacity();
        self.tools.clearRetainingCapacity();
    }

    pub fn loadServers(self: *Manager, configs: []const ServerConfig) void {
        self.clear();
        active_manager = self;

        for (configs) |cfg| {
            self.addServer(cfg) catch |err| {
                log.warn("failed to load MCP server '{s}': {s}", .{ cfg.name, @errorName(err) });
            };
        }
    }

    pub fn registeredTools(self: *Manager) []const RegisteredTool {
        return self.tools.items;
    }

    fn addServer(self: *Manager, cfg: ServerConfig) !void {
        var client = try Client.start(self.alloc, self.io, cfg);
        errdefer client.deinit();

        try client.initialize();
        const remote_tools = try client.listTools();
        defer self.alloc.free(remote_tools);

        const client_index = self.clients.items.len;
        try self.clients.append(self.alloc, client);

        for (remote_tools) |rt| {
            const exported = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ cfg.tools_prefix, rt.name });
            const desc = try std.fmt.allocPrint(self.alloc, "[MCP:{s}] {s}", .{ cfg.name, rt.description });
            self.alloc.free(rt.description);

            try self.bindings.append(self.alloc, .{
                .exported_name = exported,
                .remote_name = rt.name,
                .client_index = client_index,
            });
            try self.tools.append(self.alloc, .{
                .tool = .{
                    .def = .{
                        .name = exported,
                        .description = desc,
                        .parameters_schema = rt.input_schema,
                    },
                    .func = &toolTrampoline,
                },
                .flags = r.ContextFactory.ToolFlags{
                    .allowed_agents = cfg.enabled_agents,
                    .include_with_overrides = true,
                },
            });
        }
    }

    fn findBinding(self: *Manager, exported_name: []const u8) ?ToolBinding {
        for (self.bindings.items) |binding| {
            if (std.mem.eql(u8, binding.exported_name, exported_name)) return binding;
        }
        return null;
    }
};

var active_manager: ?*Manager = null;

fn toolTrampoline(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const manager = active_manager orelse return errResult(call, "MCP manager not initialized");
    const binding = manager.findBinding(call.name) orelse return errResult(call, "MCP tool binding not found");
    if (binding.client_index >= manager.clients.items.len) return errResult(call, "MCP client missing");

    ctx.updateToolStatus(call, "MCP {s}", .{binding.remote_name});
    const client = &manager.clients.items[binding.client_index];
    const content = client.callTool(binding.remote_name, call.arguments) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "MCP tool call failed: {s}", .{@errorName(err)}) catch "MCP tool call failed";
        return errResult(call, msg);
    };

    return .{
        .call_id = call.id,
        .name = call.name,
        .content = content.text,
        .is_error = content.is_error,
    };
}

fn errResult(call: prv.adapter.ToolCall, msg: []const u8) prv.adapter.ToolResult {
    return .{ .call_id = call.id, .name = call.name, .content = msg, .is_error = true };
}

const RemoteTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const ToolCallResult = struct {
    text: []const u8,
    is_error: bool,
};

const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    argv: []const []const u8,
    child: std.process.Child,
    next_id: i64 = 1,
    mu: std.Io.Mutex = .init,

    fn start(alloc: std.mem.Allocator, io: std.Io, cfg: ServerConfig) !Client {
        const argv = try buildArgv(alloc, cfg.command, cfg.args);
        errdefer freeArgv(alloc, argv);

        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        return .{
            .alloc = alloc,
            .io = io,
            .name = try alloc.dupe(u8, cfg.name),
            .argv = argv,
            .child = child,
        };
    }

    fn deinit(self: *Client) void {
        if (self.child.id != null) self.child.kill(self.io);
        self.alloc.free(self.name);
        freeArgv(self.alloc, self.argv);
    }

    fn initialize(self: *Client) !void {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        var w = &req.writer;

        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"blitz\",\"version\":\"0.1\"}}}}}}\n",
            .{ id, PROTOCOL_VERSION },
        );

        const response = try self.request(id, req.written());
        defer response.deinit();
        _ = try responseResult(&response.value);

        try self.sendNotification("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
    }

    fn listTools(self: *Client) ![]RemoteTool {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        try req.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\",\"params\":{{}}}}\n", .{id});

        const response = try self.request(id, req.written());
        defer response.deinit();

        const result = try responseResult(&response.value);
        const tools_val = objectGet(&result, "tools") orelse return error.InvalidMcpResponse;
        if (tools_val != .array) return error.InvalidMcpResponse;

        var out: std.ArrayList(RemoteTool) = .empty;
        errdefer out.deinit(self.alloc);

        for (tools_val.array.items) |*tool_val| {
            if (tool_val.* != .object) continue;
            const name = stringField(tool_val, "name") orelse continue;
            const description = stringField(tool_val, "description") orelse "";
            const schema_val = objectGet(tool_val, "inputSchema") orelse objectGet(tool_val, "parameters") orelse continue;
            const schema = try stringifyValue(self.alloc, schema_val);
            try out.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, name),
                .description = try self.alloc.dupe(u8, description),
                .input_schema = schema,
            });
        }

        return out.toOwnedSlice(self.alloc);
    }

    fn callTool(self: *Client, remote_name: []const u8, arguments_json: []const u8) !ToolCallResult {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        var w = &req.writer;

        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":", .{id});
        try writeJsonString(w, remote_name);
        try w.writeAll(",\"arguments\":");
        if (std.mem.trim(u8, arguments_json, " \t\r\n").len == 0) {
            try w.writeAll("{}");
        } else {
            try w.writeAll(arguments_json);
        }
        try w.writeAll("}}\n");

        const response = try self.request(id, req.written());
        defer response.deinit();

        const result = try responseResult(&response.value);
        const is_error = if (objectGet(&result, "isError")) |v| v == .bool and v.bool else false;
        const content_val = objectGet(&result, "content") orelse return .{
            .text = try self.alloc.dupe(u8, ""),
            .is_error = is_error,
        };
        const text = try flattenContent(self.alloc, &content_val);
        return .{ .text = text, .is_error = is_error };
    }

    fn request(self: *Client, id: i64, line: []const u8) !std.json.Parsed(std.json.Value) {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        try std.Io.File.writeStreamingAll(self.child.stdin.?, self.io, line);

        while (true) {
            const response_line = try self.readLine();
            defer self.alloc.free(response_line);
            const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, response_line, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            errdefer parsed.deinit();

            if (jsonIdMatches(&parsed.value, id)) return parsed;
            parsed.deinit();
        }
    }

    fn sendNotification(self: *Client, line: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try std.Io.File.writeStreamingAll(self.child.stdin.?, self.io, line);
    }

    fn readLine(self: *Client) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.alloc);

        while (list.items.len < MAX_LINE) {
            var byte: [1]u8 = undefined;
            const n = try std.Io.File.readStreaming(self.child.stdout.?, self.io, &.{&byte});
            if (n == 0) continue;
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') try list.append(self.alloc, byte[0]);
        }
        if (list.items.len >= MAX_LINE) return error.StreamTooLong;
        return list.toOwnedSlice(self.alloc);
    }

    fn nextRequestId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

fn buildArgv(alloc: std.mem.Allocator, command: []const u8, args: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, args.len + 1);
    errdefer alloc.free(out);
    out[0] = try alloc.dupe(u8, command);
    errdefer alloc.free(out[0]);
    for (args, 0..) |arg, i| {
        out[i + 1] = try alloc.dupe(u8, arg);
    }
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

fn responseResult(value: *const std.json.Value) !std.json.Value {
    if (value.* != .object) return error.InvalidMcpResponse;
    if (objectGet(value, "error")) |_| return error.McpErrorResponse;
    return objectGet(value, "result") orelse error.InvalidMcpResponse;
}

fn objectGet(value: *const std.json.Value, key: []const u8) ?std.json.Value {
    if (value.* != .object) return null;
    return value.object.get(key);
}

fn stringField(value: *const std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectGet(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn jsonIdMatches(value: *const std.json.Value, id: i64) bool {
    const id_val = objectGet(value, "id") orelse return false;
    return switch (id_val) {
        .integer => |n| n == id,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null == id,
        else => false,
    };
}

fn stringifyValue(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn flattenContent(alloc: std.mem.Allocator, value: *const std.json.Value) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    if (value.* != .array) {
        try std.json.Stringify.value(value.*, .{}, w);
        return out.toOwnedSlice();
    }

    var first = true;
    for (value.array.items) |*item| {
        if (item.* != .object) continue;
        const ty = stringField(item, "type") orelse "unknown";
        if (!first) try w.writeByte('\n');
        first = false;

        if (std.mem.eql(u8, ty, "text")) {
            try w.writeAll(stringField(item, "text") orelse "");
        } else {
            try w.print("[MCP content: {s}]", .{ty});
        }
    }

    return out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}
