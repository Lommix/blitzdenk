const std = @import("std");
const r = @import("root.zig");
const oauth = @import("oauth.zig");
const mcp = @import("mcp.zig");

const testing = std.testing;

const Fake = struct {
    io: std.Io,
    port: u16 = 0,
    mu: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    challenge: enum { header, bare, not_found } = .header,
    prm_at: enum { challenge, path, root } = .challenge,
    issuer_path: []const u8 = "",
    as_at: enum { oauth_meta, oidc_insert, oidc_append } = .oauth_meta,
    wrong_issuer: bool = false,
    pkce: bool = true,
    dcr: bool = true,
    rotate: bool = true,
    expires_in: i64 = 3600,
    refresh_mode: enum { ok, invalid_grant, drop } = .ok,
    challenge_scope: []const u8 = "read write",

    tokens: [2][]const u8 = .{ "", "" },
    static_key: []const u8 = "static-key",
    issued: usize = 0,

    log: std.ArrayList([]const u8) = .empty,
    register_body: []const u8 = "",
    token_bodies: std.ArrayList([]const u8) = .empty,
    token_auth: []const u8 = "",
    auth_headers: std.ArrayList([]const u8) = .empty,
    mcp_401: usize = 0,

    fn listen(self: *Fake, server: *std.Io.net.Server) void {
        self.port = server.socket.address.getPort();
    }

    fn serve(self: *Fake, server: *std.Io.net.Server) void {
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);
        while (true) {
            const stream = server.accept(self.io) catch return;
            group.concurrent(self.io, handle, .{ self, stream }) catch {
                stream.close(self.io);
                return;
            };
        }
    }

    fn dupe(self: *Fake, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch "";
    }

    fn record(self: *Fake, comptime fmt: []const u8, args: anytype) void {
        const a = self.arena.allocator();
        self.log.append(a, std.fmt.allocPrint(a, fmt, args) catch return) catch {};
    }

    fn origin(self: *Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch "";
    }

    fn issuer(self: *Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, self.issuer_path }) catch "";
    }

    fn handle(self: *Fake, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        var rbuf: [16384]u8 = undefined;
        var wbuf: [16384]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var writer = stream.writer(self.io, &wbuf);
        const w = &writer.interface;

        var head: [8192]u8 = undefined;
        var head_len: usize = 0;
        while (head_len < head.len) {
            const b = reader.interface.takeByte() catch return;
            head[head_len] = b;
            head_len += 1;
            if (head_len >= 4 and std.mem.eql(u8, head[head_len - 4 .. head_len], "\r\n\r\n")) break;
        }
        const head_slice = head[0..head_len];
        var content_length: usize = 0;
        var authorization: []const u8 = "";
        var lines = std.mem.splitSequence(u8, head_slice, "\r\n");
        const request_line = lines.first();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            if (std.ascii.eqlIgnoreCase(name, "authorization")) authorization = value;
        }
        var body_buf: [8192]u8 = undefined;
        if (content_length > body_buf.len) return;
        reader.interface.readSliceAll(body_buf[0..content_length]) catch return;
        const body = body_buf[0..content_length];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.first();
        const target = parts.next() orelse "";

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.record("{s} {s}", .{ method, target });
        self.route(w, method, target, authorization, body) catch {};
        w.flush() catch {};
    }

    fn route(self: *Fake, w: *std.Io.Writer, method: []const u8, target: []const u8, authorization: []const u8, body: []const u8) !void {
        var ob: [128]u8 = undefined;
        var ib: [160]u8 = undefined;
        const base = self.origin(&ob);
        const iss = self.issuer(&ib);

        if (std.mem.eql(u8, method, "POST") and (std.mem.eql(u8, target, "/mcp") or std.mem.eql(u8, target, "/other"))) {
            const slot: usize = if (std.mem.eql(u8, target, "/mcp")) 0 else 1;
            self.auth_headers.append(self.arena.allocator(), self.dupe(authorization)) catch {};
            const tok = if (std.mem.startsWith(u8, authorization, "Bearer ")) authorization["Bearer ".len..] else "";
            const ok = tok.len > 0 and (std.mem.eql(u8, tok, self.tokens[slot]) or std.mem.eql(u8, tok, self.static_key));
            if (!ok) {
                self.mcp_401 += 1;
                switch (self.challenge) {
                    .not_found => return status(w, "404 Not Found", "", ""),
                    .bare => return status(w, "401 Unauthorized", "Bearer", ""),
                    .header => {
                        var hb: [512]u8 = undefined;
                        const hdr = try std.fmt.bufPrint(&hb, "Bearer resource_metadata=\"{s}/meta/prm\", scope=\"{s}\"", .{ base, self.challenge_scope });
                        return status(w, "401 Unauthorized", hdr, "");
                    },
                }
            }
            return mcpReply(w, body);
        }

        if (std.mem.eql(u8, method, "GET")) {
            const prm_target: []const u8 = switch (self.prm_at) {
                .challenge => "/meta/prm",
                .path => "/.well-known/oauth-protected-resource/mcp",
                .root => "/.well-known/oauth-protected-resource",
            };
            if (std.mem.eql(u8, target, prm_target)) {
                var jb: [512]u8 = undefined;
                return json(w, "200 OK", try std.fmt.bufPrint(&jb, "{{\"resource\":\"{s}/mcp\",\"authorization_servers\":[\"{s}\"],\"scopes_supported\":[\"meta\"]}}", .{ base, iss }));
            }
            var as_buf: [256]u8 = undefined;
            const as_target = switch (self.as_at) {
                .oauth_meta => try std.fmt.bufPrint(&as_buf, "/.well-known/oauth-authorization-server{s}", .{self.issuer_path}),
                .oidc_insert => try std.fmt.bufPrint(&as_buf, "/.well-known/openid-configuration{s}", .{self.issuer_path}),
                .oidc_append => try std.fmt.bufPrint(&as_buf, "{s}/.well-known/openid-configuration", .{self.issuer_path}),
            };
            if (std.mem.eql(u8, target, as_target)) {
                var jb: [1024]u8 = undefined;
                const reg: []const u8 = if (self.dcr) "/register" else "";
                var rb: [160]u8 = undefined;
                const reg_field = if (reg.len > 0) try std.fmt.bufPrint(&rb, ",\"registration_endpoint\":\"{s}/register\"", .{base}) else "";
                return json(w, "200 OK", try std.fmt.bufPrint(&jb, "{{\"issuer\":\"{s}{s}\",\"authorization_endpoint\":\"{s}/authorize\",\"token_endpoint\":\"{s}/token\"{s},\"code_challenge_methods_supported\":[{s}]}}", .{
                    iss,
                    if (self.wrong_issuer) "/evil" else "",
                    base,
                    base,
                    reg_field,
                    if (self.pkce) "\"S256\"" else "\"plain\"",
                }));
            }
            return status(w, "404 Not Found", "", "");
        }

        if (std.mem.eql(u8, target, "/register")) {
            self.register_body = self.dupe(body);
            return json(w, "201 Created", "{\"client_id\":\"dyn-client\"}");
        }

        if (std.mem.eql(u8, target, "/token")) {
            self.token_bodies.append(self.arena.allocator(), self.dupe(body)) catch {};
            self.token_auth = self.dupe(authorization);
            const is_refresh = std.mem.indexOf(u8, body, "grant_type=refresh_token") != null;
            if (is_refresh) switch (self.refresh_mode) {
                .ok => {},
                .invalid_grant => return json(w, "400 Bad Request", "{\"error\":\"invalid_grant\"}"),
                .drop => return,
            };
            self.issued += 1;
            const at = self.dupe(try std.fmt.bufPrint(&ob, "at-{d}", .{self.issued}));
            self.tokens[0] = at;
            var jb: [512]u8 = undefined;
            const rt_field = if (!is_refresh or self.rotate) try std.fmt.bufPrint(&ib, ",\"refresh_token\":\"rt-{d}\"", .{self.issued}) else "";
            return json(w, "200 OK", try std.fmt.bufPrint(&jb, "{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":{d}{s}}}", .{ at, self.expires_in, rt_field }));
        }
        return status(w, "404 Not Found", "", "");
    }

    fn status(w: *std.Io.Writer, line: []const u8, www: []const u8, body: []const u8) !void {
        try w.print("HTTP/1.1 {s}\r\n", .{line});
        if (www.len > 0) try w.print("www-authenticate: {s}\r\n", .{www});
        try w.print("content-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body });
    }

    fn json(w: *std.Io.Writer, line: []const u8, body: []const u8) !void {
        try w.print("HTTP/1.1 {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ line, body.len, body });
    }

    fn mcpReply(w: *std.Io.Writer, body: []const u8) !void {
        var id: i64 = 0;
        if (std.mem.indexOf(u8, body, "\"id\":")) |idx| {
            var i = idx + 5;
            while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) id = id * 10 + (body[i] - '0');
        }
        const result: []const u8 = if (std.mem.indexOf(u8, body, "\"initialize\"") != null)
            "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"0\"}}"
        else if (std.mem.indexOf(u8, body, "notifications/initialized") != null)
            return status(w, "202 Accepted", "", "")
        else if (std.mem.indexOf(u8, body, "tools/list") != null)
            "{\"tools\":[{\"name\":\"echo\",\"description\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}]}"
        else
            "{\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}";
        var jb: [1024]u8 = undefined;
        const out = try std.fmt.bufPrint(&jb, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result });
        try w.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nmcp-session-id: s1\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ out.len, out });
    }

    fn saw(self: *Fake, needle: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.log.items) |line| if (std.mem.eql(u8, line, needle)) return true;
        return false;
    }

    fn indexOfRequest(self: *Fake, needle: []const u8) ?usize {
        for (self.log.items, 0..) |line, i| if (std.mem.eql(u8, line, needle)) return i;
        return null;
    }

    fn count(self: *Fake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.log.items) |line| {
            if (std.mem.eql(u8, line, needle)) n += 1;
        }
        return n;
    }
};

