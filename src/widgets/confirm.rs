use ratatui::{
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Style, Stylize},
    text::{Line, Text},
    widgets::{Block, Borders, Clear, Paragraph, Widget, Wrap},
};

use crate::{config::Theme, tui::SessionState};

// input -------------------------------------------------------------------------------------
pub struct ConfirmWidget<'a> {
    content: Paragraph<'a>,
}

impl<'a> ConfirmWidget<'a> {
    pub fn new(content: &'a str, scroll: u16, theme: Theme) -> Self {
        let content = tui_markdown::from_str(content);
        let content = Paragraph::new(content)
            .block(
                Block::new()
                    .title_top("[PERMISSION]")
                    .title_style(Style::new().bg(Color::White).fg(theme.selection_bg))
                    .title_alignment(Alignment::Center)
                    .title_bottom("[ctrl+y:Accept][ctrl+x:Decline]")
                    .borders(Borders::ALL)
                    .border_type(ratatui::widgets::BorderType::QuadrantOutside),
            )
            .style(Style::new().bg(theme.selection_bg))
            .scroll((scroll, 0))
            .wrap(Wrap { trim: false });

        Self { content }
    }
}

impl<'a> Widget for ConfirmWidget<'a> {
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer)
    where
        Self: Sized,
    {
        let height = self.content.line_count(80);

        let [modal] = Layout::horizontal([Constraint::Length(80)])
            .flex(Flex::Center)
            .areas(area);

        let [modal] = Layout::vertical([Constraint::Length((height + 2) as u16)])
            .flex(Flex::Center)
            .areas(modal);

        Widget::render(Clear, modal, buf);
        self.content.render(modal, buf);
    }
}
