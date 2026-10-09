const std = @import("std");
const root = @import("root.zig");

pub const PROVIDER_LUA = "provider.lua";
pub const DONE_MARKER = "setup.done";
pub const PENDING_MARKER = "setup.pending";
pub const provider_types = [_][]const u8{ "openai", "response", "anthropic" };
const SKIP_PROVIDER_TYPE = "openai";
const SKIP_URL = "https://opencode.ai/zen/go/v1";
const SKIP_KEY_ENVAR = "OPENCODE_API_KEY";
const SKIP_MODEL = "deepseek-v4-flash-vision-exp";

pub const Step = enum {
    welcome,
    provider,
    provider_type,
    url,
    key,
    model,
    vision,
    confirm,
    done,
};

pub const CatalogEntry = struct {
    name: []const u8,
    provider_type: []const u8,
    default_url: []const u8,
    key_envar: []const u8,
    free_text_model_only: bool = false,
    session_key_header: []const u8 = "",
    models: []const CatalogModel = &.{},
};

pub const CatalogModel = struct {
    name: []const u8,
    vision: bool = false,
};

pub const catalog = [_]CatalogEntry{
    .{
        .name = "Anthropic",
        .provider_type = "anthropic",
        .default_url = "https://api.anthropic.com/v1",
        .key_envar = "ANTHROPIC_API_KEY",
        .models = &.{
            .{ .name = "claude-sonnet-5.5", .vision = true },
            .{ .name = "claude-opus-5.5", .vision = true },
            .{ .name = "claude-fable-5", .vision = true },
        },
    },
    .{
        .name = "OpenAI",
        .provider_type = "response",
        .default_url = "https://api.openai.com/v1",
        .key_envar = "OPENAI_API_KEY",
        .models = &.{
            .{ .name = "gpt-6-astra", .vision = true },
            .{ .name = "gpt-6-sol", .vision = true },
            .{ .name = "gpt-6-luna", .vision = true },
        },
    },
    .{
        .name = "OpenRouter",
        .provider_type = "openai",
        .default_url = "https://openrouter.ai/api/v1",
        .key_envar = "OPENROUTER_API_KEY",
        .session_key_header = "x-session-id",
        .models = &.{},
    },
    .{
        .name = "Novita",
        .provider_type = "openai",
        .default_url = "https://api.novita.ai/openai/v1",
        .key_envar = "NOVITA_API_KEY",
        .models = &.{
            .{ .name = "zai-org/glm-5.3-flash", .vision = true },
        },
    },

    .{
        .name = "Z.ai",
        .provider_type = "openai",
        .default_url = "https://api.z.ai/api/coding/paas/v4",
        .key_envar = "Z_AI_KEY",
        .models = &.{
            .{ .name = "glm-5.3-flash", .vision = true },
            .{ .name = "glm-5.3", .vision = false },
        },
    },
    .{
        .name = "xAI",
        .provider_type = "response",
        .default_url = "https://api.x.ai/v1",
        .key_envar = "XAI_API_KEY",
        .session_key_header = "x-grok-conv-id",
        .models = &.{
            .{ .name = "grok-4.6", .vision = true },
        },
    },
    .{
        .name = "opencode go",
        .provider_type = "openai",
        .default_url = "https://opencode.ai/zen/go/v1",
        .key_envar = "OPENCODE_API_KEY",
        .session_key_header = "x-opencode-session",
        .models = &.{
            .{ .name = "glm-5.3-flash", .vision = true },
            .{ .name = "deepseek-flash", .vision = true },
            .{ .name = "qwen3.8-flash", .vision = true },
        },
    },
    .{
        .name = "Custom endpoint",
        .provider_type = "openai",
        .default_url = "",
        .key_envar = "",
        .free_text_model_only = true,
    },
};

pub fn catalogEntry(index: usize) ?CatalogEntry {
    if (index >= catalog.len) return null;
    return catalog[index];
}

