# Project Blitzdenk

A coding harness written in Zig with vendored Lua, no dependencies.

Zig version: 0.17.0

## Commands

- `zig build` compile the binary
- `zig build gen` generate the lua meta file `src/meta.lua`
- `make test` run the blitzdenk suite
- `make check` verify formatting, generated meta, and tests

## Sub-agent flow

- Reserve, spawn, state: `src/agent_registry.zig`, `src/commands.zig`
- Run loop: `src/agent.zig`, `src/agent_run.zig`
- Result injection into the parent: `App.finishBackgroundAgent` in `src/app.zig`
- Lua surface: `src/lua.zig`, `src/blitz_default.lua`
- Tui state and render: `src/app.zig`
-

## RULES

- No comments and no Doc comments!

## The skill file: blitzdenk-lua.md

- Keep up to date with changes.
- Short concise prose.
- Scope is Lua and Lua only! Zig internals are irrelevant.
- Don't include facts easily covered by meta.lua
