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
    buffer::Buffer,
    crossterm::event::{self, KeyCode, KeyEvent, KeyModifiers},
    layout::{Constraint, Direction, Layout, Margin, Rect},
    prelude::Backend,
    style::Style,
    widgets::{ListState, StatefulWidget, Widget},
    Frame, Terminal,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    hash::Hash,
    sync::Arc,
    time::{Duration, Instant},
};
use throbber_widgets_tui::ThrobberState;
use tokio::{sync::Mutex, task::JoinHandle};
use tui_textarea::TextArea;
use tui_widgets::scrollview::ScrollViewState;

pub struct TuiMessage {
    pub message: ChatMessage,
    pub state: MessageState,
}

pub struct SessionState<'a> {
    pub config: Config,
    pub messages: Vec<TuiMessage>,
    pub token_cost: i32,
    pub textarea: TextArea<'a>,
    pub runner: AgentRunner,
    pub scroll_state: ScrollViewState,
    pub running: bool,
    pub running_spinner_state: ThrobberState,
    pub model_select_state: Option<ListState>,
    pub todo_select_state: Option<ListState>,
    pub confirm: Option<PermissionRequest>,
    pub confirm_scroll: u16,
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
}

impl<'a> SessionState<'a> {
    pub fn new(config: Config) -> Self {
        Self {
            messages: Vec::new(),
            token_cost: 0,
            textarea: TextArea::default(),
            runner: AgentRunner::new(&config.current_model),
            confirm: None,
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            todo_select_state: None,
            model_select_state: None,
            config,
            confirm_scroll: 0,
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
        for msg in state.chat.messages.iter().skip(1) {
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

        let session = Self {
            messages,
            token_cost: state.token_cost,
            textarea: TextArea::default(),
            runner,
            confirm: None,
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            todo_select_state: None,
            model_select_state: None,
            confirm_scroll: 0,
            config,
        };

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
                    session.confirm = Some(permission_request);
                    session.confirm_scroll = 0;
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
                TuiEvent::SelectPrev => {
                    _ = session
                        .model_select_state
                        .as_mut()
                        .map(|l| l.select_previous())
                }
                TuiEvent::SelectNext => {
                    _ = session.model_select_state.as_mut().map(|l| l.select_next())
                }
                TuiEvent::SelectModel => {
                    if session.model_select_state.is_none() {
                        session.model_select_state =
                            Some(ListState::default().with_selected(Some(0)))
                    } else {
                        session.model_select_state = None;
                    }
                }
                TuiEvent::Key(key) => {
                    if let Some(state) = session.model_select_state.as_mut() {
                        match key.code {
                            KeyCode::Enter => {
                                let index = session
                                    .model_select_state
                                    .as_ref()
                                    .and_then(|k| k.selected())
                                    .unwrap_or_default();
                                session.config.current_model =
                                    session.config.model_list[index].clone();
                                session.config.save().await;
                                session.model_select_state = None;
                            }
                            KeyCode::Esc => {
                                session.model_select_state = None;
                            }
                            KeyCode::Char(c) => {
                                if c == 'k' {
                                    state.select_previous();
                                }
                                if c == 'j' {
                                    state.select_next();
                                }
                            }
                            _ => (),
                        }

                        continue;
                    }

                    if session.confirm.is_some() {
                        match key.code {
                            KeyCode::Up => {
                                session.confirm_scroll = session.confirm_scroll.saturating_sub(1)
                            }
                            KeyCode::Down => session.confirm_scroll += 1,
                            _ => (),
                        }
                        continue;
                    }

                    match key.code {
                        KeyCode::Up => session.scroll_state.scroll_up(),
                        KeyCode::Down => session.scroll_state.scroll_down(),
                        _ => (),
                    }

                    _ = session.textarea.input(key);
                }
                TuiEvent::ToggleTodo => {
                    if session.todo_select_state.is_none() {
                        session.todo_select_state =
                            Some(ListState::default().with_selected(Some(0)));
                    } else {
                        session.todo_select_state = None;
                    }
                }
                TuiEvent::Paste(string) => _ = session.textarea.insert_str(string),
                TuiEvent::Input(_) => (),
                TuiEvent::Resize(_, _) => (),
                TuiEvent::ScrollUp => session.scroll_state.scroll_up(),
                TuiEvent::ScrollDown => session.scroll_state.scroll_down(),
                TuiEvent::Accept => {
                    if let Some(req) = session.confirm.take() {
                        req.respond.send(true).unwrap();
                    }
                }
                TuiEvent::Decline => {
                    if let Some(req) = session.confirm.take() {
                        req.respond.send(false).unwrap();
                    }
                }
                TuiEvent::Clear => {
                    if session.runner.is_running().await {
                        continue;
                    }

                    session.token_cost = 0;
                    session.runner.clear().await;
                    session.messages.clear();
                }
                TuiEvent::Prompt => {
                    if session.runner.is_running().await {
                        continue;
                    }

                    if let Some(_select_state) = session.model_select_state.take() {
                        continue;
                    }

                    let prompt: String = session.textarea.lines().join("\n");

                    match prompt.as_str() {
                        "/init" => {
                            session.textarea = TextArea::new(
                                prompts::INIT_AGENT_PROMPT
                                    .split('\n')
                                    .map(|s| s.to_string())
                                    .collect(),
                            )
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
                history: &session.messages,
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

        if let Some(todo_state) = session.todo_select_state.as_mut() {
            let modal = window.inner(Margin::new(10, 10));
            TodoWidget::new(todo.iter(), theme).render(modal, frame.buffer_mut(), todo_state);
        }

        // select confirm
        if let Some(confirm) = session.confirm.as_ref() {
            let modal = window.inner(Margin::new(5, 5));
            ConfirmWidget::new(&confirm.message, &session, theme).render(modal, frame.buffer_mut());
        }

        // select model
        if let Some(select) = session.model_select_state.as_mut() {
            let selection =
                widgets::ModelSelectorWidget::new(session.config.model_list.clone(), theme);
            selection.render(window, frame.buffer_mut(), select);
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
                                tx.send(TuiEvent::SelectModel).unwrap();
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

                            tx.send(TuiEvent::Input(c))?;
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
    SelectModel,
    ToggleTodo,
    Paste(String),
    Key(KeyEvent),
}

pub fn read_user_context() -> AResult<String> {
    Ok(std::fs::read_to_string("./AGENTS.md")?)
}
