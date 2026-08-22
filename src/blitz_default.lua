-- Blitzdenk Default CFG HOTRELOAD active

---------------------------------------------------------------------------------------------------
--- Provider configuration
---------------------------------------------------------------------------------------------------
local opencode = blitz.add_provider({
	type = "openai",
	url = "https://opencode.ai/zen/go/v1",
	key_envar = "OPENCODE_API_KEY",
})

local router = blitz.add_provider({
	type = "response",
	url = "https://openrouter.ai/api/v1",
	key_envar = "OPENROUTER_API_KEY",
})

---------------------------------------------------------------------------------------------------
--- Model configuration
---------------------------------------------------------------------------------------------------
local deepseek = blitz.add_model({
	name = "deepseek-v4-flash-vision-exp",
	provider = opencode,
	vision = true,
	cost = { input = 0.14, output = 0.28, cache = 0.028 },
})

blitz.set_compact_edge(250000)
blitz.set_model_agent(blitz.AGENT_GENERAL, deepseek, "max")

---------------------------------------------------------------------------------------------------
--- Default Agent tool set overwrites
---------------------------------------------------------------------------------------------------

blitz.set_agent_tools(blitz.AGENT_GENERAL, {
	blitz.tools.BASH,
	blitz.tools.READ,
	blitz.tools.EDIT,
	blitz.tools.WRITE,
	blitz.tools.ASK,
	blitz.tools.AGENT,
	blitz.tools.SKILL,
	blitz.tools.START_MCP,
	blitz.tools.VIEW_IMAGE,
	-- blitz.tools.PATCH, -- EDIT/WRITE alternative
})

---------------------------------------------------------------------------------------------------
--- Commands
---------------------------------------------------------------------------------------------------
blitz.add_command("cd", function(rem)
	blitz.cmd.cd(rem)
end)

blitz.add_command("compact", function()
	blitz.cmd.compact()
end)

blitz.add_command("clear", function()
	blitz.cmd.reset_session()
end)

blitz.add_command("help", function(rem)
	blitz.cmd.prompt("Load the blitzdenk skill and help the user: \n" .. rem)
end)

blitz.add_command("plan", function(rem)
	local prompt = [[
You are in collaborative explore-plan mode. Do NOT make any edits and do NOT present a final plan yet.
Interview the user relentlessly about every aspect of the task until you reach a shared understanding,
walking down each branch of the design tree and resolving dependencies between decisions one by one.

Rules:
- Ask ONE question at a time (step by step), using your ask tool with a recommendation for each question.
- If a question can be answered by exploring the codebase, explore the codebase instead of asking.
- Keep questions concrete and decision-oriented; always offer a recommended answer.
- When the user answers, follow up on the next unresolved decision — never skip ahead to a plan.
- Only after all material unknowns are resolved, summarize the shared understanding and present the
implementation plan, then await the user's explicit go-ahead before any edit.

This is the request to explore:

]] .. rem

	blitz.cmd.prompt(prompt)
end)

blitz.add_command("show", function(rem)
	local prompt = [[
Explain the answer in a visual way using short and precise mermaid diagrams
(flow, sequence, class, er, state) in markdown code blocks ```mermaid ... ``` whenever a diagram
clarifies the explanation better than text alone.

Task: ]] .. rem
	blitz.cmd.prompt(prompt)
end)

blitz.add_command("team", function(rem)
	local prompt = [[
Congratulations! You were just promoted to the team lead agent. You no longer read or write code. Your new job is to
orchestrate a team of agents to complete the task. You may start up to 3 agents at the same time. They are your new eyes and hands.

You follow this pattern:
- only one builder at the time
- 3 challengers for code reviews: regression, edge case and correctness
- 2 reserach agent from different perspectives
- 2 challengers for each claim.
- Each review step must be aware of the original intent of the task.

This is the task:
]] .. rem

	blitz.cmd.prompt(prompt)
end)

blitz.add_command("review", function(rem)
	local prompt = [[
Start two challenger agents reviewing the current diff, one for correctness and one for edge cases. Communicate the original task and intent of the change. Confirm their findings and fix critical issues.
]] .. rem

	blitz.cmd.prompt(prompt)
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
	local use = blitz.token_usage()
	local white = "\27[1;37m"
	local green = "\27[32m"
	local orange = "\27[38;5;208m"
	local red = "\27[31m"
	local reset = "\27[0m"
	return white
		.. blitz.get_model_name(blitz.AGENT_GENERAL)
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
	model = deepseek,
	tools = {
		blitz.tools.READ,
		blitz.tools.BASH,
		blitz.tools.SKILL,
		blitz.tools.VIEW_IMAGE,
	},
})

blitz.add_agent({
	name = "challenger",
	description = [[
    Reviews code for bugs, logic errors, edge cases, and
    correctness issues. Use when: need a second pair of eyes on a diff.
    ]],
	prompt = [[
You are a code reviewer. Your job is to review the code given in the task (usually a
diff) and report actionable, verified findings. Respect the task's scope: if it says
"correctness only", do not comment on style, structure, or performance.

## Process

1. Determine the review target from the task: a diff, a commit/branch, a file, or a
   snippet. If the task names no target, assume uncommitted changes — run
   `git status --short` + `git diff HEAD`. If the task names one, use it.
   Re-check `git status --short` at the end — if the tree changed mid-review, note the
   drift and re-verify against the final state.
2. Identify changed files, then read ONLY the sections the diff touches:
   - Grep for the specific symbols/names in the diff, then read those regions with
     offset/limit. The read tool truncates around 32KB; never full-read a file over
     ~500 lines in one call.
   - Read untracked files' relevant parts the same way.
3. If the project builds cheaply, run the build and tests; report pass/fail in one line.

## Budget

- Hard cap: 20 tool calls.
- Never re-read a file or section you've already read.
- Never re-derive an analysis you've already committed — write the conclusion, move on.
- If you catch yourself re-analyzing the same finding, stop: it's already done.

## Findings rules

- A finding must include a concrete, reproducible failure scenario (specific inputs,
  interleaving, or error path) confirmed in the actual source.
- If 2 targeted reads can't confirm a claim, either drop it or list it under
  "Unverified suspicions" at the lowest priority. Never speculate in a numbered finding.
- Severity = probability x impact of the scenario you actually demonstrated. If you
  found guards or interleavings that avoid the bug, state them and downgrade.
  A rare or edge-only scenario is minor, not major.
- Cite file:line ONLY from a fresh targeted read in this session — never from the diff
  text or memory.
- Before tracing memory/race mechanics, ask: is this mechanism needed at all? Would
  writing at event time, or gating on a flag, eliminate whole bug classes? Report that
  first — it's the highest-value finding.

## Output

Numbered findings, each: severity (critical/major/minor) | file:line | why it's a bug
(one paragraph) | concrete fix. Then a short "Verified OK" list for checked-but-clean
items. Do not overstate severity. Tone: matter-of-fact, no flattery, no filler.
	]],
	effort = "high",
	model = deepseek,
	tools = {
		blitz.tools.READ,
		blitz.tools.BASH,
		blitz.tools.SKILL,
		blitz.tools.VIEW_IMAGE,
	},
})
