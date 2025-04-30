use blitzagent::{Agent, Message, Role};
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
    widgets::{self, Block, ScrollbarOrientation, ScrollbarState, Wrap},
    DefaultTerminal, Frame,
};
use std::time::{Duration, Instant};
use syntect::{
    easy::HighlightLines,
    highlighting::ThemeSet,
    parsing::{SyntaxReference, SyntaxSet},
};
use textwrap::wrap;

const PROMPT_HEADER: &'static str = "<PROMPT>";

const PROMPT_FOOTER: &'static str =
    "<| SEND: alt/shift/ctrl+ent <=> SCROLL:  <==> NEW: ctrl+n <==> SHOW TOOLS: ctrl+t |>";

enum Order {
    Clear,
    Send(Message),
}

enum Event {
    Tick,
    Input(char),
    Backspace,
    NewLine,
    Resize(Rect),
    ScrollUP,
    ScrollDown,
    ToggleTool,
    Paste(String),
    Clear,
    Send,
    Exit,
}

pub struct AppContext {
    rec: Receiver<Message>,
    inputs: Receiver<Event>,
    prompt_buffer: String,
    prompt_tx: Sender<Order>,
    chat_msg: Vec<Message>,
    scroll: u16,
    size: Rect,
    syntax_set: SyntaxSet,
    themes: ThemeSet,
    show_tool_res: bool,
    prompt_scroll: u16,
}

pub async fn init(agent: Agent, rec: Receiver<Message>) -> anyhow::Result<()> {
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
        rec,
        inputs,
        prompt_buffer: String::new(),
        chat_msg: vec![],
        prompt_tx,
        scroll: 0,
        size: Rect::new(0, 0, 0, 0),
        syntax_set: SyntaxSet::load_defaults_newlines(),
        themes: ThemeSet::load_defaults(),
        show_tool_res: false,
        prompt_scroll: 0,
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
                    agent.context.broadcast.send(msg.clone()).unwrap();
                    agent.chat.push_message(msg);
                    agent.run().await.unwrap();
                }
            }
        }
    });
}

fn handle_input(tx: Sender<Event>) {
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
                                    tx.send(Event::Exit).unwrap();
                                    break;
                                }

                                if is_ctrl && char == 'n' {
                                    tx.send(Event::Clear).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 't' {
                                    tx.send(Event::ToggleTool).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'u' {
                                    tx.send(Event::ScrollUP).unwrap();
                                    continue;
                                }

                                if is_ctrl && char == 'd' {
                                    tx.send(Event::ScrollDown).unwrap();
                                    continue;
                                }

                                tx.send(Event::Input(char)).unwrap();
                            }
                            event::KeyCode::Backspace => tx.send(Event::Backspace).unwrap(),
                            event::KeyCode::Enter => {
                                if is_alt || is_ctrl || is_shift {
                                    tx.send(Event::Send).unwrap()
                                } else {
                                    tx.send(Event::NewLine).unwrap()
                                }
                            }
                            event::KeyCode::Up => tx.send(Event::ScrollUP).unwrap(),
                            event::KeyCode::Down => tx.send(Event::ScrollDown).unwrap(),
                            _ => {}
                        }
                    }
                    event::Event::Resize(col, row) => {
                        let rect = Rect::new(0, 0, col, row);
                        tx.send(Event::Resize(rect)).unwrap()
                    }
                    event::Event::Paste(str) => {
                        tx.send(Event::Paste(str)).unwrap()
                    }
                    _ => {}
                };
            }
            if last_tick.elapsed() >= tick_rate {
                tx.send(Event::Tick).unwrap();
                last_tick = Instant::now();
            }
        }
    });
}

