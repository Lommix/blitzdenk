const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.oauth);

pub const DEFAULT_REDIRECT_PORT: u16 = 47823;
pub const CALLBACK_PATH = "/callback";
pub const AUTH_TIMEOUT_S: u64 = 300;
pub const REFRESH_SKEW_S: i64 = 60;
pub const STORE_DIR = "oauth";
const STORE_FILE = "tokens.json";
const STORE_TMP = "tokens.json.tmp";
const MAX_BODY = 1024 * 1024;
const MAX_CODE = 4096;

pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub fn storeDir(alloc: std.mem.Allocator, base_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ base_dir, STORE_DIR });
}

const UrlParts = struct {
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    query: []const u8,
};

fn splitUrl(raw: []const u8) !UrlParts {
    const sep = std.mem.indexOf(u8, raw, "://") orelse return error.InvalidUrl;
    var rest = raw[sep + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const tail = rest[auth_end..];
    const q = std.mem.indexOfScalar(u8, tail, '?') orelse tail.len;
    if (auth_end == 0) return error.InvalidUrl;
    return .{ .scheme = raw[0..sep], .authority = rest[0..auth_end], .path = tail[0..q], .query = tail[q..] };
}

pub fn normalizeUrl(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const parts = try splitUrl(std.mem.trim(u8, raw, " \t"));
    var authority = parts.authority;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        const bracket = std.mem.lastIndexOfScalar(u8, authority, ']') orelse 0;
        if (c > bracket) {
            const port = authority[c + 1 ..];
            const http_default = std.ascii.eqlIgnoreCase(parts.scheme, "http") and std.mem.eql(u8, port, "80");
            const https_default = std.ascii.eqlIgnoreCase(parts.scheme, "https") and std.mem.eql(u8, port, "443");
            if (http_default or https_default or port.len == 0) authority = authority[0..c];
        }
    }
    var path = parts.path;
    if (path.len == 0) path = "/";
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];

    const out = try std.fmt.allocPrint(alloc, "{s}://{s}{s}{s}", .{ parts.scheme, authority, path, parts.query });
    for (out[0 .. parts.scheme.len + 3 + authority.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

fn origin(url: []const u8) []const u8 {
    const parts = splitUrl(url) catch return url;
    return url[0 .. parts.scheme.len + 3 + parts.authority.len];
}

fn pathOf(url: []const u8) []const u8 {
    const parts = splitUrl(url) catch return "/";
    return if (parts.path.len == 0) "/" else parts.path;
}

fn isLoopbackHost(url: []const u8) bool {
    const parts = splitUrl(url) catch return false;
    const host = if (std.mem.lastIndexOfScalar(u8, parts.authority, ':')) |c| parts.authority[0..c] else parts.authority;
    return std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "[::1]");
}

pub fn secureEndpoint(url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return true;
    return builtin.is_test and std.ascii.startsWithIgnoreCase(url, "http://") and isLoopbackHost(url);
}

pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

pub fn parseBearerChallenge(header: []const u8) ?Challenge {
    var i: usize = 0;
    const start = while (i + 6 <= header.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(header[i .. i + 6], "bearer")) continue;
        const before_ok = i == 0 or header[i - 1] == ' ' or header[i - 1] == ',';
        const after_ok = i + 6 == header.len or header[i + 6] == ' ';
        if (before_ok and after_ok) break i + 6;
    } else return null;

    var out: Challenge = .{};
    var p = start;
    while (p < header.len) {
        while (p < header.len and (header[p] == ' ' or header[p] == ',')) p += 1;
        const name_start = p;
        while (p < header.len and header[p] != '=' and header[p] != ' ' and header[p] != ',') p += 1;
        const name = header[name_start..p];
        if (name.len == 0) break;
        while (p < header.len and header[p] == ' ') p += 1;
        if (p >= header.len or header[p] != '=') break;
        p += 1;
        while (p < header.len and header[p] == ' ') p += 1;
        var value: []const u8 = undefined;
        if (p < header.len and header[p] == '"') {
            p += 1;
            const v_start = p;
            while (p < header.len and header[p] != '"') : (p += 1) {
                if (header[p] == '\\') p += 1;
            }
            value = header[v_start..@min(p, header.len)];
            if (p < header.len) p += 1;
        } else {
            const v_start = p;
            while (p < header.len and header[p] != ',' and header[p] != ' ') p += 1;
            value = header[v_start..p];
        }
        if (std.ascii.eqlIgnoreCase(name, "resource_metadata")) out.resource_metadata = value;
        if (std.ascii.eqlIgnoreCase(name, "scope")) out.scope = value;
        if (std.ascii.eqlIgnoreCase(name, "error")) out.@"error" = value;
        if (std.ascii.eqlIgnoreCase(name, "error_description")) out.error_description = value;
    }
    return out;
}

