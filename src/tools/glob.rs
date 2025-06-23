use std::path::PathBuf;

use crate::{
    agent::{AFuture, AResult, AgentContext, AiTool, ToolArgs},
    error::AiError,
};
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
                "path": {
                    "type": "string",
                    "description": "The directory to search in. Defaults to the current working directory."
                },
            },
            "required": ["pattern"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path").unwrap_or(".".into());
            let pattern = args.get::<String>("pattern")?;

            let paths = match glob::glob(&pattern) {
                Ok(res) => res,
                Err(err) => {
                    return Err(AiError::ToolFailed(err.to_string()));
                }
            };

            let output = tokio::process::Command::new("rg")
                .arg("--files")
                .arg("--glob")
                .arg(pattern)
                .arg(path)
                .output()
                .await?;

            let mut content = String::from_utf8_lossy(&output.stdout).to_string();

            if content.is_empty() {
                content = String::from_utf8_lossy(&output.stderr).to_string();
            }

            let res = json!({
                "result": content,
            })
            .to_string();

            Ok(ToolResponse::new(tool_id, res).into())
        })
    }
}

mod test {

    use super::*;

    #[test]
    fn test_glob() {
        let res = walk_with_gitignore_and_glob("**/*").unwrap();
        dbg!(res);
    }
}

pub fn walk_with_gitignore_and_glob(pattern: &str) -> AResult<Vec<PathBuf>> {
    let glob = glob::glob(pattern)?.flatten().collect::<Vec<_>>();
    dbg!(&glob);

    let walker = WalkBuilder::new(".").standard_filters(true).build();

    let mut paths = Vec::new();

    for entry in walker.flatten() {
        if entry.file_type().map_or(false, |ft| ft.is_file()) {
            let p = entry.into_path();

            dbg!(&p);

            if glob.contains(&p) {
                paths.push(p);
            }
        }
    }

    Ok(paths)
}
