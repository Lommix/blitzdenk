---
name: blitzdenk-lua
description: >
    How to configure and extend Blitzdenk in Lua: config file layout, hot reload,
    tool sets, custom tools, agents, modes, commands, keybinds, MCP, events,
    shared state, and status UI. Load when writing or editing
    ~/.config/blitzdenk/*.lua, ./blitz.lua, or when the user asks to configure
    or extend blitzdenk.
---

# Blitzdenk Lua configuration

Blitzdenk is a Zig binary with vendored Lua. All workflow customization lives in
Lua via the global `blitz` table. `src/blitz_default.lua` in the repo is the
reference config; match its style.

## File layout

- `~/.config/blitzdenk/blitz.lua` — global user config, loaded at startup.
- `./blitz.lua` — optional project-local config, loaded after the global config.
- `~/.config/blitzdenk/meta.lua` — generated LuaLS type hints. Source of truth for signatures.
- `~/.config/blitzdenk/.luarc.json` — points LuaLS at `meta.lua`.
- `src/blitz_defs.lua` in the repo is the generated meta source; `src/blitz_default.lua` is the default config template.

## Loading and hot reload

The config dir is prepended to `package.path`, so `require("tools")` and
`require("prompts")` resolve files from `~/.config/blitzdenk/`. Put reusable
tools and prompts in `tools.lua` and `prompts.lua`, returning a table `M`.

Hot reload polls the mtime of `./blitz.lua` and every `~/.config/blitzdenk/*.lua`
about once per second. On change it resets the Lua VM, re-runs the config, and
re-registers tools, MCP servers, and keybinds. If a tool worker holds the Lua VM
lock, that tick is skipped and retried later. A syntax error makes the reload
fail and the previous config stays active. No restart is needed to test a change.

## Providers and models

A provider is already configured. Reuse its handle; do not add a new provider
unless the user asks. The handle comes from `blitz.add_provider` in the config:

```lua
local novita = blitz.add_provider({
    type = "openai",               -- "openai" | "response" | "anthropic" | "ollama"
    url = "https://api.novita.ai/openai/v1",
    key_envar = "NOVITA_API_KEY",  -- name of the env var, not the key value
    max_tokens = 32000,
})

blitz.set_model("deepseek/deepseek-v4-flash-0731", novita)
blitz.set_model_agent(blitz.AGENT_GENERAL, "deepseek-v4-pro", "max", novita)
```

`add_provider` returns an integer handle. Other optional provider fields:
`effort`, `max_completion_tokens`, `max_output_tokens`, `top_p`, `top_k`,
`frequency_penalty`, `presence_penalty`, `enable_thinking`, `thinking = { type = ..., budget_tokens = ... }`.

Effort values: `"none"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`.

## Tool sets

`blitz.tools.*` are string constants for the built-in tool names.

Built-in names: `BASH`, `CANCEL_PROCESS`, `READ_PROCESS`, `READ`, `VIEW_IMAGE`,
`WRITE`, `EDIT`, `PATCH`, `AGENT`, `ASK`, `AWAIT_AGENT`, `CANCEL_AGENT`, `GLOB`,
`GREP`, `START_MCP`. There is no LOADSKILL or TODO constant; skills load
automatically (see Skills).

- `blitz.set_agent_tools(agent_type, {names})` replaces the whole tool set.
- `blitz.add_tool(agent_type, tool_name)` adds one tool to the current set.
- `blitz.set_prompt(agent_type, prompt)` replaces the system prompt.
- `blitz.AGENT_GENERAL` is the main agent type.

```lua
blitz.set_agent_tools(blitz.AGENT_GENERAL, {
    blitz.tools.BASH,
    blitz.tools.READ,
    blitz.tools.WRITE,
    blitz.tools.EDIT,
    blitz.tools.PATCH,
    blitz.tools.GLOB,
    blitz.tools.GREP,
    tools.web_fetch,          -- custom tool from require("tools")
})
```

## Custom tools

`blitz.register_tool` returns the tool name string to use in tool sets.

```lua
local my_tool = blitz.register_tool({
    name = "my_tool",
    description = "Example tool",
    args = {
        text = { type = "string", description = "some text", required = true },
        n   = { type = "number", description = "optional count" },
    },
    func = function(ctx, call)
        ctx:set_status("running my_tool")
        if call.arguments.text == "" then
            error("text is required")   -- only the message reaches the chat
        end
        return { msg = "got: " .. call.arguments.text }
    end,
})
```

Tool function rules:

- `call.name`, `call.id`, `call.arguments` (table of parsed args).
- `ctx` fields/methods: `ctx.cwd`, `ctx.agent_id`, `ctx.state`, `ctx:set_status(msg)`,
  `ctx:set_child_id(id)`, `ctx:approve(name, args)`, `ctx:plan(path, text)`,
  `ctx:ask(header, question, options)`. `approve`/`plan`/`ask` return a status
  integer plus an optional string; compare with `blitz.REQ_STATUS_*`.
- Return `{ msg = "..." }`. To attach an image:
  `{ msg = "...", img = { media_type = "image/png", data = bytes } }`.
- Raise `error("...")` for failure.
- `return blitz.exit_loop("done")` exits the agent loop.
- `blitz.shell(cmd)` returns `output, ok` (two values).
- `blitz.json.encode(obj)` / `blitz.json.decode(str)` return the value plus an ok boolean.

## Agents

```lua
local researcher = blitz.add_agent({
    name = "researcher",
    description = "Read-only research agent.",
    prompt = [[You are a fast read-only research agent. Answer the question. Stop.]],
    effort = "low",
    model = "deepseek/deepseek-v4-flash-0731",
    provider = novita,
    tools = { blitz.tools.READ, blitz.tools.GREP, blitz.tools.GLOB },
})
```

`add_agent` returns an integer agent type id. Spawn it with
`blitz.cmd.spawn_agent({ agent_type = researcher, prompt = "..." })`.
Optional field: `in_agent_tool = false` hides the agent from the general
agent's sub-agent tool.

## Commands and cmd

```lua
blitz.add_command("/plan", function(rem)
    blitz.cmd.reset_session()
    blitz.cmd.spawn_agent({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Plan, do not edit. Request:\n" .. rem,
    })
    blitz.cmd.push_chat_entry("user", "[PLAN]: " .. rem)
end)
```

Queue API: `reset_session`, `cancel`, `retry`, `compact`, `push_chat_entry(role, text)`,
`queue_agent_message(agent_id, text)`, `spawn_agent(args)`, `await_agent(agent_id)`,
`await_agent_result(agent_id)` (returns an `AWAIT_*` status), `save_session(path)`, `load_session(path)`,
`attach_screenshot(data, media_type)`. `spawn_agent` args: `parent_id`,
`prompt`, `agent_type`, `fork`.

`blitz.get_main_agent()` returns the main agent id table (`{ index, generation }`) or nil.

## Keybinds

```lua
blitz.bind("<C-t>", function()
    local f = blitz.get_flags()
    f.show_thinking = not f.show_thinking
    blitz.set_flags(f)
end)
```

Vim-style combos: `<C-c>`, `<M-S-a>`, `<Esc>`, `<Up>`, `<F1>`, `a`.

## Modes

```lua
local read_mode = blitz.add_mode("READ", "#008F04",
    "You are in read-only mode!", "You are in read-only mode!")
blitz.set_mode(read_mode)
```

Also `blitz.set_mode_prompt(mode, prompt)`, `blitz.set_mode_prompt_sparse(mode, prompt)`,
`blitz.set_mode_name(mode, name)`. `blitz.MODE_EXEC` is the built-in exec mode.

## Events

```lua
blitz.events.add_listener(blitz.events.AGENT_COMPLETE, function(agent_id)
    -- agent_id.index and agent_id.generation
end)
```

Event tags on `blitz.events.*`: `SESSION_RESET`, `MODE_CHANGED`, `AGENT_CREATED`,
`AGENT_STARTED`, `AGENT_COMPLETE`, `AGENT_FAILED`, `AGENT_CANCELLED`,
`COMPACTION_STARTED`, `COMPACTION_COMPLETE`, `TOOL_CALL_STARTED`,
`TOOL_CALL_COMPLETE`, `AGENT_BROADCAST`, `PERMISSION_REQUESTED`,
`PERMISSION_RESOLVED`, `USER_MESSAGE_SENT`, `MCP_TOOLS_RELOADED`, `ON_INJECT`.

Payloads vary: agent events receive an agent id table, `MODE_CHANGED` receives an
integer, `USER_MESSAGE_SENT` receives a string. Check `meta.lua` for descriptions.

`ON_INJECT` fires for every agent on each step, right before the system reminder
is built. Return a string to append it to that agent's `<system-reminder>` block:

```lua
blitz.events.add_listener(blitz.events.ON_INJECT, function(agent_id)
    if agent_id.index == blitz.get_main_agent().index then
        return "[CUSTOM] main agent reminder\n"
    end
end)
```

It runs in the main Lua VM with a brief lock, like `status_bar_render`. A nil or
non-string return is skipped; errors are logged and the step continues.

## Shared state

`blitz.state` is a persistent key-value store shared across config, tools, and
listeners:

```lua
blitz.state.set("my_key", { 1, 2, 3 })
local v = blitz.state.get("my_key")
```

Pass nil to `set` to delete a key. Tables must have a contiguous 1..n array part
and string-only keys. `set` returns true on success, or nil, false on invalid input.

## MCP

```lua
local pw = blitz.mcp.add({
    name = "playwright",
    command = "npx",
    args = { "-y", "@playwright/mcp@latest", "--browser=chromium" },
    tools_prefix = "pw_",
})
blitz.mcp.enable(pw)
```

`add` registers a stdio server (disabled) and returns an integer id. `enable`
turns it on. Optional field: `transport`.

## UI and status

```lua
blitz.status_bar_render = function()
    local use = blitz.token_usage()
    return "In:" .. use.input
        .. " | Out:" .. use.output
        .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
end
```

Also: `blitz.get_flags()` / `blitz.set_flags(t)` for `show_thinking`, `debug_log`,
`skip_permissions`; `blitz.get_theme()` / `blitz.set_theme(t)` for hex colors;
`blitz.push_notification(msg)`; `blitz.log(msg)`; `blitz.token_usage_by_model()`;
`blitz.set_compact_edge(tokens)`.

## Skills

Skills are plain markdown files in `~/.config/blitzdenk/skills/*.md` with YAML
frontmatter. Only `name` and `description` are parsed (`description` may use a
folded `>` block); other frontmatter keys are ignored. Blitzdenk injects them
into the agent's system prompt at context build.

## Reference

- `meta.lua` — generated Lua API meta (source of truth).
