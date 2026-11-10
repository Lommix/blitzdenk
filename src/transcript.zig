const std = @import("std");
const session = @import("session.zig");
const session_store = @import("session_store.zig");

const Stringify = std.json.Stringify;

const AgentNode = struct {
    agent: *const session.WireAgent,
    archived: bool,
};

fn nodeLessThan(_: void, a: AgentNode, b: AgentNode) bool {
    return a.agent.id < b.agent.id;
}

/// Renders a loaded session as one JSON document: a flat agent list, each
/// agent carrying its full journal history. Compactions and resets appear
/// as marker entries instead of replacing the messages before them.
pub fn writeJson(alloc: std.mem.Allocator, loaded: *const session_store.Loaded, out: *std.Io.Writer) !void {
    const save = &loaded.save;
    var nodes: std.ArrayList(AgentNode) = .empty;
    defer nodes.deinit(alloc);
    if (save.main_metadata) |*main| try nodes.append(alloc, .{ .agent = main, .archived = false });
    for (save.agents) |*agent| try nodes.append(alloc, .{ .agent = agent, .archived = false });
    for (save.archived_agents) |*agent| try nodes.append(alloc, .{ .agent = agent, .archived = true });
    std.mem.sort(AgentNode, nodes.items, {}, nodeLessThan);

    var jw: Stringify = .{ .writer = out };
    try jw.beginObject();
    try put(&jw, "session", .{
        .id = loaded.header.id,
        .created_ms = loaded.header.created_ms,
        .cwd = loaded.header.cwd,
        .main_agent_id = save.main_agent,
    });
    try jw.objectField("agents");
    try jw.beginArray();
    for (nodes.items) |node| try writeAgent(alloc, &jw, loaded, node);
    try jw.endArray();
    try jw.endObject();
}

fn put(jw: *Stringify, name: []const u8, value: anytype) !void {
    try jw.objectField(name);
    try jw.write(value);
}

fn writeAgent(alloc: std.mem.Allocator, jw: *Stringify, loaded: *const session_store.Loaded, node: AgentNode) !void {
    const agent = node.agent;
    try jw.beginObject();
    try put(jw, "id", agent.id);
    try put(jw, "name", agent.name);
    try put(jw, "type_idx", agent.type_idx);
    try put(jw, "parent_id", agent.parent);
    try put(jw, "depth", agent.depth);
    try put(jw, "cwd", agent.cwd);
    try put(jw, "background", agent.background);
    try put(jw, "clean", agent.clean);
    try put(jw, "task_description", agent.task_description);
    try put(jw, "archived", node.archived);
    try put(jw, "tokens", agent.tokens);
    try jw.objectField("messages");
    try jw.beginArray();
    var index: usize = 0;
    for (loaded.records) |record| {
        if (record.agentID != agent.id) continue;
        switch (record.kind) {
            .message => {
                const message = record.message.?;
                if (!messageExports(message)) continue;
                try jw.beginObject();
                try put(jw, "index", index);
                try writeMessageBody(alloc, jw, loaded, agent.id, message);
                try jw.endObject();
            },
            .compaction, .reset => try writeMarker(alloc, jw, loaded, agent.id, record, index),
            else => continue,
        }
        index += 1;
    }
    try jw.endArray();
    try jw.endObject();
}

