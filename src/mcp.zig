const std = @import("std");
const r = @import("root.zig");

const log = std.log.scoped(.mcp);

pub const PROTOCOL_VERSION = "2025-11-25";
pub const MAX_LINE = 4 * 1024 * 1024;
pub const DEFAULT_TIMEOUT_S = 300;

pub const ServerConfig = struct {
    name: []const u8,
    tools_prefix: []const u8,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    key_envar: ?[]const u8 = null,
    timeout_s: u64 = DEFAULT_TIMEOUT_S,
};

pub const RegisteredTool = struct {
    tool: r.tools.Tool,
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
        self.clients.ensureTotalCapacity(self.alloc, configs.len) catch |err| {
            log.warn("failed to reserve MCP client slots: {s}", .{@errorName(err)});
            return;
        };

        for (configs) |cfg| {
            self.addServer(cfg) catch |err| {
                if (err == error.Canceled) return;
                log.warn("failed to load MCP server '{s}': {s}", .{ cfg.name, @errorName(err) });
            };
        }
    }

    pub fn registeredTools(self: *Manager) []const RegisteredTool {
        return self.tools.items;
    }

    fn addServer(self: *Manager, cfg: ServerConfig) !void {
        var client = try Client.start(self.alloc, self.io, cfg);
        const client_index = self.clients.items.len;
        self.clients.append(self.alloc, client) catch |err| {
            client.deinit();
            return err;
        };
        errdefer {
            self.clients.items[client_index].deinit();
            _ = self.clients.pop();
        }

        try self.clients.items[client_index].initialize();
        const remote_tools = try self.clients.items[client_index].listTools();
        defer self.alloc.free(remote_tools);

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
                .flags = .{ .allowed_agents = .initFull(), .add_to_agents = true },
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

pub const LoadTask = struct {
    io: std.Io,
    manager: *Manager,
    configs: []const ServerConfig,
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    pub fn init(io: std.Io, manager: *Manager, configs: []const ServerConfig) LoadTask {
        return .{
            .io = io,
            .manager = manager,
            .configs = configs,
        };
    }

    pub fn start(self: *LoadTask) void {
        self.future = std.Io.concurrent(self.io, run, .{self}) catch return self.run();
    }

    pub fn isFinished(self: *const LoadTask) bool {
        return self.finished.load(.acquire);
    }

    pub fn wait(self: *LoadTask) void {
        if (self.future) |*future| future.await(self.io);
        self.future = null;
    }

    pub fn deinit(self: *LoadTask) void {
        if (self.future) |*future| future.cancel(self.io);
        self.* = undefined;
    }

    fn run(self: *LoadTask) void {
        defer self.finished.store(true, .release);
        self.manager.loadServers(self.configs);
    }
};

var active_manager: ?*Manager = null;

fn toolTrampoline(ctx: r.tools.ToolContext, call: r.sdk.ToolCall) r.sdk.ToolOutput {
    const manager = active_manager orelse return errResult(call, "MCP manager not initialized");
    const binding = manager.findBinding(call.name) orelse return errResult(call, "MCP tool binding not found");
    if (binding.client_index >= manager.clients.items.len) return errResult(call, "MCP client missing");

    const app: *r.app.App = @ptrCast(@alignCast(ctx.base.display.ctx.?));
    var status_buf: [r.tools.STATUS_BUF]u8 = undefined;
    var w = r.tui.AnsiWriter.init(&status_buf);
    w.print("MCP {s} ", .{binding.remote_name});
    w.styled(.{ .fg = app.theme.muted }, argPreview(call.input));
    r.tools.setToolStatus(ctx, call, w.finish()) catch {};
    const client = &manager.clients.items[binding.client_index];
    const content = client.callTool(ctx.alloc, binding.remote_name, call.input) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "MCP tool call failed: {s}", .{@errorName(err)}) catch "MCP tool call failed";
        return errResult(call, msg);
    };

    return .{ .content = content.text, .is_error = content.is_error };
}

