const std = @import("std");
const models = @import("models");

pub const MAX_PROVIDERS = 16;
pub const ProviderHandle = enum(u32) { _ };
pub const ReasoningEffort = models.ReasoningEffort;

pub const parseReasoningEffort = models.parseReasoningEffort;

pub const Provider = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    key_envar: [128]u8 = undefined,
    key_len: usize = 0,
    provider_config: models.ProviderOptions = .{ .openai = .{} },
    thinking_type_buf: [16]u8 = undefined,
    thinking_type_len: usize = 0,
    reasoning_effort: ?ReasoningEffort = null,
    active: bool = false,

    pub fn getUrl(self: *const Provider) []const u8 {
        return self.url[0..self.url_len];
    }

    pub fn getKeyEnvar(self: *const Provider) []const u8 {
        return self.key_envar[0..self.key_len];
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
};

pub const ModelEntry = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    provider: ProviderHandle = @enumFromInt(0),
    bound: bool = false,

    pub fn getName(self: *const ModelEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const BlitzdenkCfg = struct {
    providers: [MAX_PROVIDERS]Provider = @splat(.{}),
    provider_count: u32 = 0,
    default_model: ModelEntry = .{},

    pub fn reserveProvider(self: *BlitzdenkCfg, url: []const u8, key_envar: []const u8) ?*Provider {
        if (self.provider_count >= MAX_PROVIDERS) return null;
        if (url.len > 512 or key_envar.len > 128) return null;
        const slot = &self.providers[self.provider_count];
        slot.* = .{};
        @memcpy(slot.url[0..url.len], url);
        slot.url_len = url.len;
        @memcpy(slot.key_envar[0..key_envar.len], key_envar);
        slot.key_len = key_envar.len;
        return slot;
    }

    pub fn commitProvider(self: *BlitzdenkCfg) ProviderHandle {
        const handle: ProviderHandle = @enumFromInt(self.provider_count);
        self.providers[self.provider_count].active = true;
        self.provider_count += 1;
        return handle;
    }

    pub fn setModel(self: *BlitzdenkCfg, name: []const u8, handle: ProviderHandle) bool {
        const index = @intFromEnum(handle);
        if (index >= self.provider_count or !self.providers[index].active) return false;
        if (name.len > 256) return false;
        const entry = &self.default_model;
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        entry.provider = handle;
        entry.bound = true;
        return true;
    }

    pub fn buildConfig(self: *const BlitzdenkCfg, env: *const std.process.Environ.Map) ?models.Config {
        const entry = &self.default_model;
        if (!entry.bound) return null;
        const index = @intFromEnum(entry.provider);
        if (index >= self.provider_count) return null;
        const provider = &self.providers[index];
        if (!provider.active) return null;
        const key = if (provider.key_len > 0) env.get(provider.getKeyEnvar()) orelse return null else "";
        return .{
            .api_key = key,
            .model = entry.getName(),
            .base_url = provider.getUrl(),
            .reasoning_effort = provider.reasoning_effort,
            .provider = provider.provider_config,
        };
    }

    pub fn resetProviders(self: *BlitzdenkCfg) void {
        self.providers = @splat(.{});
        self.provider_count = 0;
        self.default_model = .{};
    }
};

test "parse reasoning effort" {
    try std.testing.expectEqual(.xhigh, parseReasoningEffort("xhigh"));
    try std.testing.expectEqual(.medium, parseReasoningEffort("medium"));
    try std.testing.expectEqual(null, parseReasoningEffort("bogus"));
}