/// Compactions and history replacements carry their new history; the
/// other resets only truncate, so their length says what was kept.
fn writeMarker(
    alloc: std.mem.Allocator,
    jw: *Stringify,
    loaded: *const session_store.Loaded,
    agent_id: u32,
    record: session_store.Record,
    index: usize,
) !void {
    const history = record.history.?;
    try jw.beginObject();
    try put(jw, "index", index);
    try put(jw, "role", @tagName(record.kind));
    try put(jw, "reason", record.reason);
    try put(jw, "history_len", history.len);
    const rewrites = record.kind == .compaction or std.mem.eql(u8, record.reason.?, "history_replace");
    if (rewrites) {
        try jw.objectField("history");
        try jw.beginArray();
        for (history) |message| {
            if (!messageExports(message)) continue;
            try jw.beginObject();
            try writeMessageBody(alloc, jw, loaded, agent_id, message);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

fn writeMessageBody(
    alloc: std.mem.Allocator,
    jw: *Stringify,
    loaded: *const session_store.Loaded,
    agent_id: u32,
    message: session.WireMessage,
) !void {
    try put(jw, "role", messageRole(message));
    try put(jw, "time_ms", @as(?i64, if (message.time_ms == 0) null else message.time_ms));
    try jw.objectField("parts");
    try jw.beginArray();
    for (message.parts) |part| {
        if (partExports(part)) try writePart(alloc, jw, loaded, agent_id, part);
    }
    try jw.endArray();
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

fn findStatus(statuses: []const session.WireToolStatus, agent_id: u32, call_id: []const u8) ?*const session.WireToolStatus {
    for (statuses) |*status| {
        if (status.agent == agent_id and std.mem.eql(u8, status.call_id, call_id)) return status;
    }
    return null;
}

fn writePart(
    alloc: std.mem.Allocator,
    jw: *Stringify,
    loaded: *const session_store.Loaded,
    agent_id: u32,
    part: session.WirePart,
) !void {
    switch (part) {
        .text => |text| try jw.write(.{ .type = "text", .text = text }),
        .thinking => |thinking| try jw.write(.{ .type = "thinking", .text = thinking.text }),
        .image => |image| try writeImage(jw, image),
        .tool_call => |call| {
            const status = findStatus(loaded.save.tool_status, agent_id, call.id);
            try jw.beginObject();
            try put(jw, "type", "tool_call");
            try put(jw, "id", call.id);
            try put(jw, "name", call.name);
            try jw.objectField("arguments");
            try writeArguments(alloc, jw, call.arguments);
            try put(jw, "state", if (status) |s| s.state else null);
            try put(jw, "children", if (status) |s| s.children else &.{});
            try jw.endObject();
        },
        .tool_result => |result| {
            try jw.beginObject();
            try put(jw, "type", "tool_result");
            try put(jw, "call_id", result.call_id);
            try put(jw, "name", result.name);
            try put(jw, "content", result.content);
            try put(jw, "is_error", result.is_error);
            if (result.image) |image| {
                try jw.objectField("image");
                try writeImage(jw, image);
            }
            try jw.endObject();
        },
    }
}

fn writeImage(jw: *Stringify, image: session.WireImage) !void {
    try jw.write(.{ .type = "image", .media_type = image.media_type, .data_omitted = true });
}

fn writeArguments(alloc: std.mem.Allocator, jw: *Stringify, arguments: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jw.write(arguments),
    };
    defer parsed.deinit();
    try jw.write(parsed.value);
}

const HEADER = "{\"kind\":\"header\",\"v\":2,\"id\":\"20260101-120000-abcd\",\"created_ms\":1767268800000,\"cwd\":\"/work/project\"}\n";
const MAIN = "{\"kind\":\"agent\",\"agentID\":1,\"name\":\"main\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
    "{\"kind\":\"main_agent\",\"agentID\":1}\n";

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

    fn render(self: *Fixture, alloc: std.mem.Allocator) ![]const u8 {
        const loaded = try self.load();
        try std.testing.expect(loaded.problem == null);
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try writeJson(alloc, &loaded, &out.writer);
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

fn mainMessages(root: std.json.Value) std.json.Value {
    return field(element(field(root, "agents"), 0), "messages");
}

fn firstText(message: std.json.Value) []const u8 {
    return field(element(field(message, "parts"), 0), "text").string;
}

test "export lists agents flat and carries metadata, roles, parts, and indexes" {
    const journal = HEADER ++
        "{\"kind\":\"agent\",\"agentID\":65536,\"name\":\"general\",\"type_idx\":0,\"parent\":null,\"depth\":0,\"cwd\":\"/work/project\",\"background\":false,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"agent\",\"agentID\":65537,\"name\":\"worker\",\"type_idx\":1,\"parent\":65536,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":false,\"task_description\":\"scan\"}\n" ++
        "{\"kind\":\"agent\",\"agentID\":65538,\"name\":\"gone\",\"type_idx\":2,\"parent\":65536,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":true,\"task_description\":\"old\"}\n" ++
        "{\"kind\":\"main_agent\",\"agentID\":65536}\n" ++
        "{\"kind\":\"usage\",\"agentID\":65536,\"tokens\":{\"model\":\"model-id\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15},\"context_tokens\":10,\"context_from_provider\":true,\"context_estimate\":10}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}],\"time_ms\":1767268801000}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"agent\",\"parts\":[{\"thinking\":{\"text\":\"reasoning\"}},{\"tool_call\":{\"id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65536,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"call_1\",\"name\":\"read\",\"content\":\"file body\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65537,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"child\"}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":65538,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"archived work\"}]}}\n" ++
        "{\"kind\":\"agent_remove\",\"agentID\":65538}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const root = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), root.object.count());

    const session_value = field(root, "session");
    try std.testing.expectEqualStrings("20260101-120000-abcd", field(session_value, "id").string);
    try std.testing.expectEqual(@as(i64, 1767268800000), field(session_value, "created_ms").integer);
    try std.testing.expectEqualStrings("/work/project", field(session_value, "cwd").string);
    try std.testing.expectEqual(@as(i64, 65536), field(session_value, "main_agent_id").integer);

    const agents = field(root, "agents");
    try std.testing.expectEqual(@as(usize, 3), agents.array.items.len);
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
    try std.testing.expect(main.object.get("children") == null);

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
    try std.testing.expectEqualStrings("user", field(hello, "role").string);
    try std.testing.expectEqual(@as(i64, 1767268801000), field(hello, "time_ms").integer);
    try std.testing.expectEqualStrings("hello", firstText(hello));
    const reply = element(messages, 1);
    try std.testing.expectEqual(@as(i64, 1), field(reply, "index").integer);
    try std.testing.expectEqualStrings("assistant", field(reply, "role").string);
    try std.testing.expect(field(reply, "time_ms") == .null);
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

    const worker = element(agents, 1);
    try std.testing.expectEqual(@as(i64, 65537), field(worker, "id").integer);
    try std.testing.expectEqual(@as(i64, 65536), field(worker, "parent_id").integer);
    try std.testing.expectEqual(@as(i64, 1), field(worker, "depth").integer);
    try std.testing.expect(field(worker, "background").bool);
    try std.testing.expectEqualStrings("scan", field(worker, "task_description").string);
    try std.testing.expect(!field(worker, "archived").bool);
    try std.testing.expectEqualStrings("child", firstText(element(field(worker, "messages"), 0)));

    const gone = element(agents, 2);
    try std.testing.expectEqual(@as(i64, 65538), field(gone, "id").integer);
    try std.testing.expectEqual(@as(i64, 65536), field(gone, "parent_id").integer);
    try std.testing.expect(field(gone, "archived").bool);
    try std.testing.expect(field(gone, "clean").bool);
    try std.testing.expectEqual(@as(usize, 1), field(gone, "messages").array.items.len);
    try std.testing.expectEqualStrings("archived work", firstText(element(field(gone, "messages"), 0)));
}

test "tool arguments stay parsed when valid and become strings otherwise" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"c1\",\"name\":\"run\",\"arguments\":\"{\\\"cmd\\\": \\\"ls\\\", \\\"limit\\\": 5}\"}},{\"tool_call\":{\"id\":\"c2\",\"name\":\"run\",\"arguments\":\"not json\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"c1\",\"name\":\"run\",\"content\":\"\",\"is_error\":true,\"image\":{\"media_type\":\"image/png\",\"data\":\"QUJD\"}}},{\"tool_result\":{\"call_id\":\"c2\",\"name\":\"run\",\"content\":\"boom\",\"is_error\":true}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const messages = mainMessages(parsed.value);
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
    const journal = HEADER ++ MAIN ++
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
}

test "numeric tool argument lexemes survive compact re-emission" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"n1\",\"name\":\"calc\",\"arguments\":\"{\\\"x\\\":1.234567890123456789,\\\"y\\\":1.0,\\\"z\\\":-0}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"n1\",\"name\":\"calc\",\"content\":\"ok\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try fixture.render(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, document, "\"arguments\":{\"x\":1.234567890123456789,\"y\":1.0,\"z\":-0}") != null);
}

