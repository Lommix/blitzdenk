use async_trait::async_trait;
use blitzdenk_core::{
    AgentArgs, AgentContext, AgentInstruction, AiTool, ArgType, Argument, BResult, Message,
};
use scraper::Html;
use tokio::io::AsyncWriteExt;

// --------------------------------------------------------
// Tools
// --------------------------------------------------------
#[derive(Default)]
pub struct Tree;
#[async_trait]
impl AiTool for Tree {
    fn name(&self) -> &'static str {
        "list_project_file_tree"
    }

    fn description(&self) -> &'static str {
        r#"
  - Prints the current project structure with all file paths.
  - This tool is essential for understanding the directory layout and locating files within the project.
  - Any question by the user is most likely related to at least one file, making this tool highly relevant.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![]
    }

    async fn run(&self, ctx: AgentContext, _args: AgentArgs) -> BResult<Message> {
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

#[derive(Default)]
pub struct Cat;
#[async_trait]
impl AiTool for Cat {
    fn name(&self) -> &'static str {
        "cat_file"
    }

    fn description(&self) -> &'static str {
        r#"
          - Prints the content of a specified file with line numbers.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("file", "the file path", ArgType::Str)]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let path = args.get("file")?;

        let result = tokio::process::Command::new("cat")
            .args(&["-n", &path])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, None))
    }
}

#[derive(Default)]
pub struct Compress;
#[async_trait]
impl AiTool for Compress {
    fn name(&self) -> &'static str {
        "compress_file"
    }

    fn description(&self) -> &'static str {
        r#"
            compressed the content of the file to your context/memory.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new(
            "file_path",
            "the file that you want to compress",
            ArgType::Str,
        )]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let mut agent = ctx.new_agent::<CompressInstruction>();

        let file = args.get("file_path")?;

        agent
            .chat
            .push_message(Message::user(format!("find '{}' and compresss it", file)));

        agent.run().await?;

        Ok(Message::tool(agent.chat.last_content().to_string(), None))
    }
}

#[derive(Default)]
struct CompressInstruction;
impl AgentInstruction for CompressInstruction {
    fn sys_prompt(&self) -> &'static str {
        crate::prompts::COMPRESS_PROMPT
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![
            Box::new(Tree::default()),
            Box::new(Cat::default()),
            Box::new(WriteMemo::default()),
        ]
    }
}

#[derive(Default)]
pub struct WriteMemo;
#[async_trait]
impl AiTool for WriteMemo {
    fn name(&self) -> &'static str {
        "save_information"
    }

    fn description(&self) -> &'static str {
        r#"
            Add important information to your permanent memory.
            Any piece of information has to provided in markdown using headers and lists
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new(
            "information",
            "the information markdown string",
            ArgType::Str,
        )]
    }

    async fn run(&self, _ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let content = args.get("information")?;

        let mut h = tokio::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open("memo.md")
            .await?;

        h.write_all(content.as_bytes()).await?;
        h.flush().await?;

        Ok(Message::tool("memory written".into(), None))
    }
}

#[derive(Default)]
pub struct CrawlWebsite;
#[async_trait]
impl AiTool for CrawlWebsite {
    fn name(&self) -> &'static str {
        "read_website"
    }

    fn description(&self) -> &'static str {
        "reads the content of website. Requires a vaild URL"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("url", "url of the website", ArgType::Str)]
    }

    async fn run(&self, _ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let url = args.get("url")?;

        let html = reqwest::Client::new().get(url).send().await?.text().await?;
        let parsed = Html::parse_document(&html);
        let main_selector = scraper::Selector::parse("h1,h2,h3,h4,h5,h6,p,code,li,th,td").unwrap();
        let content = parsed
            .select(&main_selector)
            .map(|el| el.text().collect::<String>())
            .collect::<String>();

        Ok(Message::tool(content, None))
    }
}

#[derive(Default)]
pub struct Mkdir;
#[async_trait]
impl AiTool for Mkdir {
    fn name(&self) -> &'static str {
        "create_dir"
    }

    fn description(&self) -> &'static str {
        "creates a new dir using `mkdir -p $dir_path`"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("dir_path", "the dir path", ArgType::Str)]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let path = args.get("dir_path")?;
        let result = tokio::process::Command::new("mkdir")
            .args(&["-p", &path])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, None))
    }
}

