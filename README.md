# [WIP] Blitzdenk

Interactive multi purpose personal AI Tui, similar to tools like `opencode` or `claudecode`.

The goal is to replace web search, help with bug analysis and perform coding tasks with little to
no friction from idea to keyboard to answer.

Supports all common AI-APIs that can handle tool calls.

## Dependencies

I am lazy, thus I rely on proofen posix tools to do my bidding.

These CLI tools should be available on the target system:

- ripgrep (rg)
- ls
- cat
- tail
- head

## Configuration

All API keys are read from the your environment.

The configuration file for colors and available models is under:

`~/.cache/blitzdenk/denk.toml`

All sessions are saved on exit as json, identified by the project cwd in:

`~/.cache/blitzdenk/sessions/`

They restore, until the user creates a new one

## Neovim quick access split

```lua
vim.keymap.set("n", "<leader>o", "vplit | terminal blitzdenk", { silent = true });
```

## Keymap

| keybind     | action         |
| ----------- | -------------- |
| alt + enter | send prompt    |
| ctrl + k    | select model   |
| ctrl + n    | new session    |
| ctrl + y    | accept         |
| ctrl + x    | decline        |
| up/down     | scroll up/down |
