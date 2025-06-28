use crate::{config::Config, cost::CostList, error::AResult};
use clap::{Parser, Subcommand};
use ratatui::crossterm::{
    self,
    event::{EnableBracketedPaste, EnableMouseCapture},
    terminal::{enable_raw_mode, EnterAlternateScreen},
};

mod agent;
mod config;
mod cost;
mod error;
mod prompts;
mod tools;
mod tui;
mod widgets;

pub const SESSION_SAVE_DIR: &str = ".cache/blitzdenk/sessions/";
pub const CONFIG_SAVE_DIR: &str = ".cache/blitzdenk/";

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    Run,
    #[clap(about = "deletes all saved sessions")]
    Cleanup,
}

#[tokio::main]
async fn main() -> AResult<()> {
    let cli = Cli::parse();
    let config = Config::load().await;
    match cli.command.unwrap_or(Commands::Run) {
        Commands::Run => {
            let terminal = ratatui::init();
            let stdout = std::io::stdout();
            let mut stdout = stdout.lock();
            enable_raw_mode().unwrap();
            crossterm::execute!(
                stdout,
                EnableMouseCapture,
                EnableBracketedPaste,
                EnterAlternateScreen
            )
            .unwrap();

            let cost_list = CostList::fetch().await.ok();
            tui::run(terminal, config, cost_list).await?;
        }
        Commands::Cleanup => {
            let homepath = home::home_dir().expect("unable to find your home dir");
            let mut dir = tokio::fs::read_dir(homepath.join(SESSION_SAVE_DIR))
                .await
                .unwrap();

            let mut count = 0;

            while let Ok(Some(file)) = dir.next_entry().await {
                if file.path().extension().and_then(|s| s.to_str()) == Some("json") {
                    tokio::fs::remove_file(file.path()).await?;
                    count += 1;
                }
            }

            println!("deleted {} old sessions", count);
        }
    }
    Ok(())
}
