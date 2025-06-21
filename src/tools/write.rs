use crate::{
    agent::{AFuture, AgentContext, AgentEvent, AiTool, PermissionRequest, ToolArgs},
    error::AiError,
};
use genai::chat::*;
use serde_json::json;

pub struct Write;
impl AiTool for Write {
    fn name(&self) -> &'static str {
        "write"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
Writes a file to the local filesystem.

Usage:
- This tool will overwrite the existing file if there is one at the provided path.
- If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.
- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
- NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
- Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The absolute path to the file"
                },
                "content": {
                    "type": "string",
                    "description": "the file content"
                },
            },
            "required": ["path", "content"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path")?;
            let content = args.get::<String>("content")?;

            let req_msg = format!(
                "The agent wants to create `{}`:\n\n```diff\n{}\n```",
                path, content
            );

            let (req, rx) = PermissionRequest::new(req_msg);
            ctx.sender.send(AgentEvent::Permission(req))?;

            if !rx.await? {
                return Err(AiError::ToolFailed("user declined the edit request".into()));
            }

            tokio::fs::write(path, content).await?;
            Ok(ToolResponse::new(tool_id, json!({"result":"file was edited"}).to_string()).into())
        })
    }
}
