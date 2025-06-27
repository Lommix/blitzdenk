use crate::agent::{AgentContext, AiTool, ToolArgs};
use crate::error::AFuture;
use genai::chat::*;
use serde_json::json;

pub struct Grep;
impl AiTool for Grep {
    fn name(&self) -> &'static str {
        "grep"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
- Fast content search tool that works with any codebase size
- Searches file contents using regular expressions
- Supports full regex syntax (eg. "log.*Error", "function\s+\w+", etc.)
- Filter files by pattern with the include parameter (eg. "*.js")
- Returns file paths with at least one match sorted by modification time
- Use this tool when you need to find files containing specific patterns
- If you need to identify/count the number of matches within files, use the Bash tool with `rg` (ripgrep) directly. Do NOT use `grep`.
- When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "The regex pattern to search for in file contents"
                },
                "path": {
                    "type": "string",
                    "description": "The directory to search in. Defaults to the current working directory."
                },
                "include": {
                    "type": "string",
                    "description": "File pattern to include in the search (e.g. \"*.js\", \"*.{ts,tsx}\")"
                },
                "literal_text":{
                    "type": "boolean",
                    "description": "If true, the pattern will be treated as literal text with special regex characters escaped. Default is false."
                }
            },
            "required": ["pattern"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let pattern = args.get::<String>("pattern")?;
            let path = args.get::<String>("path").unwrap_or("./".into());

            let mut cmd = tokio::process::Command::new("rg");
            cmd.arg(pattern);

            if args.get::<bool>("literal_text").is_ok() {
                cmd.arg("--fixed-strings");
            }

            if let Ok(include) = args.get::<String>("include") {
                cmd.arg("--glob");
                cmd.arg(&include);
            }

            cmd.arg(&path);

            let output = cmd.output().await?;

            let content = String::from_utf8_lossy(&output.stdout).to_string();

            Ok(ToolResponse::new(tool_id, content).into())
        })
    }
}
