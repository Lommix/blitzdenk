use async_trait::async_trait;
use blitzagent::{
    AgentArgs, AgentContext, AgentInstruction, AiTool, ArgType, Argument, BResult, Confirmation,
    Message,
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
        "suggest the user to create a new dir using `mkdir -p $dir_path`"
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("dir_path", "the dir path", ArgType::Str)]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let path = args.get("dir_path")?;

        let (conf, rx) = Confirmation::new(format!("The agent wants to create a dir `{}`", path));
        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

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
        "suggest_search_and_replace"
    }

    fn description(&self) -> &'static str {
        "suggest to use `sed` for searching and replacing a string. Safe"
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

        let (conf, rx) = Confirmation::new(format!(
            "In `{}` the agent wants search and replace\n OLD:\n{}\n NEW:\n{}",
            file, old, new
        ));
        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

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

pub struct EditFile;
#[async_trait]
impl AiTool for EditFile {
    fn name(&self) -> &'static str {
        "suggest_edit_file"
    }

    fn description(&self) -> &'static str {
        "Make a file edit suggestions to user. Always use this tool if you want to suggest a code change"
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("file", "the file path", ArgType::Str),
            Argument::string("content", "the content", true),
            Argument::string("operation", "'insert' or 'replace'. Insert will append content after 'start_line'. Replace will replace between start and end", true),
            Argument::string("start_line", "start line number", true),
            Argument::string("end_line", "end line number", false),
        ]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let file = args.get("file")?;
        let content = args.get("content")?;
        let op = args.get("operation")?;
        let start = args.get("start_line")?.parse::<usize>()?;
        let end = args.get("end_line")?.parse::<usize>()?;

        let (conf, rx) = Confirmation::new(format!(
            r#"
            Agents wants to edit `{}`
            op:{} [{}-{}]
            ------------
            {}
            "#,
            file, op, start, end, content
        ));

        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

        match op.as_str() {
            "insert" => insert_after_line(file, start, content).await?,
            "replace" => replace_lines(file, start, end, content).await?,
            _ => {
                return Ok(Message::tool("unkown opteration".into(), None));
            }
        }

        Ok(Message::tool("user accepted".into(), None))
    }
}

pub async fn replace_lines(
    file: &str,
    start: usize,
    end: usize,
    new_content: &str,
) -> std::io::Result<()> {
    let mut lines: Vec<_> = tokio::fs::read_to_string(file)
        .await?
        .lines()
        .map(|l| l.to_string())
        .collect();

    if start >= 1 && end <= lines.len() && start <= end {
        lines.splice((start - 1)..end, new_content.lines().map(|l| l.to_string()));

        let result = lines.join("\n") + "\n";
        tokio::fs::write(file, result).await?;
    }
    Ok(())
}

pub async fn insert_after_line(
    file: &str,
    line: usize,
    insert_content: &str,
) -> std::io::Result<()> {
    let mut lines: Vec<_> = tokio::fs::read_to_string(file)
        .await?
        .lines()
        .map(|l| l.to_string())
        .collect();
    if line <= lines.len() {
        let idx = line + 1;

        for (i, l) in insert_content.lines().enumerate() {
            lines.insert(idx + i, l.to_string());
        }

        let result = lines.join("\n") + "\n";

        tokio::fs::write(file, result).await?;
    }
    Ok(())
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
        "suggest to create a new file with content. Safe"
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("file_path", "the file path", ArgType::Str),
            Argument::new("content", "the content", ArgType::Str),
        ]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message> {
        let file = args.get("file_path")?;
        let content = args.get("content")?;

        let (conf, rx) = Confirmation::new(format!(
            "Agent wants to create file `{}` with:\n{}",
            file, content,
        ));

        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

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
        "suggest using `mv` to move a file. Safe"
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

        let (conf, rx) = Confirmation::new(format!(
            "Agent wants to move a file\n from: `{}`\nto:{}",
            src, dst,
        ));

        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

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
        "suggest using `rm` to delete a file. Safe"
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
