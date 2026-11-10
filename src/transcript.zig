const std = @import("std");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

const AgentNode = struct {
    agent: *const session.WireAgent,
    archived: bool,
};

const AgentTree = struct {
    nodes: []const AgentNode,
    child_indices: []const []const usize,
    roots: []const usize,

    fn build(alloc: std.mem.Allocator, save: *const session.SaveState) !AgentTree {
        var nodes: std.ArrayList(AgentNode) = .empty;
        if (save.main_metadata) |*main| try nodes.append(alloc, .{ .agent = main, .archived = false });
        for (save.agents) |*agent| try nodes.append(alloc, .{ .agent = agent, .archived = false });
        for (save.archived_agents) |*agent| try nodes.append(alloc, .{ .agent = agent, .archived = true });
        std.mem.sort(AgentNode, nodes.items, {}, nodeLessThan);

        var index_by_id: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer index_by_id.deinit(alloc);
        for (nodes.items, 0..) |node, index| try index_by_id.put(alloc, node.agent.id, index);

        const grouped = try alloc.alloc(std.ArrayList(usize), nodes.items.len);
        for (grouped) |*children| children.* = .empty;
        var roots: std.ArrayList(usize) = .empty;
        for (nodes.items, 0..) |node, index| {
            const parent = if (node.agent.parent) |id| index_by_id.get(id) else null;
            if (parent) |parent_index| {
                try grouped[parent_index].append(alloc, index);
            } else {
                try roots.append(alloc, index);
            }
        }
        const child_indices = try alloc.alloc([]const usize, nodes.items.len);
        for (grouped, child_indices) |*children, *slice| slice.* = children.items;

        const visited = try alloc.alloc(bool, nodes.items.len);
        @memset(visited, false);
        var stack: std.ArrayList(usize) = .empty;
        try stack.appendSlice(alloc, roots.items);
        while (stack.pop()) |index| {
            if (visited[index]) continue;
            visited[index] = true;
            try stack.appendSlice(alloc, child_indices[index]);
        }
        for (visited) |seen| if (!seen) return error.CyclicAgentTree;

        return .{ .nodes = nodes.items, .child_indices = child_indices, .roots = roots.items };
    }
};

fn nodeLessThan(_: void, a: AgentNode, b: AgentNode) bool {
    return a.agent.id < b.agent.id;
}

pub fn writeJson(
    alloc: std.mem.Allocator,
    header: *const session_store.Header,
    save: *const session.SaveState,
    out: *std.Io.Writer,
) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const tree = try AgentTree.build(arena_alloc, save);

    try out.writeAll("{\"session\":{\"id\":");
    try writeString(out, header.id);
    try out.writeAll(",\"created_ms\":");
    try out.print("{d}", .{header.created_ms});
    try out.writeAll(",\"cwd\":");
    try writeString(out, header.cwd);
    try out.writeAll(",\"main_agent_id\":");
    if (save.main_agent) |id| try out.print("{d}", .{id}) else try out.writeAll("null");
    try out.writeAll("},\"agents\":[");
    for (tree.roots, 0..) |index, position| {
        if (position > 0) try out.writeByte(',');
        try writeAgent(arena_alloc, &tree, index, out);
    }
    try out.writeAll("]}");
}