test "duplicate tool argument keys stay an object with the last value" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"d1\",\"name\":\"write\",\"arguments\":\"{\\\"d\\\":1,\\\"d\\\":2}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"d1\",\"name\":\"write\",\"content\":\"ok\"}}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseVerbatim(arena.allocator(), try fixture.render(arena.allocator()));
    const arguments = field(element(field(element(mainMessages(parsed.value), 0), "parts"), 0), "arguments");
    try std.testing.expect(arguments == .object);
    try std.testing.expectEqualStrings("2", field(arguments, "d").number_string);
}

test "tool calls carry their final status and spawned children" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"agent\",\"agentID\":2,\"name\":\"child\",\"type_idx\":1,\"parent\":1,\"depth\":1,\"cwd\":\"/work/project\",\"background\":true,\"clean\":false,\"task_description\":\"\"}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"agent\",\"parts\":[{\"tool_call\":{\"id\":\"s1\",\"name\":\"agent\",\"arguments\":\"{}\"}},{\"tool_call\":{\"id\":\"s2\",\"name\":\"run\",\"arguments\":\"{}\"}},{\"tool_call\":{\"id\":\"s3\",\"name\":\"run\",\"arguments\":\"{}\"}}]}}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"tool_result\":{\"call_id\":\"s1\",\"name\":\"agent\",\"content\":\"done\"}},{\"tool_result\":{\"call_id\":\"s2\",\"name\":\"run\",\"content\":\"boom\",\"is_error\":true}}]}}\n" ++
        "{\"kind\":\"tool_status\",\"agentID\":1,\"call_id\":\"s1\",\"state\":\"succeeded\",\"children\":[2]}\n" ++
        "{\"kind\":\"tool_status\",\"agentID\":1,\"call_id\":\"s2\",\"state\":\"failed\"}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const calls = field(element(mainMessages(parsed.value), 0), "parts");
    try std.testing.expectEqualStrings("succeeded", field(element(calls, 0), "state").string);
    try std.testing.expectEqual(@as(i64, 2), element(field(element(calls, 0), "children"), 0).integer);
    try std.testing.expectEqualStrings("failed", field(element(calls, 1), "state").string);
    try std.testing.expectEqual(@as(usize, 0), field(element(calls, 1), "children").array.items.len);
    // The unfinished exchange is still exported; load marks its open call interrupted.
    try std.testing.expectEqualStrings("interrupted", field(element(calls, 2), "state").string);
}

