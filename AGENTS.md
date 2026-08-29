# Project Blitzdenk

A coding harness written in Zig with vendored Lua.
Zig version: 0.16

Important modules:

- `src/root.zig` import hub; everything is reached via the `r.*` namespace
- `src/agent_id.zig` `AgentId` packed struct `{index: u16, generation: u16}`; `pack()`/`unpack()` bitcast to u32
- `src/main.zig` control flow, owns the hot-reload loop
- `src/app.zig` main tui state and render; `applyRunEvent` turns stream events into chat preview
- `src/tui` tui lib and common widgets
- `src/tools` agent tool definitions
- `src/lua.zig` the lua bindings, big file; the whole `blitz.*` api is one declarative `Blitz` table_def
- `src/mcp.zig` the mcp api and tools.
- `src/context_factory.zig` agent and prompt configuration; system prompt built per configureAgent
- `src/skills.zig` skill loading and management
- `src/exec.zig` shell wrapper
- `src/keys.zig` key bindings
- `src/models.zig` model config; `Model` union over provider kinds ollama/openai/response/anthropic
- `src/agent.zig` the agent state; `Activity` enum and `observe()` derive status/stream state
- `src/agent_run.zig` run task + event queue bridging sdk streams to observers
- `src/agent_registry.zig` state management for many agents; `drain()` fans events out
- `src/commands.zig` async command queue.
- `src/inject.zig` agent status injections
- `src/session.zig` save/load session state; `SaveState`/`WireToolStatus` shared by store checkpoint and `blitz continue`
- `src/session_store.zig` JSONL session journals in `~/.cache/blitzdenk/<fnv1a64-of-cwd>/sessions/<id>.jsonl` (header + full-snapshot checkpoints, cap 4, tmp+rename compaction, GC >16d); `blitz continue [ID]`, `blitz sessions` (TUI session picker over `summaries()` rows; widget state in `src/session_picker.zig`, rendered like the wizard) and the exit hint in `main.zig` use it; debug.log also lives in `~/.cache/blitzdenk`; `cacheDir()` honors `XDG_CACHE_HOME` over `~/.cache`
- `src/compact.zig` chat compaction logic
- `src/events.zig` exposed hooks
- `src/defaults.zig` installs default config files into `~/.config/blitzdenk`
- `sdk/` the blitz-sdk ai provider library
- `sdk/src/provider/` one file per provider: `openai.zig` chat completions, `responses.zig` Responses API, `anthropic.zig`, `compat.zig`; `jsonx.zig` http + SSE plumbing

## Commands

- `zig build` compile the binary
- `zig build gen` generate the lua meta file `src/meta.lua`
- `make test` run the blitzdenk suite

## Zig 0.16 traps

- `std.json.parseFromSliceLeaky` default `.alloc_if_needed` returns string slices INTO the input slice; if the input is a reused buffer the parsed values alias freed/recycled memory — either give each line a fresh arena-allocated buffer (never free it; arena drop frees) or deep-clone
- arena `free` of the last allocation rewinds; freeing a per-iteration buffer lets the next iteration reuse memory under live parsed slices — leak it into the arena instead
- `Writer.Allocating.written()` is not freeable; return `toOwnedSlice()` if the caller frees
- `Io.Reader.discardDelimiterExclusive` can toss 0 bytes (delimiter at position 0) → zero loop progress → infinite loop; use `discardDelimiterInclusive` (consumes delimiter, ≥1 byte) and `catch break` on EOF
- `std.posix.chdir` doesn't exist → `std.c.chdir` (needs `-lc`); `Dir.cwd().realPath` fails FileNotFound on Linux → use `realPathFile(io, ".")`
- tests can't `zig test` a file with module imports; use `zig build test` (build.zig wires `blitz-sdk`, `agent-id`, etc.)
- `File.mtime.nanoseconds` is i96 Unix ns → `.toMilliseconds()`; `statFile` on a not-yet-created dir errors FileNotFound (create path first)

## RULES

- Keep the user space blitzdenk skill up to date (`src/skills/blitzdenk-lua.md`). Prose, direct, raw statements. No obvious facts that can re researched in the `meta.lua`
