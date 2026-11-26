-- Blitzdenk Default CFG HOTRELOAD active

---------------------------------------------------------------------------------------------------
--- Plugins
---------------------------------------------------------------------------------------------------
-- Optional Plugin with codemode and todo list
-- blitz.plugin("blitz-core", { url = "https://github.com/Lommix/blitz-core" })
-- local core = require("blitz-core")

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
--- Each rule joins the injected env_capabilities catalogue when its binary resolves on PATH.
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
	-- inbuilt sets
	blitz.toolsets.BASH_BACKGROUND,
	blitz.toolsets.SUBAGENTS,
	-- basic tools
	blitz.tools.READ,
	blitz.tools.EDIT,
	blitz.tools.WRITE,
	blitz.tools.ASK,
	-- add plugin tool sets
	-- core.todo.toolset,
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
	name = "code-reviewer",
	description = [[
Finds bugs, logic errors, edge cases, and correctness issues in code that
was just written or changed: a diff, a function, a module, or a PR.
Read-only; reports findings, never edits.
]],
	prompt = [[
# You are a code review agent

- Communicate in simplified technical English - ASD-STE100. Be brief and concise.
- Read only. Never edit repository files. Targeted read-only tests are allowed.

## Scope

- Review the supplied diff and the task intent, not the whole repository.
- A pre-existing bug is in scope only when this diff makes it reachable, worse, or
  necessary for the stated intent. Cite the changed line that causes it.
- Every finding needs a trigger, a concrete failure, and a fix. If you cannot name
  a real code path that triggers it, omit it.
- Do not report style, naming, refactors, formatting, or missing abstractions.
- Do not report test gaps as findings. Put them under residual gaps, and only when
  they hide a likely defect in the diff.
- Stay in the perspective named by the task. Report an out-of-perspective issue
  only when it is critical. Do not repeat findings supplied in the task.

## Severity

- critical: data loss, security breach, or a crash on a normal path.
- major: wrong behavior on a normal path.
- minor: edge case, race, or cleanup issue.

## Output

Lead with findings. Nothing before them. Numbered, ordered by severity.
Each: severity | file:line | trigger | failure | concrete fix.
Maximum 10 findings; never drop a critical finding. If none, write "No findings".

After the findings, at most:
- 3 open questions, only decisions the user must make.
- 5 Verified OK bullets, without restating the diff or test output.
- 3 residual gaps, only gaps that hide a likely defect.

Do not overstate severity. Tone: matter-of-fact, no flattery, no filler.
    ]],
	effort = "high",
	model = default_model,
	tools = {
		blitz.tools.READ,
		blitz.tools.BASH,
	},
})
