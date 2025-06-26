use std::path::PathBuf;

use crate::agent::{AFuture, AResult, AgentContext, AiTool, ToolArgs};
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
Fast file pattern matching tool that finds files by name and pattern, returning matching paths sorted by modification time (newest first).

WHEN TO USE THIS TOOL:
- Use when you need to find files by name patterns or extensions
- Great for finding specific file types across a directory structure
- Useful for discovering files that match certain naming conventions

HOW TO USE:
- Provide a glob pattern to match against file paths
- Optionally specify a starting directory (defaults to current working directory)
- Results are sorted with most recently modified files first

GLOB PATTERN SYNTAX:
- '*' matches any sequence of non-separator characters
- '**' matches any sequence of characters, including separators
- '?' matches any single non-separator character
- '[...]' matches any character in the brackets
- '[!...]' matches any character not in the brackets

COMMON PATTERN EXAMPLES:
- '*.js' - Find all JavaScript files in the current directory
- '**/*.js' - Find all JavaScript files in any subdirectory
- 'src/**/*.{ts,tsx}' - Find all TypeScript files in the src directory
- '*.{html,css,js}' - Find all HTML, CSS, and JS files

LIMITATIONS:
- Results are limited to 100 files (newest first)
- Does not search file contents (use Grep tool for that)
- Hidden files (starting with '.') are skipped

TIPS:
- For the most useful results, combine with the Grep tool: first find files with Glob, then search their contents with Grep
- When doing iterative exploration that may require multiple rounds of searching, consider using the Agent tool instead
- Always check if results are truncated and refine your search pattern if needed

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
            },
            "required": ["pattern"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let pattern = args.get::<String>("pattern")?;
            let result = walk_with_gitignore_and_glob(&pattern)?;
            let res = serde_json::to_string(&result)?;
            Ok(ToolResponse::new(tool_id, res).into())
        })
    }
}

mod test {
    
    #[test]
    fn test_glob() {
        let res = walk_with_gitignore_and_glob("**/*").unwrap();
        dbg!(res);
    }
}

pub fn walk_with_gitignore_and_glob(pattern: &str) -> AResult<Vec<PathBuf>> {
    let glob = glob::glob(pattern)?.flatten().collect::<Vec<_>>();

    let walker = WalkBuilder::new(".").standard_filters(true).build();

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