pub const Record = struct {
    url: []const u8,
    resource: []const u8 = "",
    issuer: []const u8 = "",
    auth_server: []const u8 = "",
    token_endpoint: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: ?[]const u8 = null,
    auth_method: []const u8 = "none",
    redirect_uri: []const u8 = "",
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,
    updated_at: i64 = 0,

    pub fn usable(self: *const Record, now: i64) bool {
        if (self.access_token == null) return false;
        const exp = self.expires_at orelse return true;
        return exp - REFRESH_SKEW_S > now;
    }

    pub fn clearTokens(self: *Record) void {
        self.access_token = null;
        self.refresh_token = null;
        self.expires_at = null;
    }
};

const StoreFile = struct {
    records: []Record = &.{},
};

var store_mu: std.Io.Mutex = .init;

pub const Store = struct {
    io: std.Io,
    dir: []const u8,

    pub fn load(self: Store, arena: std.mem.Allocator) []Record {
        store_mu.lockUncancelable(self.io);
        defer store_mu.unlock(self.io);
        return self.loadLocked(arena);
    }

    pub fn get(self: Store, arena: std.mem.Allocator, url: []const u8) ?Record {
        const key = normalizeUrl(arena, url) catch return null;
        return find(self.load(arena), key);
    }

    pub fn find(records: []const Record, key: []const u8) ?Record {
        for (records) |rec| if (std.mem.eql(u8, rec.url, key)) return rec;
        return null;
    }

    pub fn findRegistration(self: Store, arena: std.mem.Allocator, auth_server: []const u8, redirect_uri: []const u8) ?Record {
        for (self.load(arena)) |rec| {
            if (rec.client_id.len == 0) continue;
            if (std.mem.eql(u8, rec.auth_server, auth_server) and std.mem.eql(u8, rec.redirect_uri, redirect_uri)) return rec;
        }
        return null;
    }

    pub fn put(self: Store, gpa: std.mem.Allocator, rec: Record) !void {
        store_mu.lockUncancelable(self.io);
        defer store_mu.unlock(self.io);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const existing = self.loadLocked(arena);
        var list: std.ArrayList(Record) = .empty;
        try list.ensureTotalCapacity(arena, existing.len + 1);
        var replaced = false;
        for (existing) |old| {
            if (std.mem.eql(u8, old.url, rec.url)) {
                list.appendAssumeCapacity(rec);
                replaced = true;
            } else list.appendAssumeCapacity(old);
        }
        if (!replaced) list.appendAssumeCapacity(rec);

        var out = std.Io.Writer.Allocating.init(arena);
        std.json.Stringify.value(StoreFile{ .records = list.items }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &out.writer) catch return error.StoreIo;
        self.writeAtomic(arena, out.written()) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.warn("token store write failed: {s}", .{@errorName(err)});
            return error.StoreIo;
        };
    }

    fn loadLocked(self: Store, arena: std.mem.Allocator) []Record {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.dir, .{}) catch |err| {
            if (err == error.Canceled) self.io.recancel();
            return &.{};
        };
        defer dir.close(self.io);
        const data = dir.readFileAlloc(self.io, STORE_FILE, arena, .limited(MAX_BODY)) catch |err| {
            if (err == error.Canceled) self.io.recancel();
            if (err != error.FileNotFound) log.warn("token store read failed: {s}", .{@errorName(err)});
            return &.{};
        };
        const parsed = std.json.parseFromSliceLeaky(StoreFile, arena, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            log.warn("token store is corrupt, treating as empty", .{});
            return &.{};
        };
        return parsed.records;
    }

    fn writeAtomic(self: Store, arena: std.mem.Allocator, data: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.dir);
        const dir_z = try arena.dupeSentinel(u8, self.dir, 0);
        _ = std.posix.system.chmod(dir_z, 0o700);
        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.dir, .{});
        defer dir.close(self.io);
        dir.deleteFile(self.io, STORE_TMP) catch |err| {
            if (err == error.Canceled) self.io.recancel();
        };
        {
            const f = try dir.createFile(self.io, STORE_TMP, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, data);
        }
        try dir.rename(STORE_TMP, dir, STORE_FILE, self.io);
    }
};

pub const HttpResult = struct {
    status: u16,
    body: []u8,
    www_authenticate: []u8,
};

fn sendError(err: anyerror) anyerror {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.NetworkError,
    };
}

