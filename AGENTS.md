## Project Blitzdenk

A coding harness written in Zig with vendored Lua.

Zig version: 0.16

Important modules:

- `sdk/` the blitz-sdk ai provider library
- `src/main.zig` control flow
- `src/app.zig` main tui state and render
- `src/tui` tui lib and common widgets
- `src/tools` agent tool definitions
- `src/lua.zig` the lua bindings, big file
- `src/mcp.zig` the mcp api and tools.
- `src/context_factory.zig` agent and prompt configuration
- `src/skills.zig` skill loading and management
- `src/exec.zig` shell wrapper
- `src/keys.zig` key bindings
- `src/models.zig` model config
- `src/agent.zig` the agent state
- `src/agent_registry.zig` state management for many agents
- `src/commands.zig` async command queue.
- `src/inject.zig` agent status injections
- `src/session.zig` save/load session state
- `src/compact.zig` chat compaction logic
- `src/events.zig` exposed hooks
- `src/defaults.zig` default config building

## Commands

- `zig build gen` generate the lua meta file `src/blitz_defs.lua`
- `make test` run the full test suit.

## RULES

- Do not write comments!
- Keep the user space blitzdenk skill up to date! (`src/skills/blitzdenk-lua.md`)
- run `zig fmt` after editing files.
