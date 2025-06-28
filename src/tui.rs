use crate::{
    agent::{Agent, AgentContext, AgentEvent, AgentMessage, PermissionRequest, Status, TodoItem},
    config::Config,
    cost::CostList,
    error::{AResult, AiError},
    prompts, tools,
    widgets::{self, ConfirmWidget, MessageState, NotifyWidget, TodoWidget},
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
use tokio::{
    sync::{Mutex, Notify},
    task::JoinHandle,
};
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
    pub money_cost: Option<f64>,
    pub scroll_state: ScrollViewState,
    pub config: Config,
    pub running: bool,
    pub running_spinner_state: ThrobberState,
    pub popup_state: TuiState,
}

#[derive(Default)]
pub enum TuiState {
    #[default]
    None,
    Help,
    Notification {
        msg: String,
        elapsed: Duration,
    },
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
    money_cost: Option<f64>,
    input: Vec<String>,
}

impl<'a> SessionState<'a> {
    pub fn new(config: Config) -> Self {
        Self {
            messages: Vec::new(),
            token_cost: 0,
            money_cost: None,
            textarea: TextArea::default(),
            runner: AgentRunner::new(&config.current_model),
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            config,
            popup_state: TuiState::None,
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
            money_cost: self.money_cost,
        };

        let state_str = serde_json::to_string(&state)?;
        tokio::fs::write(path, state_str).await?;

        Ok(())
    }

