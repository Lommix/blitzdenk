use async_trait::async_trait;
use blitzagent::{
    AgentArgs, AgentContext, AgentInstruction, AiTool, ArgType, Argument, BResult, Confirmation,
    Message,
};
use scraper::Html;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;

// --------------------------------------------------------
// Tools
// --------------------------------------------------------
#[derive(Default)]
pub struct Tree;
#[async_trait]
impl AiTool for Tree {
    fn name(&self) -> &'static str {
        "read_project_tree"
    }

    fn description(&self) -> &'static str {
        r#"
        Print the current project tree in the style of the unix `tree` command with a layer depth of 4.
        When context about a file is needed, it is required to use this tool first, to find the file in question.
        Never assume, that the user provides a full path. Always unsure you know about the file structure before acting
        on files.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::string(
            "root",
            "the optional starting dir. Defaults to the current CWD",
            false,
        )]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let start_dir = args.get("root").map(|s| s.as_str()).unwrap_or(".");
        let result = tokio::process::Command::new("tree")
            .arg("-L")
            .arg("4")
            .arg("-f")
            .arg("-i")
            .arg("--gitignore")
            .arg(format!("{}", start_dir))
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();
        Ok(Message::tool(content, tool_id))
    }
}

#[derive(Default)]
pub struct Cat;
#[async_trait]
impl AiTool for Cat {
    fn name(&self) -> &'static str {
        "read_file"
    }

    fn description(&self) -> &'static str {
        r#"
        Read the contents of a file.
        The output of this tool call will be the 1-indexed file contents from start_line_one_indexed to end_line_one_indexed_inclusive,
        together with a summary of the lines outside start_line_one_indexed and end_line_one_indexed_inclusive.
        Note that this call can view at most 250 lines at a time and 200 lines minimum.

        When using this tool to gather information, it's your responsibility to ensure you have the COMPLETE context. Specifically, each time you call this command you should:

        1.) Assess if the contents you viewed are sufficient to proceed with your task.
        2.) Take note of where there are lines not shown.
        3.) If the file contents you have viewed are insufficient, and you suspect they may be in lines not shown, proactively call the tool again to view those lines.
        4.) When in doubt, call this tool again to gather more information. Remember that partial file views may miss critical dependencies, imports, or functionality.

        In some cases, if reading a range of lines is not enough, you may choose to read the entire file. Reading entire files is often wasteful and slow, especially for large files (i.e. more than a few hundred lines). So you should use this option sparingly. Reading the entire file is not allowed in most cases. You are only allowed to read the entire file if it has been edited or manually attached to the conversation by the user.

        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::string("file", "the file path", true),
            Argument::string("start_line", "the optional line start", false),
            Argument::string("end_line", "the optional line end", false),
        ]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let path = args.get("file")?;

        let start = args
            .get("start_line")
            .map(|s| s.parse::<i32>().unwrap_or(0))
            .unwrap_or(0);
        let end = args
            .get("end_line")
            .map(|s| s.parse::<i32>().unwrap_or(250))
            .unwrap_or(250);

        let num_lines = (end - start + 1).min(250);

        let mut cat = tokio::process::Command::new("cat")
            .args(["-n", path])
            .current_dir(&ctx.cwd)
            .stdout(std::process::Stdio::piped())
            .spawn()?;

        let catout: Stdio = cat.stdout.take().unwrap().try_into().unwrap();

        let mut tail = tokio::process::Command::new("tail")
            .args(["-n", &format!("+{start}")])
            .stdin(catout)
            .stdout(std::process::Stdio::piped())
            .spawn()?;

        let tailout: Stdio = tail.stdout.take().unwrap().try_into().unwrap();

        let result = tokio::process::Command::new("head")
            .args(["-n", &format!("{num_lines}")])
            .stdin(tailout)
            .output()
            .await?;

        let c = format!("cat -n {path} | tail -n +{start} | head -n {num_lines}");

        let content = String::from_utf8_lossy(&result.stdout).to_string();
        Ok(Message::tool(
            format!("{}\n<content>\n{}\n</content>", c, content),
            tool_id,
        ))
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

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let mut agent = ctx.new_agent::<CompressInstruction>();

        let file = args.get("file_path")?;

        agent
            .chat
            .push_message(Message::user(format!("find '{}' and compresss it", file)));

        agent.run().await?;

        Ok(Message::tool(
            agent.chat.last_content().to_string(),
            tool_id,
        ))
    }
}