const Opener = struct {
    calls: usize = 0,
    result: bool = true,

    fn open(ctx: ?*anyopaque, _: std.Io, _: []const u8) error{Canceled}!bool {
        const self: *Opener = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return self.result;
    }

    fn opener(self: *Opener) oauth.Opener {
        return .{ .ctx = self, .func = open };
    }
};

const Rig = struct {
    threaded: std.Io.Threaded,
    server: std.Io.net.Server,
    fake: Fake,
    serving: std.Io.Future(void),
    tmp: std.testing.TmpDir,
    store_dir: []const u8,
    url: []const u8,
    other_url: []const u8,

    fn create() !*Rig {
        const self = try std.heap.page_allocator.create(Rig);
        errdefer std.heap.page_allocator.destroy(self);
        try self.init();
        return self;
    }

    fn destroy(self: *Rig) void {
        self.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn init(self: *Rig) !void {
        self.threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const io = self.threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try address.listen(io, .{});
        self.fake = .{ .io = io };
        self.fake.listen(&self.server);
        self.serving = std.Io.concurrent(io, Fake.serve, .{ &self.fake, &self.server }) catch return error.SkipZigTest;
        self.tmp = testing.tmpDir(.{});
        const a = self.fake.arena.allocator();
        const tmp_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_path, a);
        self.store_dir = try std.fs.path.join(a, &.{ abs, oauth.STORE_DIR });
        self.url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{self.fake.port});
        self.other_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/other", .{self.fake.port});
    }

    fn deinit(self: *Rig) void {
        const io = self.threaded.io();
        self.serving.cancel(io);
        self.server.deinit(io);
        self.tmp.cleanup();
        self.fake.arena.deinit();
        self.threaded.deinit();
    }

    fn ioh(self: *Rig) std.Io {
        return self.threaded.io();
    }

    fn store(self: *Rig) oauth.Store {
        return .{ .io = self.ioh(), .dir = self.store_dir };
    }

    fn taskConfig(self: *Rig) oauth.TaskConfig {
        return .{ .name = "fake", .url = self.url, .store_dir = self.store_dir, .redirect_port = 0, .timeout_s = 20 };
    }

    fn seed(self: *Rig, rec: oauth.Record) !void {
        try self.store().put(testing.allocator, rec);
    }

    fn baseRecord(self: *Rig) !oauth.Record {
        const a = self.fake.arena.allocator();
        return .{
            .url = self.url,
            .resource = self.url,
            .issuer = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.fake.port}),
            .auth_server = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.fake.port}),
            .token_endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/token", .{self.fake.port}),
            .client_id = "seed-client",
            .redirect_uri = "http://127.0.0.1:1/callback",
        };
    }

    fn get(self: *Rig, arena: std.mem.Allocator) ?oauth.Record {
        return self.store().get(arena, self.url);
    }
};

