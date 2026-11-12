const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const composer = @import("composer.zig");

const WIZARD_HELP_TEXT = "↑/↓ select · enter next · esc abort";

fn wizardSelStyle(app: *const App, selected: bool) r.tui.Style {
    return .{ .fg = app.theme.text, .modifier = .{ .reverse = selected } };
}

pub fn renderWizardContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });
    if (area.height == 0) return;
    const w = &app.input_mode.wizard;
    var para: r.tui.Paragraph = .{ .border = .none, .padding = .{ .left = 2, .right = 2 } };
    var err: r.tui.Paragraph = .{ .border = .none, .padding = .{ .left = 2, .right = 2 } };
    const title_style: r.tui.Style = .{ .fg = app.theme.info, .modifier = .{ .bold = true } };
    const muted_style: r.tui.Style = .{ .fg = app.theme.muted };
    const err_style: r.tui.Style = .{ .fg = app.theme.err };
    var field: ?*r.tui.Field(256) = null;
    var field_mask: ?u8 = null;

    var l = r.tui.Line{};
    l.pushText(arena, "Setup — blitzdenk first-run wizard", title_style) catch {};
    para.lines.append(arena, l) catch {};
    var help = r.tui.Line{};
    help.pushText(arena, WIZARD_HELP_TEXT, muted_style) catch {};
    para.lines.append(arena, help) catch {};
    para.lines.append(arena, .{}) catch {};

    switch (w.step) {
        .welcome => {
            wizardAppendHeading(app, arena, &para, "Welcome to blitzdenk");
            wizardAppendHeading(app, arena, &para, "Pick a model provider to get started, or skip to use the built-in defaults.");
            wizardAppendHeading(app, arena, &para, "");
            wizardAppendOption(app, arena, &para, "Continue", w.list_selected == 0);
            wizardAppendOption(app, arena, &para, "Skip (use defaults)", w.list_selected == 1);
        },
        .provider => {
            wizardAppendHeading(app, arena, &para, "Choose a provider:");
            for (r.wizard.catalog, 0..) |entry, i| {
                wizardAppendOption(app, arena, &para, entry.name, i == w.list_selected);
            }
        },
        .provider_type => {
            wizardAppendHeading(app, arena, &para, "Custom endpoint — provider type:");
            for (r.wizard.provider_types, 0..) |name, i| {
                wizardAppendOption(app, arena, &para, name, i == w.list_selected);
            }
        },
        .url => {
            wizardAppendHeading(app, arena, &para, "Endpoint url (enter keeps the shown value):");
            field = &w.url;
        },
        .key => {
            wizardAppendHeading(app, arena, &para, "Paste your api key (stored in provider.lua):");
            field = &w.key;
            field_mask = '*';
        },
        .model => {
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            if (entry.free_text_model_only) {
                wizardAppendHeading(app, arena, &para, "Model id:");
                field = &w.model;
            } else {
                wizardAppendHeading(app, arena, &para, "Choose a model or type in the model id string (same thing)");
                wizardAppendHeading(app, arena, &para, "");
                for (entry.models, 0..) |model, i| {
                    wizardAppendOption(app, arena, &para, model.name, !w.model_free_text and w.model_curated_index == i);
                }
                wizardAppendOption(app, arena, &para, "Enter model id…", w.model_free_text);
                if (w.model_free_text) field = &w.model;
            }
        },
        .vision => {
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            const detected = r.wizard.selectModel(entry, w.model.slice()).vision;
            wizardAppendHeading(app, arena, &para, "Custom model id — should image input be enabled?");
            wizardAppendHeading(app, arena, &para, "Catalogued models skip this; vision follows the catalogue.");
            wizardAppendKeyValue(app, arena, &para, "model", w.model.slice());
            wizardAppendKeyValue(app, arena, &para, "catalogue", if (detected) "vision" else "no vision");
            wizardAppendHeading(app, arena, &para, "");
            wizardAppendOption(app, arena, &para, "Enable vision", w.vision_override == true);
            wizardAppendOption(app, arena, &para, "Text only", w.vision_override != true);
        },
        .confirm => {
            wizardAppendHeading(app, arena, &para, "Confirm — write provider.lua with these choices?");
            const selection = app.wizardSelection(w);
            const entry = r.wizard.catalogEntry(w.provider_index) orelse r.wizard.catalog[0];
            const vision_text = if (selection) |sel| (if (sel.vision) "true" else "false") else "unknown";
            wizardAppendKeyValue(app, arena, &para, "schema", w.provider_type_buf[0..w.provider_type_len]);
            wizardAppendKeyValue(app, arena, &para, "provider", entry.name);
            wizardAppendKeyValue(app, arena, &para, "url", w.url.slice());
            wizardAppendKeyValue(app, arena, &para, "key", if (!w.key.isEmpty()) "<set>" else "");
            wizardAppendKeyValue(app, arena, &para, "vision", vision_text);
            wizardAppendKeyValue(app, arena, &para, "model", w.model.slice());
            wizardAppendHeading(app, arena, &para, "");
            wizardAppendOption(app, arena, &para, "Write provider.lua", w.accept_selected);
            wizardAppendOption(app, arena, &para, "Back", !w.accept_selected);
        },
        .done => {
            wizardAppendHeading(app, arena, &para, "Setup complete — happy hacking.");
            wizardAppendHeading(app, arena, &para, "provider.lua is live; edit it and it hot-reloads like any config lua.");
        },
    }

    if (w.error_msg) |msg| {
        var err_line = r.tui.Line{};
        err_line.pushText(arena, msg, err_style) catch {};
        err.lines.append(arena, err_line) catch {};
    }
    const err_rows: u16 = @min(err.totalHeight(area.width), area.height -| 1);
    const field_rows: u16 = @intCast(@max(1, @as(usize, area.height) -| para.totalHeightLong(area.width) -| err_rows));
    const shown_rows: u16 = area.height -| field_rows -| err_rows;

    para.renderSimple(arena, .{ .x = area.x, .y = area.y, .width = area.width, .height = shown_rows }, buf);

    if (field) |f| {
        composer.renderFieldWidget(app, arena, f.slice(), f.cursor, .{
            .x = area.x +| composer.WIDGET_PAD_X,
            .y = area.y +| shown_rows,
            .width = composer.inputContentWidth(area.width),
            .height = field_rows,
        }, .{
            .prompt = composer.modePrompt(&app.input_mode),
            .text = .{ .fg = app.theme.text_hl, .modifier = .{ .reverse = true } },
            .mask = field_mask,
        }, buf);
    }

    if (err_rows > 0) {
        err.renderSimple(arena, .{
            .x = area.x,
            .y = area.y +| shown_rows +| field_rows,
            .width = area.width,
            .height = err_rows,
        }, buf);
    }
}

