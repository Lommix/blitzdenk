-- Blitzdenk Default CFG HOTRELOAD active

-- Context edge used for CTX:% in the statusbar and auto-compaction.
blitz.set_compact_edge(200000)

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

-- set specific agent models
blitz.set_model_agent(blitz.AGENT_GENERAL, model, "max", novita)
blitz.set_model_agent(blitz.AGENT_EXPLORE, model, "low", novita)

-----------------------------------------------------------------------------
--- smart mode
blitz.bind("<C-u>", function()
	blitz.set_model_agent(blitz.AGENT_GENERAL, "deepseek/deepseek-v4-pro", "max", novita)
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
	local localm = "Qwen3.6-35B-A3B"
	blitz.set_model(localm, llamacpp)
	blitz.set_model_agent(blitz.AGENT_GENERAL, localm, "max", novita)
	blitz.set_model_agent(blitz.AGENT_EXPLORE, localm, "low", novita)
end)

-- Add custom commands, args is the remaining input string
blitz.add_command(":plan", function(rem)
	blitz.queue.reset_session()
	blitz.queue.spawn_agent({
		prompt = [[
        Before making ANY edits, explain your implementation plan to the user and await his go. If the a plan
        requires a unexpected structural change the user may have overlooked use your ask tool with options on how to handle
        this case.

        This is the request: "

        ]] .. rem,
	})
end)

--- Skills: just create a `skills` dir in this at this CWD. Put your markdown skills there

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

-- Agents can enable MCP servers with the `start_mcp` tool, or you can make it manually
blitz.add_command(":browser", function()
	if is_active == true then
		return
	end
	blitz.queue.push_chat_entry("system", "playwright enabled")
	blitz.mcp.enable(playmcp)
	is_active = true
end)
]]
--

-- CUSTOM TOOLS
-----------------------------------------------------------------------------
-- Example Toole: lua repl tool
local lua_repl = blitz.register_tool({
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

-- Per-agent tool overrides (full replace). Omit a call to keep defaults.
blitz.set_agent_tools(blitz.AGENT_GENERAL, {
	blitz.tools.BASH,
	blitz.tools.CANCEL_BACKGROUND,
	blitz.tools.READ,
	blitz.tools.WRITE,
	blitz.tools.EDIT,
	blitz.tools.LIST_TODOS,
	blitz.tools.UPDATE_TODO_STATE,
	blitz.tools.CREATE_TODO,
	blitz.tools.ASK,
	blitz.tools.AGENT,
	blitz.tools.AWAIT_AGENT,
	blitz.tools.CANCEL_AGENT,
	blitz.tools.SEND_MESSAGE_TO_AGENT,
	blitz.tools.RIPGREP,
	blitz.tools.LOADSKILL,
	blitz.tools.START_LSP,
	blitz.tools.START_MCP,
	lua_repl,
})

-- CUSTOM RENDER
-----------------------------------------------------------------------------
--- Create your own statusbar render
-- blitz.status_bar_render = function()
--     local use = blitz.token_usage()
-- 	return "Cache:" .. use.cache .. " | In:" .. use.input .. " | Out:" .. use.output .. " | Ctx:" .. math.floor(blitz.context_percent()) .. "%"
-- end
