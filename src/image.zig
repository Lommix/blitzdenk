const std = @import("std");

pub const Error = error{
    Unsupported,
    Corrupt,
    TooLarge,
};

pub const Format = enum { png, jpeg, gif };
pub const max_pixel_bytes: usize = 64 * 1024 * 1024;
pub const max_work_bytes: usize = 128 * 1024 * 1024;

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Image, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }
};

pub fn sniffFormat(data: []const u8) ?Format {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) return .png;
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return .jpeg;
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], "GIF87a")) return .gif;
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], "GIF89a")) return .gif;
    return null;
}

pub const Size = struct {
    width: u32,
    height: u32,
};

pub fn dimensions(data: []const u8) ?Size {
    if (data.len >= 24 and std.mem.eql(u8, data[0..8], &png_sig) and std.mem.eql(u8, data[12..16], "IHDR")) {
        const width = std.mem.readInt(u32, data[16..20], .big);
        const height = std.mem.readInt(u32, data[20..24], .big);
        if (width == 0 or height == 0) return null;
        return .{ .width = width, .height = height };
    }
    if (data.len >= 4 and data[0] == 0xFF and data[1] == 0xD8) return jpegDimensions(data);
    if (data.len >= 10 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) {
        return .{
            .width = std.mem.readInt(u16, data[6..8], .little),
            .height = std.mem.readInt(u16, data[8..10], .little),
        };
    }
    if (data.len >= 30 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return webpDimensions(data);
    return null;
}

fn jpegDimensions(data: []const u8) ?Size {
    var pos: usize = 2;
    while (pos + 4 <= data.len) {
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }
        var marker_pos = pos + 1;
        while (marker_pos < data.len and data[marker_pos] == 0xFF) marker_pos += 1;
        if (marker_pos >= data.len) return null;
        const marker = data[marker_pos];
        pos = marker_pos + 1;
        if (marker == 0x00 or marker == 0x01 or marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD7)) continue;
        if (marker == 0xD9 or marker == 0xDA) return null;
        if (pos + 2 > data.len) return null;
        const segment_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (segment_len < 2) return null;
        const is_sof = switch (marker) {
            0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => true,
            else => false,
        };
        if (is_sof) {
            if (segment_len < 8 or pos + 7 > data.len) return null;
            const height = std.mem.readInt(u16, data[pos + 3 ..][0..2], .big);
            const width = std.mem.readInt(u16, data[pos + 5 ..][0..2], .big);
            if (width == 0 or height == 0) return null;
            return .{ .width = width, .height = height };
        }
        pos += segment_len;
    }
    return null;
}

fn webpDimensions(data: []const u8) ?Size {
    if (std.mem.eql(u8, data[12..16], "VP8X")) {
        const width = readU24Le(data[24..27]) + 1;
        const height = readU24Le(data[27..30]) + 1;
        return .{ .width = width, .height = height };
    }
    if (std.mem.eql(u8, data[12..16], "VP8L")) {
        if (data[20] != 0x2F) return null;
        const bits = std.mem.readInt(u32, data[21..25], .little);
        return .{
            .width = (bits & 0x3FFF) + 1,
            .height = ((bits >> 14) & 0x3FFF) + 1,
        };
    }
    if (std.mem.eql(u8, data[12..16], "VP8 ")) {
        if (data[23] != 0x9D or data[24] != 0x01 or data[25] != 0x2A) return null;
        const width = std.mem.readInt(u16, data[26..28], .little) & 0x3FFF;
        const height = std.mem.readInt(u16, data[28..30], .little) & 0x3FFF;
        if (width == 0 or height == 0) return null;
        return .{ .width = width, .height = height };
    }
    return null;
}

fn readU24Le(data: []const u8) u32 {
    return @as(u32, data[0]) | @as(u32, data[1]) << 8 | @as(u32, data[2]) << 16;
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)!Image {
    return switch (sniffFormat(data) orelse return Error.Unsupported) {
        .png => decodePng(alloc, data),
        .jpeg => decodeJpeg(alloc, data),
        .gif => decodeGif(alloc, data),
    };
}

pub fn encodePng(alloc: std.mem.Allocator, img: Image) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    std.debug.assert(img.pixels.len == @as(usize, img.width) * img.height * 4);
    const stride = @as(usize, img.width) * 4;
    const raw_len = (stride + 1) * @as(usize, img.height);
    const raw = try alloc.alloc(u8, raw_len);
    defer alloc.free(raw);

    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        const src = img.pixels[y * stride ..][0..stride];
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        dst[0] = 1;
        for (src, 0..) |byte, x| {
            const left = if (x >= 4) src[x - 4] else 0;
            dst[x + 1] = byte -% left;
        }
    }

    var deflated = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer deflated.deinit();
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var compressor = try std.compress.flate.Compress.init(&deflated.writer, window, .zlib, std.compress.flate.Compress.Options.level_1);
    try compressor.writer.writeAll(raw);
    try compressor.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &png_sig);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    try appendPngChunk(alloc, &out, "IHDR", &ihdr);
    try appendPngChunk(alloc, &out, "IDAT", deflated.writer.buffered());
    try appendPngChunk(alloc, &out, "IEND", &.{});
    return out.toOwnedSlice(alloc);
}

fn appendPngChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const u8) std.mem.Allocator.Error!void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(alloc, &len_buf);
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(alloc, &crc_buf);
}

pub fn downsampleMaxSide(alloc: std.mem.Allocator, img: Image, max_side: u32) !Image {
    return scaleToFit(alloc, img, max_side, max_side);
}

pub fn scaleToFit(alloc: std.mem.Allocator, img: Image, max_w: u32, max_h: u32) !Image {
    if (max_w == 0 or max_h == 0) return img;
    if (img.width <= max_w and img.height <= max_h) return img;
    const width_ratio = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(img.width));
    const height_ratio = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(img.height));
    const ratio = @min(width_ratio, height_ratio);
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.width)) * ratio)));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.height)) * ratio)));
    return resize(alloc, img, out_w, out_h);
}

pub fn scaleMaxHeight(alloc: std.mem.Allocator, img: Image, max_h: u32) !Image {
    if (img.height <= max_h) return img;
    const ratio = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(img.height));
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.width)) * ratio)));
    return resize(alloc, img, out_w, max_h);
}

pub fn scaleMaxWidth(alloc: std.mem.Allocator, img: Image, max_w: u32) !Image {
    if (img.width <= max_w) return img;
    const ratio = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(img.width));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.height)) * ratio)));
    return resize(alloc, img, max_w, out_h);
}

