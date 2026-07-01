--[[

# Local blitz customization:
a skill hook

]]
--

blitz.events.add_listener(blitz.events.AGENT_STARTED, function(agent_id)
	blitz.queue.queue_agent_message(agent_id, "load the zig skill")
end)
