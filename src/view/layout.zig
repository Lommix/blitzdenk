const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const text_utils = r.tui.text_utils;
const composer = @import("composer.zig");
const permission = @import("permission.zig");

pub const WIDGET_MIN_MAIN_COLS: u16 = 40;

pub const WIDGET_MIN_TIMELINE_ROWS: u16 = 6;

pub const WidgetPanelSlot = struct {
    rect: r.tui.Rect = .{},
    height: u16 = 0,
    entry_index: usize = 0,
    place: r.lua.WidgetPlace = .between,
};

pub const WidgetLayout = struct {
    area: r.tui.Rect = .{},
    left: ?r.tui.Rect = null,
    right: ?r.tui.Rect = null,
    left_index: usize = 0,
    right_index: usize = 0,
    panels: [r.lua.MAX_LUA_WIDGETS]WidgetPanelSlot = @splat(.{}),
    panels_len: usize = 0,
    between_total_height: u16 = 0,
    below_total_height: u16 = 0,
    panels_total_height: u16 = 0,
    main: r.tui.Rect = .{},
};

pub fn computeWidgetLayout(vm: *r.lua.LuaVm, area: r.tui.Rect) WidgetLayout {
    var out = WidgetLayout{ .area = area };
    var left_w: u16 = 0;
    var right_w: u16 = 0;

    for (vm.widget_entries[0..vm.widget_count], 0..) |*entry, i| {
        if (!entry.alive or entry.hidden) continue;
        switch (entry.kind) {
            .sidebar => {
                const w = @min(entry.size, area.width);
                if (entry.side == .left) {
                    left_w = w;
                    out.left_index = i;
                } else {
                    right_w = w;
                    out.right_index = i;
                }
            },
            .panel => {
                const h = @min(entry.size, area.height);
                if (entry.place == .below) out.below_total_height +|= h else out.between_total_height +|= h;
            },
        }
    }

    if (area.width -| left_w -| right_w < WIDGET_MIN_MAIN_COLS) right_w = 0;
    if (area.width -| left_w -| right_w < WIDGET_MIN_MAIN_COLS) left_w = 0;

    const main_w = area.width -| left_w -| right_w;
    if (left_w > 0) out.left = .{ .x = area.x, .y = area.y, .width = left_w, .height = area.height };
    if (right_w > 0) out.right = .{
        .x = area.x +| left_w +| main_w,
        .y = area.y,
        .width = right_w,
        .height = area.height,
    };
    out.main = .{ .x = area.x +| left_w, .y = area.y, .width = main_w, .height = area.height };

    for (vm.widget_entries[0..vm.widget_count], 0..) |*entry, i| {
        if (!entry.alive or entry.hidden or entry.kind != .panel) continue;
        const h = @min(entry.size, area.height);
        out.panels[out.panels_len] = .{
            .rect = .{ .x = out.main.x, .y = 0, .width = main_w, .height = h },
            .height = h,
            .entry_index = i,
            .place = entry.place,
        };
        out.panels_len += 1;
    }
    out.panels_total_height = out.between_total_height +| out.below_total_height;
    return out;
}

pub fn anchorWidgetPanels(wl: *const WidgetLayout, footer_y: u16, footer_h: u16, out: *[r.lua.MAX_LUA_WIDGETS]WidgetPanelSlot) void {
    var between_y = footer_y -| wl.between_total_height;
    var below_y = footer_y +| footer_h;
    for (wl.panels[0..wl.panels_len], 0..) |slot, i| {
        out[i] = slot;
        if (slot.place == .below) {
            out[i].rect.y = below_y;
            below_y +|= slot.height;
        } else {
            out[i].rect.y = between_y;
            between_y +|= slot.height;
        }
    }
}

/// Footer rows the active input mode needs: content, status row, padding.
pub fn inputHeight(app: *App, frame_alloc: std.mem.Allocator, main_area: r.tui.Rect) u16 {
    switch (app.input_mode) {
        .text => {
            const shown = app.displayInput(frame_alloc);
            const width = composer.inputTextWidth(composer.inputContentWidth(main_area.width), composer.modePromptCols(&app.input_mode));
            const counted = r.tui.input_layout.rowCount(frame_alloc, shown.text, width) catch 1;
            const rows: u16 = @intCast(@min(@max(counted, 1), @as(usize, std.math.maxInt(u16))));
            return @min(rows +| 3, 23); // input rows + status + 2 padding
        },
        .wizard => return 18,
        .session_picker => |*picker| return @intCast(@min(6 + @max(picker.rows.len, 1), main_area.height -| 1)),
        .perm_select, .perm_message => {
            const field_rows = permission.permFieldRows(app, frame_alloc, composer.inputContentWidth(main_area.width) -| 2);
            const extra = (field_rows orelse 1) -| 1;
            if (app.active_permission) |entry| {
                if (entry.payload == .ask) {
                    return permission.askPermissionInputHeight(app, main_area.width, main_area.height, field_rows);
                }
                if (entry.payload == .call) {
                    const rows = text_utils.wrappedRowCount(entry.payload.call.description, main_area.width -| 7);
                    return @min(8 +| rows +| extra, main_area.height -| 1);
                }
                return @min(9 +| extra, main_area.height -| 1);
            }
            _ = app.active_selection orelse return 9;
            return permission.askPermissionInputHeight(app, main_area.width, main_area.height, field_rows);
        },
    }
}

test "widget layout reserves sidebars and hides them on narrow terminals" {
    const vm = try r.lua.LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.widget_entries[0] = .{ .kind = .sidebar, .side = .left, .size = 10 };
    vm.widget_entries[1] = .{ .kind = .sidebar, .side = .right, .size = 6 };
    vm.widget_count = 2;

    const wide = computeWidgetLayout(vm, .{ .width = 100, .height = 30 });
    try std.testing.expectEqual(@as(u16, 10), wide.left.?.width);
    try std.testing.expectEqual(@as(u16, 6), wide.right.?.width);
    try std.testing.expectEqual(@as(u16, 100 - 10 - 6), wide.main.width);
    try std.testing.expectEqual(@as(u16, 10), wide.main.x);

    const narrow = computeWidgetLayout(vm, .{ .width = 50, .height = 30 });
    try std.testing.expect(narrow.left != null);
    try std.testing.expectEqual(@as(?r.tui.Rect, null), narrow.right);
    try std.testing.expectEqual(@as(u16, 50 - 10), narrow.main.width);

    const tiny = computeWidgetLayout(vm, .{ .width = 44, .height = 30 });
    try std.testing.expectEqual(@as(?r.tui.Rect, null), tiny.left);
    try std.testing.expectEqual(@as(?r.tui.Rect, null), tiny.right);
    try std.testing.expectEqual(@as(u16, 44), tiny.main.width);
}
