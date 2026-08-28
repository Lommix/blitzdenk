const std = @import("std");
const root = @import("root.zig");

pub const PROVIDER_LUA = "provider.lua";
pub const DONE_MARKER = "setup.done";
pub const PENDING_MARKER = "setup.pending";
pub const provider_types = [_][]const u8{ "openai", "response", "anthropic", "ollama" };
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
    key_step: bool = true,
    url_step: bool = false,
    free_text_model_only: bool = false,
    models: []const CatalogModel = &.{},
};

pub const CatalogModel = struct {
    name: []const u8,
    vision: bool = false,
    replay_reasoning: bool = false,
};

pub const catalog = [_]CatalogEntry{
    .{
        .name = "Anthropic",
        .provider_type = "anthropic",
        .default_url = "https://api.anthropic.com/v1",
        .key_envar = "ANTHROPIC_API_KEY",
        .models = &.{
            .{ .name = "claude-fable-5", .vision = true },
            .{ .name = "claude-opus-5", .vision = true },
            .{ .name = "claude-sonnet-5", .vision = true },
        },
    },
    .{
        .name = "OpenAI",
        .provider_type = "response",
        .default_url = "https://api.openai.com/v1",
        .key_envar = "OPENAI_API_KEY",
        .models = &.{
            .{ .name = "gpt-5.6-sol", .vision = true },
            .{ .name = "gpt-5.6-luna", .vision = true },
            .{ .name = "gpt-5.6-terra", .vision = true },
        },
    },
    .{
        .name = "OpenRouter",
        .provider_type = "openai",
        .default_url = "https://openrouter.ai/api/v1",
        .key_envar = "OPENROUTER_API_KEY",
        .models = &.{},
    },
    .{
        .name = "Novita",
        .provider_type = "openai",
        .default_url = "https://api.novita.ai/openai/v1",
        .key_envar = "NOVITA_API_KEY",
        .models = &.{
            .{ .name = "zai-org/glm-5.3-flash", .vision = true, .replay_reasoning = true },
        },
    },

    .{
        .name = "Z.ai",
        .provider_type = "openai",
        .default_url = "https://api.z.ai/api/coding/paas/v4",
        .key_envar = "Z_AI_KEY",
        .models = &.{
            .{ .name = "glm-5.3-flash", .vision = true, .replay_reasoning = true },
            .{ .name = "glm-5.3", .vision = true, .replay_reasoning = true },
        },
    },
    .{
        .name = "opencode go",
        .provider_type = "openai",
        .default_url = "https://opencode.ai/zen/go/v1",
        .key_envar = "OPENCODE_API_KEY",
        .models = &.{
            .{ .name = "glm-5.3-flash", .vision = true, .replay_reasoning = true },
            .{ .name = "deepseek-v4-flash-vision-exp", .vision = true, .replay_reasoning = true },
            .{ .name = "qwen3.8-flash", .vision = true, .replay_reasoning = true },
        },
    },
    .{
        .name = "Ollama",
        .provider_type = "ollama",
        .default_url = "http://localhost:11434/v1",
        .key_envar = "",
        .key_step = false,
        .url_step = true,
        .models = &.{},
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
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    key_buf: [256]u8 = undefined,
    key_len: usize = 0,
    model_buf: [256]u8 = undefined,
    model_len: usize = 0,
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

    const TextTarget = struct { buf: []u8, len: *usize };

    pub fn activeText(w: *Wizard) ?TextTarget {
        return switch (w.step) {
            .url => .{ .buf = w.url_buf[0..], .len = &w.url_len },
            .key => .{ .buf = w.key_buf[0..], .len = &w.key_len },
            .model => if (w.model_free_text) .{ .buf = w.model_buf[0..], .len = &w.model_len } else null,
            else => null,
        };
    }

    pub fn storeText(w: *Wizard, text: []const u8) void {
        const target = w.activeText() orelse return;
        if (target.len.* + text.len <= target.buf.len) {
            @memcpy(target.buf[target.len.*..][0..text.len], text);
            target.len.* += text.len;
        }
    }

    fn refreshUrl(w: *Wizard) void {
        const entry = catalogEntry(w.provider_index) orelse return;
        w.url_len = @min(entry.default_url.len, w.url_buf.len);
        @memcpy(w.url_buf[0..w.url_len], entry.default_url[0..w.url_len]);
    }

    pub fn resetModel(w: *Wizard) void {
        const entry = catalogEntry(w.provider_index);
        w.model_free_text = if (entry) |e| e.free_text_model_only else false;
        w.model_curated_index = if (w.step == .model and !w.model_free_text) null else w.model_curated_index;
        w.vision_override = null;
        w.model_len = 0;
        @memset(w.model_buf[0..], 0);
        w.free_text_len = 0;
        @memset(w.free_text_buf[0..], 0);
    }

    pub fn syncModelStep(w: *Wizard) void {
        if (w.step != .model) return;
        w.resetModel();
        if (!w.model_free_text and w.model_len == 0) w.moveCursor(0);
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
        if (w.url_len == 0) w.list_selected = 0;
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
            w.free_text_len = @min(w.model_len, w.free_text_buf.len);
            @memcpy(w.free_text_buf[0..w.free_text_len], w.model_buf[0..w.free_text_len]);
        }
        w.model_free_text = now_free;
        w.model_len = 0;
        @memset(w.model_buf[0..], 0);
        if (now_free) {
            w.model_len = @min(w.free_text_len, w.model_buf.len);
            @memcpy(w.model_buf[0..w.model_len], w.free_text_buf[0..w.model_len]);
        } else {
            w.model_curated_index = w.list_selected;
            if (w.list_selected < entry.models.len) {
                const model = entry.models[w.list_selected];
                w.model_len = @min(model.name.len, w.model_buf.len);
                @memcpy(w.model_buf[0..w.model_len], model.name[0..w.model_len]);
            }
        }
    }

    pub fn abortClearSecrets(w: *Wizard) void {
        @memset(w.key_buf[0..w.key_len], 0);
        w.key_len = 0;
    }

    pub fn selection(w: *const Wizard) ?Selection {
        const entry = catalogEntry(w.provider_index) orelse return null;
        const model = selectModel(entry, w.model_buf[0..w.model_len]);
        return .{
            .entry = entry,
            .provider_type = w.provider_type_buf[0..w.provider_type_len],
            .url = w.url_buf[0..w.url_len],
            .key = w.key_buf[0..w.key_len],
            .model = w.model_buf[0..w.model_len],
            .vision = if (w.vision_override) |v| v else model.vision,
            .replay_reasoning = model.replay_reasoning,
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
    replay_reasoning: bool = false,
};

pub fn nextStep(current: Step, entry: CatalogEntry, model: []const u8) Step {
    return switch (current) {
        .welcome => .provider,
        .provider => if (entry.free_text_model_only) .provider_type else if (entry.url_step) .url else if (entry.key_step) .key else .model,
        .provider_type => .url,
        .url => if (entry.key_step) .key else .model,
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
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("local provider = blitz.add_provider({\n\ttype = \"");
    try w.writeAll(selection.provider_type);
    try w.writeAll("\",\n\turl = \"");
    try w.writeAll(selection.url);
    try w.writeAll("\",\n");
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
    if (selection.replay_reasoning) {
        try w.writeAll("\treplay_reasoning = true,\n");
    }
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
        .replay_reasoning = true,
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

const TestTracker = struct {
    provider_type: [64]u8 = undefined,
    provider_type_len: usize = 0,
    url: [256]u8 = undefined,
    url_len: usize = 0,
    key_envar: [128]u8 = undefined,
    key_envar_len: usize = 0,
    key: [256]u8 = undefined,
    key_len: usize = 0,
    model: [128]u8 = undefined,
    model_len: usize = 0,
    vision: bool = false,
    provider_handle: i64 = 0,
    model_handle: i64 = 0,
    bound_agent: i64 = 0,
    bound_model: i64 = 0,
    bound_effort: [16]u8 = undefined,
    bound_effort_len: usize = 0,
};

fn trackerFromUpvalue(state: ?*root.c.lua_State) *TestTracker {
    const ptr = root.c.lua_touserdata(state, root.c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ptr));
}

fn snapshotArg(state: ?*root.c.lua_State, arg_index: c_int, name: [:0]const u8, target: []u8, len_out: *usize) void {
    const L = state.?;
    if (root.c.lua_getfield(L, arg_index, name.ptr) != root.c.LUA_TSTRING) {
        root.c.lua_pop(L, 1);
        len_out.* = 0;
        return;
    }
    var len: usize = 0;
    const raw = root.c.lua_tolstring(L, -1, &len);
    const value: []const u8 = if (raw) |p| p[0..len] else "";
    const copied = @min(len, target.len);
    @memcpy(target[0..copied], value[0..copied]);
    len_out.* = copied;
    root.c.lua_pop(L, 1);
}

const stubBlitzPrelude =
    \\blitz.AGENT_GENERAL = 1
    \\blitz.set_compact_edge = function() end
    \\blitz.set_capabilities = function() end
    \\blitz.register_tool = function() return "lua_repl" end
    \\blitz.set_agent_tools = function() end
    \\blitz.add_command = function() end
    \\blitz.tools = setmetatable({}, { __index = function() return "tool" end })
    \\blitz.add_agent = function() return 2 end
    \\
;

fn addProviderStub(state: ?*root.c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const tracker = trackerFromUpvalue(L);
    snapshotArg(L, 1, "type", &tracker.provider_type, &tracker.provider_type_len);
    snapshotArg(L, 1, "url", &tracker.url, &tracker.url_len);
    snapshotArg(L, 1, "key_envar", &tracker.key_envar, &tracker.key_envar_len);
    snapshotArg(L, 1, "key", &tracker.key, &tracker.key_len);
    tracker.provider_handle += 1;
    root.c.lua_pushinteger(L, tracker.provider_handle);
    return 1;
}

fn addModelStub(state: ?*root.c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const tracker = trackerFromUpvalue(L);
    snapshotArg(L, 1, "name", &tracker.model, &tracker.model_len);
    _ = root.c.lua_getfield(L, 1, "vision");
    tracker.vision = root.c.lua_toboolean(L, -1) != 0;
    root.c.lua_pop(L, 1);
    _ = root.c.lua_getfield(L, 1, "provider");
    tracker.provider_handle = root.c.lua_tointegerx(L, -1, null);
    root.c.lua_pop(L, 1);
    tracker.model_handle = tracker.provider_handle + 1000;
    root.c.lua_pushinteger(L, tracker.model_handle);
    return 1;
}

fn setModelAgentStub(state: ?*root.c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const tracker = trackerFromUpvalue(L);
    tracker.bound_agent = root.c.lua_tointegerx(L, 1, null);
    tracker.bound_model = root.c.lua_tointegerx(L, 2, null);
    snapshotEffort(L, tracker);
    return 0;
}

fn snapshotEffort(state: ?*root.c.lua_State, tracker: *TestTracker) void {
    const L = state.?;
    if (root.c.lua_type(L, 3) != root.c.LUA_TSTRING) {
        tracker.bound_effort_len = 0;
        return;
    }
    var len: usize = 0;
    const raw = root.c.lua_tolstring(L, 3, &len);
    const value: []const u8 = if (raw) |p| p[0..len] else "";
    const copied = @min(len, tracker.bound_effort.len);
    @memcpy(tracker.bound_effort[0..copied], value[0..copied]);
    tracker.bound_effort_len = copied;
}

fn catalogIndex(name: []const u8) usize {
    for (catalog, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) return i;
    }
    unreachable;
}

test "renderProviderLua anthropic with key and curated model" {
    const rendered = try renderProviderLua(std.testing.allocator, .{
        .entry = catalog[0],
        .provider_type = catalog[0].provider_type,
        .url = catalog[0].default_url,
        .key = "sk-ant-secret",
        .model = catalog[0].models[0].name,
        .vision = catalog[0].models[0].vision,
    });
    defer std.testing.allocator.free(rendered);

    const nl = "\n";
    const tab = "\t";
    const expected = "local provider = blitz.add_provider({" ++ nl ++
        tab ++ "type = \"anthropic\"," ++ nl ++
        tab ++ "url = \"https://api.anthropic.com/v1\"," ++ nl ++
        tab ++ "--key_envar = \"ANTHROPIC_API_KEY\"," ++ nl ++
        tab ++ "key = \"sk-ant-secret\"," ++ nl ++
        "})" ++ nl ++ nl ++
        "local model = blitz.add_model({" ++ nl ++
        tab ++ "name = \"claude-fable-5\"," ++ nl ++
        tab ++ "provider = provider," ++ nl ++
        tab ++ "vision = true," ++ nl ++
        "})" ++ nl ++ nl ++
        "return model" ++ nl;
    try std.testing.expectEqualStrings(expected, rendered);
}

test "renderProviderLua ollama omits key lines and keeps url" {
    const ollama_idx = catalogIndex("Ollama");
    const rendered = try renderProviderLua(std.testing.allocator, .{
        .entry = catalog[ollama_idx],
        .provider_type = catalog[ollama_idx].provider_type,
        .url = "http://mynas:11434/v1",
        .key = "",
        .model = "llama4:scout",
        .vision = true,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("", catalog[ollama_idx].key_envar);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "key_envar") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\tkey = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "http://mynas:11434/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\ttype = \"ollama\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\tvision = true,\n") != null);
}

test "renderProviderLua omits replay_reasoning for flagless models" {
    const openai_entry = catalog[catalogIndex("OpenAI")];
    const gpt = openai_entry.models[0];
    const plain = try renderProviderLua(std.testing.allocator, .{
        .entry = openai_entry,
        .provider_type = openai_entry.provider_type,
        .url = openai_entry.default_url,
        .key = "",
        .model = gpt.name,
        .vision = gpt.vision,
    });
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "replay_reasoning") == null);
}

