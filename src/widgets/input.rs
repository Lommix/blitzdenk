use crate::{config::Theme, tui::SessionState};
use genai::chat::{ChatMessage, ChatRequest};
use owo_colors::OwoColorize;
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Margin, Rect},
    palette::stimulus::IntoStimulus,
    prelude::BlockExt,
    style::{Color, Modifier, Style, Stylize},
    symbols::scrollbar::Set,
    text::{Line, Span, Text},
    widgets::{
        self, block::Position, Block, BorderType, Borders, Padding, Paragraph, StatefulWidget,
        Widget,
    },
};
use throbber_widgets_tui::{Throbber, ThrobberState};
use tui_textarea::TextArea;

// input -------------------------------------------------------------------------------------
pub struct PromptWidget<'a> {
    textarea: &'a TextArea<'a>,
}

impl<'a> PromptWidget<'a> {
    pub fn new(session: &'a SessionState, theme: Theme) -> Self {
        Self {
            textarea: &session.textarea,
        }
    }
}

impl<'a> widgets::Widget for PromptWidget<'a>
where
    Self: Sized,
{
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer) {
        let mut a = self.textarea.clone();
        a.set_block(
            Block::new()
                .borders(Borders::TOP)
                .padding(Padding::horizontal(1))
                .border_style(Color::Rgb(171, 178, 191))
                .border_type(BorderType::QuadrantOutside),
        );
        a.render(
            Rect::new(area.left(), area.top(), area.width, area.height),
            buf,
        );
    }
}
// status ------------------------------------------------------------------------------------
#[derive(Default)]
pub struct StatusLineWidget<'a> {
    style: Style,
    spinner: Throbber<'a>,
    token_counter: Line<'a>,
    model_info: Line<'a>,
    mode: Line<'a>,
    version: Line<'a>,
}
impl<'a> StatusLineWidget<'a> {
    pub fn new(session: &SessionState, theme: Theme) -> Self {
        let mut widget = Self::default();
        widget.style = Style::new().bg(theme.foreground).fg(theme.text_color);

        widget.spinner = Throbber::default()
            .label(if session.running {
                "running .."
            } else {
                "idle .."
            })
            .throbber_style(Style::default().fg(theme.text_color))
            .style(Style::new().fg(theme.text_color))
            .throbber_set(if session.running {
                throbber_widgets_tui::BRAILLE_EIGHT_DOUBLE
            } else {
                throbber_widgets_tui::WHITE_CIRCLE
            });

        let mut token_string = format_token_cost(session.token_cost as f64);
        widget.token_counter = Line::raw(token_string)
            .bg(theme.accent)
            .fg(theme.text_color)
            .alignment(Alignment::Center)
            .add_modifier(Modifier::BOLD);

        widget.model_info = Line::raw(format!(" [{}] ", session.config.current_model))
            .alignment(Alignment::Center)
            .fg(theme.text_color)
            .bg(theme.secondary)
            .add_modifier(Modifier::BOLD);

        widget.version = Line::raw("Blitzdenk v0.3")
            .alignment(Alignment::Center)
            .fg(theme.text_color)
            .bg(theme.secondary)
            .add_modifier(Modifier::BOLD);

        // line.push_span(Span::raw(" MODE: ").style(Style::default()));
        // line.push_span(Span::raw(" [HELP] ").style(Style::default().bg(Color::Green).fg(Color::Black)));
        // line.push_span(Span::raw(" [DEBUG] ").style(Style::default().bg(Color::DarkGray)));
        // line.push_span(Span::raw(" [CODE] ").style(Style::default().bg(Color::DarkGray)));

        widget
    }
}

impl<'a> widgets::StatefulWidget for StatusLineWidget<'a> {
    type State = ThrobberState;
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer, state: &mut Self::State)
    where
        Self: Sized,
    {
        let (version_win, mut spinner_win, token_win, model_win, mode_win) = Layout::new(
            Direction::Horizontal,
            [
                Constraint::Length(20),
                Constraint::Length(15),
                Constraint::Length(8),
                Constraint::Length(48),
                Constraint::Fill(1),
            ],
        )
        .areas(area)
        .into();

        buf.set_style(area, self.style);
        spinner_win.x += 1;
        self.version.render(version_win, buf);
        StatefulWidget::render(self.spinner, spinner_win, buf, state);
        self.token_counter.render(token_win, buf);
        self.model_info.render(model_win, buf);
        self.mode.render(model_win, buf);
    }
}

fn format_token_cost(token_cost: f64) -> String {
    if token_cost >= 1_000_000.0 {
        format!(" {:.1}mT ", token_cost / 1_000_000.0)
    } else if token_cost >= 1_000.0 {
        format!(" {:.1}kT ", token_cost / 1_000.0)
    } else {
        format!(" {}T ", token_cost)
    }
}
