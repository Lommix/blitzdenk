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

## No borders

I use tmux visual mode. I hate decorative borders that block a clean yank. There will never be nice looking borders around
messages.

## Configuration

All API keys are read from the your environment.

The configuration file for colors and available models is under:

`~/.cache/blitzdenk/denk.toml`

All sessions are saved on exit as json, identified by the project cwd in:

`~/.cache/blitzdenk/sessions/`

## 3 Modes

- Debug - no edit, helps your analyse problems in your project.
- Search - no edit, answers questions short and concise. Replacement for common websearch.
- Code - all tools, can edit your project just like any other coding agent.