#[derive(Default)]
pub struct Grep;
#[async_trait]
impl AiTool for Grep {
    fn name(&self) -> &'static str {
        "grep"
    }

    fn description(&self) -> &'static str {
        "search a pattern in the current project using `rg`"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("pattern", "the rg pattern", ArgType::Str)]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let pattern = args.get("pattern")?;

        let result = tokio::process::Command::new("rg")
            .arg(pattern)
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, None))
    }
}

fn sed_escape(s: &str) -> String {
    // Characters that need escaping in sed
    let special_chars = [
        '/', '&', '\\', '\n', '\t', '\r', // sed-specific and general delimiters
        '<', '>', '"', '\'', // HTML-related
        '[', ']', '*', '?', '^', '$', '.', // regex-related
    ];

    let mut escaped = String::new();
    for c in s.chars() {
        if special_chars.contains(&c) {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

// search and replace in file
#[derive(Default)]
pub struct Sed;
#[async_trait]
impl AiTool for Sed {
    fn name(&self) -> &'static str {
        "search_and_replace"
    }

    fn description(&self) -> &'static str {
        "using `sed` to search and replace a string"
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("file_path", "the file path", ArgType::Str),
            Argument::new("old", "the old string", ArgType::Str),
            Argument::new("new", "the new string", ArgType::Str),
        ]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let file = args.get("file_path")?;
        let old = args.get("old")?;
        let new = args.get("new")?;

        let result = tokio::process::Command::new("sed")
            .args(&[
                "-i",
                &format!("s/{}/{}/g", sed_escape(old), sed_escape(new)),
                file,
            ])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, None))
    }
}

// create file
#[derive(Default)]
pub struct CreateFile;
#[async_trait]
impl AiTool for CreateFile {
    fn name(&self) -> &'static str {
        "create_file"
    }

    fn description(&self) -> &'static str {
        "create a new file with content"
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("file_path", "the file path", ArgType::Str),
            Argument::new("content", "the content", ArgType::Str),
        ]
    }

    async fn run(&self, _ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let file = args.get("file_path")?;
        let content = args.get("content")?;

        tokio::fs::write(file, content).await?;

        Ok(Message::tool("file created".into(), None))
    }
}

// create file
#[derive(Default)]
pub struct MoveFile;
#[async_trait]
impl AiTool for MoveFile {
    fn name(&self) -> &'static str {
        "move_file"
    }

    fn description(&self) -> &'static str {
        "using `mv` to move a file"
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("src", "source path", ArgType::Str),
            Argument::new("dst", "destination path", ArgType::Str),
        ]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let src = args.get("src")?;
        let dst = args.get("dst")?;

        _ = tokio::process::Command::new("mv")
            .args(&[src, dst])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        Ok(Message::tool("file moved".into(), None))
    }
}

// create file
#[derive(Default)]
pub struct DeleteFile;
#[async_trait]
impl AiTool for DeleteFile {
    fn name(&self) -> &'static str {
        "delete_file"
    }

    fn description(&self) -> &'static str {
        "using `rm` to delete a file"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new(
            "file_path",
            "the file to delete",
            ArgType::Str,
        )]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let src = args.get("file_path")?;

        _ = tokio::process::Command::new("rm")
            .args(&[src])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        Ok(Message::tool("file deleted".into(), None))
    }
}

#[derive(Default)]
pub struct GitLog;
#[async_trait]
impl AiTool for GitLog {
    fn name(&self) -> &'static str {
        "git_log"
    }

    fn description(&self) -> &'static str {
        "shows the last 20 commits"
    }

    fn args(&self) -> Vec<Argument> {
        vec![]
    }

    async fn run(&self, ctx: AgentContext, _args: AgentArgs) -> BResult<Message> {
        let res = tokio::process::Command::new("git")
            .args(&["log", "-n 20"])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&res.stdout).to_string();
        Ok(Message::tool(content, None))
    }
}

#[derive(Default)]
pub struct GitShowCommit;
#[async_trait]
impl AiTool for GitShowCommit {
    fn name(&self) -> &'static str {
        "git_show"
    }

    fn description(&self) -> &'static str {
        "show a specific commit"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("commit", "The commit hash", ArgType::Str)]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let hash = args.get("commit")?;

        let res = tokio::process::Command::new("git")
            .args(&["show", &hash])
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&res.stdout).to_string();
        Ok(Message::tool(content, None))
    }
}