#[derive(Default)]
struct CompressInstruction;
impl AgentInstruction for CompressInstruction {
    fn sys_prompt(&self) -> &'static str {
        crate::prompts::COMPRESS_PROMPT
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![Box::new(Tree), Box::new(Cat), Box::new(WriteMemo)]
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

    async fn run(
        &self,
        _ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let content = args.get("information")?;

        let mut h = tokio::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open("agent.md")
            .await?;

        h.write_all(content.as_bytes()).await?;
        h.flush().await?;

        Ok(Message::tool("memory written".into(), tool_id))
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
        "reads the content of any url/link. Requires a vaild URL. This can and should be used to read any relevant documentation."
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("url", "url of the website", ArgType::Str)]
    }

    async fn run(
        &self,
        _ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let url = args.get("url")?;

        let html = reqwest::Client::new().get(url).send().await?.text().await?;
        let parsed = Html::parse_document(&html);
        let main_selector = scraper::Selector::parse("h1,h2,h3,h4,h5,h6,p,code,li,th,td").unwrap();
        let content = parsed
            .select(&main_selector)
            .map(|el| el.text().collect::<String>())
            .collect::<String>();

        Ok(Message::tool(content, tool_id))
    }
}

#[derive(Default)]
pub struct Grep;
#[async_trait]
impl AiTool for Grep {
    fn name(&self) -> &'static str {
        "grep_search"
    }

    fn description(&self) -> &'static str {
        r#"
        Fast text-based regex search that finds exact pattern matches within files or directories,
        utilizing the ripgrep command for efficient searching. Results will be formatted in the style of ripgrep and can be configured to include line numbers and content.
        To avoid overwhelming output, the results are capped at 50 matches.
        Use the include or exclude patterns to filter the search scope by file type or specific paths.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::new("pattern", "the rg pattern", ArgType::Str)]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let pattern = args.get("pattern")?;

        let result = tokio::process::Command::new("rg")
            .arg(pattern)
            .arg("-m")
            .arg("50")
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, tool_id))
    }
}

pub struct PatchFile;
#[async_trait]
impl AiTool for PatchFile {
    fn name(&self) -> &'static str {
        "patch_file"
    }

    fn description(&self) -> &'static str {
        r#"
        PROPOSE  to apply changes to files using `patch`.
        Reads a patch string and modifies the target files
        according to the instructions within the patch.

        **Importance of Correct Patch File Format:**

        The `patch` command relies heavily on the correct format of the patch file.
        The unified format is generally preferred and more common.

        A typical unified diff header looks like this:
        --- original_file_path  timestamp_original
        +++ new_file_path       timestamp_new

        Following the header, lines starting with:
        - `-` indicate lines removed from the original file.
        - `+` indicate lines added to the new file.
        - ` ` (a space) indicate context lines (unchanged lines).
        - `@@ -start_line_original,num_lines_original +start_line_new,num_lines_new @@` indicate hunk headers,
          specifying the line numbers and lengths of the changed blocks.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![Argument::string("diff", "", true)]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let diff = args.get("diff")?;

        let (conf, rx) = Confirmation::new(format!(
            r#"#Agent wants to run this patch:

            ```diff
            {}
            ```
            "#,
            diff
        ));
        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

        let mut cat = tokio::process::Command::new("echo")
            .args(["-e", diff])
            .current_dir(&ctx.cwd)
            .stdout(std::process::Stdio::piped())
            .spawn()?;

        let catout: Stdio = cat.stdout.take().unwrap().try_into().unwrap();

        let result = tokio::process::Command::new("patch")
            .args(["-p1"])
            .stdin(catout)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();
        let error = String::from_utf8_lossy(&result.stderr).to_string();

        Ok(Message::tool(
            format!(
                r#"
                <stdout>{content}</stdout>
                <stderr>{error}</stderr>
                "#
            ),
            tool_id,
        ))
    }
}

