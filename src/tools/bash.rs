use crate::{
    agent::{AFuture, AgentContext, AgentEvent, AiTool, PermissionRequest, ToolArgs},
    error::AiError,
};
use genai::chat::*;
use serde_json::json;

pub struct Bash;
impl AiTool for Bash {
    fn name(&self) -> &'static str {
        "bash"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
Executes a given bash command in a persistent shell session with optional timeout, ensuring proper handling and security measures.

Before executing the command, please follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use the LS tool to verify the parent directory exists and is the correct location
   - For example, before running "mkdir foo/bar", first use LS to check that "foo" exists and is the intended parent directory

2. Command Execution:
   - Always quote file paths that contain spaces with double quotes (e.g., cd "path with spaces/file.txt")
   - Examples of proper quoting:
     - cd "/Users/name/My Documents" (correct)
     - cd /Users/name/My Documents (incorrect - will fail)
     - python "/path/with spaces/script.py" (correct)
     - python /path/with spaces/script.py (incorrect - will fail)
   - After ensuring proper quoting, execute the command.
   - Capture the output of the command.

Usage notes:
  - The command argument is required.
  - You can specify an optional timeout in milliseconds (up to 600000ms / 10 minutes). If not specified, commands will timeout after 120000ms (2 minutes).
  - It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
  - If the output exceeds 30000 characters, output will be truncated before being returned to you.
  - VERY IMPORTANT: You MUST avoid using search commands like `find` and `grep`. Instead use Grep, Glob, or Task to search. You MUST avoid read tools like `cat`, `head`, `tail`, and `ls`, and use Read and LS to read files.
  - If you _still_ need to run `grep`, STOP. ALWAYS USE ripgrep at `rg` (or /usr/bin/rg) first, which all opencode users have pre-installed.
  - When issuing multiple commands, use the ';' or '&&' operator to separate them. DO NOT use newlines (newlines are ok in quoted strings).
  - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it.
    <good-example>
    pytest /foo/bar/tests
    </good-example>
    <bad-example>
    cd /foo/bar && pytest tests
    </bad-example>
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The command to execute"
                },
            },
            "required": ["command"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let command = args.get::<String>("command")?;

            let req_msg = format!("The agent wants to run:\n\n```sh\n{}\n```", command);
            let (req, rx) = PermissionRequest::new(req_msg);
            ctx.sender.send(AgentEvent::Permission(req))?;

            if !rx.await? {
                return Err(AiError::ToolFailed("user declined the edit request".into()));
            }

            let result = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output()
                .await?;

            let content = String::from_utf8_lossy(&result.stdout).to_string();
            Ok(ToolResponse::new(tool_id, json!({"result": content}).to_string()).into())
        })
    }
}
