---
name: blitzdenk-lua
description: >
    How to configure and extend Blitzdenk. Load on any blitz related question/task.
---

# Blitzdenk Lua configuration

Blitzdenk is a Zig binary with vendored Lua. Workflow customization lives in
Lua through the global `blitz` table. `~/.config/blitzdenk/blitz.lua` is a
working config; `src/blitz_default.lua` in the repo is its template. Match the
style of whichever exists.

## Find the answer fast

Two files settle most questions:

- `~/.config/blitzdenk/meta.lua` is the source of truth for every `blitz.*`
  signature, field, and constant. Read it before writing code.
- `~/.config/blitzdenk/blitz.lua` is a working example of the config.

For a question about any `blitz.*` call, open `meta.lua` and read the class
for that call. Each section below hides a buried list (event names, provider
fields, status constants). For those, the meta file is the list: inspect the
class and use it, do not enumerate.

## File layout

- `~/.config/blitzdenk/blitz.lua`, global user config, loaded at startup.
- `./blitz.lua`, optional project-local config, loaded after it.
- `~/.config/blitzdenk/meta.lua`, generated type hints, signature truth.
- `~/.config/blitzdenk/.luarc.json`, points the Lua server at `meta.lua`.
- `src/blitz_defs.lua` in the repo is the generated meta; `src/blitz_default.lua` the default config. `meta.lua` is the source of truth for both.

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

local deepseek = blitz.add_model({
    name = "deepseek/deepseek-v4-flash-0731",
    provider = novita,
    vision = false,
    cost = { input = 0.14, output = 0.28, cache = 0.028 },  -- USD per 1M tokens
})