fn resize(alloc: std.mem.Allocator, img: Image, out_w: u32, out_h: u32) !Image {
    const out = try alloc.alloc(u8, try pixelBytes(out_w, out_h));
    errdefer alloc.free(out);
    var y: usize = 0;
    while (y < out_h) : (y += 1) {
        const sy0 = y * img.height / out_h;
        const sy1 = @max(sy0 + 1, (y + 1) * img.height / out_h);
        var x: usize = 0;
        while (x < out_w) : (x += 1) {
            const sx0 = x * img.width / out_w;
            const sx1 = @max(sx0 + 1, (x + 1) * img.width / out_w);
            var acc: [4]u64 = .{ 0, 0, 0, 0 };
            var count: u64 = 0;
            var sy = sy0;
            while (sy < sy1 and sy < img.height) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1 and sx < img.width) : (sx += 1) {
                    const src = img.pixels[(sy * img.width + sx) * 4 ..][0..4];
                    acc[0] += src[0];
                    acc[1] += src[1];
                    acc[2] += src[2];
                    acc[3] += src[3];
                    count += 1;
                }
            }
            const dst = out[(y * out_w + x) * 4 ..][0..4];
            for (dst, acc) |*d, a| d.* = @intCast(a / count);
        }
    }
    alloc.free(img.pixels);
    return .{ .width = out_w, .height = out_h, .pixels = out };
}

fn checkDims(w: u32, h: u32) Error!void {
    if (w == 0 or h == 0) return Error.Corrupt;
    if (w > 32768 or h > 32768) return Error.TooLarge;
    if (@as(u64, w) * @as(u64, h) > max_pixel_bytes / 4) return Error.TooLarge;
}

fn pixelBytes(w: u32, h: u32) Error!usize {
    try checkDims(w, h);
    return @intCast(@as(u64, w) * @as(u64, h) * 4);
}

fn workBytes(bytes: u64) Error!usize {
    if (bytes > max_work_bytes) return Error.TooLarge;
    return @intCast(bytes);
}

fn inflateZlib(alloc: std.mem.Allocator, data: []const u8, expected_len: usize) ![]u8 {
    if (expected_len > max_work_bytes) return Error.TooLarge;
    var input = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    const out = try alloc.alloc(u8, expected_len);
    errdefer alloc.free(out);
    decomp.reader.readSliceAll(out) catch |err| switch (err) {
        error.EndOfStream => return Error.Corrupt,
        else => return Error.Corrupt,
    };
    return out;
}

const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

fn decodePng(alloc: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)!Image {
    if (data.len < png_sig.len or !std.mem.eql(u8, data[0..png_sig.len], &png_sig)) return Error.Corrupt;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var trns: [256]u8 = @splat(255);
    var trns_len: usize = 0;
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    var pos: usize = png_sig.len;
    var saw_ihdr = false;
    var saw_idat = false;
    while (pos + 8 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        pos += 8;
        if (@as(u64, pos) + chunk_len + 4 > data.len) return Error.Corrupt;
        const chunk_data = data[pos .. pos + chunk_len];
        pos += chunk_len + 4;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len != 13 or saw_ihdr) return Error.Corrupt;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            try checkDims(width, height);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            interlace = chunk_data[12];
            saw_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (chunk_len == 0 or chunk_len % 3 != 0 or chunk_len > 768) return Error.Corrupt;
            palette_len = @min(chunk_len / 3, 256);
            for (0..palette_len) |i| {
                palette[i] = .{ chunk_data[i * 3], chunk_data[i * 3 + 1], chunk_data[i * 3 + 2] };
            }
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            trns_len = @min(chunk_len, 256);
            @memcpy(trns[0..trns_len], chunk_data[0..trns_len]);
            if (color_type == 0 and chunk_len >= 2) {
                trns_gray = std.mem.readInt(u16, chunk_data[0..2], .big);
            } else if (color_type == 2 and chunk_len >= 6) {
                trns_rgb = .{
                    std.mem.readInt(u16, chunk_data[0..2], .big),
                    std.mem.readInt(u16, chunk_data[2..4], .big),
                    std.mem.readInt(u16, chunk_data[4..6], .big),
                };
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (@as(u64, idat.items.len) + chunk_len > max_work_bytes / 2) return Error.TooLarge;
            try idat.appendSlice(alloc, chunk_data);
            saw_idat = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    if (!saw_ihdr or !saw_idat) return Error.Corrupt;
    try checkDims(width, height);
    if (interlace != 0) return Error.Unsupported;

    const channels: u8 = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return Error.Unsupported,
    };
    switch (color_type) {
        0 => if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8 and bit_depth != 16) return Error.Unsupported,
        3 => if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8) return Error.Unsupported,
        2, 4, 6 => if (bit_depth != 8 and bit_depth != 16) return Error.Unsupported,
        else => return Error.Unsupported,
    }
    if (color_type == 3 and palette_len == 0) return Error.Corrupt;

    const bits_per_pixel: u32 = @as(u32, channels) * bit_depth;
    const stride: usize = @intCast((@as(u64, width) * bits_per_pixel + 7) / 8);
    const raw_len = try workBytes((@as(u64, stride) + 1) * height);
    const pixel_len = try pixelBytes(width, height);
    if (@as(u64, idat.items.len) + raw_len + pixel_len > max_work_bytes) return Error.TooLarge;
    const raw = inflateZlib(alloc, idat.items, raw_len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.Corrupt,
    };
    defer alloc.free(raw);

    const filter_bpp: usize = @max(1, bits_per_pixel / 8);
    unfilterPng(raw, stride, height, filter_bpp) catch return Error.Corrupt;

    const pixels = try alloc.alloc(u8, pixel_len);
    errdefer alloc.free(pixels);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = pixels[y * width * 4 ..][0 .. width * 4];
        try expandPngRow(row, dst, width, bit_depth, color_type, palette_len, &palette, &trns, trns_gray, trns_rgb);
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn unfilterPng(raw: []u8, stride: usize, height: usize, bpp: usize) !void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = y * (stride + 1);
        const filter = raw[row_start];
        const row = raw[row_start + 1 ..][0..stride];
        const prior: ?[]u8 = if (y > 0) raw[row_start - stride ..][0..stride] else null;
        switch (filter) {
            0 => {},
            1 => {
                var x: usize = bpp;
                while (x < stride) : (x += 1) row[x] = row[x] +% row[x - bpp];
            },
            2 => {
                if (prior) |p| {
                    for (row, p) |*b, *a| b.* = b.* +% a.*;
                }
            },
            3 => {
                var x: usize = 0;
                while (x < stride) : (x += 1) {
                    const left: u16 = if (x >= bpp) row[x - bpp] else 0;
                    const up: u16 = if (prior) |p| p[x] else 0;
                    row[x] = row[x] +% @as(u8, @intCast((left + up) / 2));
                }
            },
            4 => {
                var x: usize = 0;
                while (x < stride) : (x += 1) {
                    const a: i32 = if (x >= bpp) row[x - bpp] else 0;
                    const b: i32 = if (prior) |p| p[x] else 0;
                    const c: i32 = if (x >= bpp and prior != null) prior.?[x - bpp] else 0;
                    const p = a + b - c;
                    const pa = @abs(p - a);
                    const pb = @abs(p - b);
                    const pc = @abs(p - c);
                    const pred: i32 = if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                    row[x] = row[x] +% @as(u8, @intCast(pred));
                }
            },
            else => return error.BadFilter,
        }
    }
}

