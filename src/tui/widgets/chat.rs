use crate::tui::{TuiMessage, theme::Theme};
use genai::chat::{ChatMessage, ChatRequest};
use ratatui::{
    layout::{Margin, Rect, Size},
    palette::stimulus::IntoStimulus,
    prelude::BlockExt,
    style::Style,
    text::{Line, Text},
    widgets::{self, Block, BorderType, Borders, Widget, block::Position},
};
use tui_scrollview::{ScrollView, ScrollViewState};

// chat --------------------------------------------------------------------------------------
pub struct ChatWidget<'a> {
    pub history: &'a Vec<TuiMessage>,
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

        for msg in self.history.iter() {
            let msg_widget = super::MessageWidget::new(&msg.message, self.theme);
            let lines = msg_widget.lines(area.width);
            msgs.push((msg_widget, lines, offset, msg.state.clone()));
            offset += lines;
        }

        let mut scroll_view = ScrollView::new(Size::new(area.width, offset))
            .horizontal_scrollbar_visibility(tui_scrollview::ScrollbarVisibility::Never);

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
