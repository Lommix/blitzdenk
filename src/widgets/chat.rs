use crate::{config::Theme, tui::TuiMessage};
use ratatui::{
    layout::{Rect, Size},
    widgets::{self, Widget},
};
use tui_widgets::scrollview::{ScrollView, ScrollViewState, ScrollbarVisibility};

// chat --------------------------------------------------------------------------------------
/// Displays a scrollable list of chat messages.
pub struct ChatWidget<'a> {
    pub messages: &'a Vec<TuiMessage>,
    pub theme: Theme,
}

impl<'a> widgets::StatefulWidget for ChatWidget<'a> {
    type State = ScrollViewState;

    fn render(
        self,
        area: ratatui::prelude::Rect,
        buf: &mut ratatui::prelude::Buffer,
        state: &mut Self::State,
    ) where
        Self: Sized,
    {
        buf.set_style(area, self.theme.background);

        let mut offset = 0;

        let mut msgs = Vec::new();

        for msg in self.messages.iter() {
            let msg_widget = super::MessageWidget::new(&msg.message, self.theme);
            let lines = msg_widget.lines(area.width);
            msgs.push((msg_widget, lines, offset, msg.state.clone()));
            offset += lines;
        }

        let mut scroll_view = ScrollView::new(Size::new(area.width, offset))
            .horizontal_scrollbar_visibility(ScrollbarVisibility::Never);

        for (widget, lines, offset, mut state) in msgs.drain(..) {
            scroll_view.render_stateful_widget(
                widget,
                Rect::new(0, offset, area.width, lines),
                &mut state,
            );
        }

        scroll_view.render(area, buf, state);
    }
}
