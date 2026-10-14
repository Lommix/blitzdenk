const std = @import("std");
const r = @import("root.zig");
const kitty = @import("tui/kitty.zig");

pub const max_decode_bytes = 64 * 1024 * 1024;
pub const max_side = 2048;

const zoom_factors = [_]f32{ 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0 };

const image_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif",
};

pub fn hasImageExtension(path: []const u8) bool {
    for (image_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub const Drag = struct {
    mouse_x: u16,
    mouse_y: u16,
    pan_x: u32,
    pan_y: u32,
};

pub const Viewer = struct {
    path: []const u8 = "",
    err_msg: ?[]const u8 = null,
    img: ?r.image.Image = null,
    id: u32,
    zoom_step: u8 = 0,
    pan_x: u32 = 0,
    pan_y: u32 = 0,
    image_rect: r.tui.Rect = .{},
    box_rect: r.tui.Rect = .{},
    cell_px: kitty.CellPixels = .{},
    drag: ?Drag = null,
    transmitted: bool = false,

    pub fn factor(self: *const Viewer) f32 {
        return zoom_factors[@min(self.zoom_step, zoom_factors.len - 1)];
    }

    pub fn dims(self: *const Viewer) struct { w: u32, h: u32 } {
        if (self.img) |img| return .{ .w = img.width, .h = img.height };
        return .{ .w = 0, .h = 0 };
    }

    pub fn close(self: *Viewer, alloc: std.mem.Allocator) void {
        if (self.path.len > 0) alloc.free(@constCast(self.path));
        if (self.err_msg) |m| alloc.free(@constCast(m));
        if (self.img) |img| img.deinit(alloc);
        self.path = "";
        self.err_msg = null;
        self.img = null;
    }
};

pub fn open(alloc: std.mem.Allocator, id: u32, io: std.Io, cwd: []const u8, token: []const u8) Viewer {
    const path = resolvePath(alloc, cwd, token) catch {
        return failOpen(alloc, token, "out of memory");
    };
    defer alloc.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_decode_bytes)) catch |err| {
        return failOpen(alloc, path, switch (err) {
            error.FileNotFound => "file not found",
            error.IsDir => "not a file",
            error.AccessDenied => "no permission",
            error.StreamTooLong => "image too large",
            else => "unreadable file",
        });
    };
    defer alloc.free(data);
    const decoded = r.image.decode(alloc, data) catch |err| {
        return failOpen(alloc, path, switch (err) {
            error.Unsupported => "unsupported image format",
            error.TooLarge => "image too large",
            else => "corrupt image",
        });
    };
    const owned_path: []const u8 = alloc.dupe(u8, path) catch {
        decoded.deinit(alloc);
        return failOpen(alloc, path, "out of memory");
    };
    return .{
        .path = owned_path,
        .img = decoded,
        .id = id,
    };
}

fn failOpen(alloc: std.mem.Allocator, path: []const u8, msg: []const u8) Viewer {
    const owned_path: []const u8 = alloc.dupe(u8, path) catch "";
    const owned_msg: ?[]const u8 = alloc.dupe(u8, msg) catch null;
    return .{ .path = owned_path, .err_msg = owned_msg, .id = 0 };
}

fn resolvePath(alloc: std.mem.Allocator, cwd: []const u8, token: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var path = token;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len > 0 and path[0] == '~') {
        const home_val = std.c.getenv("HOME") orelse return error.NoHome;
        const expanded = try std.fmt.bufPrint(&buf, "{s}{s}", .{ std.mem.span(home_val), path[1..] });
        return alloc.dupe(u8, expanded);
    }
    if (path.len > 0 and path[0] == '/') return alloc.dupe(u8, path);
    const joined = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, path });
    return alloc.dupe(u8, joined);
}

pub fn zoomIn(viewer: *Viewer) void {
    if (viewer.img == null) return;
    if (viewer.zoom_step < zoom_factors.len - 1) {
        viewer.zoom_step += 1;
        keepCenter(viewer);
    }
}

