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

## Your own runtime

The config is not somebody else's setup. The Lua files you edit are the
sandbox you run in. A save goes live in this session within a second, and the
next step carries a `[LUA VM RELOADED]` reminder plus a refreshed tool list.

- A tool you register is your hand. List it in an agent tool set, wait for the
  reload, then call it yourself.
- A command or keybind belongs to the user. You cannot type `/name`. To use
  that behavior yourself, call the same Lua from a tool, hook, or spawned
  agent.
- The `[LUA VM RELOADED]` reminder means your last edits are live.

Smoke test what you build, in the same session. Write the Lua, let the reload
land, call the new tool, read the result, fix, repeat. Never end a tooling
task by telling the user to try it, and never move tool logic into a command
so someone else can exercise it.

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
    session_key_header = "x-session-id",
})

local deepseek = blitz.add_model({
    name = "deepseek/deepseek-v4-flash-0731",
    provider = novita,
    vision = false,
    replay_reasoning = true,
    cost = { input = 0.14, output = 0.28, cache = 0.028 },
})

blitz.set_agent_model(blitz.AGENT_GENERAL, deepseek)
blitz.set_agent_effort(blitz.AGENT_GENERAL, "max")
```

`add_provider` and `add_model` return integer handles. `vision` gates the
`view_image` tool and image pasting. Set `replay_reasoning` on chat models that
return reasoning but reject replayed history without that field (DeepSeek, GLM).
Every agent needs a bound model; unbound agents fail to spawn. Bind with
`blitz.set_agent_model(agent_type, handle)` or `model = handle` in
`blitz.add_agent`. Set the effort separately with
`blitz.set_agent_effort(agent_type, effort)`.

Pass `force = true` to either call to also swap the model on live agents of
that type: `blitz.set_agent_model(agent_type, handle, true)`. Idle
agents swap at once. An agent mid-run keeps its current model until that run
ends, then adopts the new one. A fork made during that run starts on the new
model. Without `force`, only new agents use the change.

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

Rules form the `<env_capabilities>` catalogue. It is injected once per chat as
a system-reminder. Each rule names a binary; before prompting the binary resolves through the exec pool, so the
probe runs over SSH when routing is active. A routing change re-resolves and
re-appends the catalogue to the chat. Rules only show for agents that own the
bash tool.

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
  `tonumber()` before any `blitz.agent.*` call that takes an agent id or integer;
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
`agent_id: <int>`. `fork = true` in `blitz.agent.spawn` requires `parent_id`.

Slots are finite (128) and finished agents keep their slot. History stays
readable, and `blitz.agent.message` on a finished agent starts a new turn that
continues the same conversation. Free a slot with `blitz.agent.close`.
`blitz.agent.spawn` without `parent_id` cancels the running main agent and
frees its slot; the old conversation stays rendered, the new agent replaces it
in the chat.

`blitz.list_agents()` returns one table per occupied slot, running and
finished. Fields: `agent_id`, `name`, `task`, `state`, `ctx`,
`context_tokens`, `context_limit`, `model`, `main`, `background`, `parent`,
`tps`, `queued`. `state` is one display string: `running`, `thinking`,
`writing`, `calling`, `processing`, `retrying`, `compacting`, `idle`,
`complete`, `canceled`, or `failed`. `ctx` is the context fill in percent.
`parent` is the parent's agent id, nil on roots. The task description is set
at spawn time: the agent tool fills it from its `description` argument, the
same string shown in the tool status line, and `blitz.agent.spawn` takes it
as `task = "..."`.

```lua
local agents = blitz.list_agents()
for _, a in ipairs(agents) do
    print(string.format("%s %s %d%% %s", a.name, a.state, a.ctx, a.task))
