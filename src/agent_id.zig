
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