fn expandPngRow(
    row: []const u8,
    dst: []u8,
    width: u32,
    bit_depth: u8,
    color_type: u8,
    palette_len: usize,
    palette: *const [256][3]u8,
    trns: *const [256]u8,
    trns_gray: ?u16,
    trns_rgb: ?[3]u16,
) Error!void {
    var x: usize = 0;
    switch (bit_depth) {
        16 => {
            while (x < width) : (x += 1) {
                const o = x * 4;
                switch (color_type) {
                    0 => {
                        const val16 = (@as(u16, row[x * 2]) << 8) | row[x * 2 + 1];
                        const g = row[x * 2];
                        dst[o] = g;
                        dst[o + 1] = g;
                        dst[o + 2] = g;
                        dst[o + 3] = if (trns_gray != null and trns_gray.? == val16) 0 else 255;
                    },
                    2 => {
                        dst[o] = row[x * 6];
                        dst[o + 1] = row[x * 6 + 2];
                        dst[o + 2] = row[x * 6 + 4];
                        dst[o + 3] = 255;
                    },
                    4 => {
                        const g = row[x * 4];
                        dst[o] = g;
                        dst[o + 1] = g;
                        dst[o + 2] = g;
                        dst[o + 3] = row[x * 4 + 2];
                    },
                    6 => {
                        dst[o] = row[x * 8];
                        dst[o + 1] = row[x * 8 + 2];
                        dst[o + 2] = row[x * 8 + 4];
                        dst[o + 3] = row[x * 8 + 6];
                    },
                    else => {},
                }
            }
        },
        8 => {
            while (x < width) : (x += 1) {
                const o = x * 4;
                switch (color_type) {
                    0 => {
                        const g = row[x];
                        dst[o] = g;
                        dst[o + 1] = g;
                        dst[o + 2] = g;
                        dst[o + 3] = if (trns_gray != null and trns_gray.? == g) 0 else 255;
                    },
                    2 => {
                        const r = row[x * 3];
                        const g = row[x * 3 + 1];
                        const b = row[x * 3 + 2];
                        dst[o] = r;
                        dst[o + 1] = g;
                        dst[o + 2] = b;
                        dst[o + 3] = if (trns_rgb) |t| (if (t[0] == r and t[1] == g and t[2] == b) @as(u8, 0) else 255) else 255;
                    },
                    3 => {
                        const idx = row[x];
                        if (idx >= palette_len) return Error.Corrupt;
                        const p = palette[idx];
                        dst[o] = p[0];
                        dst[o + 1] = p[1];
                        dst[o + 2] = p[2];
                        dst[o + 3] = trns[@min(idx, 255)];
                    },
                    4 => {
                        const g = row[x * 2];
                        dst[o] = g;
                        dst[o + 1] = g;
                        dst[o + 2] = g;
                        dst[o + 3] = row[x * 2 + 1];
                    },
                    6 => {
                        dst[o] = row[x * 4];
                        dst[o + 1] = row[x * 4 + 1];
                        dst[o + 2] = row[x * 4 + 2];
                        dst[o + 3] = row[x * 4 + 3];
                    },
                    else => {},
                }
            }
        },
        1, 2, 4 => {
            const depth: u8 = bit_depth;
            const per_byte: u8 = 8 / depth;
            const gray_scale: u16 = if (depth == 1) 255 else if (depth == 2) 85 else 17;
            while (x < width) : (x += 1) {
                const o = x * 4;
                const byte = row[x / per_byte];
                const shift: u3 = @intCast(8 - depth - (x % per_byte) * depth);
                const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
                const val: u8 = (byte >> shift) & mask;
                if (color_type == 3) {
                    if (val >= palette_len) return Error.Corrupt;
                    const idx = val;
                    const p = palette[idx];
                    dst[o] = p[0];
                    dst[o + 1] = p[1];
                    dst[o + 2] = p[2];
                    dst[o + 3] = trns[idx];
                } else {
                    const g: u8 = @intCast(@as(u16, val) * gray_scale);
                    dst[o] = g;
                    dst[o + 1] = g;
                    dst[o + 2] = g;
                    dst[o + 3] = if (trns_gray != null and trns_gray.? == val) 0 else 255;
                }
            }
        },
        else => {},
    }
}

fn skipGifSubBlocks(data: []const u8, pos: *usize) Error!void {
    while (true) {
        if (pos.* >= data.len) return Error.Corrupt;
        const size = data[pos.*];
        pos.* += 1;
        if (size == 0) return;
        if (@as(u64, pos.*) + size > data.len) return Error.Corrupt;
        pos.* += size;
    }
}

