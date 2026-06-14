# Blitzdenk

Coding and research harness for posix systems. No dependencies, just Zig and vendored Lua.
Configure, override and extend in Lua.

![screenshot](docs/screen.jpg)

## Core features and patterns

- All IO goes through GNU core utils (ls, tee, cat, etc.)
- Enables an invisible SSH layer that agents can pipe through.
- Small: 5MB native binary, less than 200MB ram usage.
- Doc Linking and Skill support.
- MCP support
- Multi-provider: Any OpenAI or Anthropic chat schema supported. Includes local AI.
- Customize in Lua. Code your own tools, system prompts, modes, commands and loops.

## Configuration in Lua

There are no official docs yet. Checkout the provided [lua meta file](./src/blitz_defs.lua) for all available bindings.

You can also look at [my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua), which covers at least one example per use case.

## Install

You need the Zig 0.16 compiler.

```
zig build --release=small
cp zig-out/bin/blitz ~/.local/bin/blitz
```

## SSH mode

Enables ssh layer all agent commands are piped through

`:ssh username@host:/path/to/cwd`

You'd better know what you're doing. If you delete something important, let me know in an issue, so I may laugh at you.

## Neovim integration

Sometimes I just want quick Info about something on in my current file. For this I have the following Neovim bind:

```lua
vim.keymap.set("n", "<leader>o", function()
	local fname = vim.fn.expand("%:p")
	local lineno = vim.fn.line(".")
	vim.cmd('vsplit | terminal blitz prompt "' .. fname .. ":" .. lineno .. ' " --log')
end, { silent = true })
```
