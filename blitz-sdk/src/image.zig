const std = @import("std");
const model = @import("model.zig");
const options = @import("options.zig");
const types = @import("types.zig");

pub fn generateImage(
    alloc: std.mem.Allocator,
    io: std.Io,
    m: model.ImageModel,
    opts: options.ImageOptions,
) !types.ImageResult {
    const params = model.ImageParams{
        .prompt = opts.prompt,
        .n = opts.n,
        .size = opts.size,
        .aspect_ratio = opts.aspect_ratio,
        .provider_options = opts.provider_options,
        .headers = opts.headers,
        .timeout_ms = opts.timeout_ms,
        .cancellation = opts.cancellation,
    };

    const result = try m.image(alloc, io, params, opts.client, opts.max_retries);
    errdefer {
        result.deinit(alloc);
        alloc.destroy(result);
    }
    const images = try alloc.alloc(types.ImageData, result.images.len);
    errdefer alloc.free(images);
    var done: usize = 0;
    errdefer for (images[0..done]) |img| {
        alloc.free(img.data);
        alloc.free(img.media_type);
    };
    for (result.images, 0..) |img, i| {
        images[i] = .{
            .data = try alloc.dupe(u8, img.data),
            .media_type = try alloc.dupe(u8, img.media_type),
        };
        done = i + 1;
    }
    const usage = result.usage;
    result.deinit(alloc);
    alloc.destroy(result);
    return .{ .images = images, .usage = usage };
}
