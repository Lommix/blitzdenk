use ratatui::style::Color;
use serde::{Deserialize, Serialize};

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
}

impl Theme {
    pub fn lommix() -> Self {
        Self {
            background: Color::Rgb(40, 44, 52),          // #282c34
            foreground: Color::Rgb(171, 178, 191),       // #abb2bf
            primary: Color::Rgb(97, 175, 239),           // #61afef
            secondary: Color::Rgb(198, 120, 221),        // #c678dd
            accent: Color::Rgb(224, 108, 117),           // #e06c75
            text_color: Color::Rgb(255, 255, 255),       // #FFFFFF
            border_color: Color::Rgb(65, 70, 82),        // #414552
            selection_bg: Color::Rgb(65, 70, 82),        // #414552
            selection_fg: Color::Rgb(171, 178, 191),     // #abb2bf
            error_text_color: Color::Rgb(224, 108, 117), // #e06c75
        }
    }
}

impl Default for Theme {
    fn default() -> Self {
        Theme::lommix()
    }
}