fn decodeGif(alloc: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)!Image {
    if (data.len < 13) return Error.Corrupt;
    const width = std.mem.readInt(u16, data[6..8], .little);
    const height = std.mem.readInt(u16, data[8..10], .little);
    try checkDims(width, height);
    const packed_flags = data[10];

    var pos: usize = 13;
    var gct: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    if (packed_flags & 0x80 != 0) {
        const gct_len: usize = @as(usize, 2) << @intCast(packed_flags & 0x07);
        if (pos + gct_len * 3 > data.len) return Error.Corrupt;
        for (0..gct_len) |i| {
            gct[i] = .{ data[pos + i * 3], data[pos + i * 3 + 1], data[pos + i * 3 + 2] };
        }
        pos += gct_len * 3;
        palette_len = gct_len;
    }

    var transparent_index: i16 = -1;
    while (pos < data.len) {
        const block = data[pos];
        pos += 1;
        switch (block) {
            0x21 => {
                if (pos >= data.len) return Error.Corrupt;
                const label = data[pos];
                pos += 1;
                if (label == 0xF9) {
                    if (pos >= data.len or data[pos] != 4 or pos + 6 > data.len) return Error.Corrupt;
                    if (data[pos + 1] & 0x01 != 0) transparent_index = @intCast(data[pos + 4]);
                }
                try skipGifSubBlocks(data, &pos);
            },
            0x2C => break,
            0x3B => return Error.Corrupt,
            else => return Error.Corrupt,
        }
    }
    if (pos + 9 > data.len) return Error.Corrupt;

    const frame_left = std.mem.readInt(u16, data[pos..][0..2], .little);
    const frame_top = std.mem.readInt(u16, data[pos + 2 ..][0..2], .little);
    const frame_w = std.mem.readInt(u16, data[pos + 4 ..][0..2], .little);
    const frame_h = std.mem.readInt(u16, data[pos + 6 ..][0..2], .little);
    if (frame_w == 0 or frame_h == 0) return Error.Corrupt;
    if (@as(u32, frame_left) + frame_w > width or @as(u32, frame_top) + frame_h > height) return Error.Corrupt;
    const frame_flags = data[pos + 8];
    const interlaced = frame_flags & 0x40 != 0;
    pos += 9;

    if (frame_flags & 0x80 != 0) {
        const lct_len: usize = @as(usize, 2) << @intCast(frame_flags & 0x07);
        if (pos + lct_len * 3 > data.len) return Error.Corrupt;
        for (0..lct_len) |i| {
            gct[i] = .{ data[pos + i * 3], data[pos + i * 3 + 1], data[pos + i * 3 + 2] };
        }
        pos += lct_len * 3;
        palette_len = lct_len;
    }

    if (palette_len == 0 or pos >= data.len) return Error.Corrupt;
    const min_code_size: u8 = data[pos];
    if (min_code_size < 2 or min_code_size > 8) return Error.Corrupt;
    pos += 1;

    var lzw_data: std.ArrayList(u8) = .empty;
    defer lzw_data.deinit(alloc);
    while (pos < data.len and data[pos] != 0) {
        const size: usize = data[pos];
        pos += 1;
        if (pos + size > data.len) return Error.Corrupt;
        if (@as(u64, lzw_data.items.len) + size > max_work_bytes / 2) return Error.TooLarge;
        try lzw_data.appendSlice(alloc, data[pos .. pos + size]);
        pos += size;
    }
    if (pos >= data.len) return Error.Corrupt;
    pos += 1;

    const frame_pixels = @as(u64, frame_w) * frame_h;
    const pixel_len = try pixelBytes(width, height);
    const row_map_bytes = @as(u64, frame_h) * @sizeOf(u32);
    if (@as(u64, lzw_data.items.len) + frame_pixels + pixel_len + row_map_bytes > max_work_bytes) return Error.TooLarge;
    const indices = try alloc.alloc(u8, try workBytes(frame_pixels));
    defer alloc.free(indices);
    @memset(indices, 0);
    try lzwDecode(lzw_data.items, min_code_size, indices);

    const pixels = try alloc.alloc(u8, pixel_len);
    errdefer alloc.free(pixels);
    @memset(pixels, 0);

    var row_map = try alloc.alloc(u32, frame_h);
    defer alloc.free(row_map);
    if (interlaced) {
        var out_row: usize = 0;
        const passes = [_]struct { start: usize, step: usize }{ .{ .start = 0, .step = 8 }, .{ .start = 4, .step = 8 }, .{ .start = 2, .step = 4 }, .{ .start = 1, .step = 2 } };
        for (passes) |pass| {
            var y = pass.start;
            while (y < frame_h) : (y += pass.step) {
                row_map[out_row] = @intCast(y);
                out_row += 1;
            }
        }
    } else {
        for (0..frame_h) |y| row_map[y] = @intCast(y);
    }

    var y: usize = 0;
    while (y < frame_h) : (y += 1) {
        const src_row = indices[y * frame_w ..][0..frame_w];
        const dst_y = row_map[y];
        if (dst_y >= height) continue;
        var x: usize = 0;
        while (x < frame_w and x < width) : (x += 1) {
            const idx = src_row[x];
            const dst = pixels[((@as(usize, frame_top) + dst_y) * width + @as(usize, frame_left) + x) * 4 ..][0..4];
            if (@as(i16, idx) == transparent_index) {
                dst[3] = 0;
            } else {
                if (idx >= palette_len) return Error.Corrupt;
                const c = gct[idx];
                dst[0] = c[0];
                dst[1] = c[1];
                dst[2] = c[2];
                dst[3] = 255;
            }
        }
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn lzwDecode(data: []const u8, min_code_size: u8, out: []u8) Error!void {
    const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
    const eoi_code: u16 = clear_code + 1;

    var prefixes: [4096]u16 = undefined;
    var suffixes: [4096]u8 = undefined;
    for (0..clear_code) |i| {
        prefixes[i] = 0xFFFF;
        suffixes[i] = @intCast(i);
    }
    var next_code: u16 = eoi_code + 1;
    var code_size: u4 = @intCast(min_code_size + 1);

    var bit_pos: usize = 0;
    var prev: u16 = clear_code;

    var out_pos: usize = 0;
    var stack: [4096]u8 = undefined;

    while (out_pos < out.len) {
        if ((bit_pos + code_size) > data.len * 8) break;
        var code: u16 = 0;
        var i: u4 = 0;
        while (i < code_size) : (i += 1) {
            const bit_idx = bit_pos + i;
            const byte = data[bit_idx / 8];
            const bit: u16 = (byte >> @intCast(bit_idx % 8)) & 1;
            code |= bit << i;
        }
        bit_pos += code_size;

        if (code == clear_code) {
            next_code = eoi_code + 1;
            code_size = @intCast(min_code_size + 1);
            prev = clear_code;
            continue;
        }
        if (code == eoi_code) break;
        if (code > next_code or code >= 4096) return Error.Corrupt;

        var emit_len: usize = 0;
        if (code == next_code) {
            if (prev == clear_code) return Error.Corrupt;
            var walk = prev;
            while (walk != 0xFFFF) {
                if (walk >= 4096 or emit_len >= stack.len) return Error.Corrupt;
                stack[emit_len] = suffixes[walk];
                emit_len += 1;
                walk = prefixes[walk];
            }
            if (emit_len == 0 or emit_len >= stack.len) return Error.Corrupt;
            std.mem.copyBackwards(u8, stack[1 .. emit_len + 1], stack[0..emit_len]);
            stack[0] = stack[emit_len];
            emit_len += 1;
        } else {
            var walk = code;
            while (walk != 0xFFFF) {
                if (walk >= 4096 or emit_len >= stack.len) return Error.Corrupt;
                stack[emit_len] = suffixes[walk];
                emit_len += 1;
                walk = prefixes[walk];
            }
        }

        if (out_pos + emit_len > out.len) return Error.Corrupt;
        var k: usize = 0;
        while (k < emit_len) : (k += 1) {
            out[out_pos + k] = stack[emit_len - 1 - k];
        }
        out_pos += emit_len;

        if (prev != clear_code and next_code < 4096) {
            prefixes[next_code] = prev;
            suffixes[next_code] = stack[emit_len - 1];
            next_code += 1;
            if (next_code == (@as(u16, 1) << code_size) and code_size < 12) {
                code_size += 1;
            }
        }
        prev = code;
    }
    if (out_pos < out.len) return Error.Corrupt;
}

const jpeg_zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const JpegHuff = struct {
    mincode: [17]i32 = @splat(-1),
    maxcode: [17]i32 = @splat(-1),
    valptr: [17]usize = @splat(0),
    symbols: [256]u8 = @splat(0),
    nsymbols: usize = 0,
};

const JpegComp = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    tq: u8 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    dc_pred: i32 = 0,
    bw: usize = 0,
    bh: usize = 0,
    plane: []u8 = &.{},
};

const JpegState = struct {
    data: []const u8,
    pos: usize = 0,
    quant: [4][64]u16 = @splat(@splat(0)),
    quant_defined: [4]bool = @splat(false),
    huff_dc: [4]JpegHuff = @splat(.{}),
    huff_ac: [4]JpegHuff = @splat(.{}),
    huff_dc_defined: [4]bool = @splat(false),
    huff_ac_defined: [4]bool = @splat(false),
    comps: [4]JpegComp = @splat(.{}),
    ncomp: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    restart_interval: u32 = 0,
    progressive: bool = false,
    rgb: bool = false,
    bit_acc: u32 = 0,
    bit_cnt: u5 = 0,
    marker_hit: bool = false,
    alloc: std.mem.Allocator,

    fn readU16(self: *JpegState) Error!u16 {
        if (self.pos + 2 > self.data.len) return Error.Corrupt;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn nextMarker(self: *JpegState) Error!u8 {
        while (self.pos < self.data.len) {
            if (self.data[self.pos] != 0xFF) {
                self.pos += 1;
                continue;
            }
            var m = self.pos + 1;
            while (m < self.data.len and self.data[m] == 0xFF) m += 1;
            if (m >= self.data.len) return Error.Corrupt;
            const marker = self.data[m];
            self.pos = m + 1;
            if (marker == 0x00) continue;
            return marker;
        }
        return Error.Corrupt;
    }

    fn ensure(self: *JpegState, n: usize) Error!void {
        if (@as(u64, self.pos) + n > self.data.len) return Error.Corrupt;
    }

    fn skipSegment(self: *JpegState) Error!void {
        const len = try self.readU16();
        if (len < 2) return Error.Corrupt;
        try self.ensure(len - 2);
        self.pos += len - 2;
    }

    fn readBit(self: *JpegState) Error!u1 {
        if (self.bit_cnt == 0) {
            if (self.pos >= self.data.len or self.marker_hit) return Error.Corrupt;
            const b = self.data[self.pos];
            if (b == 0xFF) {
                const n: u8 = if (self.pos + 1 < self.data.len) self.data[self.pos + 1] else 0xD9;
                if (n == 0x00) {
                    self.pos += 2;
                } else {
                    self.marker_hit = true;
                    return Error.Corrupt;
                }
            } else {
                self.pos += 1;
            }
            self.bit_acc = b;
            self.bit_cnt = 8;
        }
        self.bit_cnt -= 1;
        return @intCast((self.bit_acc >> self.bit_cnt) & 1);
    }

    fn readBits(self: *JpegState, n: u5) Error!u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | try self.readBit();
        }
        return v;
    }

    fn huffDecode(self: *JpegState, table: *const JpegHuff) Error!u8 {
        var code: i32 = 0;
        var l: usize = 1;
        while (l <= 16) : (l += 1) {
            code = (code << 1) | try self.readBit();
            if (table.maxcode[l] >= 0 and code <= table.maxcode[l]) {
                const index = table.valptr[l] + @as(usize, @intCast(code - table.mincode[l]));
                if (index >= table.nsymbols) return Error.Corrupt;
                return table.symbols[index];
            }
        }
        return Error.Corrupt;
    }

    fn restartSync(self: *JpegState) void {
        self.bit_acc = 0;
        self.bit_cnt = 0;
        self.marker_hit = false;
        if (self.pos + 1 < self.data.len and self.data[self.pos] == 0xFF) {
            const n = self.data[self.pos + 1];
            if (n >= 0xD0 and n <= 0xD7) self.pos += 2;
        }
        for (self.comps[0..self.ncomp]) |*c| c.dc_pred = 0;
    }
};

