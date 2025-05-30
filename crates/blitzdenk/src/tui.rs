use blitzagent::{Agent, Confirmation, Message, Role};
use crossbeam::channel::{Receiver, Sender};
use ratatui::{
    crossterm::{
        self,
        event::{self, EnableBracketedPaste, EnableMouseCapture, KeyModifiers},
        terminal::{enable_raw_mode, EnterAlternateScreen},
    },
    layout::{Constraint, Layout, Margin, Rect},
    style::{Color, Style, Stylize},
    text::{Line, Span},
    widgets::{self, Block, Clear, ScrollbarOrientation, ScrollbarState, Wrap},
    DefaultTerminal, Frame,
};
use std::time::{Duration, Instant};
use syntect::{
    easy::HighlightLines,
    highlighting::ThemeSet,
    parsing::{SyntaxReference, SyntaxSet},
};

use crate::Config;

const PROMPT_HEADER: &str = "[PROMPT]";

const PROMPT_FOOTER: &str =
    "─[SEND: alt/shift/ctrl+ent]──[SCROLL: ]──[NEW: ctrl+n]──[SHOW TOOLS: ctrl+t]─";

enum Order {
    Clear,
    Send(Message),
}

enum InputEvent {
    Tick,
    Input(char),
    Backspace,
    NewLine,
    Resize(Rect),
    ScrollUP,
    ScrollDown,
    ToggleTool,
    Paste(String),
    ChangeClient(String),
    Accept,
    Decline,
    Clear,
    Send,
    Exit,
}

pub struct AppContext {
    config: Config,
    rec: Receiver<Message>,
    inputs: Receiver<InputEvent>,
    prompt_buffer: String,
    prompt_tx: Sender<Order>,
    confirm_requests: Receiver<Confirmation>,
    current_confirm: Option<Confirmation>,
    chat_msg: Vec<Message>,
    scroll: u16,
    size: Rect,
    syntax_set: SyntaxSet,
    themes: ThemeSet,
    show_tool_res: bool,
    yolo_accept: bool,
    prompt_scroll: u16,
}

pub async fn init(
    agent: Agent,
    rec: Receiver<Message>,
    confirm_requests: Receiver<Confirmation>,
    config: Config,
) -> anyhow::Result<()> {
    let terminal = ratatui::init();
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();

    enable_raw_mode()?;
    crossterm::execute!(
        stdout,
        EnableMouseCapture,
        EnableBracketedPaste,
        EnterAlternateScreen
    )?;

    let (tx, inputs) = crossbeam::channel::unbounded();
    let (prompt_tx, prompt_rx) = crossbeam::channel::unbounded();

    let ctx = AppContext {
        config,
        rec,
        inputs,
        prompt_buffer: String::new(),
        chat_msg: vec![],
        prompt_tx,
        confirm_requests,
        current_confirm: None,
        scroll: 0,
        size: Rect::new(0, 0, 0, 0),
        syntax_set: SyntaxSet::load_defaults_newlines(),
        themes: ThemeSet::load_defaults(),
        show_tool_res: false,
        prompt_scroll: 0,
        yolo_accept: false,
    };

    handle_worker(agent, prompt_rx);
    handle_input(tx);

    run(ctx, terminal)?;

    ratatui::restore();
    Ok(())
}

fn handle_worker(mut agent: Agent, rec: Receiver<Order>) {
    tokio::spawn(async move {
        loop {
            let Ok(ev) = rec.recv() else {
                return;
            };
            match ev {
                Order::Clear => agent.chat.clear(),
                Order::Send(msg) => {
                    agent.context.message_tx.send(msg.clone()).unwrap();
                    agent.chat.push_message(msg);
                    agent.run().await.unwrap();
                }
            }
        }
    });
}

