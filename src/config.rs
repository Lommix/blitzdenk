use serde::{Deserialize, Serialize};

const CONFIG_PATH: &str = "/home/lommix/.cache/blitzdenk/denk.toml";

#[derive(Serialize, Deserialize, Clone)]
pub struct Config {
    pub current_model: String,
    pub model_list: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            current_model: "gemini-2.5-pro-preview-06-05".into(),
            model_list: vec![
                "claude-sonnet-4-20250514".into(),
                "claude-3-7-sonnet-20250219".into(),
                "gpt-4o-mini".into(),
                "gemini-2.5-flash-preview-05-20".into(),
                "gemini-2.5-pro-preview-06-05".into(),
            ],
        }
    }
}

impl Config {
    pub async fn load() -> Self {
        if !tokio::fs::try_exists(CONFIG_PATH).await.unwrap() {
            let config = Config::default();
            config.save().await;
            return config;
        }

        let raw = tokio::fs::read_to_string(CONFIG_PATH)
            .await
            .expect("cannot read config");
        toml::de::from_str(&raw).unwrap()
    }

    pub async fn save(&self) {
        let raw = toml::ser::to_string(self).unwrap();
        tokio::fs::write(CONFIG_PATH, raw).await.unwrap();
    }
}