pub const Wizard = struct {
    step: Step = .welcome,
    provider_index: usize = 0,
    list_selected: usize = 0,
    accept_selected: bool = false,
    model_free_text: bool = false,
    model_curated_index: ?usize = null,
    vision_override: ?bool = null,
    provider_type_buf: [16]u8 = undefined,
    provider_type_len: usize = 0,
    url: root.tui.Field(256) = .{},
    key: root.tui.Field(256) = .{},
    model: root.tui.Field(256) = .{},
    free_text_buf: [256]u8 = undefined,
    free_text_len: usize = 0,
    error_msg: ?[]const u8 = null,

    pub fn maxListIndex(w: *const Wizard) usize {
        return switch (w.step) {
            .welcome => 2,
            .provider => catalog.len,
            .provider_type => provider_types.len,
            .confirm => 2,
            .vision => 2,
            .model => blk: {
                const entry = catalogEntry(w.provider_index) orelse break :blk 0;
                break :blk entry.models.len + 1;
            },
            else => 1,
        };
    }

    pub fn stepIsList(w: *const Wizard) bool {
        return switch (w.step) {
            .welcome, .provider, .provider_type, .confirm, .vision => true,
            .model => !w.model_free_text,
            else => false,
        };
    }

    pub fn activeText(w: *Wizard) ?*root.tui.Field(256) {
        return switch (w.step) {
            .url => &w.url,
            .key => &w.key,
            .model => if (w.model_free_text) &w.model else null,
            else => null,
        };
    }

    fn refreshUrl(w: *Wizard) void {
        const entry = catalogEntry(w.provider_index) orelse return;
        w.url.set(entry.default_url);
    }

    pub fn resetModel(w: *Wizard) void {
        const entry = catalogEntry(w.provider_index);
        w.model_free_text = if (entry) |e| e.free_text_model_only else false;
        w.model_curated_index = if (w.step == .model and !w.model_free_text) null else w.model_curated_index;
        w.vision_override = null;
        w.model.clear();
        w.free_text_len = 0;
        @memset(w.free_text_buf[0..], 0);
    }

    pub fn syncModelStep(w: *Wizard) void {
        if (w.step != .model) return;
        w.resetModel();
        if (!w.model_free_text and w.model.isEmpty()) w.moveCursor(0);
    }

    pub fn enterProvider(w: *Wizard) void {
        w.provider_index = w.list_selected;
        const entry = catalogEntry(w.provider_index) orelse return;
        w.provider_type_len = @min(entry.provider_type.len, w.provider_type_buf.len);
        @memcpy(w.provider_type_buf[0..w.provider_type_len], entry.provider_type[0..w.provider_type_len]);
        w.refreshUrl();
        w.step = nextStep(.provider, entry, "");
        w.list_selected = 0;
        if (w.step == .model) w.resetModel();
    }

    pub fn finishProviderType(w: *Wizard) void {
        const chosen = provider_types[@min(w.list_selected, provider_types.len - 1)];
        w.provider_type_len = @min(chosen.len, w.provider_type_buf.len);
        @memcpy(w.provider_type_buf[0..w.provider_type_len], chosen[0..w.provider_type_len]);
        w.step = .url;
        if (w.url.isEmpty()) w.list_selected = 0;
    }

    pub fn moveCursor(w: *Wizard, delta: i8) void {
        const max_index = w.maxListIndex();
        if (max_index == 0) return;
        const moved = @as(i64, @intCast(w.list_selected)) + delta;
        w.list_selected = @intCast(@min(@max(moved, 0), @as(i64, @intCast(max_index - 1))));
        if (w.step == .confirm) {
            w.accept_selected = w.list_selected == 0;
            return;
        }
        if (w.step == .vision) {
            w.vision_override = w.list_selected == 0;
            return;
        }
        w.modelSelectionChanged();
    }

    fn modelSelectionChanged(w: *Wizard) void {
        if (w.step != .model) return;
        const entry = catalogEntry(w.provider_index) orelse return;
        if (entry.free_text_model_only) return;
        const free_row = entry.models.len;
        const now_free = w.list_selected == free_row;
        if (now_free and w.model_free_text) return;
        if (w.model_free_text) {
            w.free_text_len = @min(w.model.len, w.free_text_buf.len);
            @memcpy(w.free_text_buf[0..w.free_text_len], w.model.slice()[0..w.free_text_len]);
        }
        w.model_free_text = now_free;
        w.model.clear();
        if (now_free) {
            w.model.set(w.free_text_buf[0..w.free_text_len]);
        } else {
            w.model_curated_index = w.list_selected;
            if (w.list_selected < entry.models.len) {
                w.model.set(entry.models[w.list_selected].name);
            }
        }
    }

    pub fn abortClearSecrets(w: *Wizard) void {
        w.key.wipe();
    }

    pub fn selection(w: *const Wizard) ?Selection {
        const entry = catalogEntry(w.provider_index) orelse return null;
        const model = selectModel(entry, w.model.slice());
        return .{
            .entry = entry,
            .provider_type = w.provider_type_buf[0..w.provider_type_len],
            .url = w.url.slice(),
            .key = w.key.slice(),
            .model = w.model.slice(),
            .vision = if (w.vision_override) |v| v else model.vision,
            .session_key_header = entry.session_key_header,
        };
    }
};

pub const Selection = struct {
    entry: CatalogEntry,
    provider_type: []const u8,
    url: []const u8,
    key: []const u8,
    model: []const u8,
    vision: bool,
    session_key_header: []const u8 = "",
};

pub fn nextStep(current: Step, entry: CatalogEntry, model: []const u8) Step {
    return switch (current) {
        .welcome => .provider,
        .provider => if (entry.free_text_model_only) .provider_type else .key,
        .provider_type => .url,
        .url => .key,
        .key => .model,
        .model => if (entry.models.len > 0 and !modelIsCurated(entry, model)) .vision else .confirm,
        .vision => .confirm,
        .confirm => .done,
        .done => .done,
    };
}