fn parseHuffTable(state: *JpegState, len_in: usize) Error!void {
    const end = state.pos +| len_in;
    if (end < state.pos or end > state.data.len) return Error.Corrupt;
    var remaining = len_in;
    while (remaining > 0) {
        if (remaining < 17) return Error.Corrupt;
        if (state.pos + 17 > end) return Error.Corrupt;
        const tcth = state.data[state.pos];
        const tc = tcth >> 4;
        const th = tcth & 0x0F;
        if (tc > 1 or th > 3) return Error.Corrupt;
        var counts: [16]u8 = undefined;
        @memcpy(&counts, state.data[state.pos + 1 ..][0..16]);
        state.pos += 17;
        remaining -= 17;

        var total: usize = 0;
        for (counts) |c| total += c;
        if (total > 256 or total > remaining) return Error.Corrupt;
        if (state.pos + total > end) return Error.Corrupt;

        var table: JpegHuff = .{};
        table.nsymbols = total;
        @memcpy(table.symbols[0..total], state.data[state.pos..][0..total]);
        state.pos += total;
        remaining -= total;

        var code: i32 = 0;
        var k: usize = 0;
        for (0..16) |idx| {
            const l = idx + 1;
            table.valptr[l] = k;
            table.mincode[l] = code;
            k += counts[idx];
            if (counts[idx] > 0) {
                table.maxcode[l] = code + @as(i32, counts[idx]) - 1;
            } else {
                table.maxcode[l] = -1;
            }
            code = (code + @as(i32, counts[idx])) << 1;
        }

        if (tc == 0) {
            state.huff_dc[th] = table;
            state.huff_dc_defined[th] = true;
        } else {
            state.huff_ac[th] = table;
            state.huff_ac_defined[th] = true;
        }
    }
    if (state.pos != end) return Error.Corrupt;
}

