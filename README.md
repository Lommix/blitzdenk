# Blitzdenk

Coding and research harness for posix systems. No dependencies, just Zig and vendored Lua.
Configure, override and extend in Lua. Single binary, no supply chain, bare metal.

![screenshot](docs/assets/screen.jpg)

## Core features and patterns

- All IO goes through GNU core utils (ls, tee, cat, etc.)
- Optional SSH layer: Since IO is core utils, slapping SSH in front is free.
- Small: 5MB native binary, less than 200MB ram usage.
- MCP, LSP and Skill support.
- Multi-provider: Any OpenAI or Anthropic chat/response schema supported, including local AI.
- LuaApi: Code your own tools, system prompts, modes, commands and loops.

## Install

You can download the pre compiled binaries from [the release page](https://github.com/Lommix/blitzdenk/releases) or build it yourself:

```
zig build --release=small
cp zig-out/bin/blitz ~/.local/bin/blitz
```

## Minimal configuration

Open the blitz.lua configuration at `~/.config/blitzdenk/blitz.lua`
Setup at least on provider. The **key_envar** is not the API key! It's the environment var holding your key.

```lua
local anthropic = blitz.add_provider({
	type = "anthropic",
	url = "https://api.anthropic.com/v1/",
	key_envar = "CLAUDE_API_KEY",
	max_tokens = 32000,
	temperature = 1,
})

local llama = blitz.add_provider({
	type = "openai",
	url = "http://127.0.0.1:8118",
	key_envar = "",
	max_tokens = 32000,
})

local novita = blitz.add_provider({
	type = "openai",
	url = "https://api.novita.ai/openai/v1",
	key_envar = "NOVITA_API_KEY",
	temperature = 1,
	max_tokens = 32000,
})

local openrouter = blitz.add_provider({
	type = "openai",
	url = "https://openrouter.ai/api/v1",
	key_envar = "OPENROUTER_API_KEY",
	temperature = 1,
	max_tokens = 32000,
})

local xai = blitz.add_provider({
	type = "response",
	url = "https://api.x.ai/v1",
	key_envar = "XAI_API_KEY",
	temperature = 1,
	max_tokens = 32000,
})

local openai = blitz.add_provider({
	type = "response",
	url = "https://api.openai.com/v1",
	key_envar = "OPENAI_API_KEY",
	max_tokens = 32000,
})
```

Then set a default model to use, or specify which agent should use which model

```lua
blitz.set_model("gpt-5.4-mini", openai)
blitz.set_model_agent(blitz.AGENT_GENERAL, "deepseek/deepseek-v4-pro", "max", novita)
```

## Documentation

[checkout the github pages 'getting started' and examples](https://lommix.github.io/blitzdenk/)

[or take a look at my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua).

## Contribution

No issue no merge. Open source, restricted contribution. Simple bug fixes are welcome.
