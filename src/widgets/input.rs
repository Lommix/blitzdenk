use crate::{config::Theme, tui::SessionState};
use owo_colors::OwoColorize;
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::Line,
    widgets::{self, Block, BorderType, Borders, Padding, StatefulWidget, Widget},
};
use throbber_widgets_tui::{Throbber, ThrobberState};
use tui_textarea::TextArea;

// input -------------------------------------------------------------------------------------
pub struct PromptWidget<'a> {
    textarea: &'a TextArea<'a>,
}

impl<'a> PromptWidget<'a> {
    pub fn new(session: &'a SessionState, theme: Theme) -> Self {
        Self {
            textarea: &session.textarea,
        }
    }
}

impl<'a> widgets::Widget for PromptWidget<'a>
where
    Self: Sized,
{
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer) {
        let mut a = self.textarea.clone();
        a.set_block(
            Block::new()
                .borders(Borders::TOP)
                .padding(Padding::horizontal(1))
                .border_style(Color::Rgb(171, 178, 191))
                .border_type(BorderType::QuadrantOutside),
        );
        a.render(
            Rect::new(area.left(), area.top(), area.width, area.height),
            buf,
        );
    }
}