pub fn httpSend(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    content_type: ?[]const u8,
    payload: ?[]const u8,
    extra: []const std.http.Header,
) !HttpResult {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = client.request(method, uri, .{
        .headers = .{
            .content_type = if (content_type) |ct| .{ .override = ct } else .default,
            .accept_encoding = .omit,
        },
        .extra_headers = extra,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    }) catch |err| return sendError(err);
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = req.sendBodyUnflushed(&.{}) catch |err| return sendError(err);
        body.writer.writeAll(p) catch |err| return sendError(err);
        body.end() catch |err| return sendError(err);
        req.connection.?.flush() catch |err| return sendError(err);
    } else {
        req.sendBodiless() catch |err| return sendError(err);
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| return sendError(err);
    const status: u16 = @backingInt(response.head.status);

    var www = std.Io.Writer.Allocating.init(alloc);
    errdefer www.deinit();
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) continue;
        if (www.written().len > 0) try www.writer.writeAll(", ");
        try www.writer.writeAll(h.value);
    }
    const www_owned = try www.toOwnedSlice();
    errdefer alloc.free(www_owned);

    const reader = response.reader(&.{});
    const body = reader.allocRemaining(alloc, .limited(MAX_BODY)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NetworkError,
    };
    return .{ .status = status, .body = body, .www_authenticate = www_owned };
}

const Form = struct {
    out: std.Io.Writer.Allocating,

    fn init(alloc: std.mem.Allocator) Form {
        return .{ .out = .init(alloc) };
    }

    fn add(self: *Form, key: []const u8, value: []const u8) error{OutOfMemory}!void {
        self.write(key, value) catch return error.OutOfMemory;
    }

    fn write(self: *Form, key: []const u8, value: []const u8) !void {
        const w = &self.out.writer;
        if (self.out.written().len > 0) try w.writeByte('&');
        try percentEncode(w, key);
        try w.writeByte('=');
        try percentEncode(w, value);
    }

    fn written(self: *Form) []const u8 {
        return self.out.written();
    }
};

fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
        } else if (s[i] == '%' and i + 2 < s.len) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidEncoding;
            i += 2;
        } else {
            out[n] = s[i];
        }
        n += 1;
    }
    return out[0..n];
}

pub fn queryParam(alloc: std.mem.Allocator, query: []const u8, name: []const u8) ?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return percentDecode(alloc, pair[eq + 1 ..]) catch null;
    }
    return null;
}

const ClientAuth = struct {
    client_id: []const u8,
    client_secret: ?[]const u8,
    auth_method: []const u8,
};

