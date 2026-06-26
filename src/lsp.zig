const std = @import("std");
const prv = @import("provider");
const r = @import("root.zig");

const log = std.log.scoped(.lsp);

pub const MAX_HEADER = 16 * 1024;
pub const MAX_BODY = 8 * 1024 * 1024;
pub const TOOL_NAME = "lsp";

pub const ServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    root: []const u8 = ".",
    language_id: []const u8 = "plaintext",
};

pub const RegisteredTool = struct {
    tool: prv.tool.Tool,
    flags: r.ContextFactory.ToolFlags,
};

const Binding = struct {
    name: []const u8,
    client_index: usize,
};

pub const Manager = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    clients: std.ArrayList(Client) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
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
        for (self.bindings.items) |binding| self.alloc.free(binding.name);
        self.clients.clearRetainingCapacity();
        self.bindings.clearRetainingCapacity();
        self.tools.clearRetainingCapacity();
    }

    pub fn loadServers(self: *Manager, configs: []const ServerConfig) void {
        self.clear();
        active_manager = self;

        for (configs) |cfg| {
            self.addServer(cfg) catch |err| {
                log.warn("failed to load LSP server '{s}': {s}", .{ cfg.name, @errorName(err) });
                continue;
            };
        }

        if (self.clients.items.len > 0) {
            self.tools.append(self.alloc, .{
                .tool = .{
                    .def = .{
                        .name = TOOL_NAME,
                        .description =
                        \\Query a configured language server. Use this for precise code navigation when available.
                        \\Supported ops: hover, definition, references, document_symbols, workspace_symbols.
                        \\Lines and columns are 1-based.
                        ,
                        .parameters_schema =
                        \\{
                        \\  "type": "object",
                        \\  "properties": {
                        \\    "server": {"type": "string", "description": "Configured LSP name. Optional when only one LSP server is enabled."},
                        \\    "op": {"type": "string", "enum": ["hover", "definition", "references", "document_symbols", "workspace_symbols"]},
                        \\    "path": {"type": "string", "description": "File path for textDocument operations"},
                        \\    "line": {"type": "number", "description": "1-based line for hover/definition/references"},
                        \\    "column": {"type": "number", "description": "1-based column for hover/definition/references"},
                        \\    "query": {"type": "string", "description": "Workspace symbol query"},
                        \\    "include_declaration": {"type": "boolean", "default": false}
                        \\  },
                        \\  "required": ["op"]
                        \\}
                        ,
                    },
                    .func = &toolTrampoline,
                },
                .flags = .{
                    .allowed_agents = .initFull(),
                    .add_to_agents = true,
                },
            }) catch {};
        }
    }

    pub fn registeredTools(self: *Manager) []const RegisteredTool {
        return self.tools.items;
    }

    fn addServer(self: *Manager, cfg: ServerConfig) !void {
        var client = try Client.start(self.alloc, self.io, cfg);
        errdefer client.deinit();

        try client.initialize();
        const client_index = self.clients.items.len;
        try self.clients.append(self.alloc, client);
        try self.bindings.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, cfg.name),
            .client_index = client_index,
        });
    }

    fn findBinding(self: *Manager, server_name: ?[]const u8) ?Binding {
        if (server_name) |name| {
            for (self.bindings.items) |binding| {
                if (std.mem.eql(u8, binding.name, name)) return binding;
            }
        }
        if (self.bindings.items.len == 1) return self.bindings.items[0];
        return null;
    }

    fn namesText(self: *Manager, alloc: std.mem.Allocator) []const u8 {
        if (self.bindings.items.len == 0) return "no LSP servers are loaded";
        var out = std.Io.Writer.Allocating.init(alloc);
        errdefer out.deinit();
        out.writer.writeAll("valid LSP names: ") catch return "unknown LSP server name";
        for (self.bindings.items, 0..) |binding, i| {
            if (i > 0) out.writer.writeAll(", ") catch return "unknown LSP server name";
            out.writer.writeAll(binding.name) catch return "unknown LSP server name";
        }
        return out.toOwnedSlice() catch "unknown LSP server name";
    }
};

var active_manager: ?*Manager = null;