fn handle_input(tx: Sender<InputEvent>) {
    let tick_rate = Duration::from_millis(30);
    tokio::spawn(async move {
        let mut last_tick = Instant::now();
        loop {
            let timeout = tick_rate.saturating_sub(last_tick.elapsed());
            if event::poll(timeout).unwrap() {
                match event::read().unwrap() {
                    event::Event::Key(key) => {
                        let is_alt = key.modifiers.contains(KeyModifiers::ALT);
                        let is_ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
                        let is_shift = key.modifiers.contains(KeyModifiers::SHIFT);

                        match key.code {
                            event::KeyCode::Char(char) => {
                                if is_ctrl && char == 'c' {
                                    tx.send(InputEvent::Exit).unwrap();
                                    break;
                                }

                                if is_ctrl && char == 'n' {
                                    tx.send(InputEvent::Clear).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 't' {
                                    tx.send(InputEvent::ToggleTool).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'u' {
                                    tx.send(InputEvent::ScrollUP).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'd' {
                                    tx.send(InputEvent::ScrollDown).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'y' {
                                    tx.send(InputEvent::Accept).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'x' {
                                    tx.send(InputEvent::Decline).unwrap();
                                    continue;
                                }

                                tx.send(InputEvent::Input(char)).unwrap();
                            }
                            event::KeyCode::Backspace => tx.send(InputEvent::Backspace).unwrap(),
                            event::KeyCode::Enter => {
                                if is_alt || is_ctrl || is_shift {
                                    tx.send(InputEvent::Send).unwrap()
                                } else {
                                    tx.send(InputEvent::NewLine).unwrap()
                                }
                            }
                            event::KeyCode::Up => tx.send(InputEvent::ScrollUP).unwrap(),
                            event::KeyCode::Down => tx.send(InputEvent::ScrollDown).unwrap(),
                            _ => {}
                        }
                    }
                    event::Event::Resize(col, row) => {
                        let rect = Rect::new(0, 0, col, row);
                        tx.send(InputEvent::Resize(rect)).unwrap()
                    }
                    event::Event::Paste(str) => tx.send(InputEvent::Paste(str)).unwrap(),
                    _ => {}
                };
            }
            if last_tick.elapsed() >= tick_rate {
                tx.send(InputEvent::Tick).unwrap();
                last_tick = Instant::now();
            }
        }
    });
}

fn run(mut ctx: AppContext, mut terminal: DefaultTerminal) -> anyhow::Result<()> {
    loop {
        if let Ok(mut msg) = ctx.rec.try_recv() {
            if let Some(bytes) = msg.images.take().and_then(|mut i| i.pop()) {
                let name = format!("{:x}.png", rand::random::<u64>());
                std::fs::write(name, &bytes).expect("unable to save image");
            }
            ctx.chat_msg.push(msg.clone());
            terminal.resize(ctx.size).unwrap();
        }

        if ctx.current_confirm.is_none() {
            if let Ok(conf) = ctx.confirm_requests.try_recv() {
                if ctx.yolo_accept {
                    conf.responder.send(true).unwrap();
                } else {
                    ctx.current_confirm = Some(conf);
                }
            }
        }

        if let Ok(input) = ctx.inputs.try_recv() {
            match input {
                InputEvent::Tick => {
                    terminal.draw(|frame| draw(&mut ctx, frame))?;
                }
                InputEvent::Input(c) => ctx.prompt_buffer.push(c),
                InputEvent::Backspace => _ = ctx.prompt_buffer.pop(),
                InputEvent::NewLine => ctx.prompt_buffer.push('\n'),
                InputEvent::ToggleTool => ctx.show_tool_res = !ctx.show_tool_res,
                InputEvent::Resize(rect) => {
                    terminal.resize(rect).unwrap();
                }
                InputEvent::Send => {
                    let msg = Message::user(ctx.prompt_buffer.drain(..).collect());
                    ctx.prompt_tx.send(Order::Send(msg))?;
                }
                InputEvent::Exit => {
                    break Ok(());
                }
                InputEvent::Accept => {
                    if let Some(confirm) = ctx.current_confirm.take() {
                        confirm.responder.send(true).unwrap();
                    }
                }
                InputEvent::Decline => {
                    if let Some(confirm) = ctx.current_confirm.take() {
                        confirm.responder.send(false).unwrap();
                    }
                }
                InputEvent::ScrollUP => {
                    ctx.scroll = ctx.scroll.saturating_add(1);
                }
                InputEvent::ScrollDown => {
                    ctx.scroll = ctx.scroll.saturating_sub(1);
                }
                InputEvent::Clear => {
                    ctx.prompt_tx.send(Order::Clear).unwrap();
                    ctx.prompt_buffer.clear();
                    ctx.chat_msg.clear();
                }
                InputEvent::Paste(str) => {
                    ctx.prompt_buffer.push_str(&str);
                }
                InputEvent::ChangeClient(_new_client) => {
                    // @todo client hot swap
                }
            }
        }
    }
}

fn draw(ctx: &mut AppContext, frame: &mut Frame) {
    let (chat_box, prompt_box) =
        Layout::vertical([Constraint::Fill(1), Constraint::Percentage(20)])
            .areas(frame.area())
            .into();

    ctx.size = frame.area();
    // ----------------------------------------------
    //  chat

    let mut headers: Vec<String> = Vec::new();
    let mut lines = Vec::new();
    for msg in ctx.chat_msg.iter() {
        match msg.role {
            Role::Assistant => match msg.tool_calls.first().as_ref() {
                Some(call) => {
                    let args = format!("{:?}", call.args);
                    headers.push(format!(
                        "{} calls `{}` with `{}`",
                        msg.role,
                        call.name,
                        &args[0..args.len().min(64)],
                    ));
                }
                None => {
                    headers.push(format!("{}: ", msg.role));
                }
            },
            Role::Tool => {
                headers.push(format!("{} reponse for {:?}", msg.role, msg.tool_call_id));
            }
            _ => {
                headers.push(format!("{}:", msg.role));
            }
        }
    }

    for (i, msg) in ctx.chat_msg.iter().enumerate() {
        lines.push(Line::from(Span::styled(&headers[i], into_style(msg.role))));
        if matches!(msg.role, Role::Tool) && !ctx.show_tool_res {
            continue;
        }

        style_raw_lines(
            &mut lines,
            msg.content.lines().map(|l| (l, into_style(msg.role))),
            &ctx.themes,
            &ctx.syntax_set,
        );
    }

    let chat = widgets::Paragraph::new(lines).wrap(Wrap { trim: false });

    let line_count = chat.line_count(chat_box.width);
    let offset = (line_count as u16).saturating_sub(chat_box.height);
    frame.render_widget(
        chat.scroll((offset.saturating_sub(ctx.scroll), 0)),
        chat_box,
    );

    // ----------------------------------------------
    //  prompt
    let scrollbar = widgets::Scrollbar::new(ScrollbarOrientation::VerticalRight)
        .begin_symbol(Some("↑"))
        .end_symbol(Some("↓"));

    let mut prompt_lines = Vec::new();
    ctx.prompt_buffer.lines().for_each(|line| {
        prompt_lines.push(Line::raw(line));
    });

    // line wrapping sucks!
    let mut last_x_offset = ctx
        .prompt_buffer
        .lines()
        .last()
        .map(|l| {
            textwrap::wrap(l, prompt_box.width.saturating_sub(2) as usize)
                .last()
                .map(|l| l.len())
                .unwrap_or_default()
        })
        .unwrap_or_default() as u16;

    if ctx.prompt_buffer.ends_with(' ') {
        last_x_offset += 1;
    }

    let prompt = widgets::Paragraph::new(prompt_lines).wrap(Wrap { trim: false });

    let line_count = prompt.line_count(prompt_box.width.saturating_sub(2)) as u16;
    let mut state = ScrollbarState::new(line_count as usize).position(ctx.prompt_scroll as usize);

    frame.render_widget(
        prompt
            .scroll((
                line_count.saturating_sub(prompt_box.height.saturating_sub(2)),
                0,
            ))
            .block(
                Block::bordered()
                    .title_top(PROMPT_HEADER)
                    .title_bottom(PROMPT_FOOTER)
                    .border_type(widgets::BorderType::Rounded)
                    .border_style(Style::default().cyan()),
            ),
        prompt_box,
    );

    frame.render_stateful_widget(
        scrollbar,
        prompt_box.inner(Margin {
            vertical: 1,
            horizontal: 0,
        }),
        &mut state,
    );

    if ctx.prompt_buffer.ends_with('\n') {
        frame.set_cursor_position((
            prompt_box.x + 1,
            prompt_box.y + line_count.clamp(1, prompt_box.height.saturating_sub(2)) + 1,
        ));
    } else {
        frame.set_cursor_position((
            prompt_box.x + last_x_offset + 1,
            prompt_box.y + line_count.clamp(1, prompt_box.height.saturating_sub(2)),
        ));
    }

    if let Some(confirm) = ctx.current_confirm.as_ref() {
        let mut lines = Vec::new();
        style_raw_lines(
            &mut lines,
            confirm.message.lines().map(|l| (l, Style::default())),
            &ctx.themes,
            &ctx.syntax_set,
        );

        let confirm = widgets::Paragraph::new(lines)
            .wrap(Wrap { trim: true })
            .block(
                widgets::Block::bordered()
                    .border_type(widgets::BorderType::Double)
                    .title_bottom("═[ACCEPT:ctrl+y]═════[DECLINE:ctrl+x]"),
            );

        let lc = confirm.line_count(chat_box.width - 5) as u16;
        let mt = (chat_box.height - lc / 2).min((chat_box.height / 2) + 2);

        let confirm_area = frame.area().inner(Margin::new(5, mt));
        frame.render_widget(Clear, confirm_area);
        frame.render_widget(confirm, confirm_area);
    }
}

pub fn translate_colour(syntect_color: syntect::highlighting::Color) -> Option<Color> {
    match syntect_color {
        syntect::highlighting::Color { r, g, b, a } if a > 0 => Some(Color::Rgb(r, g, b)),
        _ => None,
    }
}

pub fn find_syntax<'a>(name: &str, set: &'a SyntaxSet) -> &'a SyntaxReference {
    if let Some(syntax) = set.find_syntax_by_extension(name) {
        return syntax;
    }

    if let Some(syntax) = set.find_syntax_by_name(name) {
        return syntax;
    }

    if let Some(syntax) = set.find_syntax_by_token(name) {
        return syntax;
    }

    set.find_syntax_plain_text()
}

fn into_style(r: Role) -> Style {
    match r {
        Role::Assistant => Style::default().fg(Color::Green),
        Role::System => Style::default().fg(Color::Red),
        Role::User => Style::default().fg(Color::Cyan),
        Role::Tool => Style::default().fg(Color::Blue),
    }
}

fn style_raw_lines<'a>(
    lines: &mut Vec<Line<'a>>,
    raw: impl Iterator<Item = (&'a str, Style)>,
    themes: &ThemeSet,
    syntax: &SyntaxSet,
) {
    let mut code_lang: Option<String> = None;
    for (line, default_style) in raw {
        if line.trim().starts_with("```") {
            let lang = line.trim().trim_start_matches("```");
            if !lang.is_empty() {
                code_lang = Some(lang.into());
            } else {
                code_lang = None;
            }
            lines.push(Line::styled(line, Style::default()));
            continue;
        }

        match code_lang.as_ref() {
            Some(lang) => {
                let mut highlight = HighlightLines::new(
                    find_syntax(lang, syntax),
                    &themes.themes["base16-ocean.dark"],
                );

                let highlighted = highlight.highlight_line(line, syntax).unwrap();
                let spans = highlighted
                    .iter()
                    .enumerate()
                    .map(|(idx, segment)| {
                        let (style, content) = segment;
                        let mut text = content.to_string();
                        if idx == highlighted.len() - 1 {
                            text = text.trim_end().to_string();
                        }
                        Span::styled(
                            text,
                            Style {
                                fg: translate_colour(style.foreground),
                                ..Style::default()
                            },
                        )
                    })
                    .collect::<Vec<_>>();

                lines.push(Line::from(spans));
            }
            None => {
                lines.push(Line::styled(line, default_style));
            }
        }
    }
}