test "compaction keeps superseded history and marks the replacement" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"original\"}]}}\n" ++
        "{\"kind\":\"compaction\",\"agentID\":1,\"history\":[{\"role\":\"user\",\"parts\":[{\"text\":\"summary\"}]}]}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"continue\"}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const messages = mainMessages(parsed.value);
    try std.testing.expectEqual(@as(usize, 3), messages.array.items.len);
    try std.testing.expectEqualStrings("original", firstText(element(messages, 0)));
    const marker = element(messages, 1);
    try std.testing.expectEqual(@as(i64, 1), field(marker, "index").integer);
    try std.testing.expectEqualStrings("compaction", field(marker, "role").string);
    try std.testing.expect(field(marker, "reason") == .null);
    try std.testing.expectEqual(@as(i64, 1), field(marker, "history_len").integer);
    try std.testing.expectEqualStrings("summary", firstText(element(field(marker, "history"), 0)));
    try std.testing.expectEqualStrings("continue", firstText(element(messages, 2)));
}

test "history replacement carries its rewrite, truncating resets only their length" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"original\"}]}}\n" ++
        "{\"kind\":\"reset\",\"agentID\":1,\"reason\":\"history_replace\",\"history\":[{\"role\":\"user\",\"parts\":[{\"text\":\"rewritten\"}]}]}\n" ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"second\"}]}}\n" ++
        "{\"kind\":\"reset\",\"agentID\":1,\"reason\":\"rewind\",\"history\":[{\"role\":\"user\",\"parts\":[{\"text\":\"rewritten\"}]}]}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), try fixture.render(arena.allocator()));
    const messages = mainMessages(parsed.value);
    try std.testing.expectEqual(@as(usize, 4), messages.array.items.len);
    try std.testing.expectEqualStrings("original", firstText(element(messages, 0)));
    const replace = element(messages, 1);
    try std.testing.expectEqualStrings("reset", field(replace, "role").string);
    try std.testing.expectEqualStrings("history_replace", field(replace, "reason").string);
    try std.testing.expectEqualStrings("rewritten", firstText(element(field(replace, "history"), 0)));
    try std.testing.expectEqualStrings("second", firstText(element(messages, 2)));
    const rewind = element(messages, 3);
    try std.testing.expectEqualStrings("rewind", field(rewind, "reason").string);
    try std.testing.expectEqual(@as(i64, 1), field(rewind, "history_len").integer);
    try std.testing.expect(rewind.object.get("history") == null);
}

test "an archived main agent stays in the export as archived" {
    const journal = HEADER ++ MAIN ++
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
    try std.testing.expect(field(archived, "archived").bool);
    try std.testing.expectEqualStrings("before removal", firstText(element(field(archived, "messages"), 0)));
}

test "empty text and thinking parts are dropped with their messages" {
    const journal = HEADER ++ MAIN ++
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
    const messages = mainMessages(parsed.value);
    try std.testing.expectEqual(@as(usize, 3), messages.array.items.len);
    for (messages.array.items, 0..) |message, index| {
        try std.testing.expectEqual(@as(i64, @intCast(index)), field(message, "index").integer);
    }
    try std.testing.expectEqualStrings("first", firstText(element(messages, 0)));
    try std.testing.expectEqualStrings("second", firstText(element(messages, 1)));
    const image = element(field(element(messages, 2), "parts"), 0);
    try std.testing.expectEqualStrings("image", field(image, "type").string);
    try std.testing.expectEqualStrings("image/jpeg", field(image, "media_type").string);
    try std.testing.expect(field(image, "data_omitted").bool);
}

test "rendering the same session twice is byte identical" {
    const journal = HEADER ++ MAIN ++
        "{\"kind\":\"message\",\"agentID\":1,\"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"stable\"}]}}\n";

    var fixture: Fixture = undefined;
    try fixture.init(journal);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try fixture.render(arena.allocator());
    const second = try fixture.render(arena.allocator());
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(!std.mem.endsWith(u8, first, "\n"));
}
