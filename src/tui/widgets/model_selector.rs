use crate::tui::theme::{self, Theme};
use genai::chat::{ChatMessage, ChatRequest};
use ratatui::{
    layout::{Alignment, Margin, Rect, Size},
    palette::stimulus::IntoStimulus,
    prelude::BlockExt,
    style::{Color, Style, Stylize},
    text::{Line, Text},
    widgets::{
        self, Block, BorderType, Borders, List, ListItem, ListState, Padding, StatefulWidget,
        Widget, block::Position,
    },
};

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
                    .title(" Select Model ")
                    .title_alignment(Alignment::Center)
                    .title_bottom(" j/k ↓↑ ")
                    .padding(Padding::top(1))
                    .title_style(Style::new().bg(Color::White).fg(theme.selection_bg))
                    .border_type(BorderType::QuadrantOutside)
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
        StatefulWidget::render(self.list, area, buf, state);
    }
}