fn writeAgent(
    alloc: std.mem.Allocator,
    tree: *const AgentTree,
    index: usize,
    out: *std.Io.Writer,
) !void {
    const node = tree.nodes[index];
    const agent = node.agent;
    try out.writeAll("{\"id\":");
    try out.print("{d}", .{agent.id});
    try out.writeAll(",\"name\":");
    try writeString(out, agent.name);
    try out.writeAll(",\"type_idx\":");
    try out.print("{d}", .{agent.type_idx});
    try out.writeAll(",\"parent_id\":");
    if (agent.parent) |parent| try out.print("{d}", .{parent}) else try out.writeAll("null");
    try out.writeAll(",\"depth\":");
    try out.print("{d}", .{agent.depth});
    try out.writeAll(",\"cwd\":");
    try writeString(out, agent.cwd);
    try out.writeAll(",\"background\":");
    try out.writeAll(if (agent.background) "true" else "false");
    try out.writeAll(",\"clean\":");
    try out.writeAll(if (agent.clean) "true" else "false");
    try out.writeAll(",\"task_description\":");
    try writeString(out, agent.task_description);
    try out.writeAll(",\"archived\":");
    try out.writeAll(if (node.archived) "true" else "false");
    try out.writeAll(",\"tokens\":");
    try writeTokens(agent.tokens, out);
    try out.writeAll(",\"messages\":");
    try writeMessages(alloc, agent, out);
    try out.writeAll(",\"children\":[");
    for (tree.child_indices[index], 0..) |child, position| {
        if (position > 0) try out.writeByte(',');
        try writeAgent(alloc, tree, child, out);
    }
    try out.writeAll("]}");
}

fn writeTokens(tokens: session.TokenState, out: *std.Io.Writer) !void {
    try out.writeAll("{\"model\":");
    try writeString(out, tokens.model);
    try out.writeAll(",\"usage\":{\"input_tokens\":");
    try out.print("{d}", .{tokens.usage.input_tokens});
    try out.writeAll(",\"output_tokens\":");
    try out.print("{d}", .{tokens.usage.output_tokens});
    try out.writeAll(",\"total_tokens\":");
    try out.print("{d}", .{tokens.usage.total_tokens});
    try out.writeAll(",\"reasoning_tokens\":");
    try out.print("{d}", .{tokens.usage.reasoning_tokens});
    try out.writeAll(",\"cache_read_tokens\":");
    try out.print("{d}", .{tokens.usage.cache_read_tokens});
    try out.writeAll(",\"cache_write_tokens\":");
    try out.print("{d}", .{tokens.usage.cache_write_tokens});
    try out.writeAll("},\"context_tokens\":");
    try out.print("{d}", .{tokens.context_tokens});
    try out.writeAll(",\"context_from_provider\":");
    try out.writeAll(if (tokens.context_from_provider) "true" else "false");
    try out.writeAll(",\"context_estimate\":");
    try out.print("{d}", .{tokens.context_estimate});
    try out.writeByte('}');
}

fn writeMessages(alloc: std.mem.Allocator, agent: *const session.WireAgent, out: *std.Io.Writer) !void {
    try out.writeByte('[');
    var index: usize = 0;
    for (agent.chat) |message| {
        if (!messageExports(message)) continue;
        if (index > 0) try out.writeByte(',');
        try out.writeAll("{\"index\":");
        try out.print("{d}", .{index});
        try out.writeAll(",\"agent_id\":");
        try out.print("{d}", .{agent.id});
        try out.writeAll(",\"role\":");
        try writeString(out, messageRole(message));
        try out.writeAll(",\"parts\":[");
        var first = true;
        for (message.parts) |part| {
            if (!partExports(part)) continue;
            if (!first) try out.writeByte(',');
            first = false;
            try writePart(alloc, part, out);
        }
        try out.writeAll("]}");
        index += 1;
    }
    try out.writeByte(']');
}

fn partExports(part: session.WirePart) bool {
    return switch (part) {
        .text => |text| text.len > 0,
        .thinking => |thinking| thinking.text.len > 0,
        else => true,
    };
}

fn messageExports(message: session.WireMessage) bool {
    for (message.parts) |part| {
        if (partExports(part)) return true;
    }
    return false;
}

fn messageRole(message: session.WireMessage) []const u8 {
    var all_tool_results = true;
    for (message.parts) |part| {
        if (!partExports(part)) continue;
        if (part != .tool_result) all_tool_results = false;
    }
    if (all_tool_results) return "tool";
    return switch (message.role) {
        .agent => "assistant",
        .system => "system",
        .user => "user",
    };
}

