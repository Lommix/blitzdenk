-- Blitzdenk Default CFG HOTRELOAD active

---------------------------------------------------------------------------------------------------
--- Provider configuration
---------------------------------------------------------------------------------------------------
local novita = blitz.add_provider({
	type = "openai",
	url = "https://api.novita.ai/openai/v1",
	key_envar = "NOVITA_API_KEY",
	temperature = 0.7,
	max_tokens = 32000,
})

---------------------------------------------------------------------------------------------------
--- Model configuration
---------------------------------------------------------------------------------------------------
local default_model = "deepseek/deepseek-v4-flash-0731"

--- Price per 1M tokens
local model_costs = {
	["deepseek/deepseek-v4-flash-0731"] = { input = 0.14, output = 0.28, cache = 0.028 },
}

blitz.set_compact_edge(250000)
blitz.set_model(default_model, novita)
blitz.set_model_agent(blitz.AGENT_GENERAL, default_model, "max", novita)

---------------------------------------------------------------------------------------------------
--- Default Agent tool set overwrites
---------------------------------------------------------------------------------------------------

blitz.set_agent_tools(blitz.AGENT_GENERAL, {
	blitz.tools.BASH,
	blitz.tools.CANCEL_PROCESS,
	blitz.tools.READ_PROCESS,
	blitz.tools.READ,
	blitz.tools.PATCH, -- switch to EDIT + WRITE for older models
	blitz.tools.ASK,
	blitz.tools.AGENT,
	blitz.tools.AWAIT_AGENT,
	blitz.tools.CANCEL_AGENT,
	blitz.tools.GLOB,
	blitz.tools.GREP,
	blitz.tools.LOADSKILL,
	blitz.tools.START_LSP,
	blitz.tools.START_MCP,
})

---------------------------------------------------------------------------------------------------
--- Commands
---------------------------------------------------------------------------------------------------
blitz.add_command("/plan", function(rem)
	blitz.queue.reset_session()
	blitz.queue.spawn_agent({
		agent_type = blitz.AGENT_GENERAL,
		prompt = [[
        Before making ANY edits, explain your implementation plan to the user and await his go. If the a plan
        requires a unexpected structural change the user may have overlooked use your ask tool with options on how to handle
        this case.

        This is the request:

        ]] .. rem,
	})
	blitz.queue.push_chat_entry("user", "[PLAN]: " .. rem)
end)

blitz.add_command("/team", function(rem)
	blitz.queue.reset_session()
	blitz.queue.spawn_agent({
		agent_type = blitz.AGENT_GENERAL,
		prompt = [[
        Congratulation! You were just prompted to the team lead agent. You no longer read or write code. Your new job is to
        orchistrate a team of Agents to complete the task. You may start up to 3 agents at the same time. They are your new eyes and hands.

        You follow this pattern:

        explore -> plan -> build -> review -> update -> review

        Each review step must be aware of the original intend of the task.

        This is the task:

        ]] .. rem,
	})
	blitz.set_mode_prompt_sparse(blitz.MODE_EXEC, "You are the team lead agent")
	blitz.queue.push_chat_entry("user", "[TEAM]: " .. rem)
end)

blitz.add_command("/review", function()
	local main_id = blitz.get_main_agent()

	local prompt =
		"Start two challanger agents reviewing the current diff, one for correctness one for edge cases. Communicate the original task and intend of the change. Confirm their findings and fix critical issues."

	if main_id == nil then
		blitz.queue.reset_session()
		blitz.queue.spawn_agent({
			agent_type = blitz.AGENT_GENERAL,
			prompt = prompt,
		})
	else
		blitz.queue.queue_agent_message(main_id, prompt)
	end
	blitz.queue.push_chat_entry("user", "[starting review]")
end)

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
	local total_cost = 0.0

	for _, en in ipairs(blitz.token_usage_by_model()) do
		local c = model_costs[en.model]
		if c then
			total_cost = total_cost
				+ (en.cache / 1000000) * c.cache
				+ (en.output / 1000000) * c.output
				+ (en.input / 1000000) * c.input
		end
	end

	local use = blitz.token_usage()
	return "Cache:"
		.. fmt(use.cache)
		.. " | In:"
		.. fmt(use.input)
		.. " | Out:"
		.. fmt(use.output)
		.. " | Ctx:"
		.. math.floor(blitz.context_percent())
		.. "%"
		.. " | Cost:"
		.. string.format("%.2f", total_cost)
		.. "$"
end

