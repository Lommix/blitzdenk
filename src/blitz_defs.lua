---@meta

---@class BlitzStatus
---@field status integer One of blitz.RET_FAILED | blitz.RET_OK | blitz.RET_ERR
---@field msg? string Optional message (set by blitz.ok / blitz.err)
---Status table returned from a tool function.

---@class BlitzCtx
---@field cwd string Current working directory
---@field agent_id BlitzAgentId Id of the calling agent ({index, generation})
---@field state table Persistent per-tool state table (survives across ticks)
local BlitzCtx = {}

---Set agent status message
---@param msg string
function BlitzCtx:set_status(msg) end

---Attach a spawned child agent to the current tool call. The TUI uses this
---to render the child's status under the calling tool entry. Call once per
---spawn; calling again overwrites the previous association.
---@param agent_id BlitzAgentId
function BlitzCtx:set_child_id(agent_id) end

---Ask user to confirm a tool call. BLOCKING: returns once the user resolves
---the request. The Lua VM is serialized across worker threads via a mutex —
---Lua tools run one-at-a-time while native tools run in parallel.
---@param tool_name string
---@param tool_arguments string Raw JSON string of tool arguments
---@return integer status One of blitz.REQ_STATUS_APPROVED | REQ_STATUS_DENIED | REQ_STATUS_MESSAGE
---@return string|nil payload Message text when status == REQ_STATUS_MESSAGE
function BlitzCtx:approve(tool_name, tool_arguments) end

---Submit a plan for user approval. BLOCKING (see ctx:approve).
---@param path string Path to plan file
---@param plan_text string Plan content (markdown)
---@return integer status One of blitz.REQ_STATUS_APPROVED | REQ_STATUS_DENIED | REQ_STATUS_MESSAGE
---@return string|nil payload Message text when status == REQ_STATUS_MESSAGE
function BlitzCtx:plan(path, plan_text) end

---Ask the user a multiple-choice question. BLOCKING.
---@param header string
---@param question string
---@param options string[]
---@return integer status One of blitz.REQ_STATUS_CHOICE | REQ_STATUS_MESSAGE | REQ_STATUS_DENIED
---@return string|nil payload Chosen option string for CHOICE; message text for MESSAGE
function BlitzCtx:ask(header, question, options) end

---@class BlitzCall
---@field id string Unique call ID
---@field name string Tool name
---@field arguments table Parsed arguments as Lua table

---@class BlitzArgDef
---@field type string JSON schema type ("string", "number", "boolean", etc.)
---@field description string Argument description
---@field required? boolean Mark as required (default false)

---@class BlitzToolDef
---@field name string Tool name
---@field description string Tool description
---@field schema? string Raw JSON schema string (backward compat)
---@field args? table<string, BlitzArgDef> Argument definitions
---@field func fun(ctx: BlitzCtx, call: BlitzCall): BlitzStatus Tool handler. Must return a status table:
--- - `return blitz.ok("content")` → complete success
--- - `return blitz.err("message")` → complete error
--- - `return blitz.FAILED` → permanent failure
---
--- Tool functions run as Zig coroutines on worker threads. Bridge calls
--- like `ctx:approve` block the worker until the user resolves them; from
--- Lua's perspective they are synchronous.