fn writePart(alloc: std.mem.Allocator, part: session.WirePart, out: *std.Io.Writer) !void {
    switch (part) {
        .text => |text| {
            try out.writeAll("{\"type\":\"text\",\"text\":");
            try writeString(out, text);
            try out.writeByte('}');
        },
        .thinking => |thinking| {
            try out.writeAll("{\"type\":\"thinking\",\"text\":");
            try writeString(out, thinking.text);
            try out.writeByte('}');
        },
        .image => |image| try writeImage(image, out),
        .tool_call => |call| {
            try out.writeAll("{\"type\":\"tool_call\",\"id\":");
            try writeString(out, call.id);
            try out.writeAll(",\"name\":");
            try writeString(out, call.name);
            try out.writeAll(",\"arguments\":");
            try writeArguments(alloc, call.arguments, out);
            try out.writeByte('}');
        },
        .tool_result => |result| {
            try out.writeAll("{\"type\":\"tool_result\",\"call_id\":");
            try writeString(out, result.call_id);
            try out.writeAll(",\"name\":");
            try writeString(out, result.name);
            try out.writeAll(",\"content\":");
            try writeString(out, result.content);
            try out.writeAll(",\"is_error\":");
            try out.writeAll(if (result.is_error) "true" else "false");
            if (result.image) |image| {
                try out.writeAll(",\"image\":");
                try writeImage(image, out);
            }
            try out.writeByte('}');
        },
    }
}

fn writeImage(image: session.WireImage, out: *std.Io.Writer) !void {
    try out.writeAll("{\"type\":\"image\",\"media_type\":");
    try writeString(out, image.media_type);
    try out.writeAll(",\"data_omitted\":true}");
}

fn writeArguments(alloc: std.mem.Allocator, arguments: []const u8, out: *std.Io.Writer) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try writeString(out, arguments);
            return;
        },
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, out);
}

fn writeString(out: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.encodeJsonString(text, .{}, out);
}

const HEADER = "{\"kind\":\"header\",\"v\":2,\"id\":\"20260101-120000-abcd\",\"created_ms\":1767268800000,\"cwd\":\"/work/project\"}\n";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    io_state: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    base: std.Io.Dir,
    name: []const u8 = "20260101-120000-abcd.jsonl",

    fn init(self: *Fixture, journal: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.io_state = std.Io.Threaded.init(std.testing.allocator, .{});
        self.arena = .init(std.testing.allocator);
        self.base = .{ .handle = self.tmp.dir.handle };
        self.name = "20260101-120000-abcd.jsonl";
        const io = self.io_state.io();
        try self.base.createDirPath(io, "sessions");
        var dir = try self.base.openDir(io, "sessions", .{});
        defer dir.close(io);
        const file = try dir.createFile(io, self.name, .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, journal, 0);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.io_state.deinit();
        self.tmp.cleanup();
    }

    fn load(self: *Fixture) !session_store.Loaded {
        return (try session_store.load(self.arena.allocator(), self.io_state.io(), self.base, self.name)).?;
    }

    fn stat(self: *Fixture) !std.Io.File.Stat {
        const io = self.io_state.io();
        var dir = try self.base.openDir(io, "sessions", .{});
        defer dir.close(io);
        return dir.statFile(io, self.name, .{});
    }

    fn read(self: *Fixture, alloc: std.mem.Allocator) ![]u8 {
        const io = self.io_state.io();
        var dir = try self.base.openDir(io, "sessions", .{});
        defer dir.close(io);
        const file = try dir.openFile(io, self.name, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        return reader.interface.allocRemaining(alloc, .limited(1 << 20));
    }

    fn render(self: *Fixture, alloc: std.mem.Allocator) ![]const u8 {
        const loaded = try self.load();
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try writeJson(alloc, &loaded.header, &loaded.save, &out.writer);
        return out.toOwnedSlice();
    }
};

fn parse(alloc: std.mem.Allocator, document: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, document, .{});
}

