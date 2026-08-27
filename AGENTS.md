# Project Blitzdenk

A coding harness written in Zig with vendored Lua.

Zig version: 0.16

Important modules:

- `src/root.zig` import hub; everything is reached via the `r.*` namespace
- `sdk/` the blitz-sdk ai provider library
- `vendor/lua` vendored Lua 5.4 C sources, fused into module `c` via translate-c in `build.zig`
- `src/main.zig` control flow, owns the hot-reload loop
- `src/app.zig` main tui state and render, plus live-agent refresh helpers
- `src/tui` tui lib and common widgets
- `src/tools` agent tool definitions
- `src/lua.zig` the lua bindings, big file; the whole `blitz.*` api is one declarative `Blitz` table_def
- `src/mcp.zig` the mcp api and tools.
- `src/context_factory.zig` agent and prompt configuration; system prompt built per configureAgent
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
- `src/defaults.zig` installs default config files into `~/.config/blitzdenk`

## Config and lua data flow

- `zig build gen` regenerates `src/blitz_defs.lua` (type hints + signatures); edit bindings only in `src/lua.zig`
- `~/.config/blitzdenk/meta.lua` is force-overwritten from embedded `blitz_defs.lua` at launch, so it lags until the next binary run
- `~/.config/blitzdenk/blitz.lua` is write-once (`force = false`); upgrades never add new api calls to existing user configs
- Lua-set definitions (prompts, tools, capability rules) are duped into the factory `prompt_arena`; `resetDefs()` clears them on hot reload and the reloaded config reinstalls them
- Binaries for env capability rules resolve once per reload via `sh -c command -v`, cached on the factory; unset fields degrade to embedded defaults
- A repo-root `./blitz.lua` (untracked) registers repo automation tools (`build`, `gen`, `fmt`, `test`, `check`, `zig_run`) used by agents here

## Commands

- `zig build` compile the binary
- `zig build gen` generate the lua meta file `src/blitz_defs.lua`
- `make test` run the full test suit
- `zig fmt src/` required after edits

## RULES

- Do not write comments!
- Keep the user space blitzdenk skill up to date! (`src/skills/blitzdenk-lua.md`)
- run `zig fmt` after editing files.
