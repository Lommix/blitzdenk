use crate::agent::{AFuture, AgentContext, AiTool, ToolArgs};
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
Fast content search tool that finds files containing specific text or patterns, returning matching file paths sorted by modification time (newest first).

WHEN TO USE THIS TOOL:
- Use when you need to find files containing specific text or patterns
- Great for searching code bases for function names, variable declarations, or error messages
- Useful for finding all files that use a particular API or pattern

HOW TO USE:
- Provide a regex pattern to search for within file contents
- Set literal_text=true if you want to search for the exact text with special characters (recommended for non-regex users)
- Optionally specify a starting directory (defaults to current working directory)
- Optionally provide an include pattern to filter which files to search
- Results are sorted with most recently modified files first

REGEX PATTERN SYNTAX (when literal_text=false):
- Supports standard regular expression syntax
- 'function' searches for the literal text "function"
- 'log\..*Error' finds text starting with "log." and ending with "Error"
- 'import\s+.*\s+from' finds import statements in JavaScript/TypeScript

COMMON INCLUDE PATTERN EXAMPLES:
- '*.js' - Only search JavaScript files
- '*.{ts,tsx}' - Only search TypeScript files
- '*.go' - Only search Go files

LIMITATIONS:
- Results are limited to 100 files (newest first)
- Performance depends on the number of files being searched
- Very large binary files may be skipped
- Hidden files (starting with '.') are skipped

TIPS:
- For faster, more targeted searches, first use Glob to find relevant files, then use Grep
- When doing iterative exploration that may require multiple rounds of searching, consider using the Agent tool instead
- Always check if results are truncated and refine your search pattern if needed
- Use literal_text=true when searching for exact text containing special characters like dots, parentheses, etc.`
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

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
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
