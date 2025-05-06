use blitzagent::*;
use clap::*;
use home::home_dir;
use serde::{Deserialize, Serialize};
use std::io::Write;

mod prompts;
mod tools;
mod tui;

pub const CONFIG_PATH: &'static str = ".config/blitzdenk/config.toml";

#[derive(Parser)]
enum Cmd {
    Chat(AgentArgs),
    Yolo(AgentArgs),
    Config,
}

#[derive(Clone, Default, ValueEnum, Serialize, Debug)]
enum ClientType {
    #[default]
    Openai,
    Ollama,
}

#[derive(Args)]
struct AgentArgs {
    client: ClientType,
    root: Option<String>,
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
            Box::new(tools::Cat),
            Box::new(tools::WriteMemo),
            Box::new(tools::CrawlWebsite),
            Box::new(tools::Grep),
            Box::new(tools::GitLog),
            Box::new(tools::GitShowCommit),
            Box::new(tools::EditFile),
            Box::new(tools::CreateFile),
            Box::new(tools::Mkdir),
        ]
    }
}

#[derive(Default)]
pub struct YoloAgent;
impl AgentInstruction for YoloAgent {
    fn sys_prompt(&self) -> &'static str {
        crate::prompts::YOLO_PROMPT
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![
            Box::new(tools::Tree),
            Box::new(tools::Cat),
            Box::new(tools::WriteMemo),
            Box::new(tools::CrawlWebsite),
            Box::new(tools::Grep),
            Box::new(tools::Mkdir),
            Box::new(tools::Sed),
            Box::new(tools::CreateFile),
            Box::new(tools::DeleteFile), //bad idea
            Box::new(tools::MoveFile),
            Box::new(tools::GitLog),
            Box::new(tools::GitShowCommit),
        ]
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cmd = Cmd::parse();
    let mut config = read_or_create_config().await?;

    match &cmd {
        Cmd::Yolo(args) | Cmd::Chat(args) => {
            print!("\x1B[2J\x1B[1;1H");

            let root = args
                .root
                .as_ref()
                .map(|s| s.as_str())
                .unwrap_or("./")
                .to_string();

            let (ctx, rx, crx) = match args.client {
                ClientType::Openai => {
                    if config.openai_key.is_empty() {
                        println!("Missing openAi api key! Please run `config`");
                        return Ok(());
                    }
                    AgentContext::new(
                        root,
                        OpenApiClient::new(config.openai_model, config.openai_key),
                    )
                }
                ClientType::Ollama => AgentContext::new(
                    root,
                    OllamaClient::new(config.ollama_model, config.ollama_url),
                ),
            };

            let agent = match cmd {
                Cmd::Yolo(_) => ctx.new_agent::<YoloAgent>(),
                _ => ctx.new_agent::<DevAgent>(),
            };

            tui::init(agent, rx, crx).await?;
        }
        Cmd::Config => {
            println!("Please select an option");
            println!("(0) openai key");
            println!("(1) select model openai");
            println!("(2) select model ollama");
            print!("SELECT:");

            let mut input = String::new();
            std::io::stdout().flush()?;
            std::io::stdin().read_line(&mut input)?;
            let choice = input.trim().parse::<i64>().expect("not a valid choice");

            match choice {
                0 => {
                    let mut input = String::new();
                    std::io::stdout().flush()?;
                    std::io::stdin().read_line(&mut input)?;
                    config.openai_key = input.trim().into();
                    save_config(&config).await?;
                    println!("key saved!");
                }
                1 => {
                    let c = OpenApiClient::new("", &config.openai_key);
                    let models = c.list_models().await?;
                    for (i, m) in models.iter().enumerate() {
                        println!("({}) {}", i, m);
                    }

                    print!("SELECT:");
                    let mut input = String::new();
                    std::io::stdout().flush()?;
                    std::io::stdin().read_line(&mut input)?;

                    let choice = input.trim().parse::<usize>()?;
                    let model = models[choice].clone();

                    config.openai_model = model;
                    save_config(&config).await?;

                    println!("new model choosen: '{}'", config.openai_model);
                }
                2 => {
                    let c = OllamaClient::new("", &config.ollama_url);
                    let models = c.list_models().await?;
                    for (i, m) in models.iter().enumerate() {
                        println!("({}) {}", i, m);
                    }
                    print!("SELECT:");
                    let mut input = String::new();
                    std::io::stdout().flush()?;
                    std::io::stdin().read_line(&mut input)?;

                    let choice = input.trim().parse::<usize>()?;
                    let model = models[choice].clone();

                    config.ollama_model = model;
                    save_config(&config).await?;
                }
                _ => {}
            }
        }
    }

    return Ok(());
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Config {
    ollama_model: String,
    ollama_url: String,
    openai_key: String,
    openai_model: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            ollama_model: "qwen3:14b".into(),
            openai_key: "".into(),
            ollama_url: "http://127.0.0.1:11434/api".into(),
            openai_model: "gpt-4.1".into(),
        }
    }
}

async fn save_config(config: &Config) -> anyhow::Result<()> {
    let home = home_dir().expect("failed to get home dir");
    let path = home.join(CONFIG_PATH);
    let str = toml::to_string(config)?;
    tokio::fs::write(path, str).await?;

    Ok(())
}

async fn read_or_create_config() -> anyhow::Result<Config> {
    let home = home_dir().expect("failed to get home dir");
    let path = home.join(CONFIG_PATH);
    let config_exists = tokio::fs::try_exists(&path).await?;

    if !config_exists {
        let str = toml::to_string(&Config::default())?;
        tokio::fs::create_dir_all(path.parent().unwrap()).await?;
        tokio::fs::write(path, str).await?;
        return Ok(Config::default());
    }

    let str = tokio::fs::read_to_string(&path).await?;
    let cfg = match toml::from_str(&str) {
        Ok(cfg) => cfg,
        Err(_) => {
            let str = toml::to_string(&Config::default())?;
            tokio::fs::create_dir_all(path.parent().unwrap()).await?;
            tokio::fs::write(path, str).await?;
            Config::default()
        }
    };

    Ok(cfg)
}