fn parseVerbatim(alloc: std.mem.Allocator, document: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, document, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .use_last,
    });
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return value.object.get(name).?;
}

fn element(value: std.json.Value, index: usize) std.json.Value {
    return value.array.items[index];
}

test "export nests the agent tree and carries metadata, roles, parts, and indexes" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":65536,\"name\":\"general\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"agent\",\"agentID\":65537,\"name\":\"worker\",\"type_idx\":1,\"parent\":65536,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":false,\"task_description\":\"scan\"}\n" ++
        "{\"kind\":\"agent\",\"agentID\":65538,\"name\":\"gone\",\"type_idx\":2,\"parent\":65536,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":true,\"task_description\":\"old\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":65536}\n" ++
        "{\"kind\":\"usage\",\"agentID\":65536,\"tokens\":{\"model\":\"model-id\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15},\"context_tokens\":10,\"context_from_provider\":true,\"context_estimate\":10}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"agent\",\"parts\":[{\"thinking\":{\"text\":\"reasoning\"}},{\"tool_call\":{\"id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"call_1\",\"name\":\"read\",\"content\":\"file body\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65537,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"child\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65538,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"archived work\"}]}}\n" ++
        "{\"kind\":\"agent_remove\",\"agentID\":65538}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    const parsed = try parse(arena.allocator(), document);
    const root = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), root.object.count());

    const session_value = field(root, "session");
    try std.testing.expectEqualStrings("20260101-120000-abcd", field(session_value, "id").string);
    try std.testing.expectEqual(@as(i64, 1767268800000), field(session_value, "created_ms").integer);
    try std.testing.expectEqualStrings("/work/project", field(session_value, "cwd").string);
    try std.testing.expectEqual(@as(i64, 65536), field(session_value, "main_agent_id").integer);

    const agents = field(root, "agents");
    try std.testing.expectEqual(@as(usize, 1), agents.array.items.len);
    const main = element(agents, 0);
    try std.testing.expectEqual(@as(i64, 65536), field(main, "id").integer);
    try std.testing.expectEqualStrings("general", field(main, "name").string);
    try std.testing.expectEqual(@as(i64, 0), field(main, "type_idx").integer);
    try std.testing.expect(field(main, "parent_id") == .null);
    try std.testing.expectEqual(@as(i64, 0), field(main, "depth").integer);
    try std.testing.expectEqualStrings("/work/project", field(main, "cwd").string);
    try std.testing.expect(!field(main, "background").bool);
    try std.testing.expect(!field(main, "clean").bool);
    try std.testing.expectEqualStrings("", field(main, "task_description").string);
    try std.testing.expect(!field(main, "archived").bool);

    const tokens = field(main, "tokens");
    try std.testing.expectEqualStrings("model-id", field(tokens, "model").string);
    const usage = field(tokens, "usage");
    try std.testing.expectEqual(@as(i64, 10), field(usage, "input_tokens").integer);
    try std.testing.expectEqual(@as(i64, 5), field(usage, "output_tokens").integer);
    try std.testing.expectEqual(@as(i64, 15), field(usage, "total_tokens").integer);
    try std.testing.expectEqual(@as(i64, 0), field(usage, "reasoning_tokens").integer);
    try std.testing.expectEqual(@as(i64, 0), field(usage, "cache_read_tokens").integer);
    try std.testing.expectEqual(@as(i64, 0), field(usage, "cache_write_tokens").integer);
    try std.testing.expectEqual(@as(i64, 10), field(tokens, "context_tokens").integer);
    try std.testing.expect(field(tokens, "context_from_provider").bool);
    try std.testing.expectEqual(@as(i64, 10), field(tokens, "context_estimate").integer);

    const messages = field(main, "messages");
    try std.testing.expectEqual(@as(usize, 3), messages.array.items.len);
    const hello = element(messages, 0);
    try std.testing.expectEqual(@as(i64, 0), field(hello, "index").integer);
    try std.testing.expectEqual(@as(i64, 65536), field(hello, "agent_id").integer);
    try std.testing.expectEqualStrings("user", field(hello, "role").string);
    try std.testing.expectEqualStrings("hello", field(element(field(hello, "parts"), 0), "text").string);
    const reply = element(messages, 1);
    try std.testing.expectEqual(@as(i64, 1), field(reply, "index").integer);
    try std.testing.expectEqualStrings("assistant", field(reply, "role").string);
    const reply_parts = field(reply, "parts");
    try std.testing.expectEqual(@as(usize, 2), reply_parts.array.items.len);
    try std.testing.expectEqualStrings("thinking", field(element(reply_parts, 0), "type").string);
    try std.testing.expectEqualStrings("reasoning", field(element(reply_parts, 0), "text").string);
    const call = element(reply_parts, 1);
    try std.testing.expectEqualStrings("tool_call", field(call, "type").string);
    try std.testing.expectEqualStrings("call_1", field(call, "id").string);
    try std.testing.expectEqualStrings("read", field(call, "name").string);
    try std.testing.expectEqualStrings("a.txt", field(field(call, "arguments"), "path").string);
    const result = element(messages, 2);
    try std.testing.expectEqual(@as(i64, 2), field(result, "index").integer);
    try std.testing.expectEqualStrings("tool", field(result, "role").string);
    const result_part = element(field(result, "parts"), 0);
    try std.testing.expectEqualStrings("tool_result", field(result_part, "type").string);
    try std.testing.expectEqualStrings("call_1", field(result_part, "call_id").string);
    try std.testing.expectEqualStrings("file body", field(result_part, "content").string);
    try std.testing.expect(!field(result_part, "is_error").bool);

    const children = field(main, "children");
    try std.testing.expectEqual(@as(usize, 2), children.array.items.len);
    const worker = element(children, 0);
    try std.testing.expectEqual(@as(i64, 65537), field(worker, "id").integer);
    try std.testing.expectEqual(@as(i64, 65536), field(worker, "parent_id").integer);
    try std.testing.expectEqual(@as(i64, 1), field(worker, "depth").integer);
    try std.testing.expect(field(worker, "background").bool);
    try std.testing.expectEqualStrings("scan", field(worker, "task_description").string);
    try std.testing.expect(!field(worker, "archived").bool);
    try std.testing.expectEqualStrings("child", field(element(field(worker, "messages"), 0), "parts").array.items[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 0), field(worker, "children").array.items.len);

    const gone = element(children, 1);
    try std.testing.expectEqual(@as(i64, 65538), field(gone, "id").integer);
    try std.testing.expect(field(gone, "archived").bool);
    try std.testing.expect(field(gone, "clean").bool);
    try std.testing.expectEqual(@as(usize, 1), field(gone, "messages").array.items.len);
    try std.testing.expectEqualStrings("archived work", field(element(field(gone, "messages"), 0), "parts").array.items[0].object.get("text").?.string);
}