fn toolTrampoline(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        server: ?[]const u8 = null,
        op: []const u8,
        path: ?[]const u8 = null,
        line: ?u32 = null,
        column: ?u32 = null,
        query: ?[]const u8 = null,
        include_declaration: bool = false,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return errResult(call, "invalid JSON arguments");

    const manager = active_manager orelse return errResult(call, "LSP manager not initialized");
    const binding = manager.findBinding(args.server) orelse return errResult(call, manager.namesText(ctx.alloc));
    if (binding.client_index >= manager.clients.items.len) return errResult(call, "LSP client missing");

    r.tools.setToolStatusPrint(ctx, call, "LSP {s} {s} {s}", .{ binding.name, args.op, args.query orelse "" });
    const client = &manager.clients.items[binding.client_index];

    const content = runOp(ctx, client, args) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "LSP request failed: {s}", .{@errorName(err)}) catch "LSP request failed";
        return errResult(call, msg);
    };
    return r.tools.okResult(call, r.tools.truncateOutputToOwned(ctx.alloc, content, r.tools.MAX_DISPLAY_BYTES, r.tools.MAX_DISPLAY_LINES));
}

fn runOp(ctx: prv.tool.ToolContext, client: *Client, args: anytype) ![]const u8 {
    if (std.mem.eql(u8, args.op, "workspace_symbols")) {
        return client.workspaceSymbols(ctx.alloc, args.query orelse "");
    }

    const path = args.path orelse return error.PathRequired;
    const resolved = try std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, path });
    const text = try readFileForLsp(ctx, resolved);
    defer ctx.swarm.exec.alloc.free(text);
    const uri = try pathToUri(ctx.alloc, resolved);
    try client.ensureDocument(uri, text);

    if (std.mem.eql(u8, args.op, "document_symbols")) {
        return client.documentSymbols(ctx.alloc, uri);
    }

    const line = args.line orelse return error.LineRequired;
    const column = args.column orelse 1;
    const pos = Position{
        .line = if (line > 0) line - 1 else 0,
        .character = if (column > 0) column - 1 else 0,
    };

    if (std.mem.eql(u8, args.op, "hover")) return client.hover(ctx.alloc, uri, pos);
    if (std.mem.eql(u8, args.op, "definition")) return client.locationRequest(ctx.alloc, "textDocument/definition", uri, pos);
    if (std.mem.eql(u8, args.op, "references")) return client.references(ctx.alloc, uri, pos, args.include_declaration);

    return error.UnknownOperation;
}

fn readFileForLsp(ctx: prv.tool.ToolContext, resolved: []const u8) ![]const u8 {
    const res = try ctx.swarm.exec.runAndWait(.{ .argv = &.{ "cat", resolved } });
    defer ctx.swarm.exec.alloc.free(res.stderr);
    if (res.ty != .success) {
        ctx.swarm.exec.alloc.free(res.stdout);
        return error.ReadFailed;
    }
    return res.stdout;
}

fn errResult(call: prv.adapter.ToolCall, msg: []const u8) prv.adapter.ToolResult {
    return .{ .call_id = call.id, .name = call.name, .content = msg, .is_error = true };
}

const Position = struct {
    line: u32,
    character: u32,
};

const OpenDoc = struct {
    uri: []const u8,
    version: i32,
};

