# [WIP] Blitzdenk

Interactive multi purpose personal AI Tui, similar to tools like [opencode](https://github.com/sst/opencode) or claudecode.

![blitzdenk](/docs/screenshot.png)

The goal is to replace web search, help with bug analysis and perform coding tasks with little to
no friction from idea to keyboard to answer. It is not a fully autonomous agent. There is a lot of
user control.

Supports all common AI-APIs that can handle tool calls.

## Dependencies

These CLI tools should be available on the target system:

- ripgrep (rg)

## Installation

Standard build.

```
cargo build --release
cp target/release/blitzdenk ~/.local/bin/
```

Or `make install` (same thing)

## Configuration

All API keys are read from the your environment.

```
OPENAI_API_KEY
ANTHROPIC_API_KEY
GEMINI_API_KEY
GROQ_API_KEY
XAI_API_KEY
DEEPSEEK_API_KEY
```

The configuration file for colors and available models is under:

`~/.config/blitzdenk/denk.toml`

You can add any models unique id to the model list. (Ollama included).

- [based on rust-genai](https://github.com/jeremychone/rust-genai)
- [models.dev](models.dev)

## User quick prompts

You can save custom quick prompts in the configuration. Identified by
an alias, they can be called with a slash prefix.

There is an example for `/init` and `/audit`.

## Saving sessions

All sessions are saved on exit as json, identified by the project cwd in:

`~/.cache/blitzdenk/sessions/`

They restore on reopen, until the user creates a new one.

## Neovim quick access split

```lua
vim.keymap.set("n", "<leader>o", "vplit | terminal blitzdenk", { silent = true });
```

## Keymap

| keybind  | action         |
| -------- | -------------- |
| enter    | send prompt    |
| ctrl + k | select model   |
| ctrl + n | new session    |
| ctrl + t | task list      |
| ctrl + h | help           |
| ctrl + s | cancel agent   |
| ctrl + c | exit           |
| up/down  | scroll up/down |

## MCP

Not yet implemented
