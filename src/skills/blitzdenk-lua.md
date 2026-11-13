---
name: blitzdenk-lua
description: "Blitzdenk Lua config (`blitz.lua`): providers/models, custom tools, agents, commands, keybinds, input, hooks, permissions, MCP, drawing."
metadata:
  blitzdenk.main-agent-only: "true"
---

# Blitzdenk Lua configuration

Customization lives in Lua through the global `blitz` table.
`~/.config/blitzdenk/blitz.lua` loads at startup; `./blitz.lua` adds project
customization.

## Workflow

1. Agree the scope with the user: project (`./blitz.lua`) or global
   (`~/.config/blitzdenk/blitz.lua`). Read the target file.
2. Read the `meta.lua` classes for every call you use
   (`~/.config/blitzdenk/meta.lua`). It is the source of truth for
   signatures, fields, defaults, event payloads, and constants. This skill
   holds only what meta.lua cannot say.
3. Write the Lua. A save hot reloads within a second; the next step carries
   `[LUA VM RELOADED]` and a refreshed tool list.
4. Smoke test in this session: call the new tool yourself, read the result,
   fix, repeat. Done means you watched it work.

The config is your own sandbox. A registered tool is your hand: list it in
an agent tool set and call it after the reload. Commands and keybinds belong
to the user; you cannot type `/name`, so exercise that Lua from a tool, hook,
or spawned agent. Tool logic stays in tools.

## Runtime model

- **Main VM**: config load, commands, keybinds, render callbacks, and the
  prompt, inject, and approve hooks. Keep it free: it reaps state for every
  agent.
- **Sandbox VM**: one per tool call and one per emitted event. It replays
  the config; config mutation (`add_provider`, `register_tool`,
  `set_agent_model`, ...) is a no-op. Carry data with `blitz.state`.

`blitz.agent.spawn` works everywhere. `blitz.agent.await` belongs in sandbox
VMs; in the main VM it returns the status of a finished agent and raises
`not available in the main vm` for a running one (inside the approve hook
that denies with `permission hook error: ...`). `blitz.input.get` needs the
main thread; inject runs off it.

## Providers and models

```lua
local novita = blitz.add_provider({
    type = "openai",               -- "openai" | "response" | "anthropic"
    url = "https://api.novita.ai/openai/v1",
    key_envar = "NOVITA_API_KEY",
    session_key_header = "x-session-id",
})

local deepseek = blitz.add_model({
    name = "deepseek/deepseek-v4-flash-0731",
    provider = novita,
    vision = false,
    cost = { input = 0.14, output = 0.28, cache = 0.028 },
})

blitz.set_agent_model(blitz.AGENT_GENERAL, deepseek)
blitz.set_agent_effort(blitz.AGENT_GENERAL, "max")
```

- Every agent type needs a bound model (`set_agent_model` or `model` in
  `add_agent`); unbound types fail to spawn.
- `vision` gates image paste, image reads, and `requires_vision` tools.
- The first-run wizard writes `~/.config/blitzdenk/provider.lua`, imported
  by `pcall(require, "provider")`. Edit or delete it to change the provider.

**Session contract**: after startup load, each type's model, provider
settings, and effort freeze into the session contract. Hot reloads keep it,
also for agents spawned later; new types join when configured; a new session
captures the latest config. Outside a reload, a change updates future spawns.
`force = true` rewrites the contract and queues the swap on live agents of
that type: idle ones adopt at once, a running one finishes its run on the old
binding. Type getters can lag mid run; `blitz.agent.get_model/get_effort(id)`
read the live agent.

## Tool sets and environment

```lua
local tools = require("tools")
local web = { tools.web_search, tools.web_fetch }  -- custom toolset
blitz.set_agent_tools(blitz.AGENT_GENERAL, {
    blitz.toolsets.BASH_BACKGROUND, -- bash + read_job + kill_job
    blitz.tools.READ, blitz.tools.EDIT,
    web,
})
blitz.set_read_image_max(4096, 4096)
blitz.set_capabilities({
    { binary = "rg", rule = "Use rg for fast recursive grep searches." },
})
```

- Tool names are nonempty UTF-8 strings.
- A toolset is a plain list of tool names. `set_agent_tools`, `add_agent`
  `tools`, and `add_tool` flatten nested lists. Tools sharing a name keep
  the first entry; `add_tool` replaces it instead, so
  `add_tool(t, blitz.toolsets.BASH_BACKGROUND)` upgrades a sync bash.
  `add_tool` applies a toolset all or none.
