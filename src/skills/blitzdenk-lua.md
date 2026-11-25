---
name: blitzdenk-lua
description: "Blitzdenk Lua config (`blitz.lua`): providers/models, custom tools, agents, commands, keybinds, input, hooks, permissions, MCP, UI, plugins."
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

- **Main VM**: config load, commands, keybinds, UI callbacks, tick and
  state callbacks, and the prompt, inject, and approve hooks. Keep it free: it
  reaps state for every agent.
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
    blitz.toolsets.BASH_BACKGROUND, -- bash + read_job + write_job + kill_job
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
- `blitz.toolsets.SUBAGENTS` is `AGENT`, `MESSAGE_AGENT`, `CANCEL_AGENT` and
  `IDLE`. See Agents.
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
- `tools = { ... }` (ids and toolsets) seals the tool: `ctx:call` and
  `ctx:batch` run only those tools, by id or exposed name, even when the agent
  does not hold them. They are resolved on every call, so reloads and MCP
  tools apply. `ctx.tools` lists the resolved exposed names, `nil` without
  `tools`. A tool with `tools` cannot be granted. Without `tools`,
  `ctx:call` runs the agent's own tools and rejects the running tool.
- `description` is at most 16384 bytes. Granted `tools` are not described
  automatically: put their arguments into `description`.
  `blitz.tool_info(tools)` returns `{ id, name, description, schema }` rows
  for ids, exposed names or toolsets that exist while the config runs (MCP
  tools do not yet). Unknown tools are skipped.
- `ctx:call` returns `text, img` and `ctx:batch` returns `texts, imgs` (index
  to image). `img` is `{ media_type, data }`, the shape of the `img` return
  field, so a wrapper can forward an image read by a nested tool.

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
- `blitz.tools.AGENT` runs background children and defaults to `general`.
  Agents that hold it get an `<available_agents>` catalogue of every type,
  built from `description`. `in_agent_tool = false` hides a type from the
  catalogue; it can still be spawned by name. The main agent and its children
  can launch agents, grandchildren cannot.
- A registered tool named like a built-in tool is skipped.
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

**Tick hooks** (`blitz.hooks.tick`): main VM, every TUI loop iteration
(16 ms or less). No fixed rate, no `dt`: throttle yourself. TUI only.

**State hooks** (`blitz.hooks.state_changed`): main VM, called with the main
agent's new `BlitzAgentRow.state`, `""` without one. Also fires headless.
Permissions, tokens, and sub-agents are not covered.

Both stack, are unregistered on error, and are cleared by a reload.

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

`blitz.hooks.clear()` removes the prompt, inject, approve, tick, and
state_changed hooks.

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

## Plugins

Plugins work like Neovim's: `blitz.plugin` declares and installs, `require`
loads, the config calls `setup`.

```lua
blitz.plugin("blitz-tools", {
    url = "https://github.com/acme/blitz-tools.git",
    ref = "v1.0.0",                -- branch floats; tag or full SHA pins
})
blitz.plugin("my-plugin", { path = "~/dev/my-plugin" })   -- development, hot reloads

local acme = require("blitz-tools")
acme.setup({ prefix = "acme" })
blitz.add_tool(blitz.AGENT_GENERAL, acme.tools.search)
```

- `blitz.plugin(name, spec)` installs, pins, and puts the plugin's `lua/` on
  the module path. It runs no plugin code and returns nothing.
- `require(name)` loads `lua/<name>/init.lua`. For a plugin that failed to
  install it raises `plugin '<name>' is not available: ...`. Optional
  plugins: `local ok, acme = pcall(require, "blitz-tools")`.
- The config dir `.luarc.json` lists each plugin's `lua/` dir, so hover and
  go-to-definition on `require(name)` reach the plugin source.
- Git plugins belong in the global config; `./blitz.lua` takes `path` only.
- A missing git plugin clones at startup only. Added to a running session it
  is `not installed`; `blitz plugin update` in a shell installs it and the app
  reloads. `blitz plugin list` shows each checkout. `blitz.plugins.get(name)`
  returns a status handle.