test "tool arguments stay parsed when valid and become strings otherwise" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"c1\",\"name\":\"run\",\"arguments\":\"{\\\"cmd\\\": \\\"ls\\\", \\\"limit\\\": 5}\"}},{\"tool_call\":{\"id\":\"c2\",\"name\":\"run\",\"arguments\":\"not json\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"c1\",\"name\":\"run\",\"content\":\"\",\"is_error\":true,\"image\":{\"media_type\":\"image/png\",\"data\":\"QUJD\"}}},{\"tool_result\":{\"call_id\":\"c2\",\"name\":\"run\",\"content\":\"boom\",\"is_error\":true}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const agent = element(field(parsed.value, "agents"), 0);
    const messages = field(agent, "messages");
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);

    const calls = field(element(messages, 0), "parts");
    try std.testing.expectEqual(@as(usize, 2), calls.array.items.len);
    const arguments = field(element(calls, 0), "arguments");
    try std.testing.expectEqualStrings("ls", field(arguments, "cmd").string);
    try std.testing.expectEqual(@as(i64, 5), field(arguments, "limit").integer);
    try std.testing.expectEqualStrings("not json", field(element(calls, 1), "arguments").string);

    const results = field(element(messages, 1), "parts");
    try std.testing.expectEqualStrings("tool", field(element(messages, 1), "role").string);
    const first = element(results, 0);
    try std.testing.expect(field(first, "is_error").bool);
    try std.testing.expectEqualStrings("", field(first, "content").string);
    const image = field(first, "image");
    try std.testing.expectEqualStrings("image/png", field(image, "media_type").string);
    try std.testing.expect(field(image, "data_omitted").bool);
    try std.testing.expect(image.object.get("data") == null);
    try std.testing.expectEqualStrings("boom", field(element(results, 1), "content").string);
    try std.testing.expect(element(results, 1).object.get("image") == null);
}