pub struct RunTerminal;
#[async_trait]
impl AiTool for RunTerminal {
    fn name(&self) -> &'static str {
        "run_terminal"
    }

    fn description(&self) -> &'static str {
        r#"
        PROPOSE a command to run on behalf of the user.
        If you have this tool, note that you DO have the ability to run commands directly on the USER's system.
        Note that the user will have to approve the command before it is executed.
        The user may reject it if it is not to their liking, or may modify the command before approving it.
        If they do change it, take those changes into account. The actual command will NOT execute until the user approves it.
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::new("command", "the command with arguments", ArgType::Str),
            Argument::new("arguments", "the command with arguments", ArgType::Str),
        ]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let command = args.get("command")?;
        let args = args.get("arguments")?;

        let (conf, rx) = Confirmation::new(format!(
            r#"Agent wants to execute:

            ```bash
            {} {}
            ```
            "#,
            command, args
        ));
        ctx.confirm_tx.send(conf).unwrap();
        let ok = rx.await?;

        if !ok {
            return Ok(Message::tool("user declined".into(), None));
        }

        let result = tokio::process::Command::new(command)
            .arg(args)
            .current_dir(ctx.cwd)
            .output()
            .await?;

        let content = String::from_utf8_lossy(&result.stdout).to_string();

        Ok(Message::tool(content, tool_id))
    }
}

pub struct EditFile;
#[async_trait]
impl AiTool for EditFile {
    fn name(&self) -> &'static str {
        "edit_file"
    }

    fn description(&self) -> &'static str {
        r#"
        Use this tool to propose an edit to an existing file or create a new file.
        This will be read by a less intelligent model, which will quickly apply the edit.
        You should make it clear what the edit is, while also minimizing the unchanged code you write.
        When writing the edit, you should specify each edit in sequence, with the special comment // ... existing code ... to represent unchanged code in between edited lines.
        For example:
        // ... existing code ... FIRST_EDIT // ... existing code ... SECOND_EDIT // ... existing code ... THIRD_EDIT // ... existing code ...
        You should still bias towards repeating as few lines of the original file as possible to convey the change.
        But, each edit should contain sufficient context of unchanged lines around the code you're editing to resolve ambiguity.
        DO NOT omit spans of pre-existing code (or comments) without using the
        // ... existing code ... comment to indicate its absence.
        // If you omit the existing code comment, the model may inadvertently delete these lines.
        // Make sure it is clear what the edit should be, and where it should be applied.
        // To create a new file, simply specify the content of the file in the code_edit field.
        You should specify the following arguments before the others: [target_file]
        "#
    }

    fn args(&self) -> Vec<Argument> {
        vec![
            Argument::string("edit_string", "things to edit", true),
            Argument::string("target_file", "the file to edit", true),
        ]
    }

    async fn run(
        &self,
        ctx: AgentContext,
        args: AgentArgs,
        tool_id: Option<String>,
    ) -> BResult<Message> {
        let edit_string = args.get("edit_string")?;
        let file = args.get("target_file")?;

        let mut agent = ctx.new_agent::<EditInstruction>();
        agent.chat.push_message(Message::user(format!(
            r#"
            Here are some code changes with lines. The changes are not marked.
            You have to read the current file and compare it to the changes.
            Then create patch tool requests for each change. Do not ask for permission.
            You run in a loop. Only use tool calls, until you are finished.

            <changes target_file="{}">
            {}
            </changes>
        "#,
            file, edit_string,
        )));

        agent.run().await?;
        Ok(Message::tool("edits done".into(), tool_id))
    }
}

#[derive(Default)]
struct EditInstruction;
impl AgentInstruction for EditInstruction {
    fn sys_prompt(&self) -> &'static str {
        crate::prompts::CURSOR_POMPT
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![Box::new(Cat), Box::new(PatchFile)]
    }
}
