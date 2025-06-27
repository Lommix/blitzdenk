#![allow(unused)]

/// [WIP]
use crate::agent::{AgentContext, AiTool, ToolArgs};
use genai::chat::ChatMessage;

#[derive(Default)]
pub struct Task;

impl AiTool for Task {
    fn name(&self) -> &'static str {
        "task"
    }

    fn description(&self) -> Option<&'static str> {
        Some("Create and run a new agent with a single string task and return the last message")
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(serde_json::json!({
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "The task string for the new agent"}
            },
            "required": ["task"]
        }))
    }

    fn run(
        tool_id: String,
        args: ToolArgs,
        ctx: AgentContext,
    ) -> crate::error::AFuture<ChatMessage> {
        Box::pin(async move { todo!() })
    }
}