test "renderProviderLua custom includes key only when given" {
    const entry = catalog[catalogIndex("Custom endpoint")];
    const selection = Selection{
        .entry = entry,
        .provider_type = "response",
        .url = "https://llm.example.net/v1",
        .key = "",
        .model = "my-model",
        .vision = false,
    };

    const without_key = try renderProviderLua(std.testing.allocator, selection);
    defer std.testing.allocator.free(without_key);
    try std.testing.expect(std.mem.indexOf(u8, without_key, "\tkey = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_key, "key_envar") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_key, "\tvision = false,\n") != null);

    const with_key = try renderProviderLua(std.testing.allocator, .{
        .key = "hunter2",
        .entry = entry,
        .provider_type = selection.provider_type,
        .url = selection.url,
        .model = selection.model,
        .vision = selection.vision,
    });
    defer std.testing.allocator.free(with_key);
    try std.testing.expect(std.mem.indexOf(u8, with_key, "\tkey = \"hunter2\",\n") != null);
}

test "skip writer creates the default combo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkipDefaults(std.testing.io, tmp.dir, std.testing.allocator);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);

    const expected = try skipProviderLua(std.testing.allocator);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\ttype = \"openai\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\turl = \"https://opencode.ai/zen/go/v1\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\t--key_envar = \"OPENCODE_API_KEY\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tkey = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tname = \"deepseek-v4-flash-vision-exp\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\tvision = true,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\treplay_reasoning = true,\n") != null);
}

