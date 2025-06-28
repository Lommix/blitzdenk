use std::{collections::HashMap, hash::Hash};

use ratatui::style::Color;
use serde::{Deserialize, Serialize};

use crate::prompts;

#[derive(Serialize, Deserialize, Clone)]
pub struct Config {
    pub current_model: String,
    pub model_list: Vec<String>,
    pub theme: Theme,
    pub user_prompts: HashMap<String, String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            current_model: "gemini-2.5-pro-preview-06-05".into(),
            model_list: [
                "claude-opus-4-20250514",
                "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-latest",
                "claude-3-5-haiku-latest",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite-preview-06-17",
                "gemini-2.0-flash-lite",
                "grok-3-beta",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>(),
            theme: Theme::lommix(),
            user_prompts: [
                ("init".to_string(), prompts::INIT_AGENT_PROMPT.to_string()),
                ("audit".to_string(), prompts::AUDIT_PROMPT.to_string()),
            ]
            .iter()
            .cloned()
            .collect(),
        }
    }
}

impl Config {
    pub async fn load() -> Self {
        let path = home::home_dir().unwrap().join(".cache/blitzdenk/denk.toml");

        if !tokio::fs::try_exists(&path).await.unwrap() {
            let config = Config::default();
            config.save().await;
            return config;
        }

        let raw = tokio::fs::read_to_string(&path)
            .await
            .expect("cannot read config");
        toml::de::from_str(&raw).unwrap()
    }

    pub async fn save(&self) {
        let path = home::home_dir().unwrap().join(".cache/blitzdenk/denk.toml");
        let raw = toml::ser::to_string(self).unwrap();
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await.unwrap();
        }

        tokio::fs::write(path, raw).await.unwrap();
    }
}

#[derive(Copy, Clone, Serialize, Deserialize)]
pub struct Theme {
    pub background: Color,
    pub foreground: Color,
    pub primary: Color,
    pub secondary: Color,
    pub accent: Color,
    pub text_color: Color,
    pub border_color: Color,
    pub selection_bg: Color,
    pub selection_fg: Color,
    pub error_text_color: Color,
    pub succes_text_color: Color,
}

impl Theme {
    pub fn lommix() -> Self {
        Self {
            background: Color::Rgb(40, 44, 52),          // #282c34;
            foreground: Color::Rgb(171, 178, 191),       // #abb2bf
            primary: Color::Rgb(97, 175, 239),           // #61afef
            secondary: Color::Rgb(98, 120, 221),         // #c678dd
            accent: Color::Rgb(224, 108, 117),           // #e06c75
            text_color: Color::Rgb(255, 255, 255),       // #FFFFFF
            border_color: Color::Rgb(65, 70, 82),        // #414552
            selection_bg: Color::Rgb(65, 70, 82),        // #414552
            selection_fg: Color::Rgb(171, 178, 191),     // #abb2bf
            error_text_color: Color::Rgb(224, 108, 117), // #e06c75
            succes_text_color: Color::Rgb(0, 180, 0),    // #00AF00
        }
    }
}

impl Default for Theme {
    fn default() -> Self {
        Theme::lommix()
    }
}