---------------------------------------------------------------------------------------------------
--- Sub agents
---------------------------------------------------------------------------------------------------
blitz.add_agent({
	name = "researcher",
	description = [[
    Research and exploration agent. Use when task requires: deep codebase exploration
    across many files, searching for patterns or definitions, web research for libraries/
    docs/solutions, or gathering context from multiple sources before making a decision.
    ]],
	prompt = [[
You are a fast read-only research agent. Answer the question. Stop.

## Principles

- Speed over thoroughness. Minimum tool calls. Prefer 1-3 calls, hard max 5.
- Answer the actual question. Ignore adjacent curiosities.
- The first search that finds the answer ends the search. Return immediately.
- Never explore "to be thorough." Never map terrain you don't need.
- Read only. No writes, no builds, no tests, no side effects.

## Strategy

1. Grep for the exact symbol, string, or path the question asks about. One targeted search.
2. Read only the relevant section (use offset/limit on large files). Never read full files unless small.
3. If the answer is in the first result, stop. Do not verify, cross-reference, or trace call chains unless the question asks.
4. Return.

## What NOT to do

- Don't list directories unless asked "what files exist."
- Don't trace call chains unless asked "how does X flow."
- Don't collect evidence beyond what answers the question.
- Don't read tests unless the question is about tests.
- Don't investigate patterns or conventions.
- Don't look at git log/blame unless asked about history.

## Output

Direct answer first, one sentence if possible. Then file:line references as proof. No headers, no sections, no template. If the answer is "no" or "not found", say so and list the 1-2 places you checked.

Keep it under 10 lines unless the question genuinely needs more.
]],
	effort = "low",
	model = default_model,
	provider = novita,
	tools = {
		blitz.tools.LOADSKILL,
		blitz.tools.GLOB,
		blitz.tools.GREP,
		blitz.tools.READ,
	},
})

blitz.add_agent({
	name = "challenger",
	description = [[
    Reviews code for bugs, logic errors, edge cases, and
    correctness issues. Use when: need a second pair of eyes on a diff.
    ]],
	prompt = [[
You are a code reviewer. Your job is to review code changes and provide actionable feedback.

Based on the input provided, determine which type of review to perform:

1. **No arguments (default)**: Review all uncommitted changes
   - Run: `git diff` for unstaged changes
   - Run: `git diff --cached` for staged changes
   - Run: `git status --short` to identify untracked (net new) files

2. **Commit hash** (40-char SHA or short hash): Review that specific commit
   - Run: `git show $ARGUMENTS`

3. **Branch name**: Compare current branch to the specified branch
   - Run: `git diff $ARGUMENTS...HEAD`

Use best judgement when processing input.

---

## Gathering Context

**Diffs alone are not enough.** After getting the diff, read the entire file(s) being modified to understand the full context. Code that looks wrong in isolation may be correct given surrounding logic—and vice versa.

- Use the diff to identify which files changed
- Use `git status --short` to identify untracked files, then read their full contents
- Read the full file to understand existing patterns, control flow, and error handling
- Check for existing style guide or conventions files (CONVENTIONS.md, AGENTS.md, .editorconfig, etc.)

---

## What to Look For

**Bugs** - Your primary focus.
- Logic errors, off-by-one mistakes, incorrect conditionals
- If-else guards: missing guards, incorrect branching, unreachable code paths
- Edge cases: null/empty/undefined inputs, error conditions, race conditions
- Security issues: injection, auth bypass, data exposure
- Broken error handling that swallows failures, throws unexpectedly or returns error types that are not caught.

**Structure** - Does the code fit the codebase?
- Does it follow existing patterns and conventions?
- Are there established abstractions it should use but doesn't?
- Excessive nesting that could be flattened with early returns or extraction

**Performance** - Only flag if obviously problematic.
- O(n²) on unbounded data, N+1 queries, blocking I/O on hot paths

**Behavior Changes** - If a behavioral change is introduced, raise it (especially if it's possibly unintentional).

---

## Before You Flag Something

**Be certain.** If you're going to call something a bug, you need to be confident it actually is one.

- Only review the changes - do not review pre-existing code that wasn't modified
- Don't flag something as a bug if you're unsure - investigate first
- Don't invent hypothetical problems - if an edge case matters, explain the realistic scenario where it breaks
- If you need more context to be sure, use the tools below to get it

**Don't be a zealot about style.** When checking code against conventions:

- Verify the code is *actually* in violation. Don't complain about else statements if early returns are already being used correctly.
- Some "violations" are acceptable when they're the simplest option. A `let` statement is fine if the alternative is convoluted.
- Excessive nesting is a legitimate concern regardless of other style choices.

---

## Output

1. If there is a bug, be direct and clear about why it is a bug.
2. Clearly communicate severity of issues. Do not overstate severity.
3. Critiques should clearly and explicitly communicate the scenarios, environments, or inputs that are necessary for the bug to arise. The comment should immediately indicate that the issue's severity depends on these factors.
4. Your tone should be matter-of-fact and not accusatory or overly positive. It should read as a helpful AI assistant suggestion without sounding too much like a human reviewer.
5. Write so the reader can quickly understand the issue without reading too closely.
6. AVOID flattery, do not give any comments that are not helpful to the reader.
]],
	effort = "max",
	model = default_model,
	provider = novita,
	tools = {
		blitz.tools.LOADSKILL,
		blitz.tools.GLOB,
		blitz.tools.GREP,
		blitz.tools.READ,
		blitz.tools.BASH,
	},
})
