use ratatui::{
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Style},
    widgets::{Block, BorderType, Clear, Padding, Paragraph, Widget},
};

use crate::config::Theme;

pub struct NotifyWidget<'a> {
    help_text: Paragraph<'a>,
}

impl<'a> NotifyWidget<'a> {
    pub fn new(theme: Theme, msg: &'a str) -> Self {
        let help_text = Paragraph::new(msg)
            .block(
                Block::bordered()
                    .padding(Padding::top(1))
                    .border_type(BorderType::QuadrantOutside)
                    .border_style(Style::new().fg(Color::White))
                    .style(Style::new().bg(theme.selection_bg)),
            )
            .alignment(Alignment::Center);

        Self { help_text }
    }
}

impl<'a> Widget for NotifyWidget<'a> {
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer) {
        let [modal] = Layout::horizontal([Constraint::Length(32)])
            .flex(Flex::End)
            .areas(area);
        let [modal] = Layout::vertical([Constraint::Length(5)])
            .flex(Flex::Start)
            .areas(modal);

        Widget::render(Clear, modal, buf);
        self.help_text.render(modal, buf);
    }
}