---@class Blitz
---@field status_bar_render? fun(): string Custom statusbar renderer. Called only when the Lua VM is free; the UI reuses the last returned string while Lua is busy.
---@field json BlitzJson JSON encode/decode helpers.
---@field html_to_markdown fun(html: string): string Convert HTML to markdown using the built-in parser.
---@field AGENT_GENERAL integer Main agent type id
---@field AGENT_EXPLORE integer Explorer sub-agent type id
---@field AGENT_REVIEW integer Review sub-agent type id
---@field MODE_EXEC integer Exec mode id
---@field TOOL_BASH string Built-in tool name
---@field TOOL_CANCEL_BACKGROUND string Built-in tool name
---@field TOOL_READ string Built-in tool name
---@field TOOL_WRITE string Built-in tool name
---@field TOOL_EDIT string Built-in tool name
---@field TOOL_PATCH string Patch tool as write/edit replacement. GPT loves it!
---@field TOOL_AGENT string Subagents and Forks
---@field TOOL_LIST_TASKS string Built-in tool name
---@field TOOL_UPDATE_TASK_STATE string Built-in tool name
---@field TOOL_CREATE_TASK string Built-in tool name
---@field TOOL_ASK string Multiple choice for users
---@field TOOL_EXIT_PLAN_MODE string plan suggestion tool, accept -> session reset + auto start
---@field TOOL_PLAN_AGENT string experimental subagent for planning implementations.
---@field TOOL_ENTER_SSH string agent tool to change tool target and cwd
---@field TOOL_EXIT_SSH string agent tool to change tool target and cwd
---@field TOOL_SEND_MESSAGE_TO_AGENT string Send a message to a running agent
---@field TOOL_AWAIT_AGENT string Wait for an agent to finish and read its result
---@field TOOL_CANCEL_AGENT string Cancel a running agent
---@field REQ_STATUS_PENDING integer 0
---@field REQ_STATUS_APPROVED integer 1
---@field REQ_STATUS_DENIED integer 2
---@field REQ_STATUS_CHOICE integer 3
---@field REQ_STATUS_MESSAGE integer 4
---@field AWAIT_COMPLETE integer 1
---@field AWAIT_FAILED integer 2
---@field AWAIT_CANCELED integer 3
---@field AWAIT_INVALID integer 4
blitz = {}

---@class BlitzTokenUsage
---@field input integer Input tokens
---@field output integer Output tokens
---@field cache integer Cached input tokens
---@field cache_creation integer Cache creation tokens

---@class BlitzThinking
---@field type string "enabled" or "adaptive"
---@field budget_tokens? integer

---@class BlitzProviderDef
---@field type string Provider type: "openai", "anthropic", or "ollama" (required)
---@field url string Provider API base URL (required)
---@field key_envar string Environment variable name for API key, empty string for no auth (required)
---@field temperature? number
---@field max_tokens? integer
---@field top_p? number
---@field top_k? integer Only for anthropic/ollama
---@field max_completion_tokens? integer Only for openai
---@field frequency_penalty? number Only for openai
---@field presence_penalty? number Only for openai
---@field thinking? BlitzThinking Only for anthropic/openai
---@field effort? string "none" | "low" | "high" | "xhigh" | "max" Provider reasoning effort
---Note: `stop` sequences are not exposed through Lua.

---@class BlitzMcpServerDef
---@field name string Stable server name used for default tool prefixes
---@field transport? string Only "stdio" is currently supported
---@field command string Executable to spawn
---@field args? string[] Command arguments
---@field tools_prefix? string Prefix for imported tool names (default: "mcp_<name>_")

---Register a provider.
---@param def BlitzProviderDef
---@return integer handle Provider handle for use with blitz.set_model
function blitz.add_provider(def) end

---Set the default model
---@param model string Model name/identifier
---@param handle integer Provider handle from blitz.add_provider
function blitz.set_model(model, handle) end

---Set the model config for specific agent
---@param agent_type integer the agent type id
---@param model string Model name/identifier
---@param effort string "none" | "low" | "medium" | "high" | "xhigh" | "max" Provider reasoning effort
---@param handle integer Provider handle from blitz.add_provider
function blitz.set_model_agent(agent_type, model, effort, handle) end

---Register a documentation source
---@param name string Display name
---@param description string Purpose description
---@param location string File or directory path
function blitz.add_doc(name, description, location) end

---Write a debug log line. Forwards to std.log.scoped(.lua) which the custom
---routes to CWD/.blitz/debug.log.
---@param msg string
function blitz.log(msg) end