test "skip writer no-ops when provider.lua exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const existing = "local model = 42\nreturn model\n";
    {
        const file = try tmp.dir.createFile(std.testing.io, PROVIDER_LUA, .{});
        defer file.close(std.testing.io);
        var buf: [64]u8 = undefined;
        var w = file.writer(std.testing.io, &buf);
        try w.interface.writeAll(existing);
        try w.interface.flush();
    }

    try std.testing.expectError(error.ProviderLuaExists, writeSkipDefaults(std.testing.io, tmp.dir, std.testing.allocator));

    const contents = try tmp.dir.readFileAlloc(std.testing.io, PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(existing, contents);
}

test "wizard finish writer no-ops when provider.lua exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const existing = "hand edit\n";
    {
        const file = try tmp.dir.createFile(std.testing.io, PROVIDER_LUA, .{});
        defer file.close(std.testing.io);
        var buf: [64]u8 = undefined;
        var w = file.writer(std.testing.io, &buf);
        try w.interface.writeAll(existing);
        try w.interface.flush();
    }

    try std.testing.expectError(error.ProviderLuaExists, writeProviderLua(std.testing.io, tmp.dir, std.testing.allocator, .{
        .entry = catalog[0],
        .provider_type = catalog[0].provider_type,
        .url = catalog[0].default_url,
        .key = "sk",
        .model = catalog[0].models[0].name,
        .vision = true,
    }));

    const contents = try tmp.dir.readFileAlloc(std.testing.io, PROVIDER_LUA, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(existing, contents);
}

