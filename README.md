# Blitzdenk

Coding and research harness for posix systems. No dependencies, just Zig and vendored Lua.
Configure, override and extend in Lua.

![screenshot](docs/screen.jpg)

## Core features and patterns

- All IO goes through GNU core utils (ls, tee, cat, etc.)
- Enables an invisible SSH layer that agents can pipe through.
- Small: 5MB native binary, less than 200MB ram usage.
- MCP support and Skill support.
- Multi-provider: Any OpenAI or Anthropic chat schema supported. Includes local AI.
- Customize in Lua. Code your own tools, system prompts, modes, commands and loops.

## Default tools

- `write`,`edit`, `bash`,`read`, `patch`, `rg` = SSH compliant
- `Subagents` and`Forks`
- `list_tasks`, `update_task_state`, `create_task`
- `ask_user` simple multiple choice questions

If you want web search and fetch you have to do it in Lua. You'll find an example in [my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua).

## Install

You can download the pre compiled binaries from [the release page](https://github.com/Lommix/blitzdenk/releases) or build it yourself:

```
zig build --release=small
cp zig-out/bin/blitz ~/.local/bin/blitz
```

## SSH mode

Enables ssh layer all agent commands are piped through

`:ssh username@host:/path/to/cwd`

You'd better know what you're doing. If you delete something important, let me know in an issue, so I may laugh at you.

## Neovim integration

Sometimes I just want quick Info about something on in my current file. For this I have the following Neovim bind:

```lua
vim.keymap.set("n", "<leader>o", function()
	local fname = vim.fn.expand("%:p")
	local lineno = vim.fn.line(".")
	vim.cmd('vsplit | terminal blitz prompt "' .. fname .. ":" .. lineno .. ' " --log')
end, { silent = true })
```

## Lua and goal loop example

Configuration default file is under `~/.config/blitzdenk/blitz.lua`. You can put a `blitz.lua` in your local CWD for project based configuration.
There are no official docs yet. Checkout the provided [lua meta file](./src/blitz_defs.lua) for all available bindings.
You can also look at [my configuration](https://github.com/Lommix/dotfiles/blob/master/config/blitzdenk/blitz.lua), which covers at least one example per use case.

Here is some inspiration on how simple goal loops are:

```lua
--- global state
local goal_finished = false

--- the exit tool
local goal_tool = blitz.register_tool({
	name = "goal_completed",
	description = "Only call this tool, when your goal is completed",
	args = {
		goal_message = {
			type = "string",
			description = "Structured goal status report",
			required = true,
		},
	},
	func = function(ctx, call)
		ctx:set_status("Goaling completed!")
		blitz.queue.push_chat_entry("user", call.arguments.goal_message)
		goal_finished = true
		return blitz.exit_loop("Goaling completed!")
	end,
})

blitz.add_command("/goal", function(prompt)

	-- add event listener to session
	blitz.add_listener(blitz.EVENT_AGENT_COMPLETE, function(agent_id)
		-- only main agent
		if blitz.get_main_agent().index ~= agent_id.index then
			return
		end

		if goal_finished then
			return
		end

		blitz.queue.queue_agent_message(agent_id, [[
			You are in goal mode. Validate the current state of your changes against the goal.
            If the goal is determined to be finished, call `goal_completed` with a status report.

            Original goal instructions:

            ]] .. prompt)
	end)

    --- add the tool to the current set
	blitz.add_tool(blitz.AGENT_MAIN, goal_tool)

	goal_finished = false
	local main_agent_id = blitz.get_main_agent()

	blitz.queue.push_chat_entry("user", "Goal: " .. prompt)

	if main_agent_id ~= nil then
		blitz.queue.queue_agent_message(main_agent_id, "Complete the goal: " .. prompt)
	else
		blitz.queue.spawn_agent({
			effort = "max",
			prompt = "Complete the goal: " .. prompt,
			tool_budget = 1024,
			level = "write",
		})
	end
end)
```

## Contribution

No Issue, no merge. Open source, but not open contribution. Too much slop, to little time to validate. Small bug fixes are welcome.