fn waitPhase(io: std.Io, task: *oauth.Task, phase: oauth.Phase) !void {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (task.phase() == phase) return;
        if (task.isFinished()) return error.TaskFinished;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.PhaseTimeout;
}

fn waitDone(io: std.Io, task: *oauth.Task) !void {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (task.isFinished()) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TaskTimeout;
}

fn browserGet(io: std.Io, url: []const u8) !u16 {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &sink.writer, .keep_alive = false });
    return @backingInt(res.status);
}

fn authParam(arena: std.mem.Allocator, task: *const oauth.Task, name: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, task.auth_url, '?') orelse return "";
    return oauth.queryParam(arena, task.auth_url[q + 1 ..], name) orelse "";
}

fn callback(arena: std.mem.Allocator, io: std.Io, task: *oauth.Task, state: []const u8) !u16 {
    const url = try std.fmt.allocPrint(arena, "{s}?code=the-code&state={s}", .{ task.redirect_uri, state });
    return browserGet(io, url);
}

fn formParam(arena: std.mem.Allocator, body: []const u8, name: []const u8) []const u8 {
    return oauth.queryParam(arena, body, name) orelse "";
}

fn runToCallback(rig: *Rig, task: *oauth.Task) !void {
    task.start();
    try waitPhase(rig.ioh(), task, .awaiting_callback);
}