const idct_cos_table = blk: {
    @setEvalBranchQuota(100000);
    var t: [64]f32 = undefined;
    for (0..8) |u| {
        for (0..8) |x| {
            t[u * 8 + x] = @cos((2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) * std.math.pi / 16.0);
        }
    }
    break :blk t;
};

fn idctBlock(src: *const [64]i32, dst: []u8, dst_stride: usize) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |v| {
        for (0..8) |x| {
            var acc: f32 = 0;
            for (0..8) |u| {
                acc += norm(u) * @as(f32, @floatFromInt(src[v * 8 + u])) * idct_cos_table[u * 8 + x];
            }
            tmp[v * 8 + x] = acc * 0.5;
        }
    }
    for (0..8) |y| {
        for (0..8) |x| {
            var acc: f32 = 0;
            for (0..8) |v| {
                acc += norm(v) * tmp[v * 8 + x] * idct_cos_table[v * 8 + y];
            }
            const val = acc * 0.5 + 128.0;
            dst[y * dst_stride + x] = @intFromFloat(std.math.clamp(val, 0, 255));
        }
    }
}

fn norm(u: usize) f32 {
    return if (u == 0) 0.70710678118 else 1.0;
}

fn extend(v: u32, n: u5) i32 {
    if (n == 0) return 0;
    const vt = @as(i32, @intCast(v));
    if (v < (@as(u32, 1) << (n - 1))) {
        return vt - (@as(i32, 1) << n) + 1;
    }
    return vt;
}

fn upsamplePlane(alloc: std.mem.Allocator, src: []const u8, src_w: usize, src_h: usize, ch: usize, cv: usize, hmax: usize, vmax: usize, out_w: usize, out_h: usize) ![]u8 {
    const out = try alloc.alloc(u8, try workBytes(@as(u64, out_w) * out_h));
    errdefer alloc.free(out);

    if (ch * 2 == hmax and cv == vmax) {
        var y: usize = 0;
        while (y < out_h) : (y += 1) {
            const row = src[y * src_w ..][0..src_w];
            var x: usize = 0;
            while (x < out_w) : (x += 1) {
                const i = x / 2;
                const left = if (i > 0) row[i - 1] else row[i];
                const right = if (i + 1 < src_w) row[i + 1] else row[i];
                out[y * out_w + x] = if (x % 2 == 0)
                    @as(u8, @intCast((3 * @as(u32, row[i]) + left + 2) >> 2))
                else
                    @as(u8, @intCast((3 * @as(u32, row[i]) + right + 2) >> 2));
            }
        }
        return out;
    }

    if (ch == hmax and cv * 2 == vmax) {
        var y: usize = 0;
        while (y < out_h) : (y += 1) {
            const i = y / 2;
            const up = if (i > 0) src[(i - 1) * src_w ..][0..src_w] else src[i * src_w ..][0..src_w];
            const down = if (i + 1 < src_h) src[(i + 1) * src_w ..][0..src_w] else src[i * src_w ..][0..src_w];
            const row = src[i * src_w ..][0..src_w];
            var x: usize = 0;
            while (x < out_w) : (x += 1) {
                out[y * out_w + x] = if (y % 2 == 0)
                    @as(u8, @intCast((3 * @as(u32, row[x]) + @as(u32, up[x]) + 2) >> 2))
                else
                    @as(u8, @intCast((3 * @as(u32, row[x]) + @as(u32, down[x]) + 2) >> 2));
            }
        }
        return out;
    }

    if (ch * 2 == hmax and cv * 2 == vmax) {
        const tmp = try alloc.alloc(u32, src_w);
        defer alloc.free(tmp);
        var y: usize = 0;
        while (y < out_h) : (y += 1) {
            const i = y / 2;
            const cur = src[i * src_w ..][0..src_w];
            const adj = if (y % 2 == 0)
                (if (i > 0) src[(i - 1) * src_w ..][0..src_w] else cur)
            else
                (if (i + 1 < src_h) src[(i + 1) * src_w ..][0..src_w] else cur);
            for (0..src_w) |x| tmp[x] = 3 * @as(u32, cur[x]) + @as(u32, adj[x]);
            var x: usize = 0;
            while (x < out_w) : (x += 1) {
                const j = x / 2;
                const left = if (j > 0) tmp[j - 1] else tmp[j];
                const right = if (j + 1 < src_w) tmp[j + 1] else tmp[j];
                out[y * out_w + x] = if (x % 2 == 0)
                    @as(u8, @intCast((3 * tmp[j] + left + 8) >> 4))
                else
                    @as(u8, @intCast((3 * tmp[j] + right + 8) >> 4));
            }
        }
        return out;
    }

    var y: usize = 0;
    while (y < out_h) : (y += 1) {
        const sy = @min(y * cv / vmax, src_h - 1);
        const row = src[sy * src_w ..][0..src_w];
        var x: usize = 0;
        while (x < out_w) : (x += 1) {
            out[y * out_w + x] = row[@min(x * ch / hmax, src_w - 1)];
        }
    }
    return out;
}

fn freeJpegPlanes(state: *JpegState) void {
    for (state.comps[0..state.ncomp]) |*comp| {
        if (comp.plane.len > 0) {
            state.alloc.free(comp.plane);
            comp.plane = &.{};
        }
    }
}

