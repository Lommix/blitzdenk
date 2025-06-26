use crate::{
    agent::{AFuture, AgentContext, AiTool, ToolArgs},
    error::AiError,
};
use genai::chat::*;
use ignore::WalkBuilder;
use serde_json::json;

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

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path")?;
            let offset = args.get::<usize>("offset")?;

            if !is_part_of_project(&path) {
                return Err(AiError::ToolFailed(
                    "path does not exists in current project".into(),
                ));
            }

            let file_content = tokio::fs::read_to_string(&path).await?;

            let total_lines = file_content.lines().count();
            let content: String = file_content.lines().skip(offset).collect();

            let res = format!(
                "total lines: {}\n<content>\n{}\n</content>",
                total_lines, content
            );
            Ok(ToolResponse::new(tool_id, res).into())
        })
    }
}

fn is_part_of_project(path: &str) -> bool {
    let walker = WalkBuilder::new(".").standard_filters(true).build();
    for p in walker.flatten() {
        if p.into_path()
            .strip_prefix("./")
            .unwrap()
            .to_str()
            .unwrap_or_default()
            == path
        {
            return true;
        }
    }
    false
}