test "oauth connect discovers from 401 challenge, registers, exchanges and stores" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = rig.ioh();

    var opener: Opener = .{};
    var task = try oauth.Task.init(testing.allocator, io, rig.taskConfig(), opener.opener());
    defer task.deinit();
    try runToCallback(rig, &task);

    try testing.expectEqual(@as(usize, 1), opener.calls);
    try testing.expect(!task.opener_failed);
    try testing.expectEqualStrings("code", authParam(a, &task, "response_type"));
    try testing.expectEqualStrings("dyn-client", authParam(a, &task, "client_id"));
    try testing.expectEqualStrings(task.redirect_uri, authParam(a, &task, "redirect_uri"));
    try testing.expectEqualStrings("S256", authParam(a, &task, "code_challenge_method"));
    try testing.expectEqualStrings(rig.url, authParam(a, &task, "resource"));
    try testing.expectEqualStrings("read write", authParam(a, &task, "scope"));
    const state = authParam(a, &task, "state");
    try testing.expect(state.len >= 16);

    try testing.expect(std.mem.indexOf(u8, rig.fake.register_body, "\"client_name\":\"Blitzdenk\"") != null);
    try testing.expect(std.mem.indexOf(u8, rig.fake.register_body, task.redirect_uri) != null);
    try testing.expect(std.mem.indexOf(u8, rig.fake.register_body, "\"authorization_code\",\"refresh_token\"") != null);
    try testing.expect(std.mem.indexOf(u8, rig.fake.register_body, "\"response_types\":[\"code\"]") != null);
    try testing.expect(std.mem.indexOf(u8, rig.fake.register_body, "\"token_endpoint_auth_method\":\"none\"") != null);

    var ub: [256]u8 = undefined;
    const port_base = task.redirect_uri[0 .. task.redirect_uri.len - oauth.CALLBACK_PATH.len];
    try testing.expectEqual(@as(u16, 404), try browserGet(io, try std.fmt.bufPrint(&ub, "{s}/favicon.ico", .{port_base})));
    try testing.expectEqual(@as(u16, 404), try browserGet(io, try std.fmt.bufPrint(&ub, "{s}/elsewhere?code=x&state={s}", .{ port_base, state })));
    try testing.expect(!task.isFinished());
    try testing.expectEqual(@as(u16, 200), try callback(a, io, &task, state));
    try waitDone(io, &task);
    try testing.expectEqual(oauth.Outcome.authorized, task.outcome);

    const token_body = rig.fake.token_bodies.items[0];
    try testing.expectEqualStrings("authorization_code", formParam(a, token_body, "grant_type"));
    try testing.expectEqualStrings("the-code", formParam(a, token_body, "code"));
    try testing.expectEqualStrings(task.redirect_uri, formParam(a, token_body, "redirect_uri"));
    try testing.expectEqualStrings("dyn-client", formParam(a, token_body, "client_id"));
    try testing.expectEqualStrings(rig.url, formParam(a, token_body, "resource"));
    const verifier = formParam(a, token_body, "code_verifier");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var cb: [64]u8 = undefined;
    try testing.expectEqualStrings(std.base64.url_safe_no_pad.Encoder.encode(&cb, &digest), authParam(a, &task, "code_challenge"));

    const rec = rig.get(a).?;
    try testing.expectEqualStrings("at-1", rec.access_token.?);
    try testing.expectEqualStrings("rt-1", rec.refresh_token.?);
    try testing.expectEqualStrings("dyn-client", rec.client_id);
    try testing.expect(rec.expires_at != null);

    var dir = try std.Io.Dir.openDirAbsolute(io, rig.store_dir, .{});
    defer dir.close(io);
    const file_stat = try dir.statFile(io, "tokens.json", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
    const dir_stat = try std.Io.Dir.cwd().statFile(io, rig.store_dir, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    try testing.expectError(error.FileNotFound, dir.statFile(io, "tokens.json.tmp", .{}));

    var manager = mcp.Manager.init(testing.allocator, io);
    defer manager.deinit();
    manager.token_dir = rig.store_dir;
    manager.loadServers(&.{.{ .name = "fake", .tools_prefix = "fk_", .url = rig.url, .oauth = true, .timeout_s = 10 }});
    try testing.expectEqual(@as(usize, 1), manager.registeredTools().len);
    try testing.expectEqual(mcp.ServerState.loaded, manager.serverStatuses()[0].state);
    for (rig.fake.auth_headers.items[rig.fake.auth_headers.items.len - 3 ..]) |h| try testing.expectEqualStrings("Bearer at-1", h);
}

test "oauth discovery falls back to well-known path and origin root" {
    inline for (.{ .{ .bare, .path }, .{ .not_found, .root } }) |mode| {
        const rig = try Rig.create();
        defer rig.destroy();
        rig.fake.challenge = mode[0];
        rig.fake.prm_at = mode[1];
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        try runToCallback(rig, &task);
        try testing.expectEqualStrings("meta", authParam(arena_state.allocator(), &task, "scope"));
        try testing.expect(rig.fake.saw("GET /.well-known/oauth-protected-resource/mcp"));
    }
}

test "oauth authorization server metadata fallback order" {
    {
        const rig = try Rig.create();
        defer rig.destroy();
        rig.fake.issuer_path = "/tenant";
        rig.fake.as_at = .oidc_append;
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        try runToCallback(rig, &task);
        const f = &rig.fake;
        const first_idx = f.indexOfRequest("GET /.well-known/oauth-authorization-server/tenant").?;
        const second_idx = f.indexOfRequest("GET /.well-known/openid-configuration/tenant").?;
        const third_idx = f.indexOfRequest("GET /tenant/.well-known/openid-configuration").?;
        try testing.expect(first_idx < second_idx and second_idx < third_idx);
    }
    {
        const rig = try Rig.create();
        defer rig.destroy();
        rig.fake.as_at = .oidc_insert;
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        try runToCallback(rig, &task);
        const f = &rig.fake;
        try testing.expect(f.indexOfRequest("GET /.well-known/oauth-authorization-server").? < f.indexOfRequest("GET /.well-known/openid-configuration").?);
    }
}

test "oauth refuses missing PKCE S256 and issuer mismatch" {
    inline for (.{ .{ false, false, oauth.ErrorKind.pkce_unsupported }, .{ true, true, oauth.ErrorKind.issuer_mismatch } }) |case| {
        const rig = try Rig.create();
        defer rig.destroy();
        rig.fake.pkce = case[0];
        rig.fake.wrong_issuer = case[1];
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        task.start();
        try waitDone(rig.ioh(), &task);
        try testing.expectEqual(oauth.Outcome.failed, task.outcome);
        try testing.expectEqual(case[2], task.err_kind);
        try testing.expectEqual(@as(usize, 0), opener.calls);
    }
}

test "oauth registration: configured client, cached registration, missing registration" {
    {
        const rig = try Rig.create();
        defer rig.destroy();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var cfg = rig.taskConfig();
        cfg.client_id = "my-client";
        cfg.client_secret = "my-secret";
        cfg.scopes = &.{ "x", "y" };
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), cfg, opener.opener());
        defer task.deinit();
        try runToCallback(rig, &task);
        try testing.expectEqualStrings("my-client", authParam(a, &task, "client_id"));
        try testing.expectEqualStrings("x y", authParam(a, &task, "scope"));
        try testing.expect(!rig.fake.saw("POST /register"));
        try testing.expectEqual(@as(u16, 200), try callback(a, rig.ioh(), &task, authParam(a, &task, "state")));
        try waitDone(rig.ioh(), &task);
        try testing.expectEqual(oauth.Outcome.authorized, task.outcome);
        try testing.expect(std.mem.startsWith(u8, rig.fake.token_auth, "Basic "));
        try testing.expectEqualStrings("my-client", formParam(a, rig.fake.token_bodies.items[0], "client_id"));
    }
    {
        const rig = try Rig.create();
        defer rig.destroy();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var cfg = rig.taskConfig();
        var probe = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
        var hold = try probe.listen(rig.ioh(), .{});
        cfg.redirect_port = hold.socket.address.getPort();
        hold.deinit(rig.ioh());
        var base = try rig.baseRecord();
        base.client_id = "cached-client";
        base.redirect_uri = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/callback", .{cfg.redirect_port});
        try rig.seed(base);
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), cfg, opener.opener());
        defer task.deinit();
        try runToCallback(rig, &task);
        try testing.expectEqualStrings(base.redirect_uri, task.redirect_uri);
        try testing.expectEqualStrings("cached-client", authParam(a, &task, "client_id"));
        try testing.expect(!rig.fake.saw("POST /register"));
    }
    {
        const rig = try Rig.create();
        defer rig.destroy();
        rig.fake.dcr = false;
        var opener: Opener = .{};
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        task.start();
        try waitDone(rig.ioh(), &task);
        try testing.expectEqual(oauth.ErrorKind.no_client_registration, task.err_kind);
    }
}

