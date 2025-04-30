# Blitzdenk - Multi API AI Tui

A minimal, concise auto-context project chat bot. A replacement for dying search.

[blitz.webm](https://github.com/user-attachments/assets/217f6f64-1092-4cf6-a2b2-e0f3c5e4f17d)


Using basic CLI tools to quickly find information relevant to your question.

(ripgrep, tree, cat, etc ... )

## Dependencies

The following linux cli tools are required and must be installed.

- `rg` (ripgrep)
- `tree`

## Features

- can navigate and read your project.
- can read and write to local project memory ('memo.md' in cwd).
- can crawl links and read docs. (drop links in 'memo.md' or chat).
- can read git logs.

## Configure

Use the `config` command. Save API keys and models.

```shell
blitzdenk config
```

Default config file is saved at: `~/.cache/blitzdenk/config`.

## Use

Basic chat in cwd. Optional you can pass a path to the desired working directory.

```shell
#openai
blitzdenk chat openai

#ollama
blitzdenk chat ollama ./path/to/project
```

## Yolo mode

Same as chat. But with access to edit and delete files with no backups. Will destroy your project. Might code a turd.
(rm, mv, mkdir, sed)

It's like cursor, but less safe.

```shell
blitzdenk yolo openai
```

## Currently Supports

Any model. Might fail on some.

- OpenAi (gpt4.1, best so far)
- Ollama (qwen3, pretty good)

## Neovim

It's a simple no-border tui. Perfect to use in the Neovim term buffer.

```lua
vim.keymap.set(("n", "<leader>o", ":vsplit term:// blitzdenk agent openai<CR>:startinsert<CR>", {})
```

## The AI pipeline approach

Agents running in a loop tend to explode small lies into big ones after n iterations. So instead of looping
the best way to get good results is in a forward pipeline.

Question -> collect context -> answer -> correction. Restart

Conclusion: Restart chats often. 1 question/task per chat.
