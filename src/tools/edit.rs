use crate::{
    agent::{AgentContext, AgentEvent, AiTool, PermissionRequest, ToolArgs},
    error::{AFuture, AiError},
};
use diffy::DiffOptions;
use genai::chat::*;
use serde::{Deserialize, Serialize};
use serde_json::json;

pub struct Edit;
impl AiTool for Edit {
    fn name(&self) -> &'static str {
        "edit"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"Performs exact string replacements in files.

Usage:
- You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.
- When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: spaces + line number + tab. Everything after that tab is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.
- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
- The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.
- Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The absolute path to the file to modify"
                },
                "old_string": {
                    "type": "string",
                    "description": "The text to replace"
                },
                "new_string": {
                    "type": "string",
                    "description": "The text to replace it with (must be different from old_string)"
                },
                "replace_all":{
                    "type": "boolean",
                    "description": "Replace all occurrences of old_string (default false)",
                }
            },
            "required": ["path", "old_string", "new_string"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path")?;
            let old = args.get::<String>("old_string")?;
            let new = args.get::<String>("new_string")?;
            let replace_all = args.get::<bool>("replace_all").unwrap_or_default();

            let old_content = tokio::fs::read_to_string(&path).await?;

            if !old_content.contains(&old) {
                return Err(AiError::ToolFailed(
                    "the `old_string` argument cannot be found in the original file!".into(),
                ));
            }

            let new_content = match replace_all {
                true => old_content.replace(&old, &new),
                false => old_content.replacen(&old, &new, 1),
            };

            let patch = DiffOptions::default().create_patch(&old_content, &new_content);

            let req_msg = format!(
                "The agent wants to edit `{}`:\n\n```diff\n{}\n```",
                path, patch
            );

            let (req, rx) = PermissionRequest::new(req_msg);
            ctx.sender.send(AgentEvent::Permission(req))?;

            if !rx.await? {
                return Err(AiError::ToolFailed("user declined the edit request".into()));
            }

            tokio::fs::write(path, new_content).await?;
            Ok(ToolResponse::new(tool_id, "file was edited").into())
        })
    }
}

pub struct MultiEdit;
impl AiTool for MultiEdit {
    fn name(&self) -> &'static str {
        "multi_edit"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
This is a tool for making multiple edits to a single file in one operation. It is built on top of the Edit tool and allows you to perform multiple find-and-replace operations efficiently. Prefer this tool over the Edit tool when you need to make multiple edits to the same file.

Before using this tool:

1. Use the Read tool to understand the file's contents and context
2. Verify the directory path is correct

To make multiple file edits, provide the following:
1. file_path: The absolute path to the file to modify (must be absolute, not relative)
2. edits: An array of edit operations to perform, where each edit contains:
   - old_string: The text to replace (must match the file contents exactly, including all whitespace and indentation)
   - new_string: The edited text to replace the old_string

IMPORTANT:
- All edits are applied in sequence, in the order they are provided
- Each edit operates on the result of the previous edit
- All edits must be valid for the operation to succeed - if any edit fails, none will be applied
- This tool is ideal when you need to make several changes to different parts of the same file

CRITICAL REQUIREMENTS:
1. All edits follow the same requirements as the single Edit tool
2. The edits are atomic - either all succeed or none are applied
3. Plan your edits carefully to avoid conflicts between sequential operations

WARNING:
- The tool will fail if edits.old_string doesn't match the file contents exactly (including whitespace)
- The tool will fail if edits.old_string and edits.new_string are the same
- Since edits are applied in sequence, ensure that earlier edits don't affect the text that later edits are trying to find

When making edits:
- Ensure all edits result in idiomatic, correct code
- Do not leave the code in a broken state
- Always use absolute file paths (starting with /)
- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
- Use replace_all for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.

If you want to create a new file, use:
- A new file path, including dir name if needed
- First edit: empty old_string and the new file's contents as new_string
- Subsequent edits: normal edit operations on the created content
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The absolute path to the file to modify"
                },
                "edits": {
                    "type": "array",
                    "description": "An array of edit operations to perform",
                    "items": {
                        "type": "object",
                        "properties": {
                            "old_string": {
                                "type": "string",
                                "description": "The text to replace"
                            },
                            "new_string": {
                                "type": "string",
                                "description": "The text to replace it with (must be different from old_string)"
                            },
                            "replace_all":{
                                "type": "boolean",
                                "description": "Replace all occurrences of old_string (default false)",
                            }
                        },
                    }
                },
            },
            "required": ["path", "edits"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let path = args.get::<String>("path")?;
            let edits = args.get::<Vec<EditArg>>("edits")?;

            let file_content = tokio::fs::read_to_string(&path).await?;
            let mut new_content = file_content.clone();

            for arg in edits.iter() {
                if !new_content.contains(&arg.old_string) {
                    return Err(AiError::ToolFailed(
                        "the `old_string` argument cannot be found in the original file!".into(),
                    ));
                }

                new_content = match arg.replace_all {
                    true => new_content.replace(&arg.old_string, &arg.new_string),
                    false => new_content.replacen(&arg.old_string, &arg.new_string, 1),
                };
            }

            let patch = DiffOptions::default().create_patch(&file_content, &new_content);

            let req_msg = format!(
                "The agent wants to edit `{}`:\n\n```diff\n{}\n```",
                path, patch
            );

            let (req, rx) = PermissionRequest::new(req_msg);
            ctx.sender.send(AgentEvent::Permission(req))?;

            if !rx.await? {
                return Err(AiError::ToolFailed("user declined the edit request".into()));
            }

            tokio::fs::write(path, new_content).await?;
            Ok(ToolResponse::new(tool_id, "files edited").into())
        })
    }
}

#[derive(Serialize, Deserialize)]
struct EditArg {
    old_string: String,
    new_string: String,
    replace_all: bool,
}
