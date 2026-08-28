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

## Run event flow

- sdk `streamText` → `RunTask` queues `Event`s (text/reasoning/tool/tool_done/step/provider_error/complete/failed) → `registry.drain` → both `Agent.observe` (activity/usage/status) and app `applyRunEvent` (chat render)
- `Agent.activity` is event-derived only; `startModel` and `.step` reset it to `thinking`, so silent steps fall back to `thinking` not the previous state
- chat-completions providers emit `tool_call_streaming_start`/`tool_call_delta` live; the responses provider aggregates tool calls and emits `.tool_call` only after the SSE stream ends
- app preview renders only `chunk.type == .tool_call`; activity updates consume all tool chunk types

## Config and lua data flow

- `zig build gen` regenerates `src/meta.lua` (type hints + signatures); edit bindings only in `src/lua.zig`
- `~/.config/blitzdenk/meta.lua` is force-overwritten from embedded `src/meta.lua` at launch, so it lags until the next binary run
- `~/.config/blitzdenk/blitz.lua` is write-once (`force = false`); upgrades never add new api calls to existing user configs
- Lua-set definitions (prompts, tools, capability rules) are duped into the factory `prompt_arena`; `resetDefs()` clears them on hot reload and the reloaded config reinstalls them
- In Lua an agent id is one packed integer (`AgentId.pack()`), used by `spawn_agent` returns, `cancel_agent`, `message_agent`, `await_agent`, event payloads, and the `agent` tool result string `agent_id: <int>`
- `pushAny`/`readAnyValueAlloc` marshal Zig↔Lua; the packed-struct branch is gated to `T == r.AgentId` — widening it to all packed structs breaks the `get_flags`/`set_flags` `AppFlags` table roundtrip
- `pushAgentId`/`readAgentIdArg` convert ids at the trust boundary; `readAgentIdArg` range-checks before `@intCast` since Lua integers are 64-bit
- `isToolVm(state)` guard blocks `cmd.*` calls from tool VMs

## Commands

- `zig build` compile the binary
- `zig build gen` generate the lua meta file `src/meta.lua`
- `make test` run the repo suite (`zig build test --summary all --error-style minimal`)
- `cd sdk && zig build test` run the sdk suite separately
- tests are in-file `test` blocks at the bottom of each module
- ALWAYS run tests with `timeout -s KILL <s>`; a looping test once filled memory until OOM
- `zig fmt src/` required after edits
- command pattern: Lua binding validates and `cmd_queue.append`s (deep-clones into the queue arena), `Command.execute` runs on the app thread; handlers silently no-op on dead agent ids
- spawn only reserves a registry slot (`.reserved`); activation happens when the queue drains, so a fresh id is not yet `registry.get`-able

## Agent ids across save/restore

- `registry.reserve()` bumps a slot's generation; restored chat entries stamped with an old id fail the renderer's generation gate, so anything persisted with an `AgentId` must be re-keyed after load (see `session.zig` `applySaveState` `main_agent` remap)
- renderer tool-status lookup is keyed on `call.agent_id` pack + generation (`app.zig` render path); `App.setToolStatus`/`setToolChild` reset per-slot generation, which re-arms stale child ids

## Zig 0.16 traps (all hit this codebase)

- `std.json.parseFromSliceLeaky` default `.alloc_if_needed` returns string slices INTO the input slice; if the input is a reused buffer the parsed values alias freed/recycled memory — either give each line a fresh arena-allocated buffer (never free it; arena drop frees) or deep-clone
- arena `free` of the last allocation rewinds; freeing a per-iteration buffer lets the next iteration reuse memory under live parsed slices — leak it into the arena instead
- `Writer.Allocating.written()` is not freeable; return `toOwnedSlice()` if the caller frees
- `Io.Reader.discardDelimiterExclusive` can toss 0 bytes (delimiter at position 0) → zero loop progress → infinite loop; use `discardDelimiterInclusive` (consumes delimiter, ≥1 byte) and `catch break` on EOF
- `std.posix.chdir` doesn't exist → `std.c.chdir` (needs `-lc`); `Dir.cwd().realPath` fails FileNotFound on Linux → use `realPathFile(io, ".")`
- tests can't `zig test` a file with module imports; use `zig build test` (build.zig wires `blitz-sdk`, `agent-id`, etc.)
- `File.mtime.nanoseconds` is i96 Unix ns → `.toMilliseconds()`; `statFile` on a not-yet-created dir errors FileNotFound (create path first)

## RULES

- Keep the user space blitzdenk skill up to date! `src/skills/blitzdenk-lua.md`