- Bad spec fields and duplicate names abort the config.
- Later registrations of a tool, command, keybind, or agent name win, so
  config after a plugin's `setup` overrides it.

Plugin layout: `lua/<name>/init.lua` (required), more modules in
`lua/<name>/*.lua`, skills in `skills/*.md`. `blitz plugin create <dir>`
scaffolds the module and editor completion files.

```lua
-- lua/blitz-tools/init.lua
local M = { tools = {} }

---@param opts? table
function M.setup(opts)
    opts = opts or {}
    M.tools.search = blitz.register_tool({ name = opts.prefix .. "_search", ... })
end

return M
```

Plugin code replays in every tool and hook VM, like the config: keep it free
of side effects.

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

## Status bar and UI

```lua
blitz.status_bar_render = function()   -- ANSI color tags render
    local use = blitz.token_usage()
    return "In:" .. use.input .. " | Out:" .. use.output
        .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
end
```

`blitz.ui` is a retained scene: build a tree of nodes once, mount it, then
change it. Blitzdenk lays out and draws the tree every frame without calling
Lua, so there is no render callback.

```lua
local ui = blitz.ui
local count = 0
local label = ui.text({ "0 clicks", fg = "muted" })

ui.mount("between", ui.box({
    dir = "row", gap = 1, padding = { x = 2 }, bg = "overlay_dark",
    label,
    ui.spacer(),
    ui.button({ label = "Add", key = "<C-a>", on_click = function()
        count = count + 1
        label:set({ count .. " clicks" })
    end }),
}))

ui.mount("left", ui.box({
    width = 24, border = "muted", title = "Session",
    ui.text({ { "ok", fg = "ok", bold = true }, " all good" }),
    ui.text({ "long text wraps inside the box", wrap = true }),
}))
```

- Compose with plain functions that return a node. Methods use `:` and
  return the node.
- `node:set(props)` merges: only the given keys change. An array part
  replaces the children of a box or the content of a text; children left
  out are removed. An empty array changes nothing: use `node:clear()`.
- Update from `blitz.hooks.tick`, `state_changed`, binds, commands, and
  `on_click`. Change a node only when its data changed; every change draws
  a frame.
- Sizing: unset is fit along the parent's `dir` and stretch across it.
  `grow` shares the free space. A mounted sidebar needs a `width`.
- Text content is strings and spans `{ "text", fg = "err", bold = true }`.
  `\n` starts a new line. Unwrapped text is cut with `…`.
- Colors are `#RRGGBB` or a theme name. `bg` and `fg` are inherited by
  children.
- `on_click` works on any box or text, not only buttons. `key` triggers it
  while the node is on screen and wins over `blitz.bind`.
- `node:remove()` unmounts and kills the subtree; calls on a dead handle do
  nothing. An unknown prop or slot raises.
- A reload clears the scene and re-runs the config. Tool and listener VMs
  get dead handles, so config that builds UI at load is safe there.
- `ui.root(box)` replaces the whole layout. The tree must hold
  `ui.timeline()` and `ui.composer()`; both are single nodes, every call
  returns the same one. Slots are yours to place with `ui.slot`:

  ```lua
  ui.root(ui.box({
      ui.composer(),                               -- input on top
      ui.slot({ name = "below" }),
      ui.box({ dir = "row", grow = 1,
          ui.timeline({ grow = 1 }),
          ui.slot({ name = "right", dir = "row" }),
      }),
  }))
  ```

  Mounted nodes follow their slot name into the new root and are removed
  when it has no such slot; `ui.mount` to a missing slot raises, so keep the
  default names when plugins mount. `ui.root(nil)` restores the default,
  which also returns when the timeline or composer leaves the tree. Without
  `grow` the timeline fits its content and the next node floats under it.
- `ui.canvas({ width = 10, draw = function(buf, frame) ... end })` is the
  escape hatch for free drawing. It is the only node that runs Lua per
  frame: coordinates are canvas-relative, `frame` drives animations, and an
  idle animation calls `blitz.ui.redraw()` from a tick hook. Frames run up
  to 60fps while agents run or before the first prompt, afterwards only on
  input or a scene change. A draw callback that errors is removed.