    async fn handle_input(&mut self, ev: KeyEvent) -> AResult<()> {
        let is_alt = ev.modifiers.contains(KeyModifiers::ALT);
        let is_ctrl = ev.modifiers.contains(KeyModifiers::CONTROL);
        let is_shift = ev.modifiers.contains(KeyModifiers::SHIFT);

        match &mut self.popup_state {
            TuiState::None => {
                match ev.code {
                    KeyCode::Char(c) => {
                        if is_ctrl && c == 'n' {
                            if self.runner.is_running().await {
                                return Ok(());
                            }
                            self.token_cost = 0;
                            self.money_cost = None;
                            self.runner.clear().await;
                            self.messages.clear();
                            self.textarea = TextArea::default();

                            return Ok(());
                        }

                        if is_ctrl && c == 'k' {
                            self.popup_state =
                                TuiState::ModelSelect(ListState::default().with_selected(Some(0)));
                            return Ok(());
                        }

                        if is_ctrl && c == 't' {
                            self.popup_state =
                                TuiState::TodoList(ListState::default().with_selected(Some(0)));
                            return Ok(());
                        }

                        if is_ctrl && c == 'h' {
                            self.popup_state = TuiState::Help;
                            return Ok(());
                        }

                        if is_ctrl && c == 's' {
                            self.runner.cancel();
                            return Ok(());
                        }

                        self.textarea.input(ev);
                    }
                    KeyCode::Enter => {
                        if !is_shift && !is_shift && !is_alt {
                            if self.runner.is_running().await {
                                return Ok(());
                            }

                            let prompt: String = self.textarea.lines().join("\n");

                            if prompt.starts_with('/') {
                                if let Some(prefab_prompt) =
                                    self.config.user_prompts.get(&prompt[1..])
                                {
                                    self.messages.push(TuiMessage {
                                        message: ChatMessage::user(prefab_prompt),
                                        state: MessageState::default(),
                                    });
                                    self.runner
                                        .add_message(ChatMessage::user(prefab_prompt))
                                        .await;
                                    self.runner.start_cycle().await?;
                                    self.textarea = TextArea::default();
                                }
                            } else {
                                self.messages.push(TuiMessage {
                                    message: ChatMessage::user(&prompt),
                                    state: MessageState::default(),
                                });

                                self.runner.add_message(ChatMessage::user(&prompt)).await;
                                self.runner.start_cycle().await?;
                                self.textarea = TextArea::default();
                            }
                        } else {
                            self.textarea.input(ev);
                        }
                    }
                    _ => {
                        self.textarea.input(ev);
                    }
                }

                return Ok(());
            }
            TuiState::Confirm { req, scroll } => match ev.code {
                KeyCode::Up | KeyCode::PageUp => {
                    *scroll = scroll.saturating_sub(1);
                    Ok(())
                }
                KeyCode::Down | KeyCode::PageDown => {
                    *scroll += 1;
                    Ok(())
                }
                KeyCode::Char(c) => {
                    if c == 'a' {
                        if let Some(s) = req.respond.take() {
                            s.send(true).unwrap();
                        }

                        return Ok(());
                    }

                    if c == 'd' {
                        if let Some(s) = req.respond.take() {
                            s.send(false).unwrap();
                        }
                        return Ok(());
                    }

                    Ok(())
                }
                _ => Ok(()),
            },
            TuiState::Help => {
                match ev.code {
                    KeyCode::Esc => self.popup_state = TuiState::None,
                    KeyCode::Char(c) => {
                        if is_ctrl && c == 'h' {
                            self.popup_state = TuiState::None
                        }
                    }
                    _ => (),
                }

                Ok(())
            }
            TuiState::Notification { msg, elapsed } => {
                //@todo: move ticker here?
                Ok(())
            }
            TuiState::ModelSelect(list_state) => match ev.code {
                KeyCode::Up | KeyCode::PageUp => {
                    list_state.select_previous();
                    Ok(())
                }
                KeyCode::Down | KeyCode::PageDown => {
                    list_state.select_next();
                    Ok(())
                }

                KeyCode::Enter => {
                    let index = list_state.selected().unwrap_or_default();

                    {
                        self.runner.cancel();
                        self.runner.agent.lock().await.model =
                            self.config.model_list[index].clone();
                    }

                    self.config.current_model = self.config.model_list[index].clone();
                    self.config.save().await;
                    self.popup_state = TuiState::None;
                    Ok(())
                }

                KeyCode::Esc => {
                    self.popup_state = TuiState::None;
                    Ok(())
                }
                KeyCode::Char(c) => {
                    if c == 'j' {
                        list_state.select_next();
                    }

                    if c == 'k' {
                        list_state.select_next();
                    }

                    if is_ctrl && c == 'k' {
                        self.popup_state = TuiState::None
                    }
                    Ok(())
                }

                _ => Ok(()),
            },
            TuiState::TodoList(list_state) => match ev.code {
                KeyCode::Up | KeyCode::PageUp => {
                    list_state.select_previous();
                    Ok(())
                }
                KeyCode::Down | KeyCode::PageDown => {
                    list_state.select_next();
                    Ok(())
                }

                KeyCode::Enter => {
                    let index = list_state.selected().unwrap_or_default();
                    if let Some((_, item)) = self
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
                    Ok(())
                }
                KeyCode::Esc => {
                    self.popup_state = TuiState::None;
                    Ok(())
                }
                KeyCode::Char(c) => {
                    if c == 'j' {
                        list_state.select_next();
                    }

                    if c == 'k' {
                        list_state.select_next();
                    }

                    if is_ctrl && c == 't' {
                        self.popup_state = TuiState::None
                    }

                    Ok(())
                }
                KeyCode::Backspace => {
                    let index = list_state.selected().unwrap_or_default();
                    let mut todo = self.runner.context.todo_list.lock().await;

                    if let Some(key) = todo.iter().nth(index).map(|(key, _)| key.clone()) {
                        todo.remove_entry(&key);
                    }
                    Ok(())
                }
                _ => Ok(()),
            },
        }
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
            money_cost: state.money_cost,
            textarea: TextArea::new(state.input),
            runner,
            scroll_state: ScrollViewState::default(),
            running: false,
            running_spinner_state: ThrobberState::default(),
            popup_state: TuiState::None,
            config,
        };

        session.scroll_state.scroll_to_bottom();

        Ok(session)
    }
}

pub enum AgentCmd {
    Run,
}

pub struct AgentRunner {
    pub agent: Arc<Mutex<Agent>>,
    pub context: AgentContext,
    pub cmd_channel: Sender<AgentCmd>,
    pub handle: JoinHandle<()>,
    pub msg_rx: Receiver<AgentEvent>,
    pub state: Arc<Mutex<bool>>,
    pub abort: Arc<Notify>,
}