const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    argv: []const []const u8,
    root_uri: []const u8,
    language_id: []const u8,
    child: std.process.Child,
    next_id: i64 = 1,
    mu: std.Io.Mutex = .init,
    open_docs: std.ArrayList(OpenDoc) = .empty,

    fn start(alloc: std.mem.Allocator, io: std.Io, cfg: ServerConfig) !Client {
        const argv = try buildArgv(alloc, cfg.command, cfg.args);
        errdefer freeArgv(alloc, argv);

        const root_path = try std.fs.path.resolve(alloc, &.{cfg.root});
        errdefer alloc.free(root_path);
        const root_uri = try pathToUri(alloc, root_path);
        alloc.free(root_path);
        errdefer alloc.free(root_uri);

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
            .root_uri = root_uri,
            .language_id = try alloc.dupe(u8, cfg.language_id),
            .child = child,
        };
    }

    fn deinit(self: *Client) void {
        if (self.child.id != null) self.child.kill(self.io);
        for (self.open_docs.items) |doc| self.alloc.free(doc.uri);
        self.open_docs.deinit(self.alloc);
        self.alloc.free(self.name);
        self.alloc.free(self.root_uri);
        self.alloc.free(self.language_id);
        freeArgv(self.alloc, self.argv);
    }

    fn initialize(self: *Client) !void {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        try req.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"processId\":null,\"rootUri\":",
            .{id},
        );
        try writeJsonString(&req.writer, self.root_uri);
        try req.writer.writeAll(",\"capabilities\":{\"workspace\":{\"configuration\":false},\"textDocument\":{\"synchronization\":{\"didSave\":false}}},\"clientInfo\":{\"name\":\"blitz\",\"version\":\"0.1\"}}}");

        const response = try self.request(id, req.written());
        defer response.deinit();
        _ = try responseResult(&response.value);
        try self.sendNotification("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    }

    fn ensureDocument(self: *Client, uri: []const u8, text: []const u8) !void {
        var version: i32 = 1;
        var found = false;
        for (self.open_docs.items) |*doc| {
            if (std.mem.eql(u8, doc.uri, uri)) {
                doc.version += 1;
                version = doc.version;
                found = true;
                break;
            }
        }

        var msg = std.Io.Writer.Allocating.init(self.alloc);
        defer msg.deinit();
        const w = &msg.writer;

        if (found) {
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":");
            try writeJsonString(w, uri);
            try w.print(",\"version\":{d}", .{version});
            try w.writeAll("},\"contentChanges\":[{\"text\":");
            try writeJsonString(w, text);
            try w.writeAll("}]}}");
        } else {
            try self.open_docs.append(self.alloc, .{
                .uri = try self.alloc.dupe(u8, uri),
                .version = version,
            });
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
            try writeJsonString(w, uri);
            try w.writeAll(",\"languageId\":");
            try writeJsonString(w, self.language_id);
            try w.print(",\"version\":{d},\"text\":", .{version});
            try writeJsonString(w, text);
            try w.writeAll("}}}");
        }

        try self.sendNotification(msg.written());
    }

    fn hover(self: *Client, alloc: std.mem.Allocator, uri: []const u8, pos: Position) ![]const u8 {
        const result = try self.positionRequest("textDocument/hover", uri, pos);
        defer result.deinit();
        return formatHover(alloc, &result.value);
    }

    fn locationRequest(self: *Client, alloc: std.mem.Allocator, method: []const u8, uri: []const u8, pos: Position) ![]const u8 {
        const result = try self.positionRequest(method, uri, pos);
        defer result.deinit();
        return formatLocations(alloc, &result.value);
    }

    fn references(self: *Client, alloc: std.mem.Allocator, uri: []const u8, pos: Position, include_declaration: bool) ![]const u8 {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        const w = &req.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/references\",\"params\":{{\"textDocument\":{{\"uri\":", .{id});
        try writeJsonString(w, uri);
        try w.writeAll("},\"position\":{\"line\":");
        try w.print("{d}", .{pos.line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{pos.character});
        try w.writeAll("},\"context\":{\"includeDeclaration\":");
        try w.writeAll(if (include_declaration) "true" else "false");
        try w.writeAll("}}}");

        const result = try self.requestResult(id, req.written());
        defer result.deinit();
        return formatLocations(alloc, &result.value);
    }

    fn documentSymbols(self: *Client, alloc: std.mem.Allocator, uri: []const u8) ![]const u8 {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        const w = &req.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/documentSymbol\",\"params\":{{\"textDocument\":{{\"uri\":", .{id});
        try writeJsonString(w, uri);
        try w.writeAll("}}}");

        const result = try self.requestResult(id, req.written());
        defer result.deinit();
        return formatSymbols(alloc, &result.value);
    }

    fn workspaceSymbols(self: *Client, alloc: std.mem.Allocator, query: []const u8) ![]const u8 {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        const w = &req.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/symbol\",\"params\":{{\"query\":", .{id});
        try writeJsonString(w, query);
        try w.writeAll("}}");

        const result = try self.requestResult(id, req.written());
        defer result.deinit();
        return formatSymbols(alloc, &result.value);
    }

    fn positionRequest(self: *Client, method: []const u8, uri: []const u8, pos: Position) !std.json.Parsed(std.json.Value) {
        const id = self.nextRequestId();
        var req = std.Io.Writer.Allocating.init(self.alloc);
        defer req.deinit();
        const w = &req.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
        try writeJsonString(w, method);
        try w.writeAll(",\"params\":{\"textDocument\":{\"uri\":");
        try writeJsonString(w, uri);
        try w.writeAll("},\"position\":{\"line\":");
        try w.print("{d}", .{pos.line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{pos.character});
        try w.writeAll("}}}");
        return self.requestResult(id, req.written());
    }

    fn requestResult(self: *Client, id: i64, payload: []const u8) !std.json.Parsed(std.json.Value) {
        const response = try self.request(id, payload);
        errdefer response.deinit();
        _ = try responseResult(&response.value);
        return response;
    }

    fn request(self: *Client, id: i64, payload: []const u8) !std.json.Parsed(std.json.Value) {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        try self.writeMessage(payload);
        while (true) {
            const body = try self.readMessage();
            defer self.alloc.free(body);
            const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            errdefer parsed.deinit();

            if (jsonIdMatches(&parsed.value, id)) return parsed;
            if (isServerRequest(&parsed.value)) {
                try self.replyToServerRequest(&parsed.value);
            }
            parsed.deinit();
        }
    }

    fn sendNotification(self: *Client, payload: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.writeMessage(payload);
    }

    fn writeMessage(self: *Client, payload: []const u8) !void {
        var header: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{payload.len});
        try std.Io.File.writeStreamingAll(self.child.stdin.?, self.io, line);
        try std.Io.File.writeStreamingAll(self.child.stdin.?, self.io, payload);
    }

    fn replyToServerRequest(self: *Client, value: *const std.json.Value) !void {
        const id_val = objectGet(value, "id") orelse return;
        const method = stringField(value, "method") orelse "";
        var payload = std.Io.Writer.Allocating.init(self.alloc);
        defer payload.deinit();
        try payload.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id_val, .{}, &payload.writer);
        if (std.mem.eql(u8, method, "workspace/configuration")) {
            try payload.writer.writeAll(",\"result\":[]}");
        } else {
            try payload.writer.writeAll(",\"result\":null}");
        }
        try self.writeMessage(payload.written());
    }

    fn readMessage(self: *Client) ![]u8 {
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(self.alloc);

        while (header.items.len < MAX_HEADER) {
            var byte: [1]u8 = undefined;
            const n = try std.Io.File.readStreaming(self.child.stdout.?, self.io, &.{&byte});
            if (n == 0) continue;
            try header.append(self.alloc, byte[0]);
            if (std.mem.endsWith(u8, header.items, "\r\n\r\n")) break;
        }
        if (header.items.len >= MAX_HEADER) return error.HeaderTooLong;

        const len = parseContentLength(header.items) orelse return error.MissingContentLength;
        if (len > MAX_BODY) return error.BodyTooLong;

        const body = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(body);
        var off: usize = 0;
        while (off < len) {
            const n = try std.Io.File.readStreaming(self.child.stdout.?, self.io, &.{body[off..]});
            if (n == 0) continue;
            off += n;
        }
        return body;
    }

    fn nextRequestId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

