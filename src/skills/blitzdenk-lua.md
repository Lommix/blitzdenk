---
name: blitzdenk-lua
description: >
    How to configure and extend Blitzdenk. Load on any blitz related question/task.
---

# Blitzdenk Lua configuration

Workflow customization lives in Lua through the global `blitz` table.
`~/.config/blitzdenk/blitz.lua` loads at startup. `./blitz.lua` adds
project-local customization. All Lua files hot reload: edit a tool or command,
then call it and confirm the behavior in the running session.

## Read meta.lua first

`~/.config/blitzdenk/meta.lua` is the source of truth for every `blitz.*`
signature, field, and constant, generated from `src/lua.zig`. Before writing
code, open it and read the class for the calls you need. It already documents
event tags, tool name constants, every `blitz.cmd` function, and all
`REQ_STATUS_*`/`AWAIT_*` values. Do not enumerate them elsewhere, do not ask
the user, and do not guess. `blitz help` shows CLI capabilities.

## Providers and models

```lua
local novita = blitz.add_provider({
    type = "openai",               -- "openai" | "response" | "anthropic" | "ollama"
    url = "https://api.novita.ai/openai/v1",
    key_envar = "NOVITA_API_KEY",
    max_tokens = 32000,
})

local deepseek = blitz.add_model({
    name = "deepseek/deepseek-v4-flash-0731",
    provider = novita,
    vision = false,
    replay_reasoning = true,
    cost = { input = 0.14, output = 0.28, cache = 0.028 },
})

blitz.set_agent_model(blitz.AGENT_GENERAL, deepseek, "max")
```

`add_provider` and `add_model` return integer handles. `vision` gates the
`view_image` tool and image pasting. Set `replay_reasoning` on chat models that
return reasoning but reject replayed history without that field (DeepSeek, GLM).
Every agent needs a bound model; unbound agents fail to spawn. Bind with
`blitz.set_agent_model(agent_type, handle, effort?)` (effort defaults to
`"medium"`) or `model = handle` in `blitz.add_agent`. Change only the effort
with `blitz.set_agent_effort(agent_type, effort)`.

The first-run wizard writes `~/.config/blitzdenk/provider.lua` and `blitz.lua`
imports it with `pcall(require, "provider")`. Edit or delete that file to
change provider and model.

## Tool sets

`blitz.tools.*` holds the built-in tool name constants.

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

## Env capabilities

```lua
blitz.set_capabilities({
    { binary = "rg", rule = "Use rg for fast recursive grep searches." },
})
```

## Custom tools

`blitz.register_tool` returns the tool name string for tool sets.

```lua
local my_tool = blitz.register_tool({
    name = "my_tool",
    description = "Example tool",
    args = {
        text = { type = "string", description = "some text", required = true },
        n    = { type = "number", description = "optional count" },
    },
    func = function(ctx, call)
        ctx:set_status("running my_tool")
        if call.arguments.text == "" then
            error("text is required")
        end
        return { msg = "got: " .. call.arguments.text }
    end,
})
```

Schema rules:

- Write `args` as a map keyed by argument name. A list of `{ name = ... }`
  tables publishes an empty schema and the model then guesses argument names.
- Use `schema` (a JSON Schema string, max 2048 bytes) for arrays, nested
  objects, and enums. If both are present, `schema` wins.
- Blitzdenk does not validate arguments against the schema before the call.
  Validate critical inputs in the function.

Tool function rules:

- Tool calls run in a separate VM and cannot mutate config Lua state. Use
  `blitz.state.set/get` for data across calls.
- Model-emitted numbers can arrive as strings (`{"id":"65537"}`). Call
  `tonumber()` before any `cmd.*` call that takes an agent id or integer;
  those bindings reject a non-number with `not a number`.
- `error("...")` fails the call. Only the message reaches the chat.
- Return `{ msg = "..." }`. Attach an image with
  `img = { media_type = "image/png", data = blitz.base64.encode(raw) }`.
  Set `exit_loop = true` to end the agent loop.