---Return token usage currently shown by the statusbar.
---@return BlitzTokenUsage
function blitz.token_usage() end

---Return main-agent context fill percentage currently shown by the statusbar.
---@return number
function blitz.context_percent() end

---Set the default context edge, in tokens, used for statusbar percentage and auto-compaction.
---Applies to existing agents and to agents created later.
---@param tokens integer
function blitz.set_compact_edge(tokens) end

--- get the main agent, if a session is running
---@return BlitzAgentId | nil
function blitz.get_main_agent() end

---Register a tool
---@param def BlitzToolDef
---@return string
function blitz.register_tool(def) end

---Override the tool set for a given agent type. Replaces defaults entirely.
---Names must match built-in tool names (see blitz.TOOL_*) or names of tools
---registered via blitz.register_tool. Unknown names are silently skipped.
---@param agent_type integer One of blitz.AGENT_GENERAL | blitz.AGENT_EXPLORE | blitz.AGENT_REVIEW
---@param tool_names string[] List of tool names this agent should have
function blitz.set_agent_tools(agent_type, tool_names) end

---Add a single tool from the tool pool to an agent type's tool set.
---@param agent_type integer One of blitz.AGENT_GENERAL | blitz.AGENT_EXPLORE | blitz.AGENT_REVIEW
---@param tool_name string Tool name to add from the pool
function blitz.add_tool(agent_type, tool_name) end

---Push a new popup notification with a lifetime of 8s to the top right corner
---@param message string
function blitz.push_notification(message) end

---Override the system prompt for a given agent type.
---@param agent_type integer One of blitz.AGENT_GENERAL | blitz.AGENT_EXPLORE | blitz.AGENT_REVIEW
---@param prompt string Full prompt text
function blitz.set_prompt(agent_type, prompt) end

---Override the mode reminder prompt (full variant).
---@param mode integer One of blitz.MODE_EXEC | blitz.MODE_RESEARCH
---@param prompt string Reminder text appended on first turn
function blitz.set_mode_prompt(mode, prompt) end

---Override the sparse mode reminder prompt (subsequent turns).
---@param mode integer One of blitz.MODE_EXEC | blitz.MODE_RESEARCH
---@param prompt string Sparse reminder text
function blitz.set_mode_prompt_sparse(mode, prompt) end

---@param name string Short display label
---@param color string hex color string like '#232323'
---@param prompt string full mode prompt
---@param sparse string short mode reminder
---@return integer mode_id the mode id
function blitz.add_mode(name, color, prompt, sparse) end

---Override the display name shown for a mode in the status bar.
---@param mode integer One of blitz.MODE_EXEC | blitz.MODE_RESEARCH
---@param name string Short display label
function blitz.set_mode_name(mode, name) end

---Switch the active session mode. Forces a full mode-reminder on the next turn.
---@param mode integer One of blitz.MODE_EXEC | blitz.MODE_RESEARCH
function blitz.set_mode(mode) end

---@class BlitzAppFlags
---@field show_thinking boolean
---@field debug_log boolean
---@field ssh_agent_control boolean
---@field skip_permissions boolean
local BlitzAppFlags = {}

---Return the current app flags.
---@return BlitzAppFlags
function blitz.get_flags() end

---Set the app flags from a table. Missing fields are set to their
---default values (all true), not preserved from the current state.
---@param flags BlitzAppFlags
function blitz.set_flags(flags) end

---Bind a vim-style key combo to a lua callback
---Examples: "<C-c>", "<M-S-a>", "<Esc>", "<Up>", "<F1>", "a"
---@param key string Vim-style key combo
---@param func fun() Callback invoked when key pressed
function blitz.bind(key, func) end

---Bind a colon command to a lua callback
---Example: blitz.add_command(":help", function(args) end)
---@param command string Command name including leading colon
---@param func fun(args: string) Callback invoked with remaining args or empty string
function blitz.add_command(command, func) end