fn decodeJpeg(alloc: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)!Image {
    var state = JpegState{ .data = data, .alloc = alloc };
    errdefer freeJpegPlanes(&state);
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return Error.Corrupt;
    state.pos = 2;

    var scan_seen = false;
    while (true) {
        const marker = try state.nextMarker();
        switch (marker) {
            0xC0, 0xC1, 0xC2 => {
                if (marker == 0xC2) return Error.Unsupported;
                const len = try state.readU16();
                if (len < 8) return Error.Corrupt;
                try state.ensure(len - 2);
                const precision = data[state.pos];
                if (precision != 8) return Error.Unsupported;
                state.height = std.mem.readInt(u16, data[state.pos + 1 ..][0..2], .big);
                state.width = std.mem.readInt(u16, data[state.pos + 3 ..][0..2], .big);
                state.ncomp = data[state.pos + 5];
                if (state.ncomp != 1 and state.ncomp != 3) return Error.Unsupported;
                if (len - 2 != 6 + 3 * state.ncomp) return Error.Corrupt;
                state.pos += 6;
                var hmax: u8 = 1;
                var vmax: u8 = 1;
                try state.ensure(3 * state.ncomp);
                for (0..state.ncomp) |i| {
                    const cid = data[state.pos];
                    const hv = data[state.pos + 1];
                    const h = hv >> 4;
                    const v = hv & 0x0F;
                    if (h == 0 or h > 4 or v == 0 or v > 4 or data[state.pos + 2] > 3) return Error.Corrupt;
                    state.comps[i] = .{ .id = cid, .h = h, .v = v, .tq = data[state.pos + 2] };
                    hmax = @max(hmax, h);
                    vmax = @max(vmax, v);
                    state.pos += 3;
                }
                state.hmax = hmax;
                state.vmax = vmax;
                if (state.ncomp == 3) {
                    if (state.comps[0].id == 'R' and state.comps[1].id == 'G' and state.comps[2].id == 'B') {
                        state.rgb = true;
                    }
                }
            },
            0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return Error.Unsupported,
            0xC4 => {
                const len = try state.readU16();
                if (len < 2) return Error.Corrupt;
                try parseHuffTable(&state, len - 2);
            },
            0xDB => {
                const len = try state.readU16();
                if (len < 2) return Error.Corrupt;
                try state.ensure(len - 2);
                var remaining = len - 2;
                while (remaining > 0) {
                    if (remaining < 65) return Error.Corrupt;
                    try state.ensure(65);
                    const pq_tq = data[state.pos];
                    const pq = pq_tq >> 4;
                    const tq = pq_tq & 0x0F;
                    if (pq != 0 or tq > 3) return Error.Unsupported;
                    for (0..64) |i| {
                        state.quant[tq][i] = data[state.pos + 1 + i];
                    }
                    state.pos += 65;
                    remaining -= 65;
                    state.quant_defined[tq] = true;
                }
            },
            0xDD => {
                const len = try state.readU16();
                if (len != 4) return Error.Corrupt;
                state.restart_interval = try state.readU16();
            },
            0xDA => {
                const len = try state.readU16();
                if (len < 6) return Error.Corrupt;
                try state.ensure(len - 2);
                const ns = data[state.pos];
                if (ns != state.ncomp) return Error.Unsupported;
                if (len - 2 != 1 + 2 * @as(usize, ns) + 3) return Error.Corrupt;
                state.pos += 1;
                for (0..ns) |_| {
                    const cs = data[state.pos];
                    const td_ta = data[state.pos + 1];
                    if (td_ta >> 4 > 3 or (td_ta & 0x0F) > 3) return Error.Corrupt;
                    var found = false;
                    for (0..state.ncomp) |j| {
                        if (state.comps[j].id == cs) {
                            state.comps[j].td = td_ta >> 4;
                            state.comps[j].ta = td_ta & 0x0F;
                            found = true;
                        }
                    }
                    if (!found) return Error.Corrupt;
                    state.pos += 2;
                }
                state.pos += 3;
                scan_seen = true;
                break;
            },
            0xD9 => break,
            0x01, 0xD0...0xD7 => {},
            else => try state.skipSegment(),
        }
    }

    if (!scan_seen) return Error.Corrupt;
    try checkDims(state.width, state.height);

    for (state.comps[0..state.ncomp]) |comp| {
        if (comp.tq >= 4 or !state.quant_defined[comp.tq] or
            comp.td >= 4 or comp.ta >= 4 or
            !state.huff_dc_defined[comp.td] or !state.huff_ac_defined[comp.ta]) return Error.Corrupt;
    }

    const width = state.width;
    const height = state.height;
    const pixel_len = try pixelBytes(width, height);
    const mcus_x = (@as(usize, width) + 8 * @as(usize, state.hmax) - 1) / (8 * @as(usize, state.hmax));
    const mcus_y = (@as(usize, height) + 8 * @as(usize, state.vmax) - 1) / (8 * @as(usize, state.vmax));

    var plane_bytes: u64 = 0;
    for (0..state.ncomp) |i| {
        const c = &state.comps[i];
        const cw = (@as(usize, width) * c.h + state.hmax - 1) / state.hmax;
        const ch = (@as(usize, height) * c.v + state.vmax - 1) / state.vmax;
        c.bw = (cw + 7) / 8;
        c.bh = (ch + 7) / 8;
        plane_bytes += @as(u64, c.bw) * 8 * c.bh * 8;
    }
    const upsample_count: u64 = if (state.ncomp == 3) 3 else 0;
    const upsample_bytes = @as(u64, width) * height * upsample_count;
    if (plane_bytes + pixel_len + upsample_bytes > max_work_bytes) return Error.TooLarge;

    for (0..state.ncomp) |i| {
        const c = &state.comps[i];
        const plane_len = try workBytes(@as(u64, c.bw) * 8 * c.bh * 8);
        c.plane = try alloc.alloc(u8, plane_len);
        @memset(c.plane, 0);
        c.dc_pred = 0;
    }

    var zz: [64]i32 = undefined;
    var mcu_idx: usize = 0;
    const total_mcus = if (state.ncomp == 1)
        state.comps[0].bw * state.comps[0].bh
    else
        mcus_x * mcus_y;

    while (mcu_idx < total_mcus) : (mcu_idx += 1) {
        if (state.restart_interval > 0 and mcu_idx > 0 and mcu_idx % state.restart_interval == 0) {
            state.restartSync();
        }
        if (state.ncomp == 1) {
            const c = &state.comps[0];
            const bx = mcu_idx % c.bw;
            const by = mcu_idx / c.bw;
            try decodeJpegBlock(&state, c, &zz, bx, by);
        } else {
            const mcu_x = mcu_idx % mcus_x;
            const mcu_y = mcu_idx / mcus_x;
            for (0..state.ncomp) |ci| {
                const c = &state.comps[ci];
                const x0 = mcu_x * c.h;
                const y0 = mcu_y * c.v;
                var by: usize = 0;
                while (by < c.v) : (by += 1) {
                    var bx: usize = 0;
                    while (bx < c.h) : (bx += 1) {
                        try decodeJpegBlock(&state, c, &zz, x0 + bx, y0 + by);
                    }
                }
            }
        }
    }

    const pixels = try alloc.alloc(u8, pixel_len);
    errdefer alloc.free(pixels);

    if (state.ncomp == 1) {
        const c = &state.comps[0];
        const stride = c.bw * 8;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const v = c.plane[y * stride + x];
                const o = (y * width + x) * 4;
                pixels[o] = v;
                pixels[o + 1] = v;
                pixels[o + 2] = v;
                pixels[o + 3] = 255;
            }
        }
    } else if (state.rgb) {
        var ups: [3][]u8 = .{ &.{}, &.{}, &.{} };
        defer for (ups) |plane| if (plane.len > 0) alloc.free(plane);
        for (0..3) |ci| {
            const c = &state.comps[ci];
            ups[ci] = try upsamplePlane(alloc, c.plane, c.bw * 8, c.bh * 8, c.h, c.v, state.hmax, state.vmax, width, height);
        }
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const o = (y * width + x) * 4;
                for (0..3) |ci| pixels[o + ci] = ups[ci][y * width + x];
                pixels[o + 3] = 255;
            }
        }
    } else {
        const yc = &state.comps[0];
        const cb = &state.comps[1];
        const cr = &state.comps[2];
        const ystride = yc.bw * 8;
        const cb_up = try upsamplePlane(alloc, cb.plane, cb.bw * 8, cb.bh * 8, cb.h, cb.v, state.hmax, state.vmax, width, height);
        defer alloc.free(cb_up);
        const cr_up = try upsamplePlane(alloc, cr.plane, cr.bw * 8, cr.bh * 8, cr.h, cr.v, state.hmax, state.vmax, width, height);
        defer alloc.free(cr_up);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const luma: f32 = @floatFromInt(yc.plane[y * ystride + x]);
                const cbv: f32 = @as(f32, @floatFromInt(cb_up[y * width + x])) - 128.0;
                const crv: f32 = @as(f32, @floatFromInt(cr_up[y * width + x])) - 128.0;
                const o = (y * width + x) * 4;
                pixels[o] = @intFromFloat(std.math.clamp(luma + 1.402 * crv, 0, 255));
                pixels[o + 1] = @intFromFloat(std.math.clamp(luma - 0.344136 * cbv - 0.714136 * crv, 0, 255));
                pixels[o + 2] = @intFromFloat(std.math.clamp(luma + 1.772 * cbv, 0, 255));
                pixels[o + 3] = 255;
            }
        }
    }

    freeJpegPlanes(&state);

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn decodeJpegBlock(state: *JpegState, c: *JpegComp, zz: *[64]i32, bx: usize, by: usize) Error!void {
    @memset(zz, 0);

    const dc_table = &state.huff_dc[c.td];
    const ac_table = &state.huff_ac[c.ta];
    const q = &state.quant[c.tq];

    const s = try state.huffDecode(dc_table);
    if (s > 15) return Error.Corrupt;
    const diff = extend(try state.readBits(@intCast(s)), @intCast(s));
    c.dc_pred += diff;
    zz[0] = c.dc_pred * @as(i32, q[0]);

    var k: usize = 1;
    while (k < 64) {
        const rs = try state.huffDecode(ac_table);
        const r = rs >> 4;
        const ss = rs & 0x0F;
        if (ss == 0) {
            if (r == 15) {
                if (k + 16 > 64) return Error.Corrupt;
                k += 16;
                continue;
            }
            break;
        }
        k += r;
        if (k > 63) return Error.Corrupt;
        if (ss > 15) return Error.Corrupt;
        const val = extend(try state.readBits(@intCast(ss)), @intCast(ss));
        zz[jpeg_zigzag[k]] = val * @as(i32, q[k]);
        k += 1;
    }

    if (bx >= c.bw or by >= c.bh) return;
    const stride = c.bw * 8;
    const off = by * 8 * stride + bx * 8;
    idctBlock(zz, c.plane[off..], stride);
}

