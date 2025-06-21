use crate::agent::{AFuture, AgentContext, AiTool, ToolArgs};
use genai::chat::*;
use serde_json::json;
use std::process::Stdio;

pub struct Read;
impl AiTool for Read {
    fn name(&self) -> &'static str {
        "read"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
        Read the contents of a file.
        The output of this tool call will be the 1-indexed file contents starting at the line_offset.
        Note that this call can view at most 250 lines at the time. Reading a full file requires calling this tool multiple times
        with increasing line_offset.
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "the path to the file"
                },
                "offset": {
                    "type": "number",
                    "description": "the start line offset"
                },
            },
            "required": ["path", "offset"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path")?;
            let offset = args.get::<i32>("offset")?;

            let mut cat = tokio::process::Command::new("cat")
                .args([&path])
                .stdout(std::process::Stdio::piped())
                .spawn()?;

            let catout: Stdio = cat.stdout.take().unwrap().try_into().unwrap();

            let mut tail = tokio::process::Command::new("tail")
                .args(["-n", &format!("+{offset}")])
                .stdin(catout)
                .stdout(std::process::Stdio::piped())
                .spawn()?;

            let tailout: Stdio = tail.stdout.take().unwrap().try_into().unwrap();

            let result = tokio::process::Command::new("head")
                .args(["-n", "250"])
                .stdin(tailout)
                .output()
                .await?;

            let content = String::from_utf8_lossy(&result.stdout).to_string();

            let total_lines = tokio::process::Command::new("wc")
                .args([&path, "-l"])
                .output()
                .await?;
            let line_count = String::from_utf8_lossy(&total_lines.stdout).to_string();

            let res = json!({
                "file_info": format!("total lines: {}",line_count),
                "offset": offset,
                "content": content,
            })
            .to_string();

            Ok(ToolResponse::new(tool_id, res).into())
        })
    }
}
