use crate::agent::{AFuture, AgentContext, AiTool, ToolArgs};
use genai::chat::*;
use ignore::WalkBuilder;
use serde_json::json;

pub struct Ls;
impl AiTool for Ls {
    fn name(&self) -> &'static str {
        "ls"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
Lists files and directories in a given path. The path parameter must be an absolute path, not a relative path. You should generally prefer the Glob and Grep tools, if you know which directories to search.
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The absolute path to the directory to list (must be absolute, not relative)"
                },
            },
            "required": [],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let mut path = args.get::<String>("path").unwrap_or("./".to_string());

            if !path.starts_with('.') {
                path = format!(".{}", path);
            }

            let walker = WalkBuilder::new(&path).max_depth(Some(1)).build();
            let mut list = Vec::new();

            for entry in walker.flatten() {
                list.push(entry.path().to_string_lossy().to_string());
            }

            Ok(ToolResponse::new(tool_id, list.join("\n")).into())
        })
    }
}
