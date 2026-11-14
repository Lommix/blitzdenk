# Blitzdenk

A minimal self improving coding harness for POSIX. No dependencies, vendored Lua.
Ships as a single <2MB binary using less then 99MB of ram.

![demo](docs/assets/screenshot.png)

```shell
curl -fsSL https://raw.githubusercontent.com/Lommix/blitzdenk/master/install.sh | sh
```

## Core features and patterns

- Tiny system prompt, minimal tool descriptions. Simple is efficient.
- Durable multi agent sessions. Nothing is ever lost, always recover.
- File tools use direct file system calls. No helper processes.
- MCP and Skill support (including remote mcp with oauth)
- Multi-provider: any OpenAI or Anthropic chat/response schema supported, including local AI.
- Image and mermaid diagram render in tui.
- Hot reload: Agents can extend themself and debug what at the same time.
- Version management: run `blitz update` on new releases. (pulls release bin from github)
- Sessions management per project: `blitz continue <?session_id>` resumes, `blitz sessions` list all
- Render custom widgets from Lua

## Plugins

Blitzdenk offers a Neovim like plugin API, where plugins are just git repositories.

```lua
blitz.plugin("blitz-core", { url = "https://github.com/Lommix/blitz-core" })
local core = require("blitz-core")

blitz.set_agent_tools(blitz.AGENT_GENERAL, {
    ...
	core.codemode,
	core.subagents.toolset,
	core.todo.toolset,
})
```

## About

Blitzdenk is my personal harness following my needs and my vision. The target is to become the neovim
of harnesses. Durable base with a rich Lua-API to extend in all directions. I want to able to iterate fast,
change and customize any detail.

## Build

You can also download the pre compiled binaries for your system on [the release page](https://github.com/Lommix/blitzdenk/releases)
or build yourself:

```
zig build --release=small
cp zig-out/bin/blitz ~/.local/bin/blitz
```

## Minimal configuration

Open the blitz.lua configuration at `~/.config/blitzdenk/blitz.lua` or in pwd `./blitz.lua`
Setup at least on provider. The **key_envar** is not the API key! It's the environment var holding your key.

```lua
local opencode = blitz.add_provider({
	type = "openai",
	url = "https://opencode.ai/zen/go/v1",
	key_envar = "OPENCODE_API_KEY",
	session_key_header = "x-opencode-session",
    -- key = "..." -- or
})

local opencode_ds_flash = blitz.add_model({
	name = "deepseek-flash",
	provider = opencode,
	vision = true,
	cost = { input = 0.15, output = 0.6, cache = 0.006 },
})

blitz.set_agent_model(blitz.AGENT_GENERAL, opencode_ds_flash)
blitz.set_agent_effort(blitz.AGENT_GENERAL, "high")
```

## Documentation

Ask the agent, once the provider is set up. The `blitzdenk-lua.md` skill contains all information required.
[or take a look at my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua).
