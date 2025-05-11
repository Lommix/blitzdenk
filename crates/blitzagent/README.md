# Blitzagent

A simple top to down hierarchy multi API agent framework.

It's a pipe!

Currently supports: Ollama, OpenAi, Gemini, Claude

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (ctx, rec) = AgentContext::new(root, OllamaClient::new(config.ollama_model))
    let agent = ctx.new_agent::<DevAgent>();

    tokio::spawn(async move {
        loop {
            let msg = rec.recv().unwrap();
            println("{}", msg);
        }
    };

    agent.chat.push_message(Message::User("list all files".into()));
    agent.run().await?;

}


#[derive(Default)]
pub struct DevAgent;
impl AgentInstruction for DevAgent {
    fn sys_prompt(&self) -> &'static str {
        crate::prompts::ASSISTANT_PROMPT
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![
            Box::new(tools::Tree),
        ]
    }
}

#[derive(Default)]
pub struct Tree;
#[async_trait]
impl AiTool for Tree {
    fn name(&self) -> &'static str {
        "tree"
    }

    fn description(&self) -> &'static str {
        "Prints the current project structure with all file paths."
    }

    fn args(&self) -> Vec<Argument> {
        vec![]
    }

    async fn run(&self, ctx: AgentContext, _args: AgentArgs) -> BResult<Message> {

        // tools can create new agents and await their final response.
        // let child_agent = ctx.new_agent::<DevAgent>();

        let result = tokio::process::Command::new("tree")
            .arg("-f")
            .arg("-i")
            .arg("--gitignore")
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();
        Ok(Message::tool(content, None))
    }
}
```
