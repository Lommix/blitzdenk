use genai::chat::ChatMessage;
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Style, Stylize},
    text::{Line, Span, Text},
    widgets::{self, Paragraph, Widget},
};
use serde::{Deserialize, Serialize};

use crate::config::Theme;

/// Stores open/collapse state for MessageWidget.
#[derive(Default, Debug, Clone, Serialize, Deserialize)]
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

/// Widget to display chat or tool messages in the UI.
pub enum MessageWidget<'a> {
    GenericToolCall(Vec<Line<'a>>),
    GenericToolResponse {
        preview: Vec<Line<'a>>,
        content: Vec<Option<Paragraph<'a>>>,
    },
    GenericChatMessage {
        header: Line<'a>,
        paragraph: Paragraph<'a>,
    },
}

impl<'a> MessageWidget<'a> {
    pub fn lines(&self, width: u16) -> u16 {
        match self {
            MessageWidget::GenericToolCall(lines) => lines.len() as u16,
            MessageWidget::GenericToolResponse { preview, content } => {
                preview.len() as u16
                    + content
                        .iter()
                        .flatten()
                        .map(|p| p.line_count(width) as u16)
                        .sum::<u16>()
            }
            MessageWidget::GenericChatMessage { header, paragraph } => {
                paragraph.line_count(width) as u16 + 1
            }
        }
    }

    pub fn new(msg: &'a ChatMessage, theme: Theme) -> Self {
        match &msg.content {
            genai::chat::MessageContent::Text(content) => {
                let header = Line::raw(format!("[{}]", msg.role))
                    .bg(theme.succes_text_color)
                    .fg(theme.text_color);

                let text = tui_markdown::from_str(content);
                let paragraph = widgets::Paragraph::new(text)
                    .wrap(widgets::Wrap { trim: false })
                    .bg(theme.selection_bg)
                    .fg(theme.selection_fg);

                MessageWidget::GenericChatMessage { header, paragraph }
            }
            genai::chat::MessageContent::ToolCalls(tool_calls) => {
                let calls = tool_calls
                    .iter()
                    .map(|call| {
                        let mut line = Line::default().bg(theme.primary).fg(theme.text_color);
                        line.push_span(Span::raw(format!("[{}]", call.fn_name)).bold());
                        line.push_span(Span::raw(" with ").italic());
                        let preview: String = call.fn_arguments.to_string();
                        line.push_span(Span::raw(format!(" {} ", preview)).bold());
                        line
                    })
                    .collect();

                MessageWidget::GenericToolCall(calls)
            }
            genai::chat::MessageContent::ToolResponses(tool_responses) => {
                let mut preview = Vec::new();
                let mut content = Vec::new();

                for res in tool_responses {
                    let mut line = Line::default().bg(theme.selection_bg);
                    line.push_span(Span::raw(format!(" ⮡ {}", res.content)).italic());
                    preview.push(line);
                    //@todo: certain tools should show their full content, like the edit
                    content.push(None);
                }

                MessageWidget::GenericToolResponse { preview, content }
            }
            genai::chat::MessageContent::Parts(content_parts) => todo!(),
        }
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
        match self {
            MessageWidget::GenericToolCall(mut lines) => {
                let mut rect = Rect::new(area.x, area.y, area.width, 1);
                lines.drain(..).enumerate().for_each(|(i, line)| {
                    line.render(rect, buf);
                    rect.y += i as u16;
                });
            }
            MessageWidget::GenericChatMessage { header, paragraph } => {
                let (header_win, content_win) = Layout::new(
                    Direction::Vertical,
                    [Constraint::Length(1), Constraint::Fill(1)],
                )
                .areas(area)
                .into();

                header.render(header_win, buf);
                paragraph.render(content_win, buf);
            }
            MessageWidget::GenericToolResponse {
                mut preview,
                mut content,
            } => {
                let mut offset = 0;
                for (preview, content) in preview.drain(..).zip(content.drain(..)) {
                    let rect = Rect::new(area.x, area.y + offset, area.width, 1);
                    preview.render(area, buf);

                    offset += 1;

                    if let Some(content) = content {
                        let lines = content.line_count(area.width) as u16;
                        let rect = Rect::new(area.x, area.y + offset, area.width, lines);
                        content.render(area, buf);
                        offset += lines;
                    }
                }
            }
        }
    }
}
