const std = @import("std");
const posix = std.posix;

const apc_start = "\x1b_G";
const apc_end = "\x1b\\";
const max_payload_chunk = 3072;

pub const CellPixels = struct {
    w: u32 = 8,
    h: u32 = 16,
};

pub const Crop = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Placement = struct {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
    src: Crop,
};

pub fn graphicsSupported(env: *const std.process.Environ.Map) bool {
    if (env.get("KITTY_WINDOW_ID") != null) return true;
    const term = env.get("TERM") orelse return false;
    if (std.mem.indexOf(u8, term, "kitty") != null) return true;
    if (std.mem.indexOf(u8, term, "ghostty") != null) return true;
    return false;
}

pub fn cellPixels(fd: posix.fd_t) CellPixels {
    var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.c.ioctl(fd, posix.T.IOCGWINSZ, &wsz);
    if (rc >= 0 and wsz.col > 0 and wsz.row > 0 and wsz.xpixel >= wsz.col and wsz.ypixel >= wsz.row) {
        return .{ .w = wsz.xpixel / wsz.col, .h = wsz.ypixel / wsz.row };
    }
    return .{};
}

pub fn transmitRgba(writer: *std.Io.Writer, id: u32, rgba: []const u8, width: u32, height: u32) !void {
    var b64_buf: [4096]u8 = undefined;
    const encoder = std.base64.standard.Encoder;

    var offset: usize = 0;
    var first = true;
    while (offset < rgba.len or first) {
        const n = @min(max_payload_chunk, rgba.len - offset);
        const src = rgba[offset .. offset + n];
        const b64 = encoder.encode(&b64_buf, src);
        const more = offset + n < rgba.len;
        try writer.writeAll(apc_start);
        if (first) {
            try writer.print("q=2,a=t,f=32,s={d},v={d},i={d},m={d};", .{ width, height, id, @intFromBool(more) });
            first = false;
        } else {
            try writer.print("m={d};", .{@intFromBool(more)});
        }
        try writer.writeAll(b64);
        try writer.writeAll(apc_end);
        offset += n;
        if (n == 0) break;
    }
}

pub fn place(writer: *std.Io.Writer, id: u32, placement: Placement) !void {
    try placeWithId(writer, id, 0, placement);
}

pub fn placeWithId(writer: *std.Io.Writer, id: u32, placement_id: u32, placement: Placement) !void {
    try writer.print("\x1b[{d};{d}H", .{ @as(u32, placement.row) + 1, @as(u32, placement.col) + 1 });
    try writer.print(apc_start ++ "a=p,i={d},p={d},q=2,x={d},y={d},w={d},h={d},c={d},r={d},C=1" ++ apc_end, .{
        id,
        placement_id,
        placement.src.x,
        placement.src.y,
        placement.src.w,
        placement.src.h,
        placement.cols,
        placement.rows,
    });
}

pub fn deleteImage(writer: *std.Io.Writer, id: u32) !void {
    try writer.print(apc_start ++ "a=d,d=i,i={d},q=2" ++ apc_end, .{id});
}

pub fn deletePlacement(writer: *std.Io.Writer, id: u32, placement_id: u32) !void {
    try writer.print(apc_start ++ "a=d,d=i,i={d},p={d},q=2" ++ apc_end, .{ id, placement_id });
}

pub fn deleteAll(writer: *std.Io.Writer) !void {
    try writer.writeAll(apc_start ++ "a=d,d=a,q=2" ++ apc_end);
}