test "done marker write is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeDoneMarker(std.testing.io, tmp.dir);
    try tmp.dir.access(std.testing.io, DONE_MARKER, .{});

    try tmp.dir.setTimestamps(std.testing.io, DONE_MARKER, .{ .modify_timestamp = .{ .new = .zero } });
    writeDoneMarker(std.testing.io, tmp.dir);

    const stat = try tmp.dir.statFile(std.testing.io, DONE_MARKER, .{});
    try std.testing.expectEqual(@as(i96, 0), stat.mtime.nanoseconds);
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}

test "state machine walks the custom flow and skips key for ollama" {
    const custom = catalog[catalogIndex("Custom endpoint")];
    var step: Step = .welcome;
    step = nextStep(step, custom, "");
    try std.testing.expectEqual(Step.provider, step);
    step = nextStep(step, custom, "");
    try std.testing.expectEqual(Step.provider_type, step);
    step = nextStep(step, custom, "");
    try std.testing.expectEqual(Step.url, step);
    step = nextStep(step, custom, "");
    try std.testing.expectEqual(Step.key, step);
    step = nextStep(step, custom, "");
    try std.testing.expectEqual(Step.model, step);
    step = nextStep(step, custom, "my-model");
    try std.testing.expectEqual(Step.confirm, step);
    step = nextStep(step, custom, "my-model");
    try std.testing.expectEqual(Step.done, step);

    const ollama = catalog[catalogIndex("Ollama")];
    step = .provider;
    step = nextStep(step, ollama, "");
    try std.testing.expectEqual(Step.url, step);
    step = nextStep(step, ollama, "");
    try std.testing.expectEqual(Step.model, step);

    const anthropic = catalog[0];
    step = .provider;
    step = nextStep(step, anthropic, "");
    try std.testing.expectEqual(Step.key, step);
    step = nextStep(step, anthropic, "");
    try std.testing.expectEqual(Step.model, step);
}

