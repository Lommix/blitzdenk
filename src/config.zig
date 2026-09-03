const std = @import("std");
const models = @import("models");
const sdk = @import("blitz-sdk");

pub const MAX_PROVIDERS = 16;
pub const MAX_MODELS = 16;
pub const ProviderHandle = enum(u32) { _ };
pub const ModelHandle = enum(u32) { _ };
pub const ReasoningEffort = models.ReasoningEffort;

pub const parseReasoningEffort = models.parseReasoningEffort;

pub const Provider = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    key_envar: [128]u8 = undefined,
    key_envar_len: usize = 0,
    key: [256]u8 = undefined,
    key_len: usize = 0,
    provider_config: models.ProviderOptions = .{ .openai = .{} },
    thinking_type_buf: [16]u8 = undefined,
    thinking_type_len: usize = 0,
    session_key_header_buf: [128]u8 = undefined,
    session_key_header_len: usize = 0,
    rate_limit: u32 = 0,
    active: bool = false,

    pub fn getUrl(self: *const Provider) []const u8 {
        return self.url[0..self.url_len];
    }

    pub fn getKeyEnvar(self: *const Provider) []const u8 {
        return self.key_envar[0..self.key_envar_len];
    }

    pub fn getKey(self: *const Provider) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn resolveKey(self: *const Provider, env: *const std.process.Environ.Map) []const u8 {
        const envar_name = self.getKeyEnvar();
        if (envar_name.len > 0) {
            if (env.get(envar_name)) |from_envar| return from_envar;
        }
        return self.getKey();
    }

    pub fn setThinkingType(self: *Provider, value: []const u8) bool {
        if (value.len > self.thinking_type_buf.len) return false;
        @memcpy(self.thinking_type_buf[0..value.len], value);
        self.thinking_type_len = value.len;
        return true;
    }

    pub fn getThinkingType(self: *const Provider) []const u8 {
        return self.thinking_type_buf[0..self.thinking_type_len];
    }

    pub fn setSessionKeyHeader(self: *Provider, value: []const u8) bool {
        if (value.len > self.session_key_header_buf.len) return false;
        @memcpy(self.session_key_header_buf[0..value.len], value);
        self.session_key_header_len = value.len;
        return true;
    }

    pub fn getSessionKeyHeader(self: *const Provider) []const u8 {
        return self.session_key_header_buf[0..self.session_key_header_len];
    }
};

pub const ModelCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache: f64 = 0,
};