- `blitz.tools.BASH` is sync only. Background jobs need
  `blitz.toolsets.BASH_BACKGROUND`.
- `blitz.toolsets.READONLY` is `GREP` (rg), `FIND` (fd) and `LS`. `GREP`
  and `FIND` need `rg` and `fd` on PATH.
- The read tool returns scaled images as PNG and shrinks further to fit the
  byte limit. A format the decoder cannot read goes out unscaled with a note.
- Capability rules form the `<env_capabilities>` catalogue, injected once
  per chat as a system-reminder.

## Custom tools

```lua
local my_tool = blitz.register_tool({
    name = "my_tool",
    description = "Example tool",
    args = {
        text = { type = "string", description = "some text", required = true },
        id   = { type = "number", description = "agent id" },
    },
    func = function(ctx, call)
        ctx:set_status("running my_tool")
        local id = tonumber(call.arguments.id)
        if call.arguments.text == "" then error("text is required") end
        return { msg = "got: " .. call.arguments.text }
        -- image: img = { media_type = "image/png", data = blitz.base64.encode(raw) }
    end,
})
```

- `args` is a map keyed by argument name. A list of `{ name = ... }` tables
  publishes an empty schema and the model guesses names.
- `schema` (JSON Schema string, max 2048 bytes) covers arrays, nested
  objects, and enums; it wins over `args`. Arguments arrive unvalidated:
  check critical inputs in `func`.
- Model numbers can arrive as strings (`{"id":"65537"}`). `tonumber()` them
  before any `blitz.agent.*` call; those reject strings with `not a number`.
- `error("...")` fails the call; only the message reaches the chat.
- Results, errors, and `ctx:call`/`ctx:batch` output share the bash/read
  cap: tail kept, full text spilled to a file with a locator. A capped string
  is incomplete input for parsing or JSON decoding.
- `msg` goes out as tool result text. Images follow as user content: a
  `user` message on `openai`/`response`, an image block on `anthropic`.
  Strict endpoints (DeepSeek) reject images inside tool messages.

## Agents

```lua
local researcher = blitz.add_agent({
    name = "researcher",
    description = "Read-only research agent.",
    prompt = [[You are a fast read-only research agent. Answer the question. Stop.]],
    effort = "low",
    model = deepseek,
    tools = { blitz.tools.READ },
    skills = { only = { "zig", "blitzdenk-lua" }, except = { "deploy" } },
})

blitz.agent.spawn({
    agent_type = researcher,
    prompt = "Find the registry lock order.",
    background = true,
    on_complete = function(id, status)
        if status == blitz.AWAIT_COMPLETE then
            blitz.cmd.message_timeline("agent", blitz.agent.result(id))
        end
    end,
})
```

- In a sandbox VM `add_agent` looks the name up and returns the live
  handle, so a module local set at load stays valid in hooks and tools. An
  unknown name returns 0, which spawns `general`.
- `blitz.list_agent_types()` maps type names from tool arguments to handles.
- The agent tool result carries the id as `agent_id: <int>`.
- **Timeline**: agents spawned inside a tool attach to its row; inside
  codemode, direct spawns and `ctx:call`/`ctx:batch` calls to `agent` attach
  to the outer codemode row. `ctx:set_child_id(id)` adds an existing agent
  (deduped).
- **Silent subagent**: `background = true` plus `on_complete`. A finished
  background child queues its answer into its parent, clean parents included.
- `on_complete` is main VM only; listeners use `blitz.hooks.agent_complete`.
  A Lua reload drops the callback.
- `clean = true` (spawn or agent tool): no AGENTS.md, no system-reminder,
  so the inject hook never runs for it.

**Slots**: 128. Finished agents keep their slot and history;
`blitz.agent.message` on one continues the conversation. `blitz.agent.close`
frees it. A spawn with neither `parent_id` nor `background` replaces the main
agent: the old run cancels and its slot frees, its conversation stays
rendered. Unknown agent ids raise.

**History**: `history` and `history_since_checkpoint` rows can be large;
read them outside render callbacks. The checkpoint moves on a new prompt or a
queued user message and resets on session load, rewind, and compaction; a
cancel keeps it. An unfinished tool exchange leaves model history but stays
visible.

**Task description**: set at spawn (`task`, or `description` on the agent
tool). A prompted main agent starts empty; fill it from a hook. The `task` on
the helper is the loop guard; without it the listener spawns helpers for
helpers.