pub fn zoomOut(viewer: *Viewer) void {
    if (viewer.img == null) return;
    if (viewer.zoom_step > 0) {
        viewer.zoom_step -= 1;
        keepCenter(viewer);
    }
}

pub fn reset(viewer: *Viewer) void {
    viewer.zoom_step = 0;
    viewer.pan_x = 0;
    viewer.pan_y = 0;
}

fn keepCenter(viewer: *Viewer) void {
    if (viewer.img == null) return;
    const d = viewer.dims();
    const old_w: u32 = @intFromFloat(@as(f32, @floatFromInt(d.w)) / prevFactor(viewer));
    const old_h: u32 = @intFromFloat(@as(f32, @floatFromInt(d.h)) / prevFactor(viewer));
    const cx = @min(viewer.pan_x + old_w / 2, d.w);
    const cy = @min(viewer.pan_y + old_h / 2, d.h);
    const cw = cropW(viewer);
    const ch = cropH(viewer);
    const half_w = @min(cw / 2, cx);
    const half_h = @min(ch / 2, cy);
    viewer.pan_x = cx -| half_w;
    viewer.pan_y = cy -| half_h;
}

fn prevFactor(viewer: *Viewer) f32 {
    const idx = if (viewer.zoom_step > 0) viewer.zoom_step - 1 else 0;
    return zoom_factors[@min(idx, zoom_factors.len - 1)];
}

fn cropW(viewer: *const Viewer) u32 {
    const d = viewer.dims();
    const w: u32 = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(d.w)) / viewer.factor()));
    return @min(w, d.w);
}

fn cropH(viewer: *const Viewer) u32 {
    const d = viewer.dims();
    const h: u32 = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(d.h)) / viewer.factor()));
    return @min(h, d.h);
}

pub fn pan(viewer: *Viewer, dx: i32, dy: i32) void {
    if (viewer.img == null) return;
    const d = viewer.dims();
    const cw = cropW(viewer);
    const ch = cropH(viewer);
    const max_x = d.w -| cw;
    const max_y = d.h -| ch;
    viewer.pan_x = clampPan(viewer.pan_x, dx, max_x);
    viewer.pan_y = clampPan(viewer.pan_y, dy, max_y);
}

fn clampPan(cur: u32, delta: i32, max: u32) u32 {
    const next: i64 = @as(i64, cur) + delta;
    if (next < 0) return 0;
    if (next > max) return max;
    return @intCast(next);
}

pub fn computePlacement(viewer: *const Viewer, cell_px: kitty.CellPixels) kitty.Placement {
    const rect = viewer.image_rect;
    const d = viewer.dims();
    var crop_w = cropW(viewer);
    var crop_h = cropH(viewer);

    const box_px_w: f32 = @floatFromInt(@as(u32, rect.width) * cell_px.w);
    const box_px_h: f32 = @floatFromInt(@as(u32, rect.height) * cell_px.h);
    if (box_px_w <= 0 or box_px_h <= 0) return .{ .col = rect.x, .row = rect.y, .cols = 1, .rows = 1, .src = .{} };

    const box_aspect = box_px_w / box_px_h;
    const crop_aspect = @as(f32, @floatFromInt(crop_w)) / @as(f32, @floatFromInt(crop_h));
    if (crop_aspect > box_aspect) {
        crop_h = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(crop_w)) / box_aspect));
    } else {
        crop_w = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(crop_h)) * box_aspect));
    }
    crop_w = @min(crop_w, d.w);
    crop_h = @min(crop_h, d.h);

    const scale = @min(box_px_w / @as(f32, @floatFromInt(crop_w)), box_px_h / @as(f32, @floatFromInt(crop_h)));
    var cols: u16 = @intFromFloat(@ceil(@as(f32, @floatFromInt(crop_w)) * scale / @as(f32, @floatFromInt(cell_px.w))));
    var rows: u16 = @intFromFloat(@ceil(@as(f32, @floatFromInt(crop_h)) * scale / @as(f32, @floatFromInt(cell_px.h))));
    cols = @max(1, @min(cols, rect.width));
    rows = @max(1, @min(rows, rect.height));

    return .{
        .col = rect.x + (rect.width - cols) / 2,
        .row = rect.y + (rect.height - rows) / 2,
        .cols = cols,
        .rows = rows,
        .src = .{
            .x = @min(viewer.pan_x, d.w -| crop_w),
            .y = @min(viewer.pan_y, d.h -| crop_h),
            .w = crop_w,
            .h = crop_h,
        },
    };
}