fn run(mut ctx: AppContext, mut terminal: DefaultTerminal) -> anyhow::Result<()> {
    loop {
        if let Ok(mut msg) = ctx.rec.try_recv() {
            if let Some(bytes) = msg.images.take().map(|mut i| i.pop()).flatten() {
                let name = format!("{:x}.png", rand::random::<u64>());
                std::fs::write(name, &bytes).expect("unable to save image");
            }
            ctx.chat_msg.push(msg.clone());
            terminal.resize(ctx.size).unwrap();
        }

        if let Ok(input) = ctx.inputs.try_recv() {
            match input {
                Event::Tick => {
                    terminal.draw(|frame| draw(&mut ctx, frame))?;
                }
                Event::Input(c) => ctx.prompt_buffer.push(c),
                Event::Backspace => _ = ctx.prompt_buffer.pop(),
                Event::NewLine => ctx.prompt_buffer.push('\n'),
                Event::ToggleTool => ctx.show_tool_res = !ctx.show_tool_res,
                Event::Resize(rect) => {
                    terminal.resize(rect).unwrap();
                }
                Event::Send => {
                    let msg = Message::user(ctx.prompt_buffer.drain(..).collect());
                    ctx.prompt_tx.send(Order::Send(msg))?;
                }
                Event::Exit => {
                    break Ok(());
                }
                Event::ScrollUP => {
                    ctx.scroll = ctx.scroll.saturating_add(1);
                }
                Event::ScrollDown => {
                    ctx.scroll = ctx.scroll.saturating_sub(1);
                }
                Event::Clear => {
                    ctx.prompt_tx.send(Order::Clear).unwrap();
                    ctx.prompt_buffer.clear();
                    ctx.chat_msg.clear();
                }
                Event::Paste(str) => {
                    ctx.prompt_buffer.push_str(&str);
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

    let scrollbar = widgets::Scrollbar::new(ScrollbarOrientation::VerticalRight)
        .begin_symbol(Some("↑"))
        .end_symbol(Some("↓"));

    let prompt_lines = ctx.prompt_buffer.lines().count();
    let mut state = ScrollbarState::new(prompt_lines).position(ctx.prompt_scroll as usize);

    let prompt = widgets::Paragraph::new(ctx.prompt_buffer.clone())
        .block(
            Block::bordered()
                .title_top(PROMPT_HEADER)
                .title_bottom(PROMPT_FOOTER)
                .border_type(widgets::BorderType::Rounded)
                .border_style(Style::default().cyan()),
        )
        .wrap(Wrap { trim: false })
        .scroll((
            prompt_lines.saturating_sub(prompt_box.height as usize - 2) as u16,
            0,
        ));

    frame.render_widget(prompt, prompt_box);
    frame.render_stateful_widget(
        scrollbar,
        prompt_box.inner(Margin {
            vertical: 1,
            horizontal: 0,
        }),
        &mut state,
    );

    let mut headers: Vec<String> = Vec::new();
    let mut lines = Vec::new();
    let mut line_count: u16 = 0;

    for msg in ctx.chat_msg.iter() {
        match msg.role {
            Role::Assistant => match msg.tool_calls.first().as_ref() {
                Some(call) => {
                    headers.push(format!(
                        "{} calls `{}` with `{:?}`",
                        msg.role, call.name, call.args
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
        line_count += wrap(&headers[i], chat_box.width as usize).len() as u16;

        let mut code_lang: Option<String> = None;

        if matches!(msg.role, Role::Tool) && !ctx.show_tool_res {
            continue;
        }

        msg.content.lines().for_each(|line| {
            if line.trim().starts_with("```") {
                let lang = line.trim().trim_start_matches("```");
                if !lang.is_empty() {
                    code_lang = Some(lang.into());
                } else {
                    code_lang = None;
                }
                lines.push(Line::styled(line, Style::default()));
                return;
            }

            line_count += wrap(line, chat_box.width as usize).len() as u16;

            match code_lang.as_ref() {
                Some(lang) => {
                    let mut highlight = HighlightLines::new(
                        find_syntax(lang, &ctx.syntax_set),
                        &ctx.themes.themes["base16-ocean.dark"],
                    );

                    let highlighted = highlight.highlight_line(line, &ctx.syntax_set).unwrap();
                    let spans = highlighted
                        .iter()
                        .enumerate()
                        .map(|(idx, segment)| {
                            let (style, content) = segment;
                            let mut text = content.to_string();
                            if idx == highlighted.len() - 1 {
                                text = text.trim_end().to_string();
                            }
                            return Span::styled(
                                text,
                                Style {
                                    fg: translate_colour(style.foreground),
                                    ..Style::default()
                                },
                            );
                        })
                        .collect::<Vec<_>>();

                    lines.push(Line::from(spans));
                }
                None => {
                    lines.push(Line::styled(line, into_style(msg.role)));
                }
            }
        });
    }

    let offset = (line_count as u16).saturating_sub(chat_box.height);

    let chat = widgets::Paragraph::new(lines)
        .scroll((offset.saturating_sub(ctx.scroll), 0))
        .wrap(Wrap { trim: false });

    frame.render_widget(chat, chat_box);

    // ----------------------------------------------

    let mut y = ctx
        .prompt_buffer
        .lines()
        .fold(0u16, |mut acc, v| {
            acc += wrap(v, prompt_box.width.saturating_sub(2) as usize).len() as u16;
            acc
        })
        .clamp(1, prompt_box.height.saturating_sub(2));

    let x = ctx
        .prompt_buffer
        .chars()
        .rev()
        .take_while(|c| !c.is_ascii_control())
        .count() as u16
        % prompt_box.width.saturating_sub(2);

    if ctx.prompt_buffer.ends_with('\n') {
        y = (y + 1).min(prompt_box.height.saturating_sub(2));
    }

    frame.set_cursor_position((prompt_box.x + x as u16 + 1, prompt_box.y + y));
}

pub fn translate_colour(syntect_color: syntect::highlighting::Color) -> Option<Color> {
    match syntect_color {
        syntect::highlighting::Color { r, g, b, a } if a > 0 => return Some(Color::Rgb(r, g, b)),
        _ => return None,
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

    return set.find_syntax_plain_text();
}

fn into_style(r: Role) -> Style {
    match r {
        Role::Assistant => Style::default().fg(Color::Green),
        Role::System => Style::default().fg(Color::Red),
        Role::User => Style::default().fg(Color::Cyan),
        Role::Tool => Style::default().fg(Color::Blue),
    }
}
