use crate::{
    agent::{
        AResult, Agent, AgentContext, AgentEvent, AgentMessage, PermissionRequest, Status, TodoItem,
    },
    config::Config,
    error::AiError,
    prompts, tools,
    widgets::{self, ConfirmWidget, MessageState, TodoWidget},
};
use crossbeam::channel::{self, Receiver, Sender};
use genai::chat::{ChatMessage, ChatRequest};
use ratatui::{
    crossterm::event::{self, KeyCode, KeyEvent, KeyModifiers},
    layout::{Constraint, Direction, Layout, Margin},
    prelude::Backend,
    style::Style,
    widgets::{ListState, StatefulWidget, Widget},
    Frame, Terminal,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use throbber_widgets_tui::ThrobberState;
use tokio::{sync::Mutex, task::JoinHandle};
use tui_textarea::TextArea;
use tui_widgets::scrollview::ScrollViewState;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TuiMessage {
    pub message: ChatMessage,
    pub state: MessageState,
}

pub struct SessionState<'a> {
    pub messages: Vec<TuiMessage>,
    pub textarea: TextArea<'a>,
    pub runner: AgentRunner,
    pub token_cost: i32,
    pub scroll_state: ScrollViewState,
    pub config: Config,
    pub running: bool,
    pub running_spinner_state: ThrobberState,
    pub popup_state: PopupState,
}

#[derive(Default)]
pub enum PopupState {
    #[default]
    None,
    Help,
    ModelSelect(ListState),
    TodoList(ListState),
    Confirm {
        req: PermissionRequest,
        scroll: u16,
    },
}

#[derive(Serialize, Deserialize)]
pub struct SessionSaveState {
    chat: ChatRequest,
    todo: HashMap<String, TodoItem>,
    model: String,
    token_cost: i32,
    input: Vec<String>,
}

impl<'a> SessionState<'a> {
    pub fn new(config: Config) -> Self {
        Self {
            messages: Vec::new(),
            token_cost: 0,
            textarea: TextArea::default(),
            runner: AgentRunner::new(&config.current_model),
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            config,
            popup_state: PopupState::None,
        }
    }

    pub async fn save(&self) -> AResult<()> {
        let agent = self.runner.agent.lock().await;
        let session_name = agent.context.current_cwd.replace('/', "");

        let path = home::home_dir()
            .map(|p| p.join(format!(".cache/blitzdenk/sessions/{}.json", session_name)))
            .unwrap();

        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let state = SessionSaveState {
            input: self.textarea.lines().to_owned(),
            chat: agent.chat.clone(),
            todo: agent.context.todo_list.lock().await.clone(),
            model: agent.model.clone(),
            token_cost: self.token_cost,
        };

        let state_str = serde_json::to_string(&state)?;
        tokio::fs::write(path, state_str).await?;

        Ok(())
    }

    pub async fn load(cwd: &str, config: Config) -> AResult<Self> {
        let session_name = cwd.replace('/', "");

        let path = home::home_dir()
            .map(|p| p.join(format!(".cache/blitzdenk/sessions/{}.json", session_name)))
            .unwrap();

        let state_str = tokio::fs::read_to_string(path).await?;
        let state: SessionSaveState = serde_json::from_str(&state_str)?;

        let mut messages = Vec::new();
        for msg in state.chat.messages.iter() {
            messages.push(TuiMessage {
                message: msg.clone(),
                state: MessageState::default(),
            });
        }

        let runner = AgentRunner::new(&state.model);

        {
            let mut agent = runner.agent.lock().await;
            agent.chat = state.chat.clone();
            *agent.context.todo_list.lock().await = state.todo.clone();
        }

        let mut session = Self {
            messages,
            token_cost: state.token_cost,
            textarea: TextArea::new(state.input),
            runner,
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            popup_state: PopupState::None,
            config,
        };

        session.scroll_state.scroll_to_bottom();

        Ok(session)
    }
}

pub enum AgentCmd {
    Cancle,
    Run,
}