pub const KeyResult = enum { close, consumed };

pub fn handleKey(viewer: *Viewer, key: r.tui.Key) KeyResult {
    if (key.code == .esc or key.code == .enter) return .close;
    if (key.code == .char) {
        const text = key.textSlice();
        if (text.len == 1) {
            switch (text[0]) {
                'q', 'w', ' ' => return .close,
                '+', '=' => zoomIn(viewer),
                '-', '_' => zoomOut(viewer),
                'r' => reset(viewer),
                'h' => pan(viewer, -@as(i32, @intCast(@max(1, cropW(viewer) / 8))), 0),
                'l' => pan(viewer, @as(i32, @intCast(@max(1, cropW(viewer) / 8))), 0),
                'k' => pan(viewer, 0, -@as(i32, @intCast(@max(1, cropH(viewer) / 8)))),
                'j' => pan(viewer, 0, @as(i32, @intCast(@max(1, cropH(viewer) / 8)))),
                else => {},
            }
        }
        return .consumed;
    }
    const step_x: i32 = @intCast(@max(1, cropW(viewer) / 4));
    const step_y: i32 = @intCast(@max(1, cropH(viewer) / 4));
    switch (key.code) {
        .arrow_left => pan(viewer, -step_x, 0),
        .arrow_right => pan(viewer, step_x, 0),
        .arrow_up => pan(viewer, 0, -step_y),
        .arrow_down => pan(viewer, 0, step_y),
        .page_up => zoomIn(viewer),
        .page_down => zoomOut(viewer),
        else => {},
    }
    return .consumed;
}

pub const MouseResult = enum { pass, consumed, close };

pub fn handleMouse(viewer: *Viewer, m: r.tui.Terminal.Mouse) MouseResult {
    switch (m.button) {
        .wheel_up => {
            zoomIn(viewer);
            return .consumed;
        },
        .wheel_down => {
            zoomOut(viewer);
            return .consumed;
        },
        .left => {
            const inside_box = m.x >= viewer.box_rect.x and m.x < viewer.box_rect.x +| viewer.box_rect.width and
                m.y >= viewer.box_rect.y and m.y < viewer.box_rect.y +| viewer.box_rect.height;
            switch (m.action) {
                .press => {
                    if (!inside_box) return .close;
                    viewer.drag = .{
                        .mouse_x = m.x,
                        .mouse_y = m.y,
                        .pan_x = viewer.pan_x,
                        .pan_y = viewer.pan_y,
                    };
                    return .consumed;
                },
                .move => {
                    if (viewer.drag) |drag| {
                        applyDrag(viewer, drag, m.x, m.y);
                        return .consumed;
                    }
                    return if (inside_box) .consumed else .pass;
                },
                .release => {
                    if (viewer.drag != null) {
                        viewer.drag = null;
                        return .consumed;
                    }
                    return if (inside_box) .consumed else .pass;
                },
            }
        },
        else => return .pass,
    }
}

fn applyDrag(viewer: *Viewer, drag: Drag, x: u16, y: u16) void {
    const placement = computePlacement(viewer, viewer.cell_px);
    if (placement.cols == 0) return;
    const px_per_col = @as(f32, @floatFromInt(placement.src.w)) / @as(f32, @floatFromInt(placement.cols));
    const px_per_row = @as(f32, @floatFromInt(placement.src.h)) / @as(f32, @floatFromInt(placement.rows));
    const dx: i32 = @as(i32, x) - @as(i32, drag.mouse_x);
    const dy: i32 = @as(i32, y) - @as(i32, drag.mouse_y);
    const d = viewer.dims();
    viewer.pan_x = clampPan(drag.pan_x, -@as(i32, @intFromFloat(@as(f32, @floatFromInt(dx)) * px_per_col)), d.w -| placement.src.w);
    viewer.pan_y = clampPan(drag.pan_y, -@as(i32, @intFromFloat(@as(f32, @floatFromInt(dy)) * px_per_row)), d.h -| placement.src.h);
}

