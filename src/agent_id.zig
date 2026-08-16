const std = @import("std");

pub const max_agents = 128;

pub const AgentId = packed struct {
    index: u16,
    generation: u16,

    pub fn pack(self: AgentId) u32 {
        return @bitCast(self);
    }

    pub fn unpack(value: u32) AgentId {
        return @bitCast(value);
    }
};

test "agent IDs preserve their Lua-compatible packed form" {
    const id = AgentId{ .index = 7, .generation = 12 };
    try std.testing.expectEqual(id, AgentId.unpack(id.pack()));
}
