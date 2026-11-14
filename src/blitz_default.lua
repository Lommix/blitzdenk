-- Blitzdenk Default CFG HOTRELOAD active

-- Default plugin set
blitz.plugin("blitz-core", { url = "https://github.com/Lommix/blitz-core" })
local core = require("blitz-core")

---------------------------------------------------------------------------------------------------
--- Theme configuration
---------------------------------------------------------------------------------------------------
blitz.set_theme({
	bg = "#282c34",
	overlay_dark = "#21252b",
	overlay = "#2c313a",
	border = "#3e4451",
	muted = "#5c6370",
	text = "#abb2bf",
	text_hl = "#d7dae0",
	ok = "#98c379",
	info = "#61afef",
	warn = "#e5c07b",
	err = "#e06c75",
	on_err = "#282c34",
	diff_surface = "#333842",
	diff_add = "#98c379",
	diff_remove = "#e06c75",
	role_user = "#61afef",
	role_agent = "#c678dd",
	role_system = "#56b6c2",
})

---------------------------------------------------------------------------------------------------
--- Model configuration
---------------------------------------------------------------------------------------------------
local default_model = nil

local ok, provider = pcall(require, "provider")
if ok and type(provider) == "number" then
	default_model = provider
	blitz.set_agent_model(blitz.AGENT_GENERAL, default_model)
	blitz.set_agent_effort(blitz.AGENT_GENERAL, "high")
end

blitz.set_compact_edge(250000)

---------------------------------------------------------------------------------------------------
--- Env capability rules
--- Each rule joins the injected env_capabilities catalogue when its binary
--- resolves on PATH.
---------------------------------------------------------------------------------------------------
blitz.set_capabilities({
	{ binary = "rg", rule = "Use rg for fast recursive grep searches. Prefer rg over grep." },
	{ binary = "fd", rule = "Use fd for fast file discovery. Prefer fd over find." },
	{ binary = "jq", rule = "Use jq to parse and filter JSON data." },
})

---------------------------------------------------------------------------------------------------
--- Default Agent tool set overwrites
---------------------------------------------------------------------------------------------------
blitz.set_agent_tools(blitz.AGENT_GENERAL, {
	blitz.toolsets.BASH_BACKGROUND,
	blitz.tools.READ,
	blitz.tools.EDIT,
	blitz.tools.WRITE,
	blitz.tools.ASK,

	--- add plugin tool sets
	core.codemode,
	core.agents.toolset,
	core.todo.toolset,
})

---------------------------------------------------------------------------------------------------
--- Custom keybinds
---------------------------------------------------------------------------------------------------
blitz.bind("<C-t>", function()
	local f = blitz.get_flags()
	f.show_thinking = not f.show_thinking
	blitz.set_flags(f)
end, "show thinking")

---------------------------------------------------------------------------------------------------
--- Commands
---------------------------------------------------------------------------------------------------
blitz.add_command("effort", function()
	blitz.cmd.select({
		questions = {
			{
				header = "Effort",
				question = "Set reasoning effort for the general agent?",
				options = { "low", "medium", "high", "xhigh", "max" },
				allow_message = false,
			},
		},
	}, function(answers)
		if answers then
			blitz.set_agent_effort(blitz.AGENT_GENERAL, answers[1][1].text, true)
		end
	end)
end, "set effort level")

blitz.add_command("cd", function(rem)
	blitz.cmd.cd(rem)
end, "cd to dir")

blitz.add_command("compact", function()
	blitz.cmd.compact()
end, "manual compact")

blitz.add_command("clear", function()
	blitz.cmd.reset_session()
end, "reset session")

blitz.add_command("help", function(rem)
	blitz.cmd.prompt("Load the blitzdenk skill and help the user: \n" .. rem)
end, "help user")

---------------------------------------------------------------------------------------------------
--- Custom status bar render
---------------------------------------------------------------------------------------------------
local function fmt(n)
	local units = { "k", "M", "G" }
	local u = 0
	while n >= 1000 and u < #units do
		n = n / 1000
		u = u + 1
	end
	if u == 0 then
		return tostring(math.floor(n))
	end
	return string.format("%.1f%s", n, units[u])
end

blitz.status_bar_render = function()
	local use = blitz.token_usage()
	local white = "\27[1;37m"
	local green = "\27[32m"
	local orange = "\27[38;5;208m"
	local red = "\27[31m"
	local reset = "\27[0m"

	local model = blitz.get_model_name(blitz.AGENT_GENERAL)
	local effort = blitz.get_agent_effort(blitz.AGENT_GENERAL)
	local main_id = blitz.get_main_agent()
	if main_id ~= nil then
		model = blitz.agent.get_model(main_id)
		effort = blitz.agent.get_effort(main_id)
	end

	return white
		.. model
		.. " • "
		.. effort
		.. reset
		.. " | Cache:"
		.. green
		.. fmt(use.cache)
		.. reset
		.. " | In:"
		.. orange
		.. fmt(use.input)
		.. reset
		.. " | Out:"
		.. orange
		.. fmt(use.output)
		.. reset
		.. " | Ctx:"
		.. math.floor(blitz.context_percent())
		.. "%"
		.. " | Cost:"
		.. red
		.. string.format("%.2f", use.cost)
		.. reset
		.. "$"
end

---------------------------------------------------------------------------------------------------
--- Sub agents
---------------------------------------------------------------------------------------------------
blitz.add_agent({
	name = "researcher",
	description = [[
Answers questions by reading code, files, docs, or the web. Locates
definitions, symbols, paths, and patterns; reports facts, never opinions
on code quality. Not for finding bugs in written code; use code-reviewer.
]],
	prompt = [[
# You are a research and exploration agent

- Read only! No writes, no builds, no tests, no side effects.
- Communicate in simplified technical English - ASD-STE100. Be brief and concise.

	]],
	effort = "medium",
	model = default_model,
	tools = {
		blitz.tools.READ,
		blitz.tools.BASH,
	},
})

blitz.add_agent({
	name = "code-reviewer",
	description = [[
Finds bugs, logic errors, edge cases, and correctness issues in code that
was just written or changed: a diff, a function, a module, or a PR.
Read-only; reports findings, never edits.
]],
	prompt = [[
# You are a code review agent

- Communicate in simplified technical English - ASD-STE100. Be brief and concise.
- Read only! No writes, no fixes. You only report back to the user.

## Output

Lead with findings, nothing else before them. Numbered, ordered by severity
(critical/major/minor), each: severity | file:line | why it's a bug (one paragraph) |
concrete fix. After the findings, in order: open questions or assumptions, then a
short "Verified OK" list for checked-but-clean items. Keep summaries brief and only
after the issues. If no findings, state it explicitly and list residual risks or
testing gaps. Do not overstate severity. Tone: matter-of-fact, no flattery, no filler.

	]],
	effort = "high",
	model = default_model,
	tools = {
		blitz.tools.READ,
		blitz.tools.BASH,
	},
})