---Bind an event listner
---Example: blitz.add_listner(blitz.EVENT_MODE_CHANGED, function(new_mode_id) end)
---@param Event integer EventType. Check blit.EVENT_.. for more information
---@param func fun(unknown) Args are in the Event description
function blitz.add_listener(Event, func) end

---@class BlitzAgentId
---@field index integer Slot index (u16)
---@field generation integer Slot generation (u16)

---@class BlitzSpawnArgs
---@field parent_id? BlitzAgentId Parent agent (required when fork=true)
---@field prompt string Initial user prompt (wrapped as a single text content part)
---@field agent_type? integer One of blitz.AGENT_* (default AGENT_GENERAL)
---@field tool_budget? integer Max tool calls (default 64)
---@field fork? boolean Fork the parent slot instead of spawning fresh (default false)
---@field level? string Permission level "read" | "write" (default "read")

---@class BlitzQueue
---Thread-safe deferred mutation of app state. Commands enqueue from any
---thread; the UI thread drains them once per tick.
local BlitzQueue = {}

---Reset the active session (drops the main agent, clears chat history).
function BlitzQueue.reset_session() end

---Cancel all in-flight agent work and drop streaming preview.
function BlitzQueue.cancel() end

---Retry the main agent's last turn.
function BlitzQueue.retry() end

---Request compaction for the main agent.
function BlitzQueue.compact() end

---Switch the active mode. Forces a full mode-reminder on the next turn.
---@param mode integer One of blitz.MODE_*
function BlitzQueue.set_mode(mode) end

---Push a chat entry (single-text message) into the chat log.
---@param role string "system" | "user" | "agent"
---@param text string
function BlitzQueue.push_chat_entry(role, text) end

---Queue a user message for the given agent. Delivered next time the agent
---picks up queued input (e.g. on the next turn). This does not interrupt the agent
---@param agent_id BlitzAgentId
---@param text string
function BlitzQueue.queue_agent_message(agent_id, text) end

---Reserve a free slot and enqueue a spawn (or fork) into it. Returns the new
---agent_id, or nil when the swarm is full.
---@param args BlitzSpawnArgs
---@return BlitzAgentId|nil
function BlitzQueue.spawn_agent(args) end

---Block until the referenced agent reaches a terminal state. Releases the
---Lua VM lock while waiting so the awaited agent's own Lua tools can run
---concurrently on other workers.
---@param agent_id BlitzAgentId
---@return integer status One of blitz.AWAIT_COMPLETE | AWAIT_FAILED | AWAIT_CANCELED | AWAIT_INVALID
function BlitzQueue.await_agent(agent_id) end

---Return the awaited agent's last assistant text (concatenated .text parts).
---Intended for use after await_agent returned AWAIT_COMPLETE.
---@param agent_id BlitzAgentId
---@return string|nil
function BlitzQueue.await_agent_result(agent_id) end

---Load a session from disk.
---@param path string File path to session file
function BlitzQueue.load_session(path) end

---Save current session to disk.
---@param path string File path to session file
function BlitzQueue.save_session(path) end

---Attach a screenshot/image to the current input. `data` is raw image bytes;
---the app base64-encodes it before sending to the provider.
---@param data string Raw image bytes
---@param media_type? string MIME type, defaults to "image/png".
function BlitzQueue.attach_screenshot(data, media_type) end

---@type BlitzQueue
blitz.queue = BlitzQueue

---@alias BlitzJsonValue nil|boolean|number|string|table

---@class BlitzJson
local BlitzJson = {}

---Encode a Lua value as JSON.
---Supports nil, booleans, numbers, strings, and tables. Tables with
---consecutive integer keys from 1..n encode as arrays; other tables encode as
---objects with string keys.
---@param obj BlitzJsonValue
---@return string|nil json
---@return boolean ok
function BlitzJson.encode(obj) end