```lua
blitz.hooks.agent_started(function(ev)
    if not ev.fresh or blitz.agent.get_task_description(ev.id) ~= "" then return end
    local prompt = blitz.agent.get_prompt(ev.id)
    if prompt == "" then return end
    local helper = blitz.agent.spawn({
        agent_type = blitz.AGENT_GENERAL,
        background = true,
        task = "summarize request",
        prompt = "Summarize this request in at most six words. Reply with the words only:\n" .. prompt,
    })
    if blitz.agent.await(helper) == blitz.AWAIT_COMPLETE then
        blitz.agent.set_task_description(ev.id, blitz.agent.result(helper))
    end
end)
```

## Skill filters

`skills` in `add_agent`, or `blitz.set_agent_skills(type, filter)` for an
existing type (live agents pick it up next step). The filter covers the
catalogue, skill loads via `read`, and `/skill-<name>`. The catalogue lists each
skill's path; `read` on that path returns the body without frontmatter. A
filtered-out skill reads as a plain file. Skill names match case-insensitively.

A skill file narrows itself in `metadata`:

```yaml
metadata:
  blitzdenk.deny-agents: "code-reviewer, prose-reviewer"
  blitzdenk.main-agent-only: "true"
```

`deny-agents` matches type names exactly and wins over `only`; unknown names
are inert. `main-agent-only` limits the skill to the runtime main agent. A
skill-side list only denies.

## Commands and keybinds

```lua
blitz.add_command("plan", function(rem)
    blitz.cmd.reset_session()
    blitz.agent.spawn({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Plan, do not edit. Request:\n" .. rem,
    })
    blitz.cmd.message_timeline("user", "[PLAN]: " .. rem)
end, "plan a task without editing")

blitz.bind("<C-t>", function()
    local f = blitz.get_flags()
    f.show_thinking = not f.show_thinking
    blitz.set_flags(f)
end, "toggle thinking output")
```

- Descriptions show in the completion popup (commands) and the dashboard
  (keybinds, fallback `custom`).
- `blitz.cmd.prompt(text)` says something as the user: timeline echo plus
  send to the main agent, or a fresh general agent. `message_timeline` only
  displays; `blitz.agent.message` queues without echo.
- Flag defaults: `show_thinking` false, other booleans true,
  `approval_mode = "default"` (auto-approves tool calls; `"strict"` asks).
- A `blitz.bind` on a default key (`<Tab>`, `<C-n>`, `<C-p>`, `<C-y>`) wins;
  `blitz.cmp.*` reproduces the popup actions.
- `blitz.input` edits the box before Enter; `blitz.hooks.prompt` rewrites the
  text on Enter.

## Ask widget

`blitz.cmd.select(request, cb)` (commands, returns at once) and
`ctx:ask(request)` (tools, blocks) open the same widget with the same
`BlitzAskRequest`. The user answers each question; the last answer submits
the batch.

```lua
local status, answers = ctx:ask({
    questions = {
        { header = "Deploy", question = "Which environment?", options = { "staging", "prod" },
          allow_message = false },
    },
})
if status ~= blitz.REQ_STATUS_CHOICE then return { msg = "deploy canceled" } end
local env = answers[1][1].text
```

- Cancel: `esc`, the `cancel` command, session reset, or Lua reload.
  `select` reports `cb(nil)`; `ctx:ask` returns `REQ_STATUS_DENIED, nil`.
  Ask never produces `REQ_STATUS_MESSAGE`.
- `esc` cancels only the ask; on other permission types it stops the run.
- `multi_select` toggles with `enter`/`space` and commits on a trailing
  submit row.
- `select` callbacks run on the main thread and may chain more `blitz.cmd`
  calls, another `select` included. Agent permissions take the screen first.
  Headless runs drop selections at exit.

## Hooks

**Event listeners** (`blitz.hooks.<event>`): each call adds a listener. All
listeners of one event run in registration order in one sandbox VM on a
background thread. The event loop never waits; an `await` delays only the
listeners behind it. A reload clears every listener and re-runs the config.
Spawning from `agent_created` or `agent_started` retriggers them: guard it.

**Prompt hook** (`blitz.hooks.prompt`): the rewrite feeds the full pipeline,
so it can produce a `/command` or skill call; echo, history, and model see
the new text. `""` drops the input. Errors log and send the input unchanged.
`blitz.cmd.prompt` and headless `--prompt` bypass it.

**Inject hook** (`blitz.hooks.inject`): `agent_type_id` is the type handle.
Errors log and the step continues. The reminder precedes the user prompt.

