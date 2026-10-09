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
    kind: models.Kind = .openai,
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

pub const ModelSpec = struct {
    name: []const u8,
    provider: ProviderHandle,
    vision: bool = false,
    replay_reasoning: bool = true,
    reasoning: bool = true,
    params: models.ModelParams = .{ .openai = .{} },
    cost: ?ModelCost = null,
};

pub const ModelEntry = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    provider: ProviderHandle = @enumFromInt(0),
    vision: bool = false,
    replay_reasoning: bool = true,
    reasoning: bool = true,
    params: models.ModelParams = .{ .openai = .{} },
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

    pub fn addModel(self: *BlitzdenkCfg, spec: ModelSpec) !ModelHandle {
        if (self.model_count >= MAX_MODELS) return error.MaxModelsReached;
        const provider_idx = @intFromEnum(spec.provider);
        if (provider_idx >= self.provider_count or !self.providers[provider_idx].active) return error.UnknownProvider;
        if (spec.name.len > 256) return error.NameTooLong;
        const slot = &self.models[self.model_count];
        slot.* = .{};
        @memcpy(slot.name[0..spec.name.len], spec.name);
        slot.name_len = spec.name.len;
        slot.provider = spec.provider;
        slot.vision = spec.vision;
        slot.replay_reasoning = spec.replay_reasoning;
        slot.reasoning = spec.reasoning;
        slot.params = spec.params;
        slot.cost = spec.cost;
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