test "oauth callback rejects wrong state and stores nothing" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var opener: Opener = .{ .result = false };
    var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
    defer task.deinit();
    try runToCallback(rig, &task);
    try testing.expect(task.opener_failed);
    try testing.expect(std.mem.startsWith(u8, task.auth_url, "http://127.0.0.1:"));
    try testing.expectEqual(@as(u16, 400), try callback(a, rig.ioh(), &task, "forged"));
    try waitDone(rig.ioh(), &task);
    try testing.expectEqual(oauth.ErrorKind.state_mismatch, task.err_kind);
    try testing.expect(rig.fake.token_bodies.items.len == 0);
    try testing.expect(rig.get(a) == null);
}

test "oauth cancel closes the listener and stores no token" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var opener: Opener = .{};
    var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
    try runToCallback(rig, &task);
    const redirect = try a.dupe(u8, task.redirect_uri);
    const colon = std.mem.lastIndexOfScalar(u8, redirect[0 .. redirect.len - oauth.CALLBACK_PATH.len], ':').?;
    const port = try std.fmt.parseInt(u16, redirect[colon + 1 .. redirect.len - oauth.CALLBACK_PATH.len], 10);
    task.deinit();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    try testing.expectError(error.ConnectionRefused, addr.connect(rig.ioh(), .{ .mode = .stream }));
    try testing.expect(rig.get(a) == null);
}

