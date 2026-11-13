const std = @import("std");

const HEAD_MAX = 8192;
const BODY_MAX = 8192;
const HEADER_MAX = 32;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    authorization: []const u8,
    body: []const u8,
    headers: []const Header,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        return findHeader(self.headers, name);
    }
};

pub const Next = enum { keep_reading, close };

pub const Response = struct {
    status: []const u8,
    body: []const u8 = "",
    content_type: ?[]const u8 = null,
    headers: []const Header = &.{},
    keep_alive: bool = false,
};

pub const Connection = struct {
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    head: [HEAD_MAX]u8 = undefined,
    body: [BODY_MAX]u8 = undefined,
    headers: [HEADER_MAX]Header = undefined,

    pub fn respond(self: *Connection, response: Response) !Next {
        try self.writeResponse(response);
        try self.writer.flush();
        return if (response.keep_alive) .keep_reading else .close;
    }

    fn writeResponse(self: *Connection, response: Response) !void {
        const w = self.writer;
        try w.print("HTTP/1.1 {s}\r\n", .{response.status});
        if (response.content_type) |content_type| try w.print("content-type: {s}\r\n", .{content_type});
        for (response.headers) |header| try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        try w.print("content-length: {d}\r\nconnection: {s}\r\n\r\n", .{ response.body.len, if (response.keep_alive) "keep-alive" else "close" });
        try w.writeAll(response.body);
    }

    fn readRequest(self: *Connection) !Request {
        const parsed = self.parseHead(try self.readHead());
        const content_length = std.fmt.parseInt(usize, findHeader(parsed.headers, "content-length") orelse "0", 10) catch 0;
        if (content_length > self.body.len) return error.BodyTooLong;
        try self.reader.readSliceAll(self.body[0..content_length]);

        var parts = std.mem.splitScalar(u8, parsed.request_line, ' ');
        return .{
            .method = parts.first(),
            .target = parts.next() orelse "",
            .authorization = findHeader(parsed.headers, "authorization") orelse "",
            .body = self.body[0..content_length],
            .headers = parsed.headers,
        };
    }

    fn readHead(self: *Connection) ![]const u8 {
        var len: usize = 0;
        while (len < self.head.len) {
            const byte = self.reader.takeByte() catch return error.Closed;
            self.head[len] = byte;
            len += 1;
            if (len >= 4 and std.mem.eql(u8, self.head[len - 4 .. len], "\r\n\r\n")) return self.head[0..len];
        }
        return error.HeadTooLong;
    }

    fn parseHead(self: *Connection, head: []const u8) ParsedHead {
        var count: usize = 0;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const request_line = lines.first();
        while (lines.next()) |line| {
            if (count == self.headers.len) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            self.headers[count] = .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " ") };
            count += 1;
        }
        return .{ .request_line = request_line, .headers = self.headers[0..count] };
    }
};

const ParsedHead = struct {
    request_line: []const u8,
    headers: []const Header,
};

pub fn Server(comptime Ctx: type) type {
    return struct {
        pub fn serve(io: std.Io, listener: *std.Io.net.Server, ctx: Ctx) void {
            var group: std.Io.Group = .init;
            defer group.cancel(io);
            while (true) {
                const stream = listener.accept(io) catch return;
                group.concurrent(io, connection, .{ io, ctx, stream }) catch {
                    stream.close(io);
                    return;
                };
            }
        }

        fn connection(io: std.Io, ctx: Ctx, stream: std.Io.net.Stream) void {
            defer stream.close(io);
            var read_buf: [16384]u8 = undefined;
            var write_buf: [16384]u8 = undefined;
            var stream_reader = stream.reader(io, &read_buf);
            var stream_writer = stream.writer(io, &write_buf);
            var conn: Connection = .{ .io = io, .reader = &stream_reader.interface, .writer = &stream_writer.interface };
            while (true) {
                const request = conn.readRequest() catch return;
                const next = ctx.handleRequest(&conn, request) catch return;
                if (next == .close) return;
            }
        }
    };
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// Numeric JSON-RPC `"id"` of a request body, 0 when absent.
pub fn jsonRpcId(body: []const u8) i64 {
    const idx = std.mem.indexOf(u8, body, "\"id\":") orelse return 0;
    var i = idx + "\"id\":".len;
    var n: i64 = 0;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        n = n * 10 + (body[i] - '0');
    }
    return n;
}
