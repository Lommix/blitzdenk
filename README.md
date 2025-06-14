# [WIP] Blitzdenk - Multi API Agent Tui

[![License: Apache 2.0](https://img.shields.io/badge/Apache2-blue.svg)](./LICENSE)
[![Crate](https://img.shields.io/crates/v/blitzdenk.svg)](https://crates.io/crates/blitzdenk)

A minimal, concise auto-context project chat bot, not a coding agent.

[blitz.webm](https://github.com/user-attachments/assets/217f6f64-1092-4cf6-a2b2-e0f3c5e4f17d)

This is a personal research project to replace search engines for simple questions.

## Install

clone + `make install` will build the and copy the bin to ~/.local/bin

## Dependencies

The following linux cli tools are required and must be installed.

- `rg` (ripgrep)
- `tree`

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

#gemini
blitzdenk chat gemini

#claude
blitzdenk chat claude
```

## Currently Supports

Any model. Might fail on some.

- OpenAi
- Ollama
- Gemini
- Claude
