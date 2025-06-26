use crate::{agent::AResult, config::Config};
use clap::{Parser, Subcommand};
use ratatui::crossterm::{
    self,
    event::{EnableBracketedPaste, EnableMouseCapture},
    terminal::{enable_raw_mode, EnterAlternateScreen},
};

mod agent;
mod config;
mod error;
mod prompts;
mod tools;
mod tui;
mod widgets;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    Run,
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

            tui::run(terminal, config).await?;
        }
    }

    Ok(())
}