---Decode a JSON string into Lua values.
---JSON arrays become 1-indexed Lua tables; objects become Lua tables; JSON
---null becomes nil.
---@param json string
---@return BlitzJsonValue obj
---@return boolean ok
function BlitzJson.decode(json) end

---@type BlitzJson
blitz.json = BlitzJson

---Convert HTML to markdown using the built-in parser.
---@param html string
---@return string markdown
function blitz.html_to_markdown(html) end

---Execute a shell command. Routed through SSH when an
---@param cmd string
---@return string|nil output stdout on success, stderr (or stdout fallback) on failure
---@return boolean success true when the command exited 0
function blitz.shell(cmd) end

---@class BlitzMcp
local BlitzMcp = {}

---Register an MCP stdio server. Disabled until explicitly enabled.
---@param def BlitzMcpServerDef
---@return integer mcp_id
function BlitzMcp.add(def) end

---Enable an MCP server for an agent type. Defaults to blitz.AGENT_GENERAL.
---@param mcp_id integer
---@param agent_type? integer One of blitz.AGENT_GENERAL | blitz.AGENT_EXPLORE
function BlitzMcp.enable(mcp_id, agent_type) end

---@type BlitzMcp
blitz.mcp = BlitzMcp

---Return success with content
---@param content? string Content string (default "")
---@return BlitzStatus
function blitz.ok(content) end

---Return error with message
---@param message? string Error message (default "error")
---@return BlitzStatus
function blitz.err(message) end

---Signal permanent failure. Tool will NOT be re-called.
---@type BlitzStatus
blitz.FAILED = nil

---Exit the agent loop. Tool will NOT be re-called.
---@type BlitzStatus
blitz.EXIT_LOOP = nil
---@type integer
blitz.RET_FAILED = 1
---@type integer
blitz.RET_OK = 2
---@type integer
blitz.RET_ERR = 3
---@type integer
blitz.RET_EXIT_LOOP = 4

---Exit the agent loop with a message
---@param content? string Content string (default "")
---@return BlitzStatus
function blitz.exit_loop(content) end

---No event data
---@type integer
blitz.EVENT_SESSION_RESET = 0
---Event data: integer mode_id
---@type integer
blitz.EVENT_MODE_CHANGED = 1
---Event data: table { id: AgentId, type_idx: integer, depth: integer }
---@type integer
blitz.EVENT_AGENT_CREATED = 2
---Event data: table { id: AgentId }
---@type integer
blitz.EVENT_AGENT_STARTED = 3
---Event data: table { id: AgentId }
---@type integer
blitz.EVENT_AGENT_COMPLETE = 4
---Event data: table { id: AgentId, err: string|nil }
---@type integer
blitz.EVENT_AGENT_FAILED = 5
---Event data: table { id: AgentId }
---@type integer
blitz.EVENT_AGENT_CANCELLED = 6
---Event data: table { id: AgentId }
---@type integer
blitz.EVENT_COMPACTION_STARTED = 7
---Event data: table { id: AgentId }
---@type integer
blitz.EVENT_COMPACTION_COMPLETE = 8
---Event data: table { agent_id: AgentId, call_id: string, name: string }
---@type integer
blitz.EVENT_TOOL_CALL_STARTED = 9
---Event data: table { agent_id: AgentId, call_id: string, name: string, is_error: boolean }
---@type integer
blitz.EVENT_TOOL_CALL_COMPLETE = 10
---Event data: table { id: AgentId, role: string }
---@type integer
blitz.EVENT_AGENT_BROADCAST = 11
---Event data: table { call_id: string|nil, level: integer }
---@type integer
blitz.EVENT_PERMISSION_REQUESTED = 12
---Event data: table { call_id: string|nil, state: integer }
---@type integer
blitz.EVENT_PERMISSION_RESOLVED = 13
---Event data: string message
---@type integer
blitz.EVENT_USER_MESSAGE_SENT = 14
---No event data
---@type integer
blitz.EVENT_MCP_TOOLS_RELOADED = 15
