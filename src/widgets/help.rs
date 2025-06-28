use ratatui::{
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Style},
    widgets::{Block, BorderType, Clear, Padding, Paragraph, Widget},
};

use crate::config::Theme;

pub const HELP_TEXT: &str = r#"
[enter] send prompt
[ctrl+k] select model
[ctrl+n] new session
[ctrl+h] help
[ctrl+t] todo list
[ctrl+c] exit
[ctrl+s] cancel agent

/init - generates a AGENTS.md
/audit - finding bugs and problems.
"#;

pub struct HelpWidget<'a> {
    help_text: Paragraph<'a>,
}

impl<'a> HelpWidget<'a> {
    pub fn new(theme: Theme) -> Self {
        let help_text = Paragraph::new(HELP_TEXT).block(
            Block::bordered()
                .title(" Help Overview ")
                .title_alignment(Alignment::Center)
                .padding(Padding::top(1))
                .title_style(Style::new().bg(Color::White).fg(theme.selection_bg))
                .border_type(BorderType::QuadrantOutside)
                .border_style(Style::new().fg(Color::White))
                .style(Style::new().bg(theme.selection_bg)),
        );

        Self { help_text }
    }
}

impl<'a> Widget for HelpWidget<'a> {
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer) {
        let [modal] = Layout::horizontal([Constraint::Length(60)])
            .flex(Flex::Center)
            .areas(area);
        let [modal] = Layout::vertical([Constraint::Length(30)])
            .flex(Flex::Center)
            .areas(modal);

        Widget::render(Clear, modal, buf);
        self.help_text.render(modal, buf);
    }
}