blitz.set_model_agent(blitz.AGENT_GENERAL, deepseek, "max")
```

`add_provider` and `add_model` return integer handles. `vision` (default
false) gates the `view_image` tool and image pasting; `cost` is optional and
absent means free. Bind a model per agent with `blitz.set_model_agent(agent_type,
handle, effort?)` (effort defaults to `"medium"`) or `model = handle` in
`blitz.add_agent`. Every agent needs a bound model; unbound agents fail to
spawn. Effort: `"none"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`.

The typed fields for provider, model, and cost live in `BlitzProviderDef`,
`BlitzModelDef`, and `BlitzModelCost` in `meta.lua`. Read the model name with
`blitz.get_model_name(agent_type)`.

## Tool sets

`blitz.tools.*` are string constants for the built-in tool names.

Built-in names: `BASH`, `READ`, `VIEW_IMAGE`,
`WRITE`, `EDIT`, `PATCH`, `AGENT`, `ASK`, `GLOB`, `GREP`, `START_MCP`, `SKILL`.

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
Omit both `args` and `schema` for a tool that takes no arguments.

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

The `args` shorthand supports only `type`, `description`, and `required`. Use
`schema` for arrays, nested objects, enums, or other JSON Schema constraints:

```lua
local process_files = blitz.register_tool({
    name = "process_files",
    description = "Process several files",
    schema = [[
{
  "type": "object",
  "properties": {
    "paths": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Files to process"
    }
  },
  "required": ["paths"],
  "additionalProperties": false
}
]],
    func = function(ctx, call)
        for _, path in ipairs(call.arguments.paths) do
            print(path)
        end
        return { msg = "done" }
    end,
})
```

`schema` must be a JSON Schema string no longer than 2048 bytes. If both
`schema` and `args` are present, `schema` is used. JSON arrays are passed to
the tool function as 1-indexed Lua tables. Blitzdenk does not validate tool
arguments against the schema before calling the function, so validate critical
inputs in the function.

Tool function rules:

- `call.name`, `call.id`, `call.arguments` (table of parsed args).
- `ctx` fields/methods: `ctx.cwd`, `ctx.vision` (calling model supports images), `ctx.agent_id`, `ctx.state`, `ctx:set_status(msg)`,
  `ctx:set_child_id(id)`, `ctx:approve(description)`, `ctx:plan(path, text)`,
  `ctx:ask(header, question, options)`. `approve`/`plan`/`ask` return a status
  integer plus an optional string; compare with `blitz.REQ_STATUS_*`.
- Return `{ msg = "..." }`. To attach an image:
  `{ msg = "...", img = { media_type = "image/png", data = bytes } }`. Set
  `exit_loop = true` to end the agent loop.
- Raise `error("...")` for failure.
- `blitz.exit_loop("done")` returns a result that ends the loop.
- `blitz.shell(cmd)` returns `output, ok` (two values).
- `blitz.shell(cmd, timeout)` accepts an optional timeout in seconds.
- `blitz.json.encode(obj)` / `blitz.json.decode(str)` return the value plus an ok boolean.
  The `BlitzToolDef`, `BlitzToolResult`, `BlitzCtx`, and `BlitzCall` classes in
  `meta.lua` list the exact fields.

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

`add_agent` returns an integer agent type id. Spawn it with
`blitz.cmd.spawn_agent({ agent_type = researcher, prompt = "..." })`.
Optional fields: `model` (a handle from `add_model`; agents without a bound
model fail to spawn) and `in_agent_tool = false` hides the agent from the
general agent's sub-agent tool.

## Commands and cmd

```lua
blitz.add_command("plan", function(rem)
    blitz.cmd.reset_session()
    blitz.cmd.spawn_agent({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Plan, do not edit. Request:\n" .. rem,
    })
    blitz.cmd.push_chat_entry("user", "[PLAN]: " .. rem)
end)
```

Queue API: `reset_session`, `cancel`, `retry`, `compact`, `cd(path)`,
`prompt(text)`,
`push_chat_entry(role, text)`, `queue_agent_message(agent_id, text)`, `spawn_agent(args)`, `await_agent(agent_id)`,
`await_agent_result(agent_id)` returns the agent's last assistant text string.
`await_agent(agent_id)` blocks and returns an `AWAIT_*` status
(`AWAIT_COMPLETE`, `AWAIT_FAILED`, `AWAIT_CANCELED`, `AWAIT_INVALID`).
`save_session(path)`, `load_session(path)`,
`attach_screenshot(data, media_type)`. `spawn_agent` args: `parent_id`,
`prompt`, `agent_type`, `fork` (`BlitzSpawnArgs` in `meta.lua`).

`blitz.cmd.prompt(text)` is the "say something" command: it echoes the text into
the chat log and sends it to the main agent (queued while it runs, restarted when
idle), or starts a fresh general agent if none exists. Use it instead of
`push_chat_entry("user", ...)` (display-only) or hand-rolling
`get_main_agent()` + `queue_agent_message` (which queues silently, no chat echo).
Note `spawn_agent` without `parent_id` replaces the running main session.

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

Command completion actions (custom `blitz.bind` on a key wins over these defaults):

- `completion_next` — `<Tab>`, `<C-n>`. Cycle forward and insert. Wraps.
- `completion_prev` — `<C-p>`. Cycle backward and insert. Wraps.
- `completion_accept` — `<C-y>`. Insert the selected entry without cycling.

Menu arrow `<Up>` / `<Down>` traverse while open (wrap, same as `<Tab>`).

## Events

```lua
blitz.events.add_listener(blitz.events.AGENT_COMPLETE, function(agent_id)
    -- agent_id.index and agent_id.generation
end)
```

Event tags on `blitz.events.*`: `SESSION_RESET`, `AGENT_CREATED`,
`AGENT_STARTED`, `AGENT_COMPLETE`, `AGENT_FAILED`, `AGENT_CANCELLED`,
`COMPACTION_STARTED`, `COMPACTION_COMPLETE`, `USER_MESSAGE_SENT`,
`MCP_TOOLS_RELOADED`, `ON_INJECT`.

Do not enumerate payloads; read the `BlitzEventDef` class in `meta.lua`, which
lists each tag with a one-line meaning.

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
blitz.mcp.enable(pw) -- start on load (optional)
```

`add` registers a stdio server (disabled) and returns an integer id. `enable`
turns it on. Optional fields: `transport`, `tools_prefix`.

## UI and status

```lua
blitz.status_bar_render = function()
    local use = blitz.token_usage()
    return "In:" .. use.input
        .. " | Out:" .. use.output
        .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
end
```

Other `blitz.*` calls: flags, theme, notifications, logging, compact edge, and
the `cost` field on `token_usage` are all in `meta.lua` under `BlitzAppFlags`,
`BlitzTheme`, and `BlitzTokenUsage`. Read those classes for the fields instead
of memorizing the list.

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