fn errResult(_: r.sdk.ToolCall, msg: []const u8) r.sdk.ToolOutput {
    return .{ .content = msg, .is_error = true };
}

fn argPreview(input: []const u8) []const u8 {
    var end = @min(input.len, 255);
    while (end > 0 and end < input.len and (input[end] & 0xC0) == 0x80) end -= 1;
    return input[0..end];
}

test "argPreview caps at 255 bytes without splitting utf8" {
    const short = "{\"path\":\"src/main.zig\"}";
    try std.testing.expectEqualStrings(short, argPreview(short));

    var long_buf: [600]u8 = undefined;
    @memset(&long_buf, 'a');
    const capped = argPreview(&long_buf);
    try std.testing.expectEqual(@as(usize, 255), capped.len);

    const multi = "é" ** 200;
    const cut = argPreview(multi);
    try std.testing.expect(cut.len <= 255);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "MCP load task completes" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    var task = LoadTask.init(std.testing.io, &manager, &.{});
    defer task.deinit();
    task.start();
    task.wait();
    try std.testing.expect(task.isFinished());
}

const FakeMcp = struct {
    inits: usize = 0,
    notifications: usize = 0,
    calls: usize = 0,
    saw_session_header: bool = false,
    saw_reinit_session_header: bool = false,
    saw_auth_header: bool = false,
    done: bool = false,

    fn serve(self: *FakeMcp, server: *std.Io.net.Server, io: std.Io) void {
        while (!self.done) {
            const stream = server.accept(io) catch return;
            self.serveConnection(stream, io);
            stream.close(io);
        }
    }

    fn serveConnection(self: *FakeMcp, stream: std.Io.net.Stream, io: std.Io) void {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);

        while (true) {
            var head: [4096]u8 = undefined;
            var head_len: usize = 0;
            var body_buf: [4096]u8 = undefined;
            const body = readHttpRequest(&reader.interface, &head, &head_len, &body_buf) catch return;
            const head_slice = head[0..head_len];

            if (std.mem.indexOf(u8, head_slice, "mcp-session-id: sess-") != null) self.saw_session_header = true;
            if (std.mem.indexOf(u8, head_slice, "mcp-session-id: sess-2") != null) self.saw_reinit_session_header = true;
            if (std.mem.indexOf(u8, head_slice, "authorization: Bearer test-key") != null) self.saw_auth_header = true;

            if (std.mem.indexOf(u8, body, "\"method\":\"initialize\"") != null) {
                self.inits += 1;
                writeJson(&writer.interface, requestId(body), "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"0\"}}", self.inits) catch return;
            } else if (std.mem.indexOf(u8, body, "\"method\":\"notifications/initialized\"") != null) {
                self.notifications += 1;
                writeEmpty(&writer.interface, "202 Accepted") catch return;
            } else if (std.mem.indexOf(u8, body, "\"method\":\"tools/list\"") != null) {
                writeJson(&writer.interface, requestId(body), "{\"tools\":[{\"name\":\"echo\",\"description\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}]}", null) catch return;
            } else if (std.mem.indexOf(u8, body, "\"method\":\"tools/call\"") != null) {
                self.calls += 1;
                if (self.calls == 1) {
                    writeEmpty(&writer.interface, "404 Not Found") catch return;
                    continue;
                }
                writeSse(&writer.interface, requestId(body)) catch return;
                self.done = true;
                std.Io.sleep(io, .fromSeconds(60), .awake) catch {};
                return;
            } else {
                writeEmpty(&writer.interface, "400 Bad Request") catch return;
            }
        }
    }

    fn readHttpRequest(reader: *std.Io.Reader, head: []u8, head_len: *usize, body_buf: []u8) ![]const u8 {
        while (head_len.* + 4 <= head.len) {
            const b = reader.takeByte() catch return error.Closed;
            head[head_len.*] = b;
            head_len.* += 1;
            if (head_len.* >= 4 and std.mem.eql(u8, head[head_len.* - 4 .. head_len.*], "\r\n\r\n")) break;
        } else return error.HeadTooLong;

        const head_slice = head[0..head_len.*];
        const cl = std.mem.indexOf(u8, head_slice, "content-length:") orelse return error.BadRequest;
        var i = cl + "content-length:".len;
        while (i < head_slice.len and head_slice[i] == ' ') i += 1;
        var n: usize = 0;
        while (i < head_slice.len and head_slice[i] >= '0' and head_slice[i] <= '9') : (i += 1) {
            n = n * 10 + (head_slice[i] - '0');
        }
        if (n > body_buf.len) return error.BodyTooLong;
        try reader.readSliceAll(body_buf[0..n]);
        return body_buf[0..n];
    }

    fn requestId(body: []const u8) i64 {
        const idx = std.mem.indexOf(u8, body, "\"id\":") orelse return 0;
        var i = idx + "\"id\":".len;
        var n: i64 = 0;
        while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
            n = n * 10 + (body[i] - '0');
        }
        return n;
    }

    fn writeJson(w: *std.Io.Writer, id: i64, result: []const u8, session: ?usize) !void {
        var body_buf: [2048]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result });
        if (session) |seq| {
            try w.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: keep-alive\r\nmcp-session-id: sess-{d}\r\n\r\n{s}", .{ body.len, seq, body });
        } else {
            try w.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n{s}", .{ body.len, body });
        }
        try w.flush();
    }

    fn writeEmpty(w: *std.Io.Writer, status: []const u8) !void {
        try w.print("HTTP/1.1 {s}\r\ncontent-length: 0\r\nconnection: keep-alive\r\n\r\n", .{status});
        try w.flush();
    }

    fn writeSse(w: *std.Io.Writer, id: i64) !void {
        var event_buf: [2048]u8 = undefined;
        const event = try std.fmt.bufPrint(&event_buf, "event: message\ndata: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"isError\":false,\"content\":[{{\"type\":\"text\",\"text\":\"hello\"}}]}}}}\n\n", .{id});
        var out_buf: [4096]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buf, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n{x}\r\n{s}\r\n", .{ event.len, event });
        try w.writeAll(out);
        try w.flush();
    }
};