```lua
blitz.hooks.inject({
    main_only = true,
    digest = true,
    func = function(agent_id, agent_type_id)
        return "[AGENTS] " .. #blitz.list_agents() .. " slots used\n"
    end,
})
```

`blitz.hooks.clear()` removes the prompt, inject, and approve hooks.

## Permissions

Flow: approve hook → park with a ticket + `permission_requested` → approval
mode → TUI. Both Lua stages run in every mode and can deny what default mode
would approve.

**Approve hook** (`blitz.hooks.approve`, main VM, last wins): return a
`BlitzPermissionDecision` or nil for the normal flow.

```lua
blitz.hooks.approve(function(p)
    if p.kind == "diff" and p.path:find("^/tmp/") then return { approved = true } end
    if p.tool == "bash" and p.description:find("rm ") then
        return { approved = false, msg = "no destructive commands" }
    end
    if p.kind == "ask" then
        return { approved = true, answers = { { { index = 1 } } } } -- rest: recommended
    end
end)
```

- Recommended pick: first option marked `(recommended)` on single-select,
  every marked option on multi-select, option one when none is marked.
- An answer that misfits its question (empty, several picks on
  single-select, text without a message row) denies the whole batch.
- A table without `approved` denies with a fixed reason; a hook error
  denies with `permission hook error: <msg>`.
- No ticket exists yet: `blitz.permissions.resolve` inside the hook misses.

**Queue**: decide parked tickets any time with `blitz.permissions.*`, from
commands, keybinds, or listeners. Snapshots never go stale; only `resolve`
fails late. Requests of dead agents deny regardless. Mode auto-approval and
the TUI wait for every `permission_requested` listener.

**Judge pattern**: the listener spawns a judge agent that decides by calling
a custom tool which resolves the ticket; no await, no parsing. Give the judge
read-only tools plus that tool: its own calls emit permission events, so a
judge with bash spawns judges forever.

Headless `--prompt` skips both Lua stages and auto-resolves, picking
recommended ask options.

## MCP

```lua
blitz.mcp.enable(blitz.mcp.add({
    name = "playwright",
    command = "npx",
    args = { "-y", "@playwright/mcp@latest", "--browser=chromium" },
    tools_prefix = "pw_",
}))

local linear = blitz.mcp.add({
    name = "linear",
    url = "https://mcp.linear.app/mcp",   -- streamable http
    oauth = true,
    tools_prefix = "lin_",
})
```

Set exactly one of `url` or `command`.

**OAuth** (`url` servers, no static key): the browser opens only when the
user runs `/mcp connect <name>`. It authorizes if needed, enables the server,
and reloads tools (`mcp_tools_reloaded`). `/mcp cancel` stops it. Dynamic
client registration runs when offered, else set `client_id`. Tokens live in
`$XDG_STATE_HOME/blitzdenk/oauth/tokens.json` (default
`~/.local/state/blitzdenk`), keyed by url, so a rename keeps the login.
Tokens refresh on expiry; deleting a record logs out. A server answering 401
at load is skipped with a notification naming the connect command.

## Session transcripts

```lua
local id = blitz.get_session_id()              -- nil before the first record
if id then blitz.export_transcript(id, "/tmp/session.json") end
```

The file is one JSON document for `jq`: `.session` plus a flat `.agents[]`
(tree through `parent_id`). Each agent's `.messages[]` holds the full
history in order. `role` is `user`, `assistant`, `tool`, `system`, or a
`compaction`/`reset` marker with `reason` and `history_len`; compaction and
`history_replace` markers also carry the new `history`. `tool_call` parts
carry `state` and spawned `children`; `time_ms` is null on old sessions.
Image data is omitted.

## Status bar and drawing

```lua
blitz.status_bar_render = function()   -- ANSI color tags render
    local use = blitz.token_usage()
    return "In:" .. use.input .. " | Out:" .. use.output
        .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
end

local sb = blitz.draw.sidebar({
    side = "left",
    width = 24,
    render = function(w, h, buf, frame)
        buf.box(0, 0, w, h, "muted")
        buf.set_color(1, 1, "sessions", "#A50000")
        local spin = frame % 10 + 1
        buf.set(1, 2, string.sub("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", spin, spin))
    end,
})
```

- Coordinates are widget-relative, (0,0) top-left; out-of-rect writes clip.
- Frames run up to 60fps while agents run or before the first prompt;
  afterwards only on input. Animations call `blitz.draw.redraw()`.
- Keep render pure drawing: no awaits, no long work, or frames drop.
- `frame` resets on session reset.
- A second sidebar on the same side kills the first handle.