const TokenJson = struct {
    access_token: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
    expires_in: ?std.json.Value = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

const TokenResult = union(enum) {
    ok: TokenJson,
    invalid_grant,
    rejected,
};

fn tokenRequest(arena: std.mem.Allocator, client: *std.http.Client, endpoint: []const u8, auth: ClientAuth, form: *Form) !TokenResult {
    if (!secureEndpoint(endpoint)) return error.InsecureEndpoint;
    var headers: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    try form.add("client_id", auth.client_id);
    if (auth.client_secret) |secret| {
        if (std.mem.eql(u8, auth.auth_method, "client_secret_basic")) {
            var raw = std.Io.Writer.Allocating.init(arena);
            try percentEncode(&raw.writer, auth.client_id);
            try raw.writer.writeByte(':');
            try percentEncode(&raw.writer, secret);
            const enc = std.base64.standard.Encoder;
            const buf = try arena.alloc(u8, enc.calcSize(raw.written().len));
            const b64 = enc.encode(buf, raw.written());
            headers[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Basic {s}", .{b64}) };
            header_count = 1;
        } else {
            try form.add("client_secret", secret);
        }
    }
    const res = try httpSend(arena, client, .POST, endpoint, "application/x-www-form-urlencoded", form.written(), headers[0..header_count]);
    log.info("token endpoint {s} status {d}", .{ origin(endpoint), res.status });
    const parsed = std.json.parseFromSliceLeaky(TokenJson, arena, res.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    if (res.status == 401) return .invalid_grant;
    if (res.status >= 400) {
        const code = if (parsed) |p| p.@"error" orelse "" else "";
        log.warn("token endpoint error: {s}", .{code});
        if (std.mem.eql(u8, code, "invalid_grant")) return .invalid_grant;
        return .rejected;
    }
    const tok = parsed orelse return .rejected;
    if (tok.access_token == null) return .rejected;
    if (tok.token_type) |tt| if (!std.ascii.eqlIgnoreCase(tt, "bearer")) return .rejected;
    return .{ .ok = tok };
}

fn expiresIn(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub const RefreshError = error{ AuthRequired, NetworkError, OutOfMemory, Canceled };

pub fn refresh(arena: std.mem.Allocator, client: *std.http.Client, rec: *Record, now: i64) RefreshError!void {
    const refresh_token = rec.refresh_token orelse return error.AuthRequired;
    var form = Form.init(arena);
    try form.add("grant_type", "refresh_token");
    try form.add("refresh_token", refresh_token);
    if (rec.resource.len > 0) try form.add("resource", rec.resource);
    const result = tokenRequest(arena, client, rec.token_endpoint, .{
        .client_id = rec.client_id,
        .client_secret = rec.client_secret,
        .auth_method = rec.auth_method,
    }, &form) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.NetworkError,
    };
    switch (result) {
        .ok => |tok| {
            rec.access_token = tok.access_token;
            if (tok.refresh_token) |rt| rec.refresh_token = rt;
            rec.expires_at = if (expiresIn(tok.expires_in)) |s| now + s else null;
            if (tok.scope) |s| rec.scope = s;
            rec.updated_at = now;
        },
        .invalid_grant => {
            rec.clearTokens();
            rec.updated_at = now;
            return error.AuthRequired;
        },
        .rejected => return error.AuthRequired,
    }
}

pub const Phase = enum(u8) { idle, probing, discovering, registering, awaiting_callback, exchanging, storing, done, failed };

pub const ErrorKind = enum {
    no_client_registration,
    pkce_unsupported,
    discovery_failed,
    registration_failed,
    state_mismatch,
    issuer_mismatch,
    token_rejected,
    timeout,
    network,
    store_io,
    canceled,

    pub fn text(self: ErrorKind) []const u8 {
        return switch (self) {
            .no_client_registration => "no client registration; set client_id",
            .pkce_unsupported => "server lacks PKCE S256",
            .discovery_failed => "discovery failed",
            .registration_failed => "client registration failed",
            .state_mismatch => "state mismatch",
            .issuer_mismatch => "issuer mismatch",
            .token_rejected => "token rejected",
            .timeout => "timed out",
            .network => "network error",
            .store_io => "token store I/O failed",
            .canceled => "canceled",
        };
    }

    fn fromError(err: anyerror) ErrorKind {
        return switch (err) {
            error.NoClientRegistration => .no_client_registration,
            error.PkceUnsupported => .pkce_unsupported,
            error.DiscoveryFailed => .discovery_failed,
            error.RegistrationFailed => .registration_failed,
            error.StateMismatch => .state_mismatch,
            error.IssuerMismatch => .issuer_mismatch,
            error.TokenRejected => .token_rejected,
            error.Timeout => .timeout,
            error.StoreIo => .store_io,
            error.Canceled => .canceled,
            else => .network,
        };
    }
};

pub const Outcome = enum { authorized, no_auth_needed, failed };

pub const Opener = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, io: std.Io, url: []const u8) error{Canceled}!bool,
};

pub const browser_opener: Opener = .{ .func = openBrowser };

fn openBrowser(_: ?*anyopaque, io: std.Io, url: []const u8) error{Canceled}!bool {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return if (err == error.Canceled) error.Canceled else false;
    const term = child.wait(io) catch |err| return if (err == error.Canceled) error.Canceled else false;
    return term.success();
}

pub const TaskConfig = struct {
    name: []const u8,
    url: []const u8,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
    redirect_port: u16 = DEFAULT_REDIRECT_PORT,
    store_dir: []const u8,
    timeout_s: u64 = AUTH_TIMEOUT_S,
};

const AuthServer = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8,
};

const ResourceMeta = struct {
    resource: ?[]const u8,
    auth_server: []const u8,
    scopes: []const []const u8,
};

const ConnResult = struct {
    kind: enum { ignored, ok, failed } = .ignored,
    err: ErrorKind = .network,
    code_buf: [MAX_CODE]u8 = undefined,
    code_len: usize = 0,
};

const CallbackSel = union(enum) {
    conn: ConnResult,
    timeout: void,
    accept_failed: void,
};

const Expect = struct {
    state: []const u8,
    issuer: []const u8,
};

