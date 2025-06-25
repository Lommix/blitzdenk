use crate::error::AiError;
use crossbeam::channel::Sender;
use genai::chat::*;
use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::{oneshot, Mutex};

pub type AResult<T> = Result<T, crate::error::AiError>;
pub type AFuture<T> = std::pin::Pin<Box<dyn Future<Output = AResult<T>> + Send + Sync>>;
pub type ToolFn = Arc<dyn Fn(String, ToolArgs, AgentContext) -> AFuture<ChatMessage> + Send + Sync>;

#[derive(Clone)]
pub struct Agent {
    pub chat: ChatRequest,
    pub model: String,
    pub tool_box: ToolBox,
    pub running: bool,
    pub context: AgentContext,
}

impl Agent {
    pub fn new(model: impl Into<String>, sender: Sender<AgentEvent>) -> Self {
        Self {
            chat: ChatRequest::default(),
            tool_box: ToolBox::default(),
            model: model.into(),
            running: false,
            context: AgentContext {
                sender: sender.clone(),
                current_cwd: std::env::current_dir()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string(),
                todo_list: Default::default(),
            },
        }
    }

    pub fn add_system_msg(&mut self, prompt: impl Into<String>) {
        self.chat.system = Some(prompt.into());
    }

    pub fn add_user_msg(&mut self, prompt: impl Into<String>) {
        self.chat = self
            .chat
            .clone()
            .append_message(ChatMessage::user(prompt.into()));
    }

    pub fn add_tool<T: AiTool + 'static>(&mut self, def: T) {
        self.chat = self.chat.clone().append_tool(def.into_tool());
        self.tool_box.insert(def.name().into(), Arc::new(T::run));
    }

    pub async fn run(&mut self) -> AResult<()> {
        if self.running {
            return Err(AiError::AlreadyRunning);
        }
        self.running = true;

        let client = genai::Client::default();
        let mut chat = self.chat.clone();

        loop {
            let res = client.exec_chat(&self.model, chat.clone(), None).await?;
            let token_cost = res.usage.total_tokens;

            for text in res.texts().iter() {
                let msg = ChatMessage::assistant(text.to_string());
                chat = chat.append_message(msg.clone());
                self.context
                    .sender
                    .send(AgentEvent::Message(AgentMessage::new(msg, token_cost)))?;
            }

            for call in res.clone().into_tool_calls().drain(..) {
                let func = self.tool_box.get(&call.fn_name).unwrap();
                let args: HashMap<String, Value> =
                    serde_json::from_value(call.fn_arguments.clone()).unwrap();

                let msg =
                    match func(call.call_id.clone(), ToolArgs(args), self.context.clone()).await {
                        Ok(msg) => msg,
                        Err(err) => ToolResponse::new(
                            call.call_id.clone(),
                            json!({"error": err.to_string()}).to_string(),
                        )
                        .into(),
                    };

                self.context
                    .sender
                    .send(AgentEvent::Message(AgentMessage::new(msg.clone(), None)))?;

                chat = chat.append_message(msg);
            }

            // todo: auto finish todo list
            if res.tool_calls().len() == 0 {
                break;
            }
            // if self.context.has_open_todos().await {
            //     chat = chat.append_message(ChatMessage::user(
            //         "you have unfinished work on your todo list.",
            //     ));
            // } else {
            //     break;
            // }
        }

        self.chat = chat;
        self.running = false;
        Ok(())
    }
}

pub enum AgentEvent {
    Message(AgentMessage),
    Permission(PermissionRequest),
}

#[derive(Debug)]
pub struct AgentMessage {
    pub chat_message: ChatMessage,
    pub token_cost: Option<i32>,
}

impl AgentMessage {
    pub fn new(chat_message: ChatMessage, token_cost: Option<i32>) -> Self {
        Self {
            chat_message,
            token_cost,
        }
    }
}

#[derive(Clone, Default)]
pub struct ToolBox(HashMap<String, ToolFn>);
impl ToolBox {}
impl std::ops::Deref for ToolBox {
    type Target = HashMap<String, ToolFn>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for ToolBox {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[derive(Clone, Default)]
pub struct ToolArgs(pub HashMap<String, Value>);
impl ToolArgs {
    pub fn get<T>(&self, key: &str) -> AResult<T>
    where
        T: DeserializeOwned,
    {
        let arg = self
            .0
            .get(key)
            .ok_or(AiError::MissingArgument(key.into()))?;

        let val = serde_json::from_value(arg.clone())?;
        Ok(val)
    }
}

pub trait AiTool {
    fn name(&self) -> &'static str;
    fn description(&self) -> Option<&'static str>;
    fn schema(&self) -> Option<serde_json::Value>;
    fn run(tool_id: String, args: ToolArgs, ctx: AgentContext) -> AFuture<ChatMessage>;

    fn into_tool(&self) -> Tool {
        Tool {
            name: self.name().into(),
            description: self.description().map(|s| s.into()),
            schema: self.schema(),
        }
    }
}

#[derive(Clone)]
pub struct AgentContext {
    pub sender: Sender<AgentEvent>,
    pub current_cwd: String,
    pub todo_list: Arc<Mutex<HashMap<String, TodoItem>>>,
}

impl AgentContext {
    pub async fn get_open_todos(&self) -> Vec<(String, TodoItem)> {
        self.todo_list
            .lock()
            .await
            .iter()
            .flat_map(|entry| {
                if entry.1.status != Status::Completed {
                    return Some((entry.0.clone(), entry.1.clone()));
                }
                None
            })
            .collect()
    }

    pub async fn has_open_todos(&self) -> bool {
        self.todo_list
            .lock()
            .await
            .iter()
            .filter(|entry| entry.0 != "completed")
            .next()
            .is_some()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum Priority {
    #[serde(rename = "high")]
    High,
    #[serde(rename = "medium")]
    Medium,
    #[serde(rename = "low")]
    Low,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum Status {
    #[serde(rename = "completed")]
    Pending,
    #[serde(rename = "in_progress")]
    InProgress,
    #[serde(rename = "pending")]
    Completed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TodoItem {
    pub priority: Priority,
    pub status: Status,
    pub content: String,
}

pub struct PermissionRequest {
    pub message: String,
    pub respond: oneshot::Sender<bool>,
}

impl PermissionRequest {
    pub fn new(msg: impl Into<String>) -> (Self, oneshot::Receiver<bool>) {
        let (tx, rx) = oneshot::channel();
        (
            Self {
                message: msg.into(),
                respond: tx,
            },
            rx,
        )
    }
}