end
```

## Commands

```lua
blitz.add_command("plan", function(rem)
    blitz.cmd.reset_session()
    blitz.agent.spawn({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Plan, do not edit. Request:\n" .. rem,
    })
    blitz.cmd.message_chat("user", "[PLAN]: " .. rem)
end, "plan a task without editing")
```

The callback always receives one string: the remaining input after the
command name, `""` when none. Always declare the parameter. The optional
description shows next to the command in the completion popup.

Two tables split the queue API. `blitz.cmd` holds app commands
(`reset_session`, `cancel`, `retry`, `compact`, `prompt`, `select`, and so
on, `BlitzCmd` in `meta.lua`). `blitz.agent` holds agent bindings (`spawn`,
`message`, `await`, `result`, `cancel`, `close`, `BlitzAgent` in
`meta.lua`).

`blitz.cmd.prompt(text)` is the "say something" command: it echoes the text
into the chat and sends it to the main agent, or starts a fresh general agent
if none exists. Use it instead of `message_chat("user", ...)` (display only)
or `get_main_agent()` + `blitz.agent.message` (queues silently, no chat
echo).

## Selection

`blitz.cmd.select(request, cb)` opens the ask widget from a command and
returns at once. The request is one table: `header`, `question`, `options`
(1-8 strings), optional `allow_message` (default false) to append the
custom-message row. When the user picks, the callback runs as
`cb(option_text, index)` with a 1-based index. The custom-message row reports
`cb(message, nil)` and only exists with `allow_message = true`. A cancel
(`cancel` command, session reset, Lua reload) reports `cb(nil, nil)`.

```lua
blitz.add_command("effort", function()
    blitz.cmd.select({
        header = "Effort",
        question = "Set reasoning effort for the general agent?",
        options = { "minimal", "low", "medium", "high", "max" },
    }, function(choice)
        if choice then
            blitz.set_agent_effort(blitz.AGENT_GENERAL, choice)
            blitz.cmd.message_chat("system", "effort set to " .. choice)
        end
    end)
end, "pick agent reasoning effort")
```

Callbacks run on the main thread under the Lua lock, so they may call other
`blitz.cmd` functions, including another `select`. Permissions from agents
take the screen first; the selection shows after they resolve. Selections
need the TUI; a headless run drops them at exit.

## Keybinds

```lua
blitz.bind("<C-t>", function()
    local f = blitz.get_flags()
    f.show_thinking = not f.show_thinking
    blitz.set_flags(f)
end, "toggle thinking output")
```

The optional description shows next to the keybind in the dashboard. Without
it the row falls back to `custom`.

`set_flags` reads only the fields you pass: `show_thinking`, `show_diffs`,
and `debug_log` booleans, `approval_mode` string (`"strict"`, `"default"`,
`"yolo"`, `"smart"`). Fields you omit stay unchanged; `get_flags` returns all
four, `approval_mode` as its tag name. `smart` behaves like `default` today.
`show_diffs` is true by default; false hides diff blocks in the chat history.

The completion popup answers to `blitz.cmp.next`, `blitz.cmp.prev`, and
`blitz.cmp.accept`. Each queues one action, the same as the default keys
`<Tab>`/`<C-n>`, `<C-p>`, and `<C-y>`; a call is a no-op when the popup is
closed. A custom `blitz.bind` on the same key wins over the default.

## Hooks

Each event is one registration function under `blitz.hooks`. Calling it adds
a listener; multiple listeners per event run in registration order.
Listeners live until the config reloads; a Lua reload clears all listeners
and re-runs your config.

Every emitted event runs its listeners in one sandbox Lua VM on a
background thread, like a tool call. The config re-loads into that VM and
each listener of the event runs in registration order. Config mutation
(`add_provider`, `register_tool`, `set_agent_model`, ...) is a no-op inside
a listener. Use `blitz.state.set/get` for data across calls. The event
loop does not wait for listeners; a `blitz.agent.await` inside one listener
delays only the listeners behind it. `blitz.agent.spawn` and
`blitz.agent.await` work inside:

A listener that spawns an agent retriggers `agent_created` and
`agent_started`. Spawning from those two listeners loops without end.

`agent_started` fires on spawn and on every wake-up: a queued message, a
background agent result, or a new prompt. `ev.fresh` is true only on the
first run of a new agent; it is false on continuation runs.

```lua
blitz.hooks.user_message_sent(function(ev)
    local id = blitz.agent.spawn({
        agent_type = blitz.AGENT_GENERAL,
        prompt = "Summarize in one line: " .. ev.text,
    })
    if blitz.agent.await(id) == blitz.AWAIT_COMPLETE then
        blitz.cmd.message_chat("agent", blitz.agent.result(id))
    else
        blitz.cmd.message_chat("user", "helper agent failed")
    end
end)
```

Every payload is one table with the fields shown in `meta.lua` (`BlitzAgentEvent`,
`BlitzAgentStartedEvent`, `BlitzAgentCreatedEvent`, `BlitzAgentFailedEvent`, `BlitzUserMessageEvent`);
`session_reset` and `mcp_tools_reloaded` listeners take no argument. The full
list with signatures lives in `BlitzHooks` in `meta.lua`.

## Inject hook

`blitz.hooks.inject(fn)` installs one hook that runs for every agent on each step,
right before the system reminder is built. Return a string to append it to
that agent's `<system-reminder>` block. It runs in the main Lua VM with a
brief lock. A nil return is skipped; errors are logged and the step continues.
Last registration wins. Never call `blitz.agent.await` inside the hook.

```lua
blitz.hooks.inject(function(agent_id)
    if agent_id == blitz.get_main_agent() then
        return "[CUSTOM] main agent reminder\n"
    end
end)
```

## Permission hook

`blitz.hooks.approve(fn)` installs one hook that decides every tool
approval before the approval-mode check. It runs in every approval mode and
can deny what `--approval yolo` would auto-approve. Last registration wins;
`blitz.hooks.clear()` removes the approve and inject hooks.

Return a `BlitzPermissionDecision` table, or `nil` for the normal flow
(approval mode, then TUI):

- `{ approved = true }` — allow the call. On ask payloads this picks the
  first option marked `(recommended)` (like the headless runner).
- `{ approved = false }` — deny
- `{ approved = false, msg = "..." }` — deny, `msg` reaches the model as tool error
- `{ approved = false, select = 2 }` — ask payloads only: pick the 1-based
  option. Ignored on other kinds and when `approved` is true. Out-of-range
  values deny. On ask, a denial without `select` denies the question.

A malformed table (missing `approved`) denies with a fixed reason. A hook
error denies with `permission hook error: <msg>`.

```lua
blitz.hooks.approve(function(p)
    if p.kind == "diff" and p.path:find("^/tmp/") then
        return { approved = true }
    end
    if p.tool == "bash" and p.description:find("rm ") then
        return { approved = false, msg = "no destructive commands" }
    end
    return nil
end)
```

The payload is `BlitzPermissionPayload` in `meta.lua`: `agent_id`, `call_id`,
`kind` (`call|diff|ask|plan`), `tool`, plus the kind fields. The decision
shape is `BlitzPermissionDecision` in the same file.

Never call `blitz.agent.await` inside the hook. The hook runs on the main
thread; the await would block the loop that runs the agent. The hook runs
before the ticket exists, so `blitz.permissions.resolve` from inside it always
misses.

## Permission queue

Requests that pass the approve hook untouched and miss auto-approval park in a
pending set. Each parked request gets an integer `ticket`, and Lua can inspect
and decide parked requests at any time from commands, keybinds, or event
listeners. `list_pending()` returns an array of snapshot tables, `get(ticket)`
one snapshot or nil, and `resolve(ticket, decision)` decides one ticket. It
returns `false` for unknown or already-resolved tickets. Snapshots carry
`ticket`, `agent_id`, `call_id`, `kind`, `tool`, and the kind fields, the same
shape as the hook payload; `decision` takes the same `BlitzPermissionDecision`
table as the approve hook, including `msg` and ask `select`. Requests whose
agent died deny on resolve no matter what the decision says.

`blitz.hooks.permission_requested(fn)` fires when a request parks. The event
carries the ticket; fetch details with `blitz.permissions.get`. Listeners run
in the sandbox VM, so they may spawn agents. The lazy reviewer pattern: the
listener only spawns a judge agent, and the judge decides by calling a custom
tool that resolves the ticket. No awaiting, no answer parsing.

Give the reviewer read-only tools plus the review tool. Tool calls from the
reviewer emit their own permission events, and a reviewer that can run bash
spawns reviewers without end. Unresolved tickets fall back to the TUI. A
snapshot never goes stale, only `resolve` can fail late.

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

## SSH mode

While ssh routing is on, every call (bash, read, write, edit,
patch, search, `blitz.shell`) wraps in `ssh user@host` instead of running
locally. Requires `yolo` approval level for auto approval.

The TUI owns the connection: `/ssh user@host:~/dir` or `/ssh-<alias>` establishes the
target, `/ssh off` clears it. Lua only flips the routing flag:

```lua
blitz.ssh.enable()
blitz.ssh.disable()
```

`blitz.ssh.get_state()` reads the live state: `{ active, user, host, cwd }`.
`active` is true while tool calls actually route through ssh, so it implies a
target and all three fields are set. After `disable` the target fields stay
but `active` is false. Safe to call from config, tools, and listeners.

```lua
local s = blitz.ssh.get_state()
if s.active then
    blitz.cmd.message_chat("system", "routing to " .. s.user .. "@" .. s.host)