test "oauth timeout fails the task" {
    const rig = try Rig.create();
    defer rig.destroy();
    var cfg = rig.taskConfig();
    cfg.timeout_s = 1;
    var opener: Opener = .{};
    var task = try oauth.Task.init(testing.allocator, rig.ioh(), cfg, opener.opener());
    defer task.deinit();
    task.start();
    try waitDone(rig.ioh(), &task);
    try testing.expectEqual(oauth.ErrorKind.timeout, task.err_kind);
}

test "oauth connect with valid or refreshable token skips the browser" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var base = try rig.baseRecord();
    base.access_token = "seed-at";
    base.refresh_token = "seed-rt";
    try rig.seed(base);

    var opener: Opener = .{};
    {
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        task.start();
        try waitDone(rig.ioh(), &task);
        try testing.expectEqual(oauth.Outcome.authorized, task.outcome);
    }
    base.expires_at = oauth.nowSeconds(rig.ioh()) - 10;
    try rig.seed(base);
    {
        var task = try oauth.Task.init(testing.allocator, rig.ioh(), rig.taskConfig(), opener.opener());
        defer task.deinit();
        task.start();
        try waitDone(rig.ioh(), &task);
        try testing.expectEqual(oauth.Outcome.authorized, task.outcome);
    }
    try testing.expectEqual(@as(usize, 0), opener.calls);
    try testing.expectEqualStrings("seed-rt", formParam(a, rig.fake.token_bodies.items[0], "refresh_token"));
    try testing.expectEqualStrings(rig.url, formParam(a, rig.fake.token_bodies.items[0], "resource"));
    try testing.expectEqualStrings("at-1", rig.get(a).?.access_token.?);
}

