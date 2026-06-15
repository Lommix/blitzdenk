# Blitzdenk

Coding and research Harness. Zero external dependencies. Extendable via Lua.
Zig version: 0.16

User config: '/home/lommix/.config/blitzdenk/blitz.lua'

Modules:

- `src/main.zig` control flow
- `src/app.zig` main tui state and render
- `src/tui` tui lib and common widgets
- `src/tools` agent tool definitions
- `src/provider` core agent framework
- `vendor/lua` vendored lua c files

Lua:

- `src/blitz_default.lua` default lua config template
- `src/blitz_defs.lua` lua meta table for lsp (always keep up to date)
