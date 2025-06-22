use ratatui::crossterm::{
    self,
    event::{EnableBracketedPaste, EnableMouseCapture},
    terminal::{enable_raw_mode, EnterAlternateScreen},
};

use crate::agent::AResult;

mod agent;
mod config;
mod error;
mod prompts;
mod tools;
mod tui;
mod widgets;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    Run,
    Init,
}

#[tokio::main]
async fn main() -> AResult<()> {
    let cli = Cli::parse();

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

            tui::run(terminal).await?;
        }
        Commands::Init => {
            println!("Init command executed");
        }
    }

    Ok(())
}