test "oauth runtime: stored token, expiry refresh, 401 refresh and retry with rotation" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = rig.ioh();
    const cfg: mcp.ServerConfig = .{ .name = "fake", .tools_prefix = "fk_", .url = rig.url, .oauth = true, .timeout_s = 10 };

    var base = try rig.baseRecord();
    base.access_token = "seed-at";
    base.refresh_token = "seed-rt";
    try rig.seed(base);
    rig.fake.tokens[0] = "seed-at";
    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{cfg});
        try testing.expectEqual(@as(usize, 1), manager.registeredTools().len);
        try testing.expectEqualStrings("Bearer seed-at", rig.fake.auth_headers.items[0]);
        try testing.expectEqual(@as(usize, 0), rig.fake.mcp_401);

        rig.fake.tokens[0] = "revoked-elsewhere";
        const result = try manager.clients.items[0].callTool(a, "echo", "{}");
        try testing.expectEqualStrings("hello", result.text);
        try testing.expectEqual(@as(usize, 1), rig.fake.mcp_401);
        const rec = rig.get(a).?;
        try testing.expectEqualStrings("at-1", rec.access_token.?);
        try testing.expectEqualStrings("rt-1", rec.refresh_token.?);
        try testing.expectEqualStrings("seed-client", rec.client_id);
    }

    base.access_token = "stale";
    base.refresh_token = "rt-1";
    base.expires_at = oauth.nowSeconds(io) + 5;
    try rig.seed(base);
    rig.fake.rotate = false;
    const before = rig.fake.mcp_401;
    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{cfg});
        try testing.expectEqual(@as(usize, 1), manager.registeredTools().len);
        try testing.expectEqual(before, rig.fake.mcp_401);
        const rec = rig.get(a).?;
        try testing.expectEqualStrings("at-2", rec.access_token.?);
        try testing.expectEqualStrings("rt-1", rec.refresh_token.?);
    }
}

test "oauth runtime: revoked refresh keeps registration, network failure keeps tokens" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = rig.ioh();
    const cfg: mcp.ServerConfig = .{ .name = "fake", .tools_prefix = "fk_", .url = rig.url, .oauth = true, .timeout_s = 10 };

    var base = try rig.baseRecord();
    base.access_token = "old";
    base.refresh_token = "old-rt";
    base.expires_at = oauth.nowSeconds(io) - 1;
    try rig.seed(base);

    rig.fake.refresh_mode = .drop;
    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{cfg});
        try testing.expectEqual(mcp.ServerState.failed, manager.serverStatuses()[0].state);
        const rec = rig.get(a).?;
        try testing.expectEqualStrings("old", rec.access_token.?);
        try testing.expectEqualStrings("old-rt", rec.refresh_token.?);
    }

    rig.fake.refresh_mode = .invalid_grant;
    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{cfg});
        try testing.expectEqual(mcp.ServerState.auth_required, manager.serverStatuses()[0].state);
        try testing.expectEqual(@as(usize, 0), manager.registeredTools().len);
        const rec = rig.get(a).?;
        try testing.expect(rec.access_token == null);
        try testing.expect(rec.refresh_token == null);
        try testing.expectEqualStrings("seed-client", rec.client_id);
    }
}