test "vision step appears only for free-text ids on catalogued providers" {
    const anthropic = catalog[0];
    var step: Step = nextStep(.model, anthropic, "claude-whatever");
    try std.testing.expectEqual(Step.vision, step);
    try std.testing.expectEqual(Step.confirm, nextStep(step, anthropic, "claude-whatever"));

    step = nextStep(.model, anthropic, anthropic.models[0].name);
    try std.testing.expectEqual(Step.confirm, step);

    const openrouter = catalog[catalogIndex("OpenRouter")];
    step = nextStep(.model, openrouter, "any-model");
    try std.testing.expectEqual(Step.confirm, step);

    const custom = catalog[catalogIndex("Custom endpoint")];
    step = nextStep(.model, custom, "my-model");
    try std.testing.expectEqual(Step.confirm, step);
}

test "modelIsCurated matches catalogue names only" {
    const anthropic = catalog[0];
    try std.testing.expect(modelIsCurated(anthropic, anthropic.models[1].name));
    try std.testing.expect(!modelIsCurated(anthropic, "claude-whatever"));
}

test "vision override wins over catalogue detection" {
    var w = Wizard{};
    w.provider_index = catalogIndex("Anthropic");
    w.step = .vision;
    w.list_selected = 1;
    w.moveCursor(-1);
    try std.testing.expect(w.vision_override.?);
    try std.testing.expect(w.selection().?.vision);
    w.moveCursor(1);
    try std.testing.expect(!w.vision_override.?);
    try std.testing.expect(!w.selection().?.vision);
}

