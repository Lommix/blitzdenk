use std::path::PathBuf;

use crate::agent::{AgentContext, AiTool, ToolArgs};
use crate::error::{AFuture, AResult};
use genai::chat::*;
use ignore::WalkBuilder;
use serde_json::json;

pub struct Glob;
impl AiTool for Glob {
    fn name(&self) -> &'static str {
        "glob"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
- Fast file pattern matching tool that works with any codebase size
- Supports glob patterns like "**/*.js" or "src/**/*.ts"
- Returns matching file paths sorted by modification time
- Use this tool when you need to find files by name patterns
- When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead
- You have the capability to call multiple tools in a single response. It is always better to speculatively perform multiple searches as a batch that are potentially useful.
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "The glob pattern to match files against"
                },
                "path": {
                    "type": "string",
                    "description": r#"The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter "undefined" or "null" - simply omit it for the default behavior. Must be a valid directory path if provided."#
                }
            },
            "required": ["pattern"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let pattern = args.get::<String>("pattern")?;
            let path = args.get::<String>("path").unwrap_or(String::from("."));

            let result = walk_with_gitignore_and_glob(&path, &pattern)?;
            let res = serde_json::to_string(&result)?;
            Ok(ToolResponse::new(tool_id, res).into())
        })
    }
}

pub fn walk_with_gitignore_and_glob(path: &str, pattern: &str) -> AResult<Vec<PathBuf>> {
    let glob = glob::glob(pattern)?.flatten().collect::<Vec<_>>();

    let walker = WalkBuilder::new(path).standard_filters(true).build();

    let mut paths = Vec::new();

    for entry in walker.flatten() {
        if entry.file_type().is_some_and(|ft| ft.is_file()) {
            let p = entry.path().strip_prefix("./").unwrap().to_path_buf();

            if glob.contains(&p) {
                paths.push(p);
            }
        }
    }

    Ok(paths)
}