pub fn render(viewer: *Viewer, theme: r.app.Theme, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (area.width < 20 or area.height < 8) return;
    const box_w = @max(@min(area.width -| 2, @max(30, area.width * 4 / 5)), 20);
    const box_h = @max(@min(area.height -| 2, @max(10, area.height * 4 / 5)), 8);
    const box: r.tui.Rect = .{
        .x = area.x + (area.width - box_w) / 2,
        .y = area.y + (area.height - box_h) / 2,
        .width = box_w,
        .height = box_h,
    };
    viewer.box_rect = box;

    buf.fill(area, .{ .style = .{ .bg = theme.overlay_dark } });
    drawBorder(buf, box, .{ .fg = theme.muted, .bg = theme.overlay_dark });

    const inner: r.tui.Rect = .{
        .x = box.x + 1,
        .y = box.y + 1,
        .width = box.width -| 2,
        .height = box.height -| 2,
    };
    const title_style = r.tui.Style{ .fg = theme.text_hl, .modifier = .{ .bold = true }, .bg = theme.overlay_dark };
    var title_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const d = viewer.dims();
    const title = if (viewer.err_msg != null)
        std.fmt.bufPrint(&title_buf, "image", .{}) catch "image"
    else
        std.fmt.bufPrint(&title_buf, "{s}  {d}x{d}  {d}%", .{ std.fs.path.basename(viewer.path), d.w, d.h, zoomPercent(viewer) }) catch "image";
    drawCentered(buf, inner.y, inner, title, title_style);

    const footer_y = inner.y + inner.height -| 1;
    drawCentered(buf, footer_y, inner, "q close · wheel/± zoom · drag/hjkl pan · r reset", .{ .fg = theme.muted, .bg = theme.overlay_dark });

    const img_area: r.tui.Rect = .{
        .x = inner.x,
        .y = inner.y + 1,
        .width = inner.width,
        .height = inner.height -| 2,
    };
    buf.fill(img_area, .{ .style = .{ .bg = theme.overlay_dark } });
    viewer.image_rect = img_area;

    if (viewer.err_msg) |msg| {
        var msg_buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&msg_buf, "{s}: {s}", .{ viewer.path, msg }) catch "cannot show image";
        drawCentered(buf, img_area.y + img_area.height / 2, img_area, text, .{ .fg = theme.err, .bg = theme.overlay_dark });
    }
}

fn zoomPercent(viewer: *const Viewer) u32 {
    return @intFromFloat(viewer.factor() * 100.0);
}

fn drawBorder(buf: *r.tui.Buffer, box: r.tui.Rect, style: r.tui.Style) void {
    var x = box.x;
    while (x < box.x + box.width) : (x += 1) {
        buf.set(x, box.y, .{ .char = '─', .style = style });
        buf.set(x, box.y + box.height -| 1, .{ .char = '─', .style = style });
    }
    var y = box.y;
    while (y < box.y + box.height) : (y += 1) {
        buf.set(box.x, y, .{ .char = '│', .style = style });
        buf.set(box.x + box.width -| 1, y, .{ .char = '│', .style = style });
    }
    buf.set(box.x, box.y, .{ .char = '┌', .style = style });
    buf.set(box.x + box.width -| 1, box.y, .{ .char = '┐', .style = style });
    buf.set(box.x, box.y + box.height -| 1, .{ .char = '└', .style = style });
    buf.set(box.x + box.width -| 1, box.y + box.height -| 1, .{ .char = '┘', .style = style });
}

fn drawCentered(buf: *r.tui.Buffer, y: u16, area: r.tui.Rect, text: []const u8, style: r.tui.Style) void {
    if (area.width < 4) return;
    const shown = if (text.len > area.width - 2) text[0 .. area.width - 4] else text;
    const pad = (area.width - @as(u16, @intCast(shown.len))) / 2;
    buf.setStringMax(area.x + pad, y, shown, style, area.width - pad);
}
