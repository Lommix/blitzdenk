# Blitzdenk

Coding and research harness for posix systems. No dependencies, just Zig and vendored Lua.
Configure, override and extend in Lua. Single binary, no supply chain, bare metal.

![screenshot](docs/assets/screen.jpg)

## Core features and patterns

- All IO goes through GNU core utils (ls, tee, cat, etc.)
- Optional SSH layer: Since all IO goes through core utils, slapping SSH in front is free.
- Small: 5MB native binary, less than 200MB ram usage.
- MCP, LSP and Skill support.
- Multi-provider: Any OpenAI or Anthropic chat schema supported, including local AI.
- LuaApi: Code your own tools, system prompts, modes, commands and loops.

## Install

You can download the pre compiled binaries from [the release page](https://github.com/Lommix/blitzdenk/releases) or build it yourself:

```
zig build --release=small
cp zig-out/bin/blitz ~/.local/bin/blitz
```

## Documentation

[checkout the github pages 'getting started' and examples](https://lommix.github.io/blitzdenk/)

[or take a look at my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua).

## Contribution

No issue no merge. Open source, restricted contribution. Simple bug fixes are welcome.