pub const Task = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    cfg: TaskConfig,
    opener: Opener,
    phase_value: std.atomic.Value(Phase) = .init(.idle),
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    outcome: Outcome = .failed,
    err_kind: ErrorKind = .canceled,
    auth_url: []const u8 = "",
    redirect_uri: []const u8 = "",
    opener_failed: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: TaskConfig, opener: Opener) !Task {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const scopes = try a.alloc([]const u8, cfg.scopes.len);
        for (cfg.scopes, 0..) |s, i| scopes[i] = try a.dupe(u8, s);
        const owned: TaskConfig = .{
            .name = try a.dupe(u8, cfg.name),
            .url = try a.dupe(u8, cfg.url),
            .client_id = if (cfg.client_id) |v| try a.dupe(u8, v) else null,
            .client_secret = if (cfg.client_secret) |v| try a.dupe(u8, v) else null,
            .scopes = scopes,
            .redirect_port = cfg.redirect_port,
            .store_dir = try a.dupe(u8, cfg.store_dir),
            .timeout_s = cfg.timeout_s,
        };
        return .{ .gpa = gpa, .io = io, .arena = arena, .opener = opener, .cfg = owned };
    }

    pub fn start(self: *Task) void {
        self.future = std.Io.concurrent(self.io, run, .{self}) catch {
            self.err_kind = .network;
            self.phase_value.store(.failed, .release);
            self.finished.store(true, .release);
            return;
        };
    }

    pub fn isFinished(self: *const Task) bool {
        return self.finished.load(.acquire);
    }

    pub fn phase(self: *const Task) Phase {
        return self.phase_value.load(.acquire);
    }

    pub fn name(self: *const Task) []const u8 {
        return self.cfg.name;
    }

    pub fn deinit(self: *Task) void {
        if (self.future) |*future| future.cancel(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    fn setPhase(self: *Task, p: Phase) void {
        self.phase_value.store(p, .release);
    }

    fn run(self: *Task) void {
        defer self.finished.store(true, .release);
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        self.outcome = self.flow(&client) catch |err| {
            self.err_kind = ErrorKind.fromError(err);
            log.warn("authorization for '{s}' failed: {s}", .{ self.cfg.name, @errorName(err) });
            self.outcome = .failed;
            self.setPhase(.failed);
            return;
        };
        self.setPhase(.done);
    }

    fn flow(self: *Task, client: *std.http.Client) !Outcome {
        const a = self.arena.allocator();
        const store: Store = .{ .io = self.io, .dir = self.cfg.store_dir };
        const key = try normalizeUrl(a, self.cfg.url);
        const now = nowSeconds(self.io);

        if (store.get(a, key)) |found| {
            var rec = found;
            if (rec.usable(now)) return .authorized;
            if (rec.refresh_token != null and rec.token_endpoint.len > 0) {
                self.setPhase(.exchanging);
                if (refresh(a, client, &rec, now)) {
                    self.setPhase(.storing);
                    try store.put(self.gpa, rec);
                    return .authorized;
                } else |err| switch (err) {
                    error.AuthRequired => store.put(self.gpa, rec) catch |e| {
                        if (e == error.Canceled) return error.Canceled;
                    },
                    error.NetworkError => return error.NetworkError,
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                }
            }
        }

        self.setPhase(.probing);
        const probe = try httpSend(a, client, .POST, self.cfg.url, "application/json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"blitz\",\"version\":\"0.1\"}}}", &.{
            .{ .name = "accept", .value = "application/json, text/event-stream" },
        });
        log.info("probe {s} status {d}", .{ origin(key), probe.status });
        if (probe.status >= 200 and probe.status < 300) return .no_auth_needed;
        const challenge: Challenge = if (probe.status == 401) parseBearerChallenge(probe.www_authenticate) orelse .{} else .{};

        self.setPhase(.discovering);
        const prm = try discoverResource(a, client, key, challenge);
        const as = try discoverAuthServer(a, client, prm.auth_server);
        const resource = prm.resource orelse key;
        const scope = try selectScope(a, self.cfg.scopes, challenge.scope, prm.scopes);

        var server = try bindLoopback(self.io, self.cfg.redirect_port);
        defer server.deinit(self.io);
        const redirect_uri = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}" ++ CALLBACK_PATH, .{server.socket.address.getPort()});

        self.setPhase(.registering);
        const auth = try self.register(a, client, store, as, prm.auth_server, redirect_uri);

        var verifier_raw: [32]u8 = undefined;
        var state_raw: [16]u8 = undefined;
        self.io.randomSecure(&verifier_raw) catch |err| return if (err == error.Canceled) error.Canceled else error.NetworkError;
        self.io.randomSecure(&state_raw) catch |err| return if (err == error.Canceled) error.Canceled else error.NetworkError;
        var verifier_buf: [64]u8 = undefined;
        const verifier = std.base64.url_safe_no_pad.Encoder.encode(&verifier_buf, &verifier_raw);
        var state_buf: [32]u8 = undefined;
        const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buf, &state_raw);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var challenge_buf: [64]u8 = undefined;
        const code_challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &digest);

        var url_form = Form.init(a);
        try url_form.add("response_type", "code");
        try url_form.add("client_id", auth.client_id);
        try url_form.add("redirect_uri", redirect_uri);
        try url_form.add("code_challenge", code_challenge);
        try url_form.add("code_challenge_method", "S256");
        try url_form.add("state", state);
        try url_form.add("resource", resource);
        if (scope) |s| try url_form.add("scope", s);
        const joiner: []const u8 = if (std.mem.indexOfScalar(u8, as.authorization_endpoint, '?') != null) "&" else "?";
        self.auth_url = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ as.authorization_endpoint, joiner, url_form.written() });
        self.redirect_uri = redirect_uri;
        self.opener_failed = !(try self.opener.func(self.opener.ctx, self.io, self.auth_url));
        self.setPhase(.awaiting_callback);

        const code = try self.awaitCallback(&server, .{ .state = state, .issuer = as.issuer });

        self.setPhase(.exchanging);
        var form = Form.init(a);
        try form.add("grant_type", "authorization_code");
        try form.add("code", code);
        try form.add("redirect_uri", redirect_uri);
        try form.add("code_verifier", verifier);
        try form.add("resource", resource);
        const result = tokenRequest(a, client, as.token_endpoint, auth, &form) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.NetworkError,
        };
        const tok = switch (result) {
            .ok => |t| t,
            else => return error.TokenRejected,
        };

        self.setPhase(.storing);
        try store.put(self.gpa, .{
            .url = key,
            .resource = resource,
            .issuer = as.issuer,
            .auth_server = prm.auth_server,
            .token_endpoint = as.token_endpoint,
            .client_id = auth.client_id,
            .client_secret = auth.client_secret,
            .auth_method = auth.auth_method,
            .redirect_uri = redirect_uri,
            .access_token = tok.access_token,
            .refresh_token = tok.refresh_token,
            .expires_at = if (expiresIn(tok.expires_in)) |s| now + s else null,
            .scope = tok.scope orelse scope,
            .updated_at = now,
        });
        return .authorized;
    }

    fn register(self: *Task, a: std.mem.Allocator, client: *std.http.Client, store: Store, as: AuthServer, auth_server: []const u8, redirect_uri: []const u8) !ClientAuth {
        if (self.cfg.client_id) |id| return .{
            .client_id = id,
            .client_secret = self.cfg.client_secret,
            .auth_method = if (self.cfg.client_secret != null) "client_secret_basic" else "none",
        };
        if (store.findRegistration(a, auth_server, redirect_uri)) |rec| return .{
            .client_id = rec.client_id,
            .client_secret = rec.client_secret,
            .auth_method = rec.auth_method,
        };
        const endpoint = as.registration_endpoint orelse return error.NoClientRegistration;
        if (!secureEndpoint(endpoint)) return error.RegistrationFailed;

        var body = std.Io.Writer.Allocating.init(a);
        try body.writer.writeAll("{\"client_name\":\"Blitzdenk\",\"redirect_uris\":[");
        try std.json.Stringify.value(redirect_uri, .{}, &body.writer);
        try body.writer.writeAll("],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}");
        const res = httpSend(a, client, .POST, endpoint, "application/json", body.written(), &.{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.RegistrationFailed,
        };
        log.info("registration {s} status {d}", .{ origin(endpoint), res.status });
        if (res.status != 200 and res.status != 201) return error.RegistrationFailed;
        const Reg = struct {
            client_id: ?[]const u8 = null,
            client_secret: ?[]const u8 = null,
            token_endpoint_auth_method: ?[]const u8 = null,
        };
        const reg = std.json.parseFromSliceLeaky(Reg, a, res.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.RegistrationFailed;
        const id = reg.client_id orelse return error.RegistrationFailed;
        return .{
            .client_id = id,
            .client_secret = reg.client_secret,
            .auth_method = reg.token_endpoint_auth_method orelse if (reg.client_secret != null) "client_secret_basic" else "none",
        };
    }

    fn awaitCallback(self: *Task, server: *std.Io.net.Server, expect: Expect) ![]const u8 {
        var buffer: [4]CallbackSel = undefined;
        var select = std.Io.Select(CallbackSel).init(self.io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.accept_failed, acceptLoop, .{ self, server, &select, &expect }) catch return error.NetworkError;
        select.async(.timeout, sleepSeconds, .{ self.io, self.cfg.timeout_s });
        while (true) {
            const sel = try select.await();
            switch (sel) {
                .timeout => return error.Timeout,
                .accept_failed => return error.NetworkError,
                .conn => |res| switch (res.kind) {
                    .ignored => continue,
                    .failed => return switch (res.err) {
                        .state_mismatch => error.StateMismatch,
                        .issuer_mismatch => error.IssuerMismatch,
                        else => error.TokenRejected,
                    },
                    .ok => return try self.arena.allocator().dupe(u8, res.code_buf[0..res.code_len]),
                },
            }
        }
    }

    fn acceptLoop(self: *Task, server: *std.Io.net.Server, select: *std.Io.Select(CallbackSel), expect: *const Expect) void {
        while (true) {
            const stream = server.accept(self.io) catch return;
            select.concurrent(.conn, handleConn, .{ self.io, stream, expect }) catch {
                stream.close(self.io);
                return;
            };
        }
    }
};

fn sleepSeconds(io: std.Io, seconds: u64) void {
    std.Io.sleep(io, .fromSeconds(@intCast(seconds)), .awake) catch {};
}

fn handleConn(io: std.Io, stream: std.Io.net.Stream, expect: *const Expect) ConnResult {
    defer stream.close(io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [2048]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;

    const line_raw = (reader.interface.takeDelimiter('\n') catch return .{}) orelse return .{};
    var line_copy: [8192]u8 = undefined;
    const line = std.mem.trimEnd(u8, line_raw, "\r");
    @memcpy(line_copy[0..line.len], line);
    const request_line = line_copy[0..line.len];
    while (true) {
        const h = (reader.interface.takeDelimiter('\n') catch break) orelse break;
        if (std.mem.trimEnd(u8, h, "\r").len == 0) break;
    }

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.first();
    const target = parts.next() orelse "";
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |i| target[i + 1 ..] else "";

    if (!std.mem.eql(u8, path, CALLBACK_PATH)) {
        respond(w, "404 Not Found", "Not found");
        return .{};
    }
    if (!std.mem.eql(u8, method, "GET")) {
        respond(w, "405 Method Not Allowed", "Method not allowed");
        return .{};
    }

    var scratch: [MAX_CODE * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();
    const state = queryParam(a, query, "state") orelse "";
    if (!std.mem.eql(u8, state, expect.state)) {
        respond(w, "400 Bad Request", "Authorization failed: state mismatch. You can close this window.");
        return .{ .kind = .failed, .err = .state_mismatch };
    }
    if (queryParam(a, query, "iss")) |iss| {
        if (expect.issuer.len > 0 and !sameIssuer(iss, expect.issuer)) {
            respond(w, "400 Bad Request", "Authorization failed: issuer mismatch. You can close this window.");
            return .{ .kind = .failed, .err = .issuer_mismatch };
        }
    }
    if (queryParam(a, query, "error")) |code| {
        log.warn("authorization error: {s}", .{code[0..@min(code.len, 64)]});
        respond(w, "400 Bad Request", "Authorization was denied. You can close this window.");
        return .{ .kind = .failed, .err = .token_rejected };
    }
    const code = queryParam(a, query, "code") orelse {
        respond(w, "400 Bad Request", "Authorization failed: missing code. You can close this window.");
        return .{ .kind = .failed, .err = .token_rejected };
    };
    if (code.len > MAX_CODE) return .{ .kind = .failed, .err = .token_rejected };
    respond(w, "200 OK", "Blitzdenk is authorized. You can close this window.");
    var out: ConnResult = .{ .kind = .ok, .code_len = code.len };
    @memcpy(out.code_buf[0..code.len], code);
    return out;
}

fn respond(w: *std.Io.Writer, status: []const u8, message: []const u8) void {
    w.print("HTTP/1.1 {s}\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n<!doctype html><title>Blitzdenk</title><p>{s}</p>", .{
        status,
        "<!doctype html><title>Blitzdenk</title><p></p>".len + message.len,
        message,
    }) catch return;
    w.flush() catch {};
}

fn sameIssuer(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn bindLoopback(io: std.Io, port: u16) !std.Io.net.Server {
    const preferred = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    if (preferred.listen(io, .{})) |server| return server else |err| {
        if (err == error.Canceled) return error.Canceled;
        log.info("callback port {d} unavailable: {s}", .{ port, @errorName(err) });
    }
    const fallback = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    return fallback.listen(io, .{}) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => error.NetworkError,
    };
}

fn selectScope(a: std.mem.Allocator, configured: []const []const u8, challenge: ?[]const u8, supported: []const []const u8) !?[]const u8 {
    if (configured.len > 0) return try std.mem.join(a, " ", configured);
    if (challenge) |s| if (s.len > 0) return s;
    if (supported.len > 0) return try std.mem.join(a, " ", supported);
    return null;
}

fn getJson(a: std.mem.Allocator, client: *std.http.Client, url: []const u8) !?std.json.Value {
    if (!secureEndpoint(url)) {
        log.warn("refusing insecure metadata url {s}", .{origin(url)});
        return null;
    }
    const res = httpSend(a, client, .GET, url, null, null, &.{.{ .name = "accept", .value = "application/json" }}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    log.info("metadata {s}{s} status {d}", .{ origin(url), pathOf(url), res.status });
    if (res.status != 200) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    return value;
}

fn str(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn strList(a: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8 {
    const v = value.object.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| if (item == .string) try out.append(a, item.string);
    return out.items;
}

fn discoverResource(a: std.mem.Allocator, client: *std.http.Client, key: []const u8, challenge: Challenge) !ResourceMeta {
    var candidates: [3][]const u8 = undefined;
    var n: usize = 0;
    if (challenge.resource_metadata) |u| {
        candidates[n] = u;
        n += 1;
    }
    const base = origin(key);
    const path = pathOf(key);
    if (!std.mem.eql(u8, path, "/")) {
        candidates[n] = try std.fmt.allocPrint(a, "{s}/.well-known/oauth-protected-resource{s}", .{ base, path });
        n += 1;
    }
    candidates[n] = try std.fmt.allocPrint(a, "{s}/.well-known/oauth-protected-resource", .{base});
    n += 1;

    for (candidates[0..n]) |url| {
        const value = (try getJson(a, client, url)) orelse continue;
        const servers = try strList(a, value, "authorization_servers");
        if (servers.len == 0) continue;
        return .{
            .resource = str(value, "resource"),
            .auth_server = servers[0],
            .scopes = try strList(a, value, "scopes_supported"),
        };
    }
    return error.DiscoveryFailed;
}

fn discoverAuthServer(a: std.mem.Allocator, client: *std.http.Client, issuer: []const u8) !AuthServer {
    if (!secureEndpoint(issuer)) return error.DiscoveryFailed;
    const base = origin(issuer);
    const raw_path = std.mem.trimEnd(u8, pathOf(issuer), "/");
    var candidates: [3][]const u8 = undefined;
    var n: usize = 0;
    if (raw_path.len > 0) {
        candidates[0] = try std.fmt.allocPrint(a, "{s}/.well-known/oauth-authorization-server{s}", .{ base, raw_path });
        candidates[1] = try std.fmt.allocPrint(a, "{s}/.well-known/openid-configuration{s}", .{ base, raw_path });
        candidates[2] = try std.fmt.allocPrint(a, "{s}{s}/.well-known/openid-configuration", .{ base, raw_path });
        n = 3;
    } else {
        candidates[0] = try std.fmt.allocPrint(a, "{s}/.well-known/oauth-authorization-server", .{base});
        candidates[1] = try std.fmt.allocPrint(a, "{s}/.well-known/openid-configuration", .{base});
        n = 2;
    }

    var mismatch = false;
    for (candidates[0..n]) |url| {
        const value = (try getJson(a, client, url)) orelse continue;
        const got = str(value, "issuer") orelse "";
        if (!sameIssuer(got, issuer)) {
            log.warn("issuer mismatch at {s}{s}", .{ origin(url), pathOf(url) });
            mismatch = true;
            continue;
        }
        const methods = try strList(a, value, "code_challenge_methods_supported");
        var s256 = false;
        for (methods) |m| if (std.mem.eql(u8, m, "S256")) {
            s256 = true;
        };
        if (!s256) return error.PkceUnsupported;
        const authz = str(value, "authorization_endpoint") orelse return error.DiscoveryFailed;
        const token = str(value, "token_endpoint") orelse return error.DiscoveryFailed;
        if (!secureEndpoint(authz) or !secureEndpoint(token)) return error.DiscoveryFailed;
        return .{
            .issuer = got,
            .authorization_endpoint = authz,
            .token_endpoint = token,
            .registration_endpoint = str(value, "registration_endpoint"),
        };
    }
    return if (mismatch) error.IssuerMismatch else error.DiscoveryFailed;
}

test {
    _ = @import("oauth_test.zig");
}

test "normalize url" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "HTTPS://Example.COM:443/mcp/", "https://example.com/mcp" },
        .{ "http://Host:80", "http://host/" },
        .{ "http://host:8080/a/b?x=1#frag", "http://host:8080/a/b?x=1" },
        .{ "https://host/", "https://host/" },
    };
    for (cases) |case| {
        const got = try normalizeUrl(a, case[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "bearer challenge parsing" {
    const c = parseBearerChallenge("Basic realm=\"x\", Bearer resource_metadata=\"https://h/.well-known/oauth-protected-resource\", scope=\"a b\", error=insufficient_scope").?;
    try std.testing.expectEqualStrings("https://h/.well-known/oauth-protected-resource", c.resource_metadata.?);
    try std.testing.expectEqualStrings("a b", c.scope.?);
    try std.testing.expectEqualStrings("insufficient_scope", c.@"error".?);
    try std.testing.expect(parseBearerChallenge("Basic realm=\"x\"") == null);
}