For `ctx`, `call`, and result fields, read `BlitzCtx`, `BlitzCall`, and
`BlitzToolResult` in `meta.lua`.

## Agents

```lua
local researcher = blitz.add_agent({
    name = "researcher",
    description = "Read-only research agent.",
    prompt = [[You are a fast read-only research agent. Answer the question. Stop.]],
    effort = "low",
    model = deepseek,
    tools = { blitz.tools.READ, blitz.tools.GREP, blitz.tools.GLOB },
})
```

An agent id is one packed integer; the agent tool result carries it as
`agent_id: <int>`. `fork = true` in `spawn_agent` requires `parent_id`.

Slots are finite (128) and finished agents keep their slot. History stays
readable, and `message_agent` on a finished agent starts a new turn that
continues the same conversation. Free a slot with `blitz.cmd.close_agent`.
`spawn_agent` without `parent_id` cancels the running main agent and frees its
slot; the old conversation stays rendered, the new agent replaces it in the
chat.

## Commands

```lua
blitz.add_command("plan", function(rem)
    blitz.cmd.reset_session()
    blitz.cmd.spawn_agent({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Plan, do not edit. Request:\n" .. rem,
    })
    blitz.cmd.message_chat("user", "[PLAN]: " .. rem)
end, "plan a task without editing")
```

The optional description shows next to the command in the completion popup.
The full command queue API (`reset_session`, `cancel`, `spawn_agent`,
`await_agent`, and so on) is `BlitzCmd` in `meta.lua`.

`blitz.cmd.prompt(text)` is the "say something" command: it echoes the text
into the chat and sends it to the main agent, or starts a fresh general agent
if none exists. Use it instead of `message_chat("user", ...)` (display only)
or `get_main_agent()` + `message_agent` (queues silently, no chat echo).

## Keybinds

```lua
blitz.bind("<C-t>", function()
    local f = blitz.get_flags()
    f.show_thinking = not f.show_thinking
    blitz.set_flags(f)
end)
```

Completion actions with their default keys: `completion_next` (`<Tab>`,
`<C-n>`), `completion_prev` (`<C-p>`), `completion_accept` (`<C-y>`). A custom
`blitz.bind` on the same key wins over the default.

## Events

```lua
blitz.events.add_listener(blitz.events.AGENT_COMPLETE, function(agent_id)
end)
```

For the tag list read `BlitzEventDef` in `meta.lua`.

`ON_INJECT` fires for every agent on each step, right before the system
reminder is built. Return a string to append it to that agent's
`<system-reminder>` block. It runs in the main Lua VM with a brief lock. A nil
return is skipped; errors are logged and the step continues.

```lua
blitz.events.add_listener(blitz.events.ON_INJECT, function(agent_id)
    if agent_id == blitz.get_main_agent() then
        return "[CUSTOM] main agent reminder\n"
    end
end)
```

## Shared state

`blitz.state` is a key-value store shared across config, tools, and listeners.

```lua
blitz.state.set("my_key", { 1, 2, 3 })
local v = blitz.state.get("my_key")
```

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

## UI and status

```lua
blitz.status_bar_render = function()
    local use = blitz.token_usage()
    return "In:" .. use.input
        .. " | Out:" .. use.output
        .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
end
```

The status bar renders ansi color tags.

## Skills

Skills are markdown files discovered from three ranked layers: project
`.blitz/skills` (highest), project `.agents/skills`, and user
`~/.config/blitzdenk/skills`. Project skills shadow same-named user skills.
The project root is the nearest ancestor of the working directory containing
`.git`.

Frontmatter keys: `name` (kebab-case), `description`, optional `whenToUse`,
`user-invocable` (default true), and `disable-model-invocation` (default
false). Unknown keys are ignored. Descriptions support YAML folded (`>`) and
literal (`|`) block scalars.