test "whitespace in tool arguments is re-emitted as compact JSON" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"w1\",\"name\":\"read\",\"arguments\":\"{\\n  \\\"path\\\" :  \\\"a.txt\\\",\\n  \\\"count\\\" : 2\\n}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"w1\",\"name\":\"read\",\"content\":\"ok\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    try std.testing.expect(std.mem.indexOfScalar(u8, document, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, document, "\"arguments\":{\"path\":\"a.txt\",\"count\":2}") != null);
    const parsed = try parse(arena.allocator(), document);
    const arguments = field(element(field(element(field(element(field(parsed.value, "agents"), 0), "messages"), 0), "parts"), 0), "arguments");
    try std.testing.expectEqualStrings("a.txt", field(arguments, "path").string);
    try std.testing.expectEqual(@as(i64, 2), field(arguments, "count").integer);
}

test "numeric tool argument lexemes survive compact re-emission" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"n1\",\"name\":\"calc\",\"arguments\":\"{\\\"x\\\":1.234567890123456789,\\\"y\\\":1.0,\\\"z\\\":-0}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"n1\",\"name\":\"calc\",\"content\":\"ok\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, document, "\"arguments\":{\"x\":1.234567890123456789,\"y\":1.0,\"z\":-0}") != null);
    const parsed = try parseVerbatim(arena.allocator(), document);
    const arguments = field(element(field(element(field(element(field(parsed.value, "agents"), 0), "messages"), 0), "parts"), 0), "arguments");
    try std.testing.expect(arguments == .object);
    try std.testing.expectEqualStrings("1.234567890123456789", field(arguments, "x").number_string);
    try std.testing.expectEqualStrings("1.0", field(arguments, "y").number_string);
    try std.testing.expectEqualStrings("-0", field(arguments, "z").number_string);
}

test "duplicate tool argument keys stay an object with the last value" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"d1\",\"name\":\"write\",\"arguments\":\"{\\\"d\\\":1,\\\"d\\\":2}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"d1\",\"name\":\"write\",\"content\":\"ok\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    const parsed = try parseVerbatim(arena.allocator(), document);
    const arguments = field(element(field(element(field(element(field(parsed.value, "agents"), 0), "messages"), 0), "parts"), 0), "arguments");
    try std.testing.expect(arguments == .object);
    const d = field(arguments, "d");
    try std.testing.expect(d == .number_string);
    try std.testing.expectEqualStrings("2", d.number_string);
}

test "reset replaces superseded history with the replayed remainder" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"original\"}]}}\n" ++
        "{\"kind\":\"reset\",\"agentID\":1,\"reason\":\"history_replace\",\"history\":[{\"role\":\"user\",\"parts\":[{\"text\":\"rewritten\"}]}]}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"continue\"}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    const parsed = try parse(arena.allocator(), document);
    const messages = field(element(field(parsed.value, "agents"), 0), "messages");
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);
    try std.testing.expectEqualStrings("rewritten", field(element(field(element(messages, 0), "parts"), 0), "text").string);
    try std.testing.expectEqualStrings("continue", field(element(field(element(messages, 1), "parts"), 0), "text").string);
    try std.testing.expect(std.mem.indexOf(u8, document, "original") == null);
}

