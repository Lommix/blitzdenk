-- Blitzdenk Default CFG HOTRELOAD active

-- Context edge used for CTX:% in the statusbar and auto-compaction.
-- blitz.set_compact_edge(124 * 1024)

-- Optional custom statusbar renderer. The UI calls this only when Lua is free
-- and otherwise renders the last returned value.
-- blitz.status_bar_render = function()
-- 	local usage = blitz.token_usage()
-- 	return "IN:" .. usage.input .. " OUT:" .. usage.output .. " CACHE:" .. usage.cache
-- end

-----------------------------------------------------------------------------
-- Register providers configurations.
local llamacpp = blitz.add_provider({
	type = "openai",
	url = "http://localhost:8080",
	effort = "low",
	key_envar = "",
	temperature = 0.7,
})

-----------------------------------------------------------------------------
-- !!!"key_envar" IS NOT THE API KEY! iT'S THE ENVAR NAME UNDER WHICH THE KEY IS SAVED!!!
-----------------------------------------------------------------------------

-- local novita = blitz.add_provider({
-- 	type = "anthropic",
-- 	url = "https://api.novita.ai/anthropic",
-- 	key_envar = "NOVITA_API_KEY",
-- 	thinking = { type = "enabled", budget_tokens = 1024 },
-- 	temperature = 0.7,
-- })

-- open ai schema equal:
local novita = blitz.add_provider({
	type = "openai",
	url = "https://api.novita.ai/openai/v1",
	key_envar = "NOVITA_API_KEY", -- the ENVAR string, holding the api key, directly using a api key does not work!
	effort = "high",
	temperature = 0.7,
})

-----------------------------------------------------------------------------
-- Setup default model
local model = "deepseek/deepseek-v4-flash"
blitz.set_model(model, novita)
-----------------------------------------------------------------------------
--- smart mode
blitz.bind("<C-u>", function()
	blitz.set_model("deepseek/deepseek-v4-pro", novita)
end)

-- Add custom bindings, using vim style keybind strings
blitz.bind("<C-s>", function()
	local png, ok = blitz.shell('grim -g "$(slurp)" -t png -')
	if ok and png and #png > 0 then
		blitz.queue.attach_screenshot(png, "image/png")
	end
end)

-- example: switch to local ai mode
blitz.bind("<C-l>", function()
	blitz.set_model("Qwen3.6-35B-A3B", llamacpp)
end)

-- Add custom commands, args is the remaining input string
blitz.add_command(":greet", function(args)
	blitz.queue.reset_session()
	blitz.queue.spawn_agent({
		prompt = "Your job is the to greet " .. args,
	})
end)

--- Skills: just create a `skills` dir in this at this CWD. Put your markdown skills there
--- Docs and skills:

-- blitz.add_doc("zig std", "zig std lib source code", "/usr/lib/zig/std")

--- MCP support
--- register first. On enable, MCP tools are added to your current session
--[[
local playmcp = blitz.mcp.add({
	name = "playwright",
	command = "npx",
	args = {
		"-y",
		"@playwright/mcp@latest",
		"--browser=chromium",
		"--executable-path=/usr/bin/chromium",
	},
	tools_prefix = "pw_",
})

local is_active = false

-- -- custom chat command
blitz.add_command(":browser", function()
	if is_active == true then
		return
	end
	blitz.queue.push_chat_entry("system", "playwright enabled")
	blitz.mcp.enable(playmcp, blitz.AGENT_MAIN)
	is_active = true
end)
]]
--

-- compact after 128k context size
blitz.set_compact_edge(128000)

-- Per-agent tool overrides (full replace). Omit a call to keep defaults.
-- You need to overwrite this, if you want to add your custom tools
blitz.set_agent_tools(blitz.AGENT_MAIN, {
	blitz.TOOL_BASH,
	blitz.TOOL_CANCEL_AGENT,
	blitz.TOOL_AWAIT_AGENT,
	blitz.TOOL_SEND_MESSAGE_TO_AGENT,
	blitz.TOOL_READ,
	blitz.TOOL_LIST_TASKS,
	blitz.TOOL_UPDATE_TASK_STATE,
	blitz.TOOL_CREATE_TASK,
	blitz.TOOL_ASK,
	-- blitz.TOOL_PATCH, -- Some models(GPT) may prefer codex style patch for (edit,write,delte,move).
	blitz.TOOL_WRITE,
	blitz.TOOL_EDIT,
	"lua_repl", -- your tool by name
})

-- CUSTOM TOOLS
-----------------------------------------------------------------------------
-- Example Toole: lua repl tool
blitz.register_tool({
	name = "lua_repl",
	description = "Execute arbitrary Lua code and return the result. Use this tool for any math calculations",
	args = {
		code = { type = "string", description = "Lua code to execute", required = true },
	},
	func = function(ctx, call)
		ctx:set_status("lua: `" .. call.arguments.code .. "`")

		local fn, err = load(call.arguments.code)
		if not fn then
			return blitz.err(err)
		end

		local ok, result = pcall(fn)
		if not ok then
			return blitz.err(tostring(result))
		end

		return blitz.ok(tostring(result or "nil"))
	end,
})

-- CUSTOM RENDER
-----------------------------------------------------------------------------
--- Create your own statusbar render
-- blitz.status_bar_render = function()
--     local use = blitz.token_usage()
-- 	return "Cache:" .. use.cache .. " | In:" .. use.input .. " | Out:" .. use.output .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
-- end
