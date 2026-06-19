const std = @import("std");
const adapter = @import("adapter.zig");

pub const MAX_PROVIDERS = 16;
pub const ProviderHandle = enum(u32) { _ };
pub const ReasoningEffort = adapter.ReasoningEffort;

pub fn parseReasoningEffort(value: []const u8) ?ReasoningEffort {
    return std.meta.stringToEnum(ReasoningEffort, value);
}

pub const Provider = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    key_envar: [128]u8 = undefined,
    key_len: usize = 0,
    provider_config: adapter.ProviderConfig = .{ .openai = .{} },
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

    pub fn setThinkingType(self: *Provider, s: []const u8) bool {
        if (s.len > self.thinking_type_buf.len) return false;
        @memcpy(self.thinking_type_buf[0..s.len], s);
        self.thinking_type_len = s.len;
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

pub const MAX_DOCS = 32;

pub const PathEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    description: [256]u8 = undefined,
    desc_len: usize = 0,
    location: [512]u8 = undefined,
    loc_len: usize = 0,

    pub fn getName(self: *const PathEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn getDescription(self: *const PathEntry) []const u8 {
        return self.description[0..self.desc_len];
    }
    pub fn getLocation(self: *const PathEntry) []const u8 {
        return self.location[0..self.loc_len];
    }
};

// TODO: This should not live in the provider module
pub const BlitzdenkCfg = struct {
    providers: [MAX_PROVIDERS]Provider = @splat(.{}),
    provider_count: u32 = 0,

    default_model: ModelEntry = .{},

    doc_entries: [MAX_DOCS]PathEntry = @splat(.{}),
    doc_count: u32 = 0,

    /// Reserve the next provider slot. Caller fills url/key_envar/provider_config
    /// (including the inline buffer for thinking.type) then calls
    /// commitProvider to activate it. Returns null if the slot cap is reached or
    /// url/key_envar exceed their buffers.
    pub fn reserveProvider(
        self: *BlitzdenkCfg,
        url: []const u8,
        key_envar: []const u8,
    ) ?*Provider {
        if (self.provider_count >= MAX_PROVIDERS) return null;
        if (url.len > 512 or key_envar.len > 128) return null;

        var slot = &self.providers[self.provider_count];
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
        const idx = @intFromEnum(handle);
        if (idx >= self.provider_count or !self.providers[idx].active) return false;
        if (name.len > 256) return false;

        const entry = &self.default_model;
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        entry.provider = handle;
        entry.bound = true;
        return true;
    }

    pub fn buildConfig(self: *const BlitzdenkCfg, env: *const std.process.Environ.Map) ?adapter.Config {
        const entry = &self.default_model;
        if (!entry.bound) return null;

        const idx = @intFromEnum(entry.provider);
        if (idx >= self.provider_count) return null;
        const prov = &self.providers[idx];
        if (!prov.active) return null;

        const key = if (prov.key_len > 0)
            env.get(prov.getKeyEnvar()) orelse return null
        else
            "";

        return .{
            .api_key = key,
            .model = entry.getName(),
            .base_url = prov.getUrl(),
            .reasoning_effort = prov.reasoning_effort,
            .provider = prov.provider_config,
        };
    }

    pub fn addDoc(self: *BlitzdenkCfg, name: []const u8, desc: []const u8, location: []const u8) bool {
        if (self.doc_count >= MAX_DOCS) return false;
        if (name.len > 128 or desc.len > 256 or location.len > 512) return false;
        var slot = &self.doc_entries[self.doc_count];
        @memcpy(slot.name[0..name.len], name);
        slot.name_len = name.len;
        @memcpy(slot.description[0..desc.len], desc);
        slot.desc_len = desc.len;
        @memcpy(slot.location[0..location.len], location);
        slot.loc_len = location.len;
        self.doc_count += 1;
        return true;
    }


    pub fn resetProviders(self: *BlitzdenkCfg) void {
        self.providers = @splat(.{});
        self.provider_count = 0;
        self.default_model = .{};
        self.doc_entries = @splat(.{});
        self.doc_count = 0;
    }
};

test "parse reasoning effort" {
    try std.testing.expectEqual(.xhigh, parseReasoningEffort("xhigh"));
    try std.testing.expectEqual(null, parseReasoningEffort("medium"));
}
