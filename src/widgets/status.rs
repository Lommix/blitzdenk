use crate::{config::Theme, tui::SessionState};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style, Stylize},
    text::Line,
    widgets::{self, StatefulWidget, Widget},
};
use throbber_widgets_tui::{Throbber, ThrobberState};

// status ------------------------------------------------------------------------------------
#[derive(Default)]
/// Application status bar with spinner, model, and tokens.
pub struct StatusLineWidget<'a> {
    style: Style,
    spinner: Throbber<'a>,
    token_counter: Line<'a>,
    todo_info: Line<'a>,
    model_info: Line<'a>,
    mode: Line<'a>,
    version: Line<'a>,
}
impl<'a> StatusLineWidget<'a> {
    pub fn new(
        session: &SessionState,
        theme: Theme,
        completed_tasks: usize,
        total_tasks: usize,
    ) -> Self {
        let mut widget = Self::default();
        widget.style = Style::new().bg(theme.secondary).fg(theme.text_color);

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

        let token_string = format!(
            "{} {}",
            format_token_cost(session.token_cost as f64),
            format_currency(session.money_cost),
        );
        widget.token_counter = Line::raw(token_string)
            .bg(theme.secondary)
            .fg(theme.text_color)
            .alignment(Alignment::Center)
            .add_modifier(Modifier::BOLD);

        widget.model_info = Line::raw(format!(" [{}] ", session.config.current_model))
            .alignment(Alignment::Center)
            .fg(theme.text_color)
            .bg(theme.secondary)
            .add_modifier(Modifier::BOLD);

        widget.todo_info = Line::raw(format!(
            "{}/{} Tasks completed",
            completed_tasks, total_tasks
        ))
        .alignment(Alignment::Center)
        .fg(theme.text_color)
        .bg(theme.secondary)
        .add_modifier(Modifier::BOLD);

        widget.version = Line::raw("Blitzdenk v0.3")
            .alignment(Alignment::Center)
            .fg(theme.text_color)
            .bg(theme.secondary)
            .add_modifier(Modifier::BOLD);

        widget
    }
}

impl<'a> widgets::StatefulWidget for StatusLineWidget<'a> {
    type State = ThrobberState;
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer, state: &mut Self::State)
    where
        Self: Sized,
    {
        let (version_win, mut spinner_win, todo_win, token_win, model_win) = Layout::new(
            Direction::Horizontal,
            [
                Constraint::Length(20),
                Constraint::Length(12),
                Constraint::Length(28),
                Constraint::Length(20),
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
        self.todo_info.render(todo_win, buf);
        self.model_info.render(model_win, buf);
        self.mode.render(model_win, buf);
    }
}

fn format_token_cost(token_cost: f64) -> String {
    if token_cost >= 1_000_000.0 {
        format!(" {:.1}m Tokens ", token_cost / 1_000_000.0)
    } else if token_cost >= 1_000.0 {
        format!(" {:.1}k Tokens ", token_cost / 1_000.0)
    } else {
        format!(" {} Tokens", token_cost)
    }
}

fn format_currency(value: f64) -> String {
    format!("${:.2}", value)
}
