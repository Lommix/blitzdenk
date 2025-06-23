use ratatui::{
    layout::{Constraint, Flex, Layout, Rect},
    style::Stylize,
    text::Line,
    widgets::{Paragraph, Widget},
};
use tui_widgets::big_text::BigText;

// input -------------------------------------------------------------------------------------
pub struct TitleWidget<'a> {
    title: BigText<'a>,
    info: Paragraph<'a>,
}

impl<'a> TitleWidget<'a> {
    pub fn new() -> Self {
        let mut line = Line::default();
        line.push_span("BLITZ".blue());
        line.push_span("DENK".white());

        let title = tui_widgets::big_text::BigText::builder()
            .pixel_size(tui_widgets::big_text::PixelSize::Quadrant)
            .lines(vec![line])
            .build();

        let info = Paragraph::new(
            "v0.3\n\n[ctrl+k] select model\n[ctrl+n] new session\n[alt+enter] send prompt\n/init",
        );

        Self { title, info }
    }
}

impl<'a> Widget for TitleWidget<'a> {
    fn render(self, area: Rect, buf: &mut ratatui::prelude::Buffer)
    where
        Self: Sized,
    {
        let [modal] = Layout::horizontal([Constraint::Length(40)])
            .flex(Flex::Center)
            .areas(area);

        let [modal] = Layout::vertical([Constraint::Length(16)])
            .flex(Flex::Center)
            .areas(modal);

        let [title, info] = Layout::vertical([Constraint::Length(4), Constraint::Fill(1)])
            .flex(Flex::Center)
            .areas(modal);

        self.title.render(title, buf);
        self.info.render(info, buf);
    }
}
