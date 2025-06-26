use crate::config::Theme;
use ratatui::{
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Style, Stylize},
    widgets::{
        self, Block, BorderType, Clear, List, ListItem, ListState, Padding, StatefulWidget, Widget,
    },
};

/// Selectable list for available model choices.
pub struct ModelSelectorWidget<'a> {
    list: List<'a>,
}

impl<'a> ModelSelectorWidget<'a> {
    pub fn new<I>(items: I, theme: Theme) -> Self
    where
        I: IntoIterator,
        I::Item: Into<ListItem<'a>>,
    {
        let list = List::default()
            .block(
                Block::bordered()
                    .title(" [Select Model] ")
                    .title_alignment(Alignment::Center)
                    .title_bottom(" j/k ↓↑ ")
                    .padding(Padding::top(1))
                    .title_style(Style::new().bg(Color::White).fg(theme.selection_bg))
                    .border_type(BorderType::QuadrantOutside)
                    .border_style(Style::new().fg(Color::White))
                    .style(Style::new().bg(theme.selection_bg)),
            )
            .highlight_style(Style::new().italic().bold().bg(theme.selection_fg))
            .highlight_symbol(">>")
            .direction(widgets::ListDirection::TopToBottom)
            .repeat_highlight_symbol(true)
            .items(items);

        Self { list }
    }
}

impl<'a> StatefulWidget for ModelSelectorWidget<'a> {
    type State = ListState;

    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer, state: &mut Self::State) {
        let [modal] = Layout::horizontal([Constraint::Length(48)])
            .flex(Flex::Center)
            .areas(area);

        let [modal] = Layout::vertical([Constraint::Length(16)])
            .flex(Flex::Center)
            .areas(modal);

        Widget::render(Clear, modal, buf);
        StatefulWidget::render(self.list, modal, buf, state);
    }
}