pub struct AgentRunner {
    pub agent: Arc<Mutex<Agent>>,
    pub context: AgentContext,
    pub cmd_channel: Sender<AgentCmd>,
    pub handle: JoinHandle<()>,
    pub msg_rx: Receiver<AgentEvent>,
    pub state: Arc<Mutex<bool>>,
}

impl AgentRunner {
    pub fn new(model: impl Into<String>) -> Self {
        let (msg_tx, msg_rx) = channel::unbounded();
        let mut agent = Agent::new(model, msg_tx);
        agent.add_tool(tools::Glob);
        agent.add_tool(tools::Grep);
        agent.add_tool(tools::Read);
        agent.add_tool(tools::Edit);
        agent.add_tool(tools::MultiEdit);
        agent.add_tool(tools::Bash);
        agent.add_tool(tools::Fetch);
        agent.add_tool(tools::Write);
        agent.add_tool(tools::TodoRead);
        agent.add_tool(tools::TodoWrite);
        agent.add_tool(tools::Ls);
        agent.add_system_msg(Self::build_system_prompt());

        let context = agent.context.clone();

        let agent_wrapped = Arc::new(Mutex::new(agent));
        let (cmd_tx, cmd_rx) = channel::unbounded();

        let _agent = agent_wrapped.clone();
        let state = Arc::new(Mutex::new(false));
        let _state = state.clone();

        let handle = tokio::spawn(async move {
            loop {
                let Ok(event) = cmd_rx.recv() else {
                    break;
                };

                match event {
                    AgentCmd::Cancle => {
                        todo!("impl cancle")
                    }
                    AgentCmd::Run => {
                        {
                            if *_state.lock().await {
                                continue;
                            }
                        }

                        let mut agent = _agent.lock().await;

                        {
                            *_state.lock().await = true;
                        }

                        match agent.run().await {
                            Ok(_) => (),
                            Err(err) => agent
                                .context
                                .sender
                                .send(AgentEvent::Message(AgentMessage::new(
                                    ChatMessage::system(err.to_string()),
                                    None,
                                )))
                                .unwrap(),
                        }

                        {
                            *_state.lock().await = false;
                        }
                    }
                }
            }
        });

        Self {
            agent: agent_wrapped,
            cmd_channel: cmd_tx,
            handle,
            msg_rx,
            state,
            context,
        }
    }

    pub async fn start_cycle(&self) -> AResult<()> {
        if self.is_running().await {
            return Err(AiError::AlreadyRunning);
        }

        self.cmd_channel.send(AgentCmd::Run)?;
        Ok(())
    }

    pub fn shutdown(&self) {
        self.handle.abort();
    }

    pub async fn clear(&self) {
        let mut agent = self.agent.lock().await;
        agent.chat.messages.clear();
        agent.add_system_msg(Self::build_system_prompt());
    }

    fn build_system_prompt() -> String {
        let mut system_prompt = prompts::DEFAULT_AGENT_PROMPT.to_string();

        if let Ok(user_context) = read_user_context() {
            system_prompt.push_str(&format!(
                r#"# User Rules and Context

Here is the user provided project context and ruleset. User context can overwrite any existing rule.

<user_context>
{}
</user_context>
"#,
                user_context
            ));
        }

        system_prompt
    }

    pub fn cancle(&self) -> AResult<()> {
        self.cmd_channel.send(AgentCmd::Cancle)?;
        Ok(())
    }

    pub async fn is_running(&self) -> bool {
        *self.state.lock().await
    }

    pub fn is_running_sync(&self) -> bool {
        *self.state.blocking_lock()
    }

    pub async fn add_message(&self, msg: ChatMessage) {
        let mut agent = self.agent.lock().await;
        agent.chat = agent.chat.clone().append_message(msg);
    }
}