test "MCP http client speaks streamable http with session reuse and sse responses" {
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var fake: FakeMcp = .{};
    var serving = std.Io.async(io, FakeMcp.serve, .{ &fake, &server, io });
    defer serving.cancel(io);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var manager = Manager.init(std.testing.allocator, io);
    manager.loadServers(&.{.{ .name = "fake", .tools_prefix = "fk_", .url = url, .key = "test-key", .timeout_s = 10 }});

    const tools = manager.registeredTools();
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("fk_echo", tools[0].tool.def.name);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try manager.clients.items[0].callTool(arena.allocator(), "echo", "{}");
    try std.testing.expectEqualStrings("hello", result.text);
    try std.testing.expect(!result.is_error);

    try std.testing.expectEqual(@as(usize, 2), fake.inits);
    try std.testing.expectEqual(@as(usize, 2), fake.notifications);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.saw_session_header);
    try std.testing.expect(fake.saw_reinit_session_header);
    try std.testing.expect(fake.saw_auth_header);

    manager.deinit();
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
    transport: Transport,
    next_id: i64 = 1,
    mu: std.Io.Mutex = .init,

    const Transport = union(enum) {
        stdio: Stdio,
        http: Http,
    };

    const Stdio = struct {
        argv: []const []const u8,
        child: std.process.Child,
    };

    const Http = struct {
        url: []const u8,
        authorization: ?[]const u8,
        client: std.http.Client,
        session_id: ?[]const u8 = null,
        timeout_ms: u64,
    };

    fn start(alloc: std.mem.Allocator, io: std.Io, cfg: ServerConfig) !Client {
        if (cfg.url) |url| return startHttp(alloc, io, cfg, url);
        return startStdio(alloc, io, cfg);
    }

    fn startStdio(alloc: std.mem.Allocator, io: std.Io, cfg: ServerConfig) !Client {
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
            .transport = .{ .stdio = .{ .argv = argv, .child = child } },
        };
    }

    fn startHttp(alloc: std.mem.Allocator, io: std.Io, cfg: ServerConfig, url: []const u8) !Client {
        const authorization: ?[]const u8 = try resolveAuthorization(alloc, cfg);
        errdefer if (authorization) |a| alloc.free(a);
        const url_dup = try alloc.dupe(u8, url);
        errdefer alloc.free(url_dup);
        const name = try alloc.dupe(u8, cfg.name);
        errdefer alloc.free(name);

        return .{
            .alloc = alloc,
            .io = io,
            .name = name,
            .transport = .{ .http = .{
                .url = url_dup,
                .authorization = authorization,
                .client = .{ .allocator = alloc, .io = io },
                .timeout_ms = std.math.mul(u64, cfg.timeout_s, std.time.ms_per_s) catch std.math.maxInt(u64),
            } },
        };
    }

    fn resolveAuthorization(alloc: std.mem.Allocator, cfg: ServerConfig) !?[]const u8 {
        if (cfg.key_envar) |envar| {
            const name = try alloc.dupeZ(u8, envar);
            defer alloc.free(name);
            if (std.c.getenv(name.ptr)) |value| {
                const token = std.mem.span(value);
                if (token.len > 0) return try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
            }
        }
        if (cfg.key) |key| {
            if (key.len > 0) return try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
        }
        return null;
    }

    fn deinit(self: *Client) void {
        switch (self.transport) {
            .stdio => |*t| {
                if (t.child.id != null) t.child.kill(self.io);
                freeArgv(self.alloc, t.argv);
            },
            .http => |*t| {
                t.client.deinit();
                self.alloc.free(t.url);
                if (t.authorization) |a| self.alloc.free(a);
                if (t.session_id) |s| self.alloc.free(s);
            },
        }
        self.alloc.free(self.name);
    }

    fn initialize(self: *Client) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.initializeLocked();
    }

    fn initializeLocked(self: *Client) !void {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        var w = &req.writer;

        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"blitz\",\"version\":\"0.1\"}}}}}}\n",
            .{ id, PROTOCOL_VERSION },
        );

        const response = try self.requestLocked(id, req.written());
        defer response.deinit();
        _ = try responseResult(&response.value);

        const notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        switch (self.transport) {
            .stdio => |*t| try self.stdioWrite(t, notification),
            .http => |*t| {
                const parsed = try self.httpRequestTimed(t, null, notification);
                parsed.deinit();
            },
        }
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

    fn callTool(self: *Client, alloc: std.mem.Allocator, remote_name: []const u8, arguments_json: []const u8) !ToolCallResult {
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
            .text = try alloc.dupe(u8, ""),
            .is_error = is_error,
        };
        const text = try flattenContent(alloc, &content_val);
        return .{ .text = text, .is_error = is_error };
    }

    fn request(self: *Client, id: i64, line: []const u8) !std.json.Parsed(std.json.Value) {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.requestWithRetry(id, line, 0);
    }

    fn requestWithRetry(self: *Client, id: ?i64, line: []const u8, attempt: u8) !std.json.Parsed(std.json.Value) {
        return self.requestLocked(id, line) catch |err| switch (err) {
            error.McpSessionExpired => blk: {
                if (attempt > 0) break :blk err;
                switch (self.transport) {
                    .http => |*t| {
                        if (t.session_id) |old| {
                            self.alloc.free(old);
                            t.session_id = null;
                        }
                        try self.initializeLocked();
                    },
                    else => break :blk err,
                }
                break :blk try self.requestWithRetry(id, line, 1);
            },
            else => err,
        };
    }

    fn requestLocked(self: *Client, id: ?i64, line: []const u8) !std.json.Parsed(std.json.Value) {
        return switch (self.transport) {
            .stdio => |*t| self.stdioRoundTrip(t, id.?, line),
            .http => |*t| self.httpRequestTimed(t, id, line),
        };
    }

    fn stdioRoundTrip(self: *Client, t: *Stdio, id: i64, line: []const u8) !std.json.Parsed(std.json.Value) {
        try self.stdioWrite(t, line);

        while (true) {
            const response_line = try self.readLine(t);
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

    fn stdioWrite(self: *Client, t: *Stdio, line: []const u8) !void {
        try std.Io.File.writeStreamingAll(t.child.stdin.?, self.io, line);
    }

    fn readLine(self: *Client, t: *Stdio) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.alloc);

        while (list.items.len < MAX_LINE) {
            var byte: [1]u8 = undefined;
            const n = try std.Io.File.readStreaming(t.child.stdout.?, self.io, &.{&byte});
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

    const HttpSelection = union(enum) {
        response: anyerror!std.json.Parsed(std.json.Value),
        timeout: void,
    };

    fn httpRequestTimed(self: *Client, t: *Http, id: ?i64, body: []const u8) !std.json.Parsed(std.json.Value) {
        if (t.timeout_ms == 0) return self.httpExchange(t, id, body);
        var buffer: [2]HttpSelection = undefined;
        var select = std.Io.Select(HttpSelection).init(self.io, &buffer);
        select.async(.response, httpExchange, .{ self, t, id, body });
        select.async(.timeout, timeoutTask, .{ self.io, t.timeout_ms });
        switch (try select.await()) {
            .response => |response| {
                select.cancelDiscard();
                return response;
            },
            .timeout => {
                while (select.cancel()) |selection| switch (selection) {
                    .response => |maybe| if (maybe) |value| {
                        value.deinit();
                    } else |_| {},
                    .timeout => {},
                };
                return error.Timeout;
            },
        }
    }

    fn timeoutTask(io: std.Io, timeout_ms: u64) void {
        std.Io.sleep(io, .fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
    }

    fn httpExchange(self: *Client, t: *Http, id: ?i64, body: []const u8) !std.json.Parsed(std.json.Value) {
        var headers_buf: [4]std.http.Header = undefined;
        var header_count: usize = 0;
        headers_buf[header_count] = .{ .name = "accept", .value = "application/json, text/event-stream" };
        header_count += 1;
        if (t.authorization) |a| {
            headers_buf[header_count] = .{ .name = "authorization", .value = a };
            header_count += 1;
        }
        if (t.session_id) |sid| {
            headers_buf[header_count] = .{ .name = "mcp-session-id", .value = sid };
            header_count += 1;
            headers_buf[header_count] = .{ .name = "mcp-protocol-version", .value = PROTOCOL_VERSION };
            header_count += 1;
        }

        const uri = std.Uri.parse(t.url) catch return error.InvalidMcpUrl;
        var req = t.client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
            },
            .extra_headers = headers_buf[0..header_count],
        }) catch return error.NetworkError;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var request_body = req.sendBodyUnflushed(&.{}) catch return error.NetworkError;
        request_body.writer.writeAll(body) catch return error.NetworkError;
        request_body.end() catch return error.NetworkError;
        req.connection.?.flush() catch return error.NetworkError;

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
        const status = response.head.status;
        const content_type_raw = response.head.content_type orelse "";
        var content_type_buf: [64]u8 = undefined;
        const content_type = content_type_buf[0..@min(content_type_raw.len, content_type_buf.len)];
        @memcpy(content_type, content_type_raw[0..content_type.len]);
        try self.captureSession(t, &response.head);

        if (status == .not_found and t.session_id != null) return error.McpSessionExpired;
        if (@intFromEnum(status) >= 400) {
            const reader = response.reader(&.{});
            try self.drainAndWarn(reader, status);
            return error.McpHttpError;
        }
        if (id == null) {
            return std.json.parseFromSlice(std.json.Value, self.alloc, "{}", .{});
        }

        const reader = response.reader(&.{});
        if (std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")) {
            return self.readSseResponse(reader, id.?);
        }
        return self.readJsonResponse(reader, id.?);
    }

    fn captureSession(self: *Client, t: *Http, head: *const std.http.Client.Response.Head) !void {
        var it = head.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            const duped = try self.alloc.dupe(u8, header.value);
            if (t.session_id) |old| self.alloc.free(old);
            t.session_id = duped;
            return;
        }
    }

    fn drainAndWarn(self: *Client, reader: *std.Io.Reader, status: std.http.Status) !void {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var scratch: [4 * 1024]u8 = undefined;
        while (output.items.len < scratch.len) {
            var writer = std.Io.Writer.fixed(&scratch);
            _ = reader.stream(&writer, .limited(scratch.len)) catch break;
            if (writer.end == 0) break;
            try output.appendSlice(self.alloc, scratch[0..writer.end]);
        }
        log.warn("MCP http {d}: {s}", .{ @intFromEnum(status), output.items });
        output.deinit(self.alloc);
    }

    fn readJsonResponse(self: *Client, reader: *std.Io.Reader, id: i64) !std.json.Parsed(std.json.Value) {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var scratch: [16 * 1024]u8 = undefined;
        while (true) {
            var writer = std.Io.Writer.fixed(&scratch);
            _ = reader.stream(&writer, .limited(scratch.len)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.NetworkError,
                error.WriteFailed => unreachable,
            };
            if (output.items.len + writer.end > MAX_LINE) return error.StreamTooLong;
            try output.appendSlice(self.alloc, scratch[0..writer.end]);
        }
        const body = try output.toOwnedSlice(self.alloc);
        defer self.alloc.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (!jsonIdMatches(&parsed.value, id)) {
            parsed.deinit();
            return error.InvalidMcpResponse;
        }
        return parsed;
    }

    fn readSseResponse(self: *Client, reader: *std.Io.Reader, id: i64) !std.json.Parsed(std.json.Value) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.alloc);
        var scratch: [16 * 1024]u8 = undefined;
        var total: usize = 0;

        while (true) {
            var writer = std.Io.Writer.fixed(&scratch);
            _ = reader.stream(&writer, .limited(scratch.len)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.NetworkError,
                error.WriteFailed => unreachable,
            };
            if (writer.end == 0) continue;
            total += writer.end;
            if (total > MAX_LINE) return error.StreamTooLong;

            for (scratch[0..writer.end]) |ch| {
                if (ch != '\n') {
                    try line.append(self.alloc, ch);
                    if (line.items.len > MAX_LINE) return error.StreamTooLong;
                    continue;
                }
                const trimmed = std.mem.trimEnd(u8, line.items, "\r");
                if (trimmed.len == 0) {
                    if (try self.matchSseData(data.items, id)) |parsed| {
                        return parsed;
                    }
                    data.clearRetainingCapacity();
                } else if (std.mem.startsWith(u8, trimmed, "data:")) {
                    const payload = std.mem.trim(u8, trimmed["data:".len..], " \t");
                    if (data.items.len > 0) try data.append(self.alloc, '\n');
                    try data.appendSlice(self.alloc, payload);
                }
                line.clearRetainingCapacity();
            }
        }
        if (try self.matchSseData(data.items, id)) |parsed| return parsed;
        return error.InvalidMcpResponse;
    }

    fn matchSseData(self: *Client, payload: []const u8, id: i64) !?std.json.Parsed(std.json.Value) {
        if (payload.len == 0) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return null;
        if (!jsonIdMatches(&parsed.value, id)) {
            parsed.deinit();
            return null;
        }
        return parsed;
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
    if (objectGet(value, "method") != null) return false;
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
