-- Blitzdenk Default CFG HOTRELOAD active

---------------------------------------------------------------------------------------------------
--- Plugins
---------------------------------------------------------------------------------------------------
-- Optional Plugin with subagents, codemode and todo list
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
	blitz.toolsets.BASH_BACKGROUND,
	blitz.tools.READ,
	blitz.tools.EDIT,
	blitz.tools.WRITE,
	blitz.tools.ASK,
	-- add plugin tool sets
	-- core.subagents.toolset,
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
