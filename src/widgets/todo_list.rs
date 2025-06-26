use ratatui::{
    layout::Alignment,
    style::{Color, Style, Stylize},
    text::{Line, Span},
    widgets::{
        Block, BorderType, Clear, List, ListDirection, ListItem, ListState, Padding, Paragraph,
        StatefulWidget, Widget,
    },
};

use crate::{agent::{Status, TodoItem}, config::Theme};

/// Todo list widget showing tasks and their statuses.
pub struct TodoWidget<'a> {
    list: List<'a>,
}

impl<'a> TodoWidget<'a> {
    pub fn new(items: impl Iterator<Item = (&'a String, &'a TodoItem)>, theme: Theme) -> Self {
        let items = items.map(|(id, item)| {
            let mut line = Line::default();
            line.push_span(Span::raw(id));
            line.push_span(Span::raw(format!(": [{:?}] ", item.status)));
            line.push_span(Span::raw(&item.content));


            if item.status == Status::Completed {
                line = line.crossed_out();
            }

            line
            // ListItem::new(format!(
            //     "{} [{:?}] {:?} {}",
            //     id, item.status, item.priority, item.content
            // ))
        });
        Self {
            list: List::new(items)
                .block(
                    Block::bordered()
                        .title("Todo List")
                        .title_alignment(Alignment::Center)
                        .title_bottom(" j/k ↓↑ ")
                        .padding(Padding::top(1))
                        .title_style(Style::new().bg(Color::White).fg(theme.selection_bg))
                        .border_type(BorderType::QuadrantOutside)
                        .border_style(Style::new().fg(Color::White))
                        .style(Style::new().bg(theme.selection_bg)),
                )
                .highlight_style(Style::new().bg(theme.selection_fg))
                .highlight_symbol(">>")
                .direction(ListDirection::TopToBottom)
                .repeat_highlight_symbol(true),
        }
    }
}

impl<'a> StatefulWidget for TodoWidget<'a> {
    type State = ListState;
    fn render(
        self,
        area: ratatui::prelude::Rect,
        buf: &mut ratatui::prelude::Buffer,
        state: &mut Self::State,
    ) where
        Self: Sized,
    {
        Widget::render(Clear, area, buf);
        StatefulWidget::render(self.list, area, buf, state);
    }
}
