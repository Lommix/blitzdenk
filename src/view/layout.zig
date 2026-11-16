//! Footer height each input mode needs; the scene in `scene.zig` owns the
//! frame layout around it.
const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const text_utils = r.tui.text_utils;
const composer = @import("composer.zig");
const permission = @import("permission.zig");

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