test "an archived main agent stays in the export as an archived root" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"before removal\"}]}}\n" ++
        "{\"kind\":\"agent_remove\",\"agentID\":1}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    try std.testing.expect(field(field(parsed.value, "session"), "main_agent_id") == .null);
    const agents = field(parsed.value, "agents");
    try std.testing.expectEqual(@as(usize, 1), agents.array.items.len);
    const archived = element(agents, 0);
    try std.testing.expectEqual(@as(i64, 1), field(archived, "id").integer);
    try std.testing.expect(field(archived, "archived").bool);
    try std.testing.expectEqualStrings("before removal", field(element(field(element(field(archived, "messages"), 0), "parts"), 0), "text").string);
}

test "a parent cycle is rejected instead of dropping agents" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"agent\",\"agentID\":2,\"name\":\"child\",\"type_idx\":1,\"parent\":1,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"agent_update\",\"agentID\":1,\"parent\":2}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loaded = try fixture.load();
    try std.testing.expect(loaded.problem == null);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.CyclicAgentTree, writeJson(arena.allocator(), &loaded.header, &loaded.save, &out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "empty text and thinking parts are dropped with their messages" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"first\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"text\":\"\"},{\"thinking\":{\"text\":\"\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"second\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"image\":{\"media_type\":\"image/jpeg\",\"data\":\"QUJD\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const messages = field(element(field(parsed.value, "agents"), 0), "messages");
    try std.testing.expectEqual(@as(usize, 3), messages.array.items.len);
    for (messages.array.items, 0..) |message, index| {
        try std.testing.expectEqual(@as(i64, @intCast(index)), field(message, "index").integer);
    }
    try std.testing.expectEqualStrings("first", field(element(field(element(messages, 0), "parts"), 0), "text").string);
    try std.testing.expectEqualStrings("second", field(element(field(element(messages, 1), "parts"), 0), "text").string);
    const image = element(field(element(messages, 2), "parts"), 0);
    try std.testing.expectEqualStrings("image", field(image, "type").string);
    try std.testing.expectEqualStrings("image/jpeg", field(image, "media_type").string);
    try std.testing.expect(field(image, "data_omitted").bool);
}

test "compaction replaces superseded history with the replayed remainder" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"original\"}]}}\n" ++
        "{\"kind\":\"compaction\",\"agentID\":1,\"history\":[{\"role\":\"user\",\"parts\":[{\"text\":\"summary\"}]}]}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"continue\"}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const messages = field(element(field(parsed.value, "agents"), 0), "messages");
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);
    try std.testing.expectEqualStrings("summary", field(element(field(element(messages, 0), "parts"), 0), "text").string);
    try std.testing.expectEqualStrings("continue", field(element(field(element(messages, 1), "parts"), 0), "text").string);
    try std.testing.expect(std.mem.indexOf(u8, try fixture.render(arena.allocator()), "original") == null);
}

test "a torn last line is reported instead of rendered as a shorter transcript" {
    std.testing.log_level = .err;
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"accepted\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"torn\"}]}";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    const loaded = try fixture.load();
    try std.testing.expectEqualStrings("UnterminatedRecord", loaded.problem.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.save.chat.len);
}

test "rendering the same session twice is byte identical and leaves the journal untouched" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":1}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"stable\"}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = try fixture.stat();
    const bytes_before = try fixture.read(arena.allocator());
    const first = try fixture.render(arena.allocator());
    const second = try fixture.render(arena.allocator());
    const after = try fixture.stat();
    const bytes_after = try fixture.read(arena.allocator());
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, bytes_before, bytes_after);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    try std.testing.expect(!std.mem.endsWith(u8, first, "\n"));
}