fn wizardAppendHeading(app: *const App, arena: std.mem.Allocator, para: *r.tui.Paragraph, text: []const u8) void {
    var line = r.tui.Line{};
    line.pushText(arena, text, .{ .fg = app.theme.text }) catch return;
    para.lines.append(arena, line) catch {};
}

pub fn renderSessionPickerContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });
    const picker = &app.input_mode.session_picker;
    var para: r.tui.Paragraph = .{ .border = .none, .padding = .{ .left = 2, .right = 2 } };

    var title = r.tui.Line{};
    title.pushText(arena, "Sessions — continue a recorded session", .{ .fg = app.theme.info, .modifier = .{ .bold = true } }) catch {};
    para.lines.append(arena, title) catch {};

    var help = r.tui.Line{};
    help.pushText(arena, "↑/↓ or j/k select · enter continue · esc quit", .{ .fg = app.theme.muted }) catch {};
    para.lines.append(arena, help) catch {};
    para.lines.append(arena, .{}) catch {};

    const visible_rows: usize = @max(area.height, 3) - 3;
    if (visible_rows == 0) {
        para.renderSimple(arena, area, buf);
        return;
    }
    picker.syncScroll(visible_rows);
    const start = @min(picker.scroll, picker.rows.len -| visible_rows);
    const end = @min(start + visible_rows, picker.rows.len);
    var index: usize = start;
    while (index < end) : (index += 1) {
        const row = picker.rows[index];
        const selected = index == picker.selected;
        var line = r.tui.Line{};
        if (r.session_picker.isNewSession(row)) {
            line.pushText(arena, if (selected) "❯ " else "  ", .{ .modifier = .{ .bold = true } }) catch return;
            line.pushText(arena, row.prompt, .{ .fg = app.theme.ok, .modifier = .{ .bold = selected } }) catch return;
            para.lines.append(arena, line) catch {};
            continue;
        }
        line.pushText(arena, if (selected) "❯ " else "  ", .{ .modifier = .{ .bold = true } }) catch return;
        line.pushText(arena, row.date, .{ .fg = app.theme.role_agent }) catch return;
        line.pushText(arena, "  ", .{}) catch return;
        line.pushText(arena, row.id, .{ .fg = app.theme.muted }) catch return;
        line.pushText(arena, "  ", .{}) catch return;
        const prompt = if (row.prompt.len > 0) row.prompt else r.session_picker.EMPTY_PROMPT_LABEL;
        line.pushText(arena, clipPromptToWidth(arena, prompt, pickerMaxPromptWidth(area.width)), if (selected) .{ .fg = app.theme.text_hl, .modifier = .{ .bold = true } } else .{ .fg = app.theme.info }) catch return;
        para.lines.append(arena, line) catch {};
    }

    para.renderSimple(arena, area, buf);
}

fn pickerMaxPromptWidth(area_width: u16) usize {
    const widget_padding = 4;
    const para_padding = 4;
    const prefix = 2 + 16 + 2 + r.session_store.ID_LEN + 2;
    return @as(usize, area_width) -| (widget_padding + para_padding + prefix);
}

fn clipPromptToWidth(arena: std.mem.Allocator, text: []const u8, max: usize) []const u8 {
    const width = r.tui.widgets.displayCols(text);
    if (width <= max) return text;
    var cut: usize = 0;
    var cols: usize = 0;
    const limit = max -| 1;
    while (cut < text.len and cols < limit) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[cut]) catch 1;
        const end = @min(cut + seq_len, text.len);
        cols += 1;
        cut = end;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..cut]}) catch text;
}

fn wizardAppendOption(app: *const App, arena: std.mem.Allocator, para: *r.tui.Paragraph, text: []const u8, selected: bool) void {
    var line = r.tui.Line{};
    line.pushText(arena, if (selected) "❯ " else "  ", wizardSelStyle(app, selected)) catch return;
    line.pushText(arena, text, wizardSelStyle(app, selected)) catch return;
    para.lines.append(arena, line) catch {};
}

fn wizardAppendKeyValue(app: *App, arena: std.mem.Allocator, para: *r.tui.Paragraph, key: []const u8, value: []const u8) void {
    var line = r.tui.Line{};
    const padded = std.fmt.allocPrint(arena, "  {s:<10}", .{key}) catch return;
    line.pushText(arena, padded, .{ .fg = app.theme.muted }) catch return;
    line.pushText(arena, value, .{ .fg = app.theme.text }) catch return;
    para.lines.append(arena, line) catch {};
}
