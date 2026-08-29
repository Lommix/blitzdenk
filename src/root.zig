pub const VERSION = @import("build_options").version;

pub const sdk = @import("blitz-sdk");
pub const models = @import("models");
pub const config = @import("config.zig");
pub const defaults = @import("defaults.zig");
pub const app = @import("app.zig");
pub const agent = @import("agent.zig");
pub const AgentId = @import("agent-id").AgentId;
pub const agent_state = @import("agent-state");
pub const agent_registry = @import("agent_registry.zig");
pub const agent_run = @import("agent_run.zig");
pub const compact = @import("compact.zig");
pub const exec = @import("exec");
pub const artifact = @import("artifact.zig");
pub const permissions = @import("permissions");
pub const ContextFactory = @import("context_factory.zig");
pub const skills = @import("skills.zig");
pub const session = @import("session.zig");
pub const session_store = @import("session_store.zig");
pub const prompt_history = @import("prompt_history.zig");
pub const session_picker = @import("session_picker.zig");
pub const util = @import("util.zig");
pub const clipboard = @import("clipboard.zig");
pub const keys = @import("keys.zig");
pub const events = @import("events.zig");
pub const lua = @import("lua.zig");
pub const lua_state = @import("lua_state.zig");
pub const mcp = @import("mcp.zig");
pub const tools = @import("tools/root.zig");
pub const tui = @import("tui/root.zig");
pub const cmd = @import("commands.zig");
pub const update = @import("update.zig");
pub const c = @import("c");
pub const inject = @import("inject.zig");
pub const dash = @import("dashboard.zig");
pub const wizard = @import("wizard.zig");
pub const completion = @import("completion.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