test "selectModel matches curated entries and falls back to free text" {
    const anthropic = catalog[0];
    const curated = selectModel(anthropic, anthropic.models[0].name);
    try std.testing.expectEqualStrings(anthropic.models[0].name, curated.name);
    try std.testing.expect(curated.vision);

    const free = selectModel(anthropic, "claude-whatever");
    try std.testing.expectEqualStrings("claude-whatever", free.name);
    try std.testing.expect(!free.vision);

    const opencode = catalog[catalogIndex("opencode go")];
    try std.testing.expect(selectModel(opencode, "glm-5.3-flash").replay_reasoning);
    try std.testing.expect(selectModel(opencode, "qwen3.8-flash").replay_reasoning);
    try std.testing.expect(!selectModel(opencode, "unlisted-model").replay_reasoning);
}

test "writer rejects quote in model and leaves provider.lua untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const selection = Selection{
        .entry = catalog[0],
        .provider_type = catalog[0].provider_type,
        .url = catalog[0].default_url,
        .key = "sk-ant-secret",
        .model = "evil\"os.execute('pwn')",
        .vision = true,
    };
    try std.testing.expect(!freeTextFieldIsSafe(selection.model));
    try std.testing.expectError(error.WizardTextUnsafe, writeProviderLua(std.testing.io, tmp.dir, std.testing.allocator, selection));

    const stat = tmp.dir.statFile(std.testing.io, PROVIDER_LUA, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}

test "written provider.lua is owner-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeProviderLua(std.testing.io, tmp.dir, std.testing.allocator, .{
        .entry = catalog[0],
        .provider_type = catalog[0].provider_type,
        .url = catalog[0].default_url,
        .key = "sk-ant-secret",
        .model = catalog[0].models[0].name,
        .vision = true,
    });

    const stat = try tmp.dir.statFile(std.testing.io, PROVIDER_LUA, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "default config loads without provider.lua and binds on require success" {
    const c = root.c;
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    var tracker = TestTracker{};

    c.lua_createtable(L, 0, 0);
    c.lua_setglobal(L, "blitz");
    _ = c.lua_getglobal(L, "blitz");
    registerStub(L, &tracker, "add_provider", &addProviderStub);
    registerStub(L, &tracker, "add_model", &addModelStub);
    registerStub(L, &tracker, "set_agent_model", &setModelAgentStub);
    c.lua_pop(L, 1);

    try execTestLua(L, stubBlitzPrelude);
    try execTestLua(L, defaultConfigLua());

    try std.testing.expectEqual(@as(i64, 0), tracker.model_handle);
    try std.testing.expectEqual(@as(i64, 0), tracker.bound_model);

    try execTestLua(L, "package.preload[\"provider\"] = function() return {} end\n");
    try execTestLua(L, defaultConfigLua());

    try std.testing.expectEqual(@as(i64, 0), tracker.bound_model);

    try execTestLua(L, "package.loaded[\"provider\"] = nil package.preload[\"provider\"] = function() return 77 end\n");
    try execTestLua(L, defaultConfigLua());

    try std.testing.expectEqual(@as(i64, 77), tracker.bound_model);
    try std.testing.expectEqual(@as(i64, 1), tracker.bound_agent);
    try std.testing.expectEqualStrings("max", tracker.bound_effort[0..tracker.bound_effort_len]);
}

fn execTestLua(L: ?*root.c.lua_State, code: []const u8) !void {
    if (root.c.luaL_loadbufferx(L, code.ptr, code.len, "chunk", null) != 0) return error.LuaLoadFailed;
    if (root.c.lua_pcallk(L, 0, root.c.LUA_MULTRET, 0, 0, null) != 0) return error.LuaExecFailed;
}

fn registerStub(state: ?*root.c.lua_State, tracker: *TestTracker, comptime name: [:0]const u8, comptime stub: *const fn (?*root.c.lua_State) callconv(.c) c_int) void {
    const L = state;
    root.c.lua_pushlightuserdata(L, @ptrCast(tracker));
    root.c.lua_pushcclosure(L, stub, 1);
    root.c.lua_setfield(L, -2, name.ptr);
}