test "oauth runtime: auth-required server does not block others, static key wins, tokens stay per url" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const io = rig.ioh();

    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{
            .{ .name = "locked", .tools_prefix = "a_", .url = rig.url, .oauth = true, .timeout_s = 10 },
            .{ .name = "open", .tools_prefix = "b_", .url = rig.other_url, .key = "static-key", .oauth = true, .timeout_s = 10 },
        });
        const st = manager.serverStatuses();
        try testing.expectEqual(mcp.ServerState.auth_required, st[0].state);
        try testing.expectEqual(mcp.ServerState.loaded, st[1].state);
        try testing.expectEqual(@as(usize, 1), manager.registeredTools().len);
        try testing.expectEqualStrings("b_echo", manager.registeredTools()[0].tool.def.name);
    }

    var first = try rig.baseRecord();
    first.access_token = "token-a";
    try rig.seed(first);
    var second = try rig.baseRecord();
    second.url = rig.other_url;
    second.access_token = "token-b";
    try rig.seed(second);
    rig.fake.tokens = .{ "token-a", "token-b" };
    rig.fake.static_key = "static-key";
    rig.fake.auth_headers.clearRetainingCapacity();
    {
        var manager = mcp.Manager.init(testing.allocator, io);
        defer manager.deinit();
        manager.token_dir = rig.store_dir;
        manager.loadServers(&.{
            .{ .name = "renamed", .tools_prefix = "a_", .url = rig.url, .oauth = true, .timeout_s = 10 },
            .{ .name = "keyed", .tools_prefix = "b_", .url = rig.url, .key = "static-key", .oauth = true, .timeout_s = 10 },
            .{ .name = "second", .tools_prefix = "c_", .url = rig.other_url, .oauth = true, .timeout_s = 10 },
        });
        try testing.expectEqual(@as(usize, 3), manager.registeredTools().len);
        var a_count: usize = 0;
        var b_count: usize = 0;
        var key_count: usize = 0;
        for (rig.fake.auth_headers.items) |h| {
            if (std.mem.eql(u8, h, "Bearer token-a")) a_count += 1;
            if (std.mem.eql(u8, h, "Bearer token-b")) b_count += 1;
            if (std.mem.eql(u8, h, "Bearer static-key")) key_count += 1;
        }
        try testing.expectEqual(@as(usize, 3), a_count);
        try testing.expectEqual(@as(usize, 3), b_count);
        try testing.expectEqual(@as(usize, 3), key_count);
    }
}

test "oauth token store tolerates corrupt file and replaces atomically" {
    const rig = try Rig.create();
    defer rig.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = rig.ioh();
    try std.Io.Dir.cwd().createDirPath(io, rig.store_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, rig.store_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "tokens.json", .data = "{not json" });
    try testing.expect(rig.get(a) == null);
    var rec = try rig.baseRecord();
    rec.access_token = "fresh";
    try rig.seed(rec);
    try testing.expectEqualStrings("fresh", rig.get(a).?.access_token.?);
    const variant = try std.fmt.allocPrint(a, "HTTP://127.0.0.1:{d}/mcp/#x", .{rig.fake.port});
    try testing.expectEqualStrings("fresh", rig.store().get(a, variant).?.access_token.?);
}

test "connect only starts the oauth flow for opted-in url servers without static key" {
    try testing.expect(mcp.wantsOAuth(.{ .name = "a", .tools_prefix = "", .url = "https://x", .oauth = true }));
    try testing.expect(!mcp.wantsOAuth(.{ .name = "a", .tools_prefix = "", .url = "https://x" }));
    try testing.expect(!mcp.wantsOAuth(.{ .name = "a", .tools_prefix = "", .url = "https://x", .oauth = true, .key = "k" }));
    try testing.expect(!mcp.wantsOAuth(.{ .name = "a", .tools_prefix = "", .command = "srv", .oauth = true }));
}