end
```

`blitz.shell` opts carry `force_local`: true runs the command on this machine
and skips the ssh wrap. Use it for commands that only make sense locally, like
`git status` before a push or a local `ssh-add` check.

Calls are safe from config, tools, and listeners.

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

## Drawing

`blitz.draw` reserves screen regions and paints them from Lua.

```lua
local sb = blitz.draw.sidebar({
    side = "left",
    width = 24,
    render = function(w, h, buf)
        buf.box(0, 0, w, h, "muted")
        buf.set_color(1, 1, "sessions", "#A50000")
        buf.set(1, 2, "active")
    end,
})

local panel = blitz.draw.panel({
    height = 8,
    place = "between",
    render = function(w, h, buf)
        buf.fill(0, 0, w, h, "overlay_dark")
        buf.set(0, 0, "context")
    end,
})
```

A sidebar spans the full terminal height on its side. A panel attaches to the
input widget and follows it: `place = "between"` (default) sits it directly
above the input, `place = "below"` directly under it.

Coordinates are widget-relative, (0,0) top-left. Writes outside the widget
rect clip silently. Colors are `#RRGGBB` hex or theme names (`text`, `muted`,
`info`, `err`, ...). `set` writes theme text color, `set_color` a given
foreground, `fill` a solid background, `rect` a one cell background outline,
`box` a unicode line border.

Render callbacks run on every drawn frame, up to 60fps while agents run or
before the first prompt is sent. Afterwards the app draws only on input, so
animations call `blitz.draw.redraw()` to force frames. Keep the callback pure
drawing: no awaits, no long work, or frames drop.

Both calls return a handle with `show()`, `hide()`, `remove()` and
`set_size(cells)`. One sidebar per side: a second `sidebar` call on the same
side replaces the first and its handle goes dead.

## Skills

Skills are markdown files discovered from three ranked layers: project
`.blitz/skills` (highest), project `.agents/skills`, and user
`~/.config/blitzdenk/skills`. Project skills shadow same-named user skills.
The project root is the nearest ancestor of the working directory containing
`.git`.

Frontmatter keys: `name` (kebab-case), `description`, optional `whenToUse`,
`user-invocable` (default true), and `disable-model-invocation` (default
false). Unknown keys are ignored. Keys and values may be single- or
double-quoted; double quotes decode `\"` and `\\` escapes, single quotes
decode `''` doubling. Descriptions support YAML folded (`>`) and literal
(`|`) block scalars with chomp indicators (`>-`, `|+`); chomping itself is
ignored, and digit indentation indicators (`>2`) are unsupported.
