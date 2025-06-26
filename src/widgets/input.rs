use crate::{config::Theme, tui::SessionState};
use ratatui::{
    layout::Rect,
    style::Color,
    widgets::{self, Block, BorderType, Borders, Padding},
};
use tui_textarea::TextArea;

/// Renders the user prompt input textarea.
pub struct PromptWidget<'a> {
    textarea: &'a TextArea<'a>,
}

impl<'a> PromptWidget<'a> {
    pub fn new(session: &'a SessionState, _theme: Theme) -> Self {
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
                .borders(Borders::TOP | Borders::LEFT | Borders::RIGHT)
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