impl Drop for AgentRunner {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

pub async fn run<T>(mut terminal: Terminal<T>, config: Config) -> AResult<()>
where
    T: Backend,
{
    let cwd = std::env::current_dir()
        .expect("failed to read current dir!")
        .to_string_lossy()
        .to_string();

    let mut session = SessionState::load(&cwd, config.clone())
        .await
        .unwrap_or(SessionState::new(config));

    let input = InputRunner::new();

    loop {
        if let Ok(response) = session.runner.msg_rx.try_recv() {
            match response {
                AgentEvent::Message(agent_message) => {
                    session.messages.push(TuiMessage {
                        message: agent_message.chat_message,
                        state: MessageState::default(),
                    });

                    session.token_cost = agent_message.token_cost.unwrap_or(session.token_cost);
                    session.scroll_state.scroll_to_bottom();
                }
                AgentEvent::Permission(permission_request) => {
                    session.popup_state = PopupState::Confirm {
                        req: permission_request,
                        scroll: 0,
                    };
                }
            }
        }

        if let Ok(event) = input.rx.try_recv() {
            match event {
                TuiEvent::Tick => {
                    session.running = session.runner.is_running().await;
                    session.running_spinner_state.calc_next();
                    let todo = session.runner.context.todo_list.lock().await.clone();
                    _ = terminal.draw(render(&mut session, todo)).unwrap();
                }
                TuiEvent::SelectPrev => match &mut session.popup_state {
                    PopupState::ModelSelect(list_state) | PopupState::TodoList(list_state) => {
                        list_state.select_previous()
                    }
                    _ => (),
                },
                TuiEvent::SelectNext => match &mut session.popup_state {
                    PopupState::ModelSelect(list_state) | PopupState::TodoList(list_state) => {
                        list_state.select_next()
                    }
                    _ => (),
                },
                TuiEvent::ToggleHelp => match &session.popup_state {
                    PopupState::Help => session.popup_state = PopupState::None,
                    PopupState::Confirm { req, scroll } => (),
                    _ => session.popup_state = PopupState::Help,
                },
                TuiEvent::ToggleSelectModal => match &session.popup_state {
                    PopupState::ModelSelect(_) => session.popup_state = PopupState::None,
                    PopupState::Confirm { req, scroll } => (),
                    _ => {
                        session.popup_state =
                            PopupState::ModelSelect(ListState::default().with_selected(Some(0)))
                    }
                },
                TuiEvent::ToggleTodo => match &session.popup_state {
                    PopupState::TodoList(_) => session.popup_state = PopupState::None,
                    PopupState::Confirm { req, scroll } => (),
                    _ => {
                        session.popup_state =
                            PopupState::TodoList(ListState::default().with_selected(Some(0)))
                    }
                },
                TuiEvent::Key(key) => {
                    match key.code {
                        KeyCode::Char(c) => match &mut session.popup_state {
                            PopupState::ModelSelect(list_state)
                            | PopupState::TodoList(list_state) => {
                                if c == 'k' {
                                    list_state.select_previous();
                                }

                                if c == 'j' {
                                    list_state.select_next();
                                }
                            }
                            _ => (),
                        },
                        KeyCode::Up => session.scroll_state.scroll_up(),
                        KeyCode::Down => session.scroll_state.scroll_down(),
                        KeyCode::Enter => match &session.popup_state {
                            PopupState::ModelSelect(list_state) => {
                                let index = list_state.selected().unwrap_or_default();

                                {
                                    session.runner.agent.lock().await.model =
                                        session.config.model_list[index].clone();
                                }

                                session.config.current_model =
                                    session.config.model_list[index].clone();
                                session.config.save().await;

                                session.popup_state = PopupState::None;
                            }
                            PopupState::TodoList(list_state) => {
                                let index = list_state.selected().unwrap_or_default();
                                if let Some((_, item)) = session
                                    .runner
                                    .context
                                    .todo_list
                                    .lock()
                                    .await
                                    .iter_mut()
                                    .nth(index)
                                {
                                    match item.status {
                                        Status::Pending => item.status = Status::Completed,
                                        Status::InProgress => item.status = Status::Completed,
                                        Status::Completed => item.status = Status::Pending,
                                    }
                                }
                            }
                            _ => (),
                        },
                        _ => (),
                    }

                    if matches!(session.popup_state, PopupState::None) {
                        _ = session.textarea.input(key);
                    }
                }
                TuiEvent::Paste(string) => _ = session.textarea.insert_str(string),
                TuiEvent::Input(_) => (),
                TuiEvent::Resize(_, _) => (),
                TuiEvent::ScrollUp => match &mut session.popup_state {
                    PopupState::None => session.scroll_state.scroll_up(),
                    PopupState::Confirm { req, scroll } => {
                        *scroll = scroll.saturating_sub(0);
                    }
                    _ => (),
                },
                TuiEvent::ScrollDown => match &mut session.popup_state {
                    PopupState::None => session.scroll_state.scroll_down(),
                    PopupState::Confirm { req, scroll } => {
                        *scroll += 1;
                    }
                    _ => (),
                },
                TuiEvent::Accept => {
                    if let PopupState::Confirm { req, scroll } = session.popup_state {
                        req.respond.send(true).unwrap();
                        session.popup_state = PopupState::None;
                    }
                }
                TuiEvent::Decline => {
                    if let PopupState::Confirm { req, scroll } = session.popup_state {
                        req.respond.send(false).unwrap();
                        session.popup_state = PopupState::None;
                    }
                }
                TuiEvent::Clear => {
                    if session.runner.is_running().await {
                        continue;
                    }
                    session.token_cost = 0;
                    session.runner.clear().await;
                    session.messages.clear();
                    session.textarea = TextArea::default();
                }
                TuiEvent::Prompt => {
                    if session.runner.is_running().await {
                        continue;
                    }

                    let prompt: String = session.textarea.lines().join("\n");

                    match prompt.as_str() {
                        "/init" => {
                            session.messages.push(TuiMessage {
                                message: ChatMessage::user(prompts::INIT_AGENT_PROMPT),
                                state: MessageState::default(),
                            });
                            session
                                .runner
                                .add_message(ChatMessage::user(prompts::INIT_AGENT_PROMPT))
                                .await;
                            session.runner.start_cycle().await?;
                            session.textarea = TextArea::default();
                        }
                        any => {
                            session.messages.push(TuiMessage {
                                message: ChatMessage::user(any),
                                state: MessageState::default(),
                            });

                            session.runner.add_message(ChatMessage::user(any)).await;
                            session.runner.start_cycle().await?;
                            session.textarea = TextArea::default();
                        }
                    };
                }
                TuiEvent::Exit => {
                    session.runner.shutdown();
                    session.save().await.unwrap();
                    break;
                }
            }
        }
    }

    ratatui::restore();
    Ok(())
}

pub fn render(
    session: &mut SessionState,
    todo: HashMap<String, TodoItem>,
) -> impl FnOnce(&mut Frame) {
    move |frame| {
        let theme = session.config.theme;
        let window = frame.area();

        let (chat_window, prompt_window, status_window) = Layout::new(
            Direction::Vertical,
            [
                Constraint::Fill(1),
                Constraint::Length(6),
                Constraint::Length(1),
            ],
        )
        .areas(window)
        .into();

        frame
            .buffer_mut()
            .set_style(chat_window, Style::new().bg(theme.background));

        frame
            .buffer_mut()
            .set_style(prompt_window, Style::new().bg(theme.background));

        // --------------
        // title screen / chat

        if session.messages.is_empty() {
            widgets::TitleWidget::new().render(window, frame.buffer_mut());
        } else {
            widgets::ChatWidget {
                messages: &session.messages,
                theme,
            }
            .render(chat_window, frame.buffer_mut(), &mut session.scroll_state);
        }

        // --------------
        // textarea

        let input_widget = widgets::PromptWidget::new(session, theme);
        input_widget.render(prompt_window, frame.buffer_mut());

        let total_tasks = todo.len();
        let completed_tasks = todo
            .iter()
            .filter(|(_, i)| i.status == Status::Completed)
            .count();

        let status_widget =
            widgets::StatusLineWidget::new(session, theme, completed_tasks, total_tasks);
        status_widget.render(
            status_window,
            frame.buffer_mut(),
            &mut session.running_spinner_state,
        );

        match &mut session.popup_state {
            PopupState::None => (),
            PopupState::Help => {
                let modal = window.inner(Margin::new(10, 10));
                widgets::HelpWidget::new(theme).render(modal, frame.buffer_mut());
            }
            PopupState::ModelSelect(list_state) => {
                let selection =
                    widgets::ModelSelectorWidget::new(session.config.model_list.clone(), theme);
                selection.render(window, frame.buffer_mut(), list_state);
            }
            PopupState::TodoList(list_state) => {
                let modal = window.inner(Margin::new(10, 10));
                TodoWidget::new(todo.iter(), theme).render(modal, frame.buffer_mut(), list_state);
            }
            PopupState::Confirm { req, scroll } => {
                let modal = window.inner(Margin::new(5, 5));
                ConfirmWidget::new(&req.message, *scroll, theme).render(modal, frame.buffer_mut());
            }
        }
    }
}

struct InputRunner {
    handle: JoinHandle<()>,
    rx: Receiver<TuiEvent>,
}
impl InputRunner {
    pub fn new() -> Self {
        let (tx, rx) = channel::unbounded();
        let handle = tokio::spawn(async move {
            _ = handle_input(tx);
        });

        Self { handle, rx }
    }
}

impl Drop for InputRunner {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

fn handle_input(tx: Sender<TuiEvent>) -> AResult<()> {
    let tick_rate = Duration::from_millis(30);
    let mut last_tick = Instant::now();

    loop {
        let timeout = tick_rate.saturating_sub(last_tick.elapsed());
        if event::poll(timeout).unwrap() {
            let Ok(event) = event::read() else {
                break;
            };

            match event {
                event::Event::Key(key) => {
                    let is_alt = key.modifiers.contains(KeyModifiers::ALT);
                    let is_ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
                    // let is_shift = key.modifiers.contains(KeyModifiers::SHIFT);
                    match key.code {
                        KeyCode::Enter => {
                            if is_alt || is_ctrl {
                                tx.send(TuiEvent::Prompt)?;
                                continue;
                            }
                        }
                        KeyCode::Char(c) => {
                            if is_ctrl && c == 'c' {
                                tx.send(TuiEvent::Exit).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 'n' {
                                tx.send(TuiEvent::Clear).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 'k' {
                                tx.send(TuiEvent::ToggleSelectModal).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 'y' {
                                tx.send(TuiEvent::Accept).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 'x' {
                                tx.send(TuiEvent::Decline).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 't' {
                                tx.send(TuiEvent::ToggleTodo).unwrap();
                                continue;
                            }

                            if is_ctrl && c == 'h' {
                                tx.send(TuiEvent::ToggleHelp).unwrap();
                                continue;
                            }
                        }
                        _ => (),
                    }
                    tx.send(TuiEvent::Key(key))?;
                }
                event::Event::Paste(content) => tx.send(TuiEvent::Paste(content))?,
                event::Event::Resize(w, h) => tx.send(TuiEvent::Resize(w, h))?,
                event::Event::Mouse(mouse_event) => match mouse_event.kind {
                    event::MouseEventKind::ScrollDown => tx.send(TuiEvent::ScrollDown)?,
                    event::MouseEventKind::ScrollUp => tx.send(TuiEvent::ScrollUp)?,
                    _ => (),
                },
                event::Event::FocusGained => {}
                event::Event::FocusLost => {}
            }
        }

        if last_tick.elapsed() >= tick_rate {
            last_tick = Instant::now();
            tx.send(TuiEvent::Tick)?;
        }
    }

    Ok(())
}

pub enum TuiEvent {
    Tick,
    Input(char),
    Resize(u16, u16),
    ScrollUp,
    ScrollDown,
    SelectNext,
    SelectPrev,
    Accept,
    Decline,
    Clear,
    Prompt,
    Exit,
    ToggleSelectModal,
    ToggleTodo,
    ToggleHelp,
    Paste(String),
    Key(KeyEvent),
}

pub fn read_user_context() -> AResult<String> {
    Ok(std::fs::read_to_string("./AGENTS.md")?)
}