fn parseContentLength(header: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, header, "\r\n");
    while (it.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..sep], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const val = std.mem.trim(u8, line[sep + 1 ..], " \t");
        return std.fmt.parseInt(usize, val, 10) catch null;
    }
    return null;
}

fn responseResult(value: *const std.json.Value) !std.json.Value {
    if (value.* != .object) return error.InvalidLspResponse;
    if (objectGet(value, "error")) |_| return error.LspErrorResponse;
    return objectGet(value, "result") orelse std.json.Value{ .null = {} };
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

fn isServerRequest(value: *const std.json.Value) bool {
    return objectGet(value, "id") != null and stringField(value, "method") != null;
}

fn buildArgv(alloc: std.mem.Allocator, command: []const u8, args: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, args.len + 1);
    errdefer alloc.free(out);
    out[0] = try alloc.dupe(u8, command);
    errdefer alloc.free(out[0]);
    for (args, 0..) |arg, i| out[i + 1] = try alloc.dupe(u8, arg);
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("file://");
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.writer.writeByte(ch);
        } else {
            try out.writer.print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice();
}

fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const rest = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const b = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch rest[i];
            try out.writer.writeByte(b);
            i += 2;
        } else {
            try out.writer.writeByte(rest[i]);
        }
    }
    return out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn stringifyValue(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn formatHover(alloc: std.mem.Allocator, value: *const std.json.Value) ![]const u8 {
    const result = try responseResult(value);
    if (result == .null) return alloc.dupe(u8, "no hover");
    const contents = objectGet(&result, "contents") orelse return stringifyValue(alloc, result);
    return formatMarkedText(alloc, &contents);
}

fn formatMarkedText(alloc: std.mem.Allocator, value: *const std.json.Value) ![]const u8 {
    switch (value.*) {
        .string => |s| return alloc.dupe(u8, s),
        .object => {
            if (stringField(value, "value")) |s| return alloc.dupe(u8, s);
            return stringifyValue(alloc, value.*);
        },
        .array => {
            var out = std.Io.Writer.Allocating.init(alloc);
            errdefer out.deinit();
            for (value.array.items, 0..) |*item, i| {
                if (i > 0) try out.writer.writeByte('\n');
                const txt = try formatMarkedText(alloc, item);
                try out.writer.writeAll(txt);
            }
            return out.toOwnedSlice();
        },
        else => return stringifyValue(alloc, value.*),
    }
}

fn formatLocations(alloc: std.mem.Allocator, value: *const std.json.Value) ![]const u8 {
    const result = try responseResult(value);
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();

    if (result == .array) {
        if (result.array.items.len == 0) return alloc.dupe(u8, "no locations");
        for (result.array.items) |*item| try writeLocation(&out.writer, alloc, item);
    } else if (result == .object) {
        try writeLocation(&out.writer, alloc, &result);
    } else if (result == .null) {
        try out.writer.writeAll("no locations");
    } else {
        try std.json.Stringify.value(result, .{}, &out.writer);
    }
    return out.toOwnedSlice();
}

fn writeLocation(w: *std.Io.Writer, alloc: std.mem.Allocator, value: *const std.json.Value) !void {
    if (value.* != .object) return;
    const uri = stringField(value, "uri") orelse stringField(value, "targetUri") orelse return;
    const range = objectGet(value, "range") orelse objectGet(value, "targetRange") orelse return;
    const start = objectGet(&range, "start") orelse return;
    const line = intField(&start, "line") orelse 0;
    const ch = intField(&start, "character") orelse 0;
    const path = try uriToPath(alloc, uri);
    try w.print("{s}:{d}:{d}\n", .{ path, line + 1, ch + 1 });
}

fn formatSymbols(alloc: std.mem.Allocator, value: *const std.json.Value) ![]const u8 {
    const result = try responseResult(value);
    if (result == .null) return alloc.dupe(u8, "no symbols");
    if (result != .array) return stringifyValue(alloc, result);

    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    if (result.array.items.len == 0) return alloc.dupe(u8, "no symbols");
    for (result.array.items) |*item| try writeSymbol(&out.writer, alloc, item, 0);
    return out.toOwnedSlice();
}

fn writeSymbol(w: *std.Io.Writer, alloc: std.mem.Allocator, value: *const std.json.Value, depth: usize) !void {
    if (value.* != .object) return;
    const name = stringField(value, "name") orelse return;
    for (0..depth) |_| try w.writeAll("  ");
    try w.writeAll(name);

    if (objectGet(value, "location")) |loc| {
        try w.writeAll(" ");
        try writeLocation(w, alloc, &loc);
    } else if (objectGet(value, "range")) |range| {
        if (objectGet(&range, "start")) |start| {
            const line = intField(&start, "line") orelse 0;
            const ch = intField(&start, "character") orelse 0;
            try w.print(":{d}:{d}\n", .{ line + 1, ch + 1 });
        } else try w.writeByte('\n');
    } else try w.writeByte('\n');

    if (objectGet(value, "children")) |children| {
        if (children == .array) for (children.array.items) |*child| try writeSymbol(w, alloc, child, depth + 1);
    }
}

fn intField(value: *const std.json.Value, key: []const u8) ?i64 {
    const field = objectGet(value, key) orelse return null;
    return switch (field) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

test "parse content length" {
    try std.testing.expectEqual(@as(?usize, 12), parseContentLength("Content-Length: 12\r\n\r\n"));
}