pub fn modelIsCurated(entry: CatalogEntry, name: []const u8) bool {
    for (entry.models) |model| {
        if (std.mem.eql(u8, model.name, name)) return true;
    }
    return false;
}

pub fn selectModel(entry: CatalogEntry, name: []const u8) CatalogModel {
    for (entry.models) |model| {
        if (std.mem.eql(u8, model.name, name)) return model;
    }
    return .{ .name = name, .vision = false };
}

pub fn freeTextFieldIsSafe(text: []const u8) bool {
    for (text) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

pub fn renderProviderLua(allocator: std.mem.Allocator, selection: Selection) ![]u8 {
    if (!freeTextFieldIsSafe(selection.model)) return error.WizardTextUnsafe;
    if (!freeTextFieldIsSafe(selection.url)) return error.WizardTextUnsafe;
    if (!freeTextFieldIsSafe(selection.key)) return error.WizardTextUnsafe;
    if (!freeTextFieldIsSafe(selection.session_key_header)) return error.WizardTextUnsafe;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("local provider = blitz.add_provider({\n\ttype = \"");
    try w.writeAll(selection.provider_type);
    try w.writeAll("\",\n\turl = \"");
    try w.writeAll(selection.url);
    try w.writeAll("\",\n");
    if (selection.session_key_header.len > 0) {
        try w.writeAll("\tsession_key_header = \"");
        try w.writeAll(selection.session_key_header);
        try w.writeAll("\",\n");
    }
    if (selection.entry.key_envar.len > 0) {
        try w.writeAll("\t--key_envar = \"");
        try w.writeAll(selection.entry.key_envar);
        try w.writeAll("\",\n");
    }
    if (selection.key.len > 0) {
        try w.writeAll("\tkey = \"");
        try w.writeAll(selection.key);
        try w.writeAll("\",\n");
    }
    try w.writeAll("})\n\nlocal model = blitz.add_model({\n\tname = \"");
    try w.writeAll(selection.model);
    try w.writeAll("\",\n\tprovider = provider,\n\tvision = ");
    try w.writeAll(if (selection.vision) "true" else "false");
    try w.writeAll(",\n");
    try w.writeAll("})\n\nreturn model\n");

    return out.toOwnedSlice();
}

pub fn skipProviderLua(allocator: std.mem.Allocator) ![]u8 {
    return renderProviderLua(allocator, .{
        .entry = .{ .name = "", .provider_type = SKIP_PROVIDER_TYPE, .default_url = SKIP_URL, .key_envar = SKIP_KEY_ENVAR },
        .provider_type = SKIP_PROVIDER_TYPE,
        .url = SKIP_URL,
        .key = "",
        .model = SKIP_MODEL,
        .vision = true,
        .session_key_header = "x-opencode-session",
    });
}

pub fn providerLuaExists(io: std.Io, config_dir: std.Io.Dir) bool {
    _ = config_dir.statFile(io, PROVIDER_LUA, .{}) catch return false;
    return true;
}

pub fn writeProviderLua(io: std.Io, config_dir: std.Io.Dir, allocator: std.mem.Allocator, selection: Selection) !void {
    if (providerLuaExists(io, config_dir)) return error.ProviderLuaExists;
    const contents = try renderProviderLua(allocator, selection);
    defer allocator.free(contents);
    try writeNoOverwrite(io, config_dir, PROVIDER_LUA, contents);
}

pub fn writeSkipDefaults(io: std.Io, config_dir: std.Io.Dir, allocator: std.mem.Allocator) !void {
    if (providerLuaExists(io, config_dir)) return error.ProviderLuaExists;
    const contents = try skipProviderLua(allocator);
    defer allocator.free(contents);
    try writeNoOverwrite(io, config_dir, PROVIDER_LUA, contents);
}

pub fn writeDoneMarker(io: std.Io, config_dir: std.Io.Dir) void {
    writeMarker(io, config_dir, DONE_MARKER);
}

pub fn writePendingMarker(io: std.Io, config_dir: std.Io.Dir) void {
    writeMarker(io, config_dir, PENDING_MARKER);
}

fn writeMarker(io: std.Io, config_dir: std.Io.Dir, name: []const u8) void {
    if (config_dir.statFile(io, name, .{})) |_| {
        return;
    } else |_| {}
    const file = config_dir.createFile(io, name, .{}) catch return;
    file.close(io);
}

fn writeNoOverwrite(io: std.Io, config_dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    const file = try config_dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    file.setPermissions(io, .fromMode(0o600)) catch {};
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

pub fn defaultConfigLua() []const u8 {
    return @embedFile("blitz_default.lua");
}