test "malformed gif descriptor is rejected" {
    const data = [_]u8{
        'G', 'I',  'F', '8', '9',  'a',
        1,   0,    1,   0,   0x80, 0,
        0,   0,    0,   0,   255,  255,
        255, 0x2C,
    };
    try std.testing.expectError(Error.Corrupt, decode(std.testing.allocator, &data));
}

test "short jpeg sof is rejected" {
    const data = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0, 7 };
    try std.testing.expectError(Error.Corrupt, decode(std.testing.allocator, &data));
}

test "jpeg table selectors are bounds checked" {
    const data = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xC0,
        0,    11,
        8,    0,
        1,    0,
        1,    1,
        1,    0x11,
        0,    0xFF,
        0xDA, 0,
        8,    1,
        1,    0x40,
        0,    0x3F,
        0,
    };
    try std.testing.expectError(Error.Corrupt, decode(std.testing.allocator, &data));
}

test "png dimensions are checked before allocation" {
    var data: [45]u8 = undefined;
    @memcpy(data[0..8], &png_sig);
    std.mem.writeInt(u32, data[8..12], 13, .big);
    @memcpy(data[12..16], "IHDR");
    std.mem.writeInt(u32, data[16..20], 32769, .big);
    std.mem.writeInt(u32, data[20..24], 1, .big);
    data[24] = 8;
    data[25] = 6;
    data[26] = 0;
    data[27] = 0;
    data[28] = 0;
    @memset(data[29..33], 0);
    std.mem.writeInt(u32, data[33..37], 0, .big);
    @memcpy(data[37..41], "IDAT");
    @memset(data[41..45], 0);
    try std.testing.expectError(Error.TooLarge, decode(std.testing.allocator, &data));
}

test "scale to fit uses one bounded output" {
    const pixels = try std.testing.allocator.alloc(u8, 400 * 200 * 4);
    var image = Image{ .width = 400, .height = 200, .pixels = pixels };
    image = scaleToFit(std.testing.allocator, image, 100, 100) catch |err| {
        std.testing.allocator.free(pixels);
        return err;
    };
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), image.width);
    try std.testing.expectEqual(@as(u32, 50), image.height);
}
