-- Blitzdenk Default CFG HOTRELOAD active

-- Default plugin set
blitz.plugin("blitz-core", { url = "https://github.com/Lommix/blitz-core" })
local core = require("blitz-core")

-- statusbar rendering
blitz.status_bar_render = core.statusbar

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

local codemode = core.codemode.setup({
	name = "codemode",
	tools = {
		blitz.tools.BASH,
		blitz.tools.READ,
		blitz.tools.WRITE,
		blitz.tools.EDIT,
	},
	description = [[Callable tools, each takes one table:
- bash{ command, description, timeout? }: run a shell command
- read{ file_path, offset?, limit? }: read a text file or image
- write{ file_path, content }: write a new file
- edit{ file_path, old_string, new_string, replace_all? }: replace text in a file]],
})

blitz.set_agent_tools(blitz.AGENT_GENERAL, {
	blitz.toolsets.BASH_BACKGROUND,
	blitz.tools.READ,
	blitz.tools.EDIT,
	blitz.tools.WRITE,
	blitz.tools.ASK,

	--- add plugin tool sets
	codemode,
	core.subagents.toolset,
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

blitz.add_agent({
	name = "builder",
	description = "Implements one approved slice of a spec inside a fixed write set. No user contact, no subagents.",
	prompt = [[
# You are a builder. You implement one approved slice of a spec.

The brief is your contract. It gives the spec path, the work item, the write set, the active builders, the verification command, the report path, and the output contract.

## Rules

- Work only inside the write set.
- Do not reformat or revert other builders' edits.
- Add tests only when the brief names them.
- Run the exact verification command in the brief.
- Write the full report to the report path in the brief.
- Write self-documenting code. Names carry meaning. Never write comments in code.
- Before adding complexity for a speculative or vanishingly unlikely race or security edge case, state the concrete failure mode, likelihood, and complexity cost in the report. Do not add it without the lead's approval.

    ]],
	effort = "high",
	model = default_model,
	tools = {
		blitz.tools.BASH,
		blitz.tools.READ,
		blitz.tools.WRITE,
		blitz.tools.EDIT,
	},
})