impl AgentRunner {
    pub fn new(model: impl Into<String>) -> Self {
        let (msg_tx, msg_rx) = channel::unbounded();
        let mut agent = Agent::new(model, msg_tx);
        agent.add_tool(tools::Glob);
        agent.add_tool(tools::Grep);
        agent.add_tool(tools::Read);
        agent.add_tool(tools::Edit);
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
        let abort = Arc::new(Notify::new());

        let _abort = abort.clone();

        let handle = tokio::spawn(async move {
            loop {
                let Ok(event) = cmd_rx.recv() else {
                    break;
                };

                match event {
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

                        match agent.run(_abort.clone()).await {
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
            abort,
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

    pub fn cancel(&self) {
        self.abort.notify_one();
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

pub async fn run<T>(
    mut terminal: Terminal<T>,
    config: Config,
    cost_list: Option<CostList>,
) -> AResult<()>
where
    T: Backend,
{
    let cwd = std::env::current_dir()
        .expect("failed to read current dir!")
        .to_string_lossy()
        .to_string();

    let mut session = SessionState::load(&cwd, config.clone())
        .await
        .unwrap_or(SessionState::new(config.clone()));

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

                    if let Some(ref cost_list) = cost_list {
                        if let Some(cost) =
                            cost_list.calc_cost(&session.config.current_model, session.token_cost)
                        {
                            session.money_cost = match session.money_cost {
                                Some(c) => Some(c + cost),
                                None => Some(cost),
                            }
                        }
                    }

                    session.scroll_state.scroll_to_bottom();
                }
                AgentEvent::Permission(permission_request) => {
                    session.popup_state = TuiState::Confirm {
                        req: permission_request,
                        scroll: 0,
                    };
                }
                AgentEvent::Timeout => {
                    session.popup_state = TuiState::Notification {
                        msg: "Timout reached.".into(),
                        elapsed: Duration::from_secs(6),
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
                TuiEvent::Key(key) => {
                    session.handle_input(key).await?;

                    // exit
                    if let KeyCode::Char(c) = key.code {
                        let is_ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
                        if is_ctrl && c == 'c' {
                            session.runner.cancel();
                            session.save().await?;
                            break;
                        }
                    }
                }
                TuiEvent::Paste(string) => _ = session.textarea.insert_str(string),
                TuiEvent::Resize(_, _) => (),
                TuiEvent::ScrollUp => match &mut session.popup_state {
                    TuiState::None => session.scroll_state.scroll_up(),
                    TuiState::Confirm { req, scroll } => {
                        *scroll = scroll.saturating_sub(0);
                    }
                    _ => (),
                },
                TuiEvent::ScrollDown => match &mut session.popup_state {
                    TuiState::None => session.scroll_state.scroll_down(),
                    TuiState::Confirm { req, scroll } => {
                        *scroll += 1;
                    }
                    _ => (),
                },
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
            TuiState::None => (),
            TuiState::Help => {
                let modal = window.inner(Margin::new(10, 10));
                widgets::HelpWidget::new(theme).render(modal, frame.buffer_mut());
            }
            TuiState::ModelSelect(list_state) => {
                let selection =
                    widgets::ModelSelectorWidget::new(session.config.model_list.clone(), theme);
                selection.render(window, frame.buffer_mut(), list_state);
            }
            TuiState::TodoList(list_state) => {
                TodoWidget::new(todo.iter(), theme).render(window, frame.buffer_mut(), list_state);
            }
            TuiState::Confirm { req, scroll } => {
                ConfirmWidget::new(&req.message, *scroll, theme).render(window, frame.buffer_mut());
            }
            TuiState::Notification { msg, elapsed } => {
                if let Some(new_elapsed) = elapsed.checked_sub(Duration::from_millis(30)) {
                    *elapsed = new_elapsed;
                    let modal = window.inner(Margin::new(3, 3));
                    NotifyWidget::new(theme, msg).render(modal, frame.buffer_mut());
                } else {
                    session.popup_state = TuiState::None;
                }
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
                event::Event::Key(key) => tx.send(TuiEvent::Key(key))?,
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
    Resize(u16, u16),
    ScrollUp,
    ScrollDown,
    Paste(String),
    Key(KeyEvent),
}

pub fn read_user_context() -> AResult<String> {
    Ok(std::fs::read_to_string("./AGENTS.md")?)
}
