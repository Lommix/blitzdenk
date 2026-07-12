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
-- Provider setup (OpenAI-compatible example).
-- Choose the URL, model, and environment-variable name for your provider,
-- then uncomment and edit this block. `key_envar` is the variable name, not
-- the API key itself. Keyless local providers may use key_envar = "".
--
-- local provider = blitz.add_provider({
-- 	type = "openai",
-- 	url = "https://api.openai.com/v1",
-- 	key_envar = "OPENAI_API_KEY",
-- })
-- blitz.set_model("gpt-5.4-mini", provider)

-- Add custom bindings, using vim style keybind strings
blitz.bind("<C-s>", function()
	local png, ok = blitz.shell('grim -g "$(slurp)" -t png -')
	if ok and png and #png > 0 then
		blitz.queue.attach_screenshot(png, "image/png")
	end
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
