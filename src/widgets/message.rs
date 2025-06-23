use genai::chat::ChatMessage;
use owo_colors::OwoColorize;
use ratatui::{
    layout::{Constraint, Direction, Layout},
    style::{Color, Style},
    text::Line,
    widgets::{self, Widget},
};

use crate::config::Theme;

#[derive(Default, Clone)]
pub struct MessageState {
    collapse: bool,
}

impl MessageState {
    pub fn open(&mut self) {
        self.collapse = false;
    }
    pub fn close(&mut self) {
        self.collapse = true;
    }
    pub fn toggle(&mut self) {
        self.collapse = !self.collapse;
    }
}

// message ----------------------------------------------------------------------------------
pub struct MessageWidget<'a> {
    content: widgets::Paragraph<'a>,
    header: Line<'a>,
}

impl<'a> MessageWidget<'a> {
    pub fn new(msg: &'a ChatMessage, theme: Theme) -> Self {
        let style = Style::default()
            .bg(theme.selection_bg)
            .fg(theme.selection_fg);

        let (title, color) = match &msg.content {
            genai::chat::MessageContent::Text(_) => {
                (format!("{}", msg.role), theme.succes_text_color)
            }
            genai::chat::MessageContent::Parts(_) => (format!("{}", msg.role), theme.secondary),
            genai::chat::MessageContent::ToolCalls(tool_calls) => {
                let call = tool_calls.first().unwrap();
                let preview: String = call.fn_arguments.to_string();
                (
                    format!("Calling {} with {}", call.fn_name, preview),
                    theme.primary,
                )
            }
            genai::chat::MessageContent::ToolResponses(tool_responses) => {
                let preview: String = tool_responses
                    .first()
                    .map(|s| s.content.clone())
                    .unwrap_or_default();

                (format!(" ⮡ {}", preview), theme.selection_bg)
            }
        };

        let header = Line::raw(title).style(Style::new().bg(color).fg(theme.text_color));

        let c: String = match &msg.content {
            genai::chat::MessageContent::Text(t) => t.clone(),
            genai::chat::MessageContent::Parts(parts) => parts
                .iter()
                .map(|p| match p {
                    genai::chat::ContentPart::Text(t) => t.as_str(),
                    genai::chat::ContentPart::Image {
                        content_type,
                        source,
                    } => "",
                })
                .collect(),
            genai::chat::MessageContent::ToolCalls(tool_calls) => tool_calls
                .iter()
                .map(|c| {
                    format!(
                        "[{}] Tool `{}` with `{}`\n",
                        c.call_id, c.fn_name, c.fn_arguments
                    )
                })
                .collect(),
            genai::chat::MessageContent::ToolResponses(tool_responses) => tool_responses
                .iter()
                .map(|r| format!("[{}] response:\n{}\n", r.call_id, r.content))
                .collect(),
        };

        let text = tui_markdown::from_str(msg.content.text_as_str().unwrap_or_default());
        let content = widgets::Paragraph::new(text)
            .wrap(widgets::Wrap { trim: false })
            .style(style);

        Self { header, content }
    }

    pub fn lines(&self, width: u16) -> u16 {
        self.content.line_count(width) as u16 + 1
    }
}

impl<'a> widgets::StatefulWidget for MessageWidget<'a> {
    type State = MessageState;

    fn render(
        self,
        area: ratatui::prelude::Rect,
        buf: &mut ratatui::prelude::Buffer,
        _state: &mut Self::State,
    ) where
        Self: Sized,
    {
        let (header_win, content_win) = Layout::new(
            Direction::Vertical,
            [Constraint::Length(1), Constraint::Fill(1)],
        )
        .areas(area)
        .into();

        self.header.render(header_win, buf);
        self.content.render(content_win, buf);
    }
}