pub const ModelEntry = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    provider: ProviderHandle = @enumFromInt(0),
    vision: bool = false,
    replay_reasoning: bool = false,
    cost: ?ModelCost = null,

    pub fn getName(self: *const ModelEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const BlitzdenkCfg = struct {
    providers: [MAX_PROVIDERS]Provider = @splat(.{}),
    provider_count: u32 = 0,
    models: [MAX_MODELS]ModelEntry = @splat(.{}),
    model_count: u32 = 0,

    pub fn reserveProvider(self: *BlitzdenkCfg, url: []const u8, key_envar: []const u8, key: []const u8) ?*Provider {
        if (self.provider_count >= MAX_PROVIDERS) return null;
        if (url.len > 512 or key_envar.len > 128 or key.len > 256) return null;
        const slot = &self.providers[self.provider_count];
        slot.* = .{};
        @memcpy(slot.url[0..url.len], url);
        slot.url_len = url.len;
        @memcpy(slot.key_envar[0..key_envar.len], key_envar);
        slot.key_envar_len = key_envar.len;
        @memcpy(slot.key[0..key.len], key);
        slot.key_len = key.len;
        return slot;
    }

    pub fn commitProvider(self: *BlitzdenkCfg) ProviderHandle {
        const handle: ProviderHandle = @enumFromInt(self.provider_count);
        self.providers[self.provider_count].active = true;
        self.provider_count += 1;
        return handle;
    }

    pub fn getProvider(self: *const BlitzdenkCfg, handle: ProviderHandle) ?*const Provider {
        const index = @intFromEnum(handle);
        if (index >= self.provider_count or !self.providers[index].active) return null;
        return &self.providers[index];
    }

    pub fn addModel(self: *BlitzdenkCfg, name: []const u8, provider: ProviderHandle, vision: bool, replay_reasoning: bool, cost: ?ModelCost) !ModelHandle {
        if (self.model_count >= MAX_MODELS) return error.MaxModelsReached;
        const provider_idx = @intFromEnum(provider);
        if (provider_idx >= self.provider_count or !self.providers[provider_idx].active) return error.UnknownProvider;
        if (name.len > 256) return error.NameTooLong;
        const slot = &self.models[self.model_count];
        slot.* = .{};
        @memcpy(slot.name[0..name.len], name);
        slot.name_len = name.len;
        slot.provider = provider;
        slot.vision = vision;
        slot.replay_reasoning = replay_reasoning;
        slot.cost = cost;
        self.model_count += 1;
        return @enumFromInt(self.model_count - 1);
    }

    pub fn getModel(self: *const BlitzdenkCfg, handle: ModelHandle) ?*const ModelEntry {
        const index = @intFromEnum(handle);
        if (index >= self.model_count) return null;
        return &self.models[index];
    }

    pub fn modelCost(self: *const BlitzdenkCfg, name: []const u8, usage: sdk.Usage) f64 {
        for (self.models[0..self.model_count]) |*model| {
            const cost = model.cost orelse continue;
            if (!std.mem.eql(u8, model.getName(), name)) continue;
            return (@as(f64, @floatFromInt(usage.input_tokens)) / 1e6) * cost.input +
                (@as(f64, @floatFromInt(usage.output_tokens)) / 1e6) * cost.output +
                (@as(f64, @floatFromInt(usage.cache_read_tokens)) / 1e6) * cost.cache;
        }
        return 0;
    }

    pub fn reset(self: *BlitzdenkCfg) void {
        self.providers = @splat(.{});
        self.provider_count = 0;
        self.models = @splat(.{});
        self.model_count = 0;
    }
};

test "parse reasoning effort" {
    try std.testing.expectEqual(.xhigh, parseReasoningEffort("xhigh"));
    try std.testing.expectEqual(.medium, parseReasoningEffort("medium"));
    try std.testing.expectEqual(null, parseReasoningEffort("bogus"));
    inline for (std.meta.fields(ReasoningEffort)) |field| {
        try std.testing.expectEqualStrings(field.name, @tagName(@field(ReasoningEffort, field.name)));
        try std.testing.expect(parseReasoningEffort(field.name) != null);
    }
}

test "provider uses the stored key when the envar is absent" {
    var cfg: BlitzdenkCfg = .{};
    const provider = cfg.reserveProvider("https://example.test/v1", "EXAMPLE_API_KEY", "stored-key").?;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("stored-key", provider.resolveKey(&env));
}

test "provider prefers the envar value over the stored key" {
    var cfg: BlitzdenkCfg = .{};
    const provider = cfg.reserveProvider("https://example.test/v1", "EXAMPLE_API_KEY", "stored-key").?;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EXAMPLE_API_KEY", "envar-key");
    try std.testing.expectEqualStrings("envar-key", provider.resolveKey(&env));
}

test "provider resolves to an empty key when both sources are empty" {
    var cfg: BlitzdenkCfg = .{};
    const provider = cfg.reserveProvider("http://localhost:8080/v1", "", "").?;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("", provider.resolveKey(&env));
}

test "reserveProvider rejects an oversize key" {
    var cfg: BlitzdenkCfg = .{};
    try std.testing.expect(cfg.reserveProvider("https://example.test/v1", "EXAMPLE_API_KEY", "k" ** 256) != null);
    try std.testing.expect(cfg.reserveProvider("https://example.test/v1", "EXAMPLE_API_KEY", "k" ** 257) == null);
}
