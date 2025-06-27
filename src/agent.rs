use crate::error::{AFuture, AResult, AiError};
use crossbeam::channel::Sender;
use genai::chat::*;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{
    oneshot::{self},
    Mutex,
};

pub type ToolFn = Arc<dyn Fn(String, ToolArgs, AgentContext) -> AFuture<ChatMessage> + Send + Sync>;

pub const TIMEOUT_DURATION: Duration = Duration::from_secs(120);

#[derive(Clone)]
pub struct Agent {
    pub chat: ChatRequest,
    pub model: String,
    pub tool_box: ToolBox,
    pub running: bool,
    pub context: AgentContext,
}

enum AgentReq {
    Timeout,
    Abort,
    Result(ChatResponse),
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

    pub fn add_tool<T: AiTool + 'static>(&mut self, def: T) {
        self.chat = self.chat.clone().append_tool(def.into_tool());
        self.tool_box.insert(def.name().into(), Arc::new(T::run));
    }

    pub async fn run(&mut self, abort: Arc<tokio::sync::Notify>) -> AResult<()> {
        if self.running {
            return Err(AiError::AlreadyRunning);
        }
        self.running = true;

        let client = genai::Client::default();
        let mut chat = self.chat.clone();

        let options = ChatOptions {
            reasoning_effort: None,
            ..Default::default()
        };

        loop {
            let res = match tokio::select! {
                res = client.exec_chat(&self.model, chat.clone(), Some(&options)) => { AgentReq::Result(res?) }
                _ = tokio::time::sleep(TIMEOUT_DURATION) => { AgentReq::Timeout }
                _ = abort.notified() => { AgentReq::Abort }
            } {
                AgentReq::Timeout => {
                    self.context.sender.send(AgentEvent::Timeout).unwrap();
                    break;
                }
                AgentReq::Abort => break,
                AgentReq::Result(chat_response) => chat_response,
            };

            let token_cost = res.usage.total_tokens;

            // add text message
            for text in res.texts().iter() {
                let msg = ChatMessage::assistant(text.to_string());
                chat = chat.append_message(msg.clone());
                self.context
                    .sender
                    .send(AgentEvent::Message(AgentMessage::new(msg, token_cost)))?;
            }

            // add tool calls
            if !res.tool_calls().is_empty() {
                let tool_msg = ChatMessage::from(res.clone().into_tool_calls());
                chat = chat.append_message(tool_msg.clone());
                self.context
                    .sender
                    .send(AgentEvent::Message(AgentMessage::new(tool_msg, None)))?;
            }

            // resolve tool calls
            for call in res.clone().into_tool_calls().drain(..) {
                let func = self.tool_box.get(&call.fn_name).unwrap();
                let args: HashMap<String, Value> =
                    serde_json::from_value(call.fn_arguments.clone()).unwrap();

                let msg =
                    match func(call.call_id.clone(), ToolArgs(args), self.context.clone()).await {
                        Ok(msg) => msg,
                        Err(err) => ToolResponse::new(call.call_id.clone(), err.to_string()).into(),
                    };

                self.context
                    .sender
                    .send(AgentEvent::Message(AgentMessage::new(msg.clone(), None)))?;

                chat = chat.append_message(msg);
            }

            if res.tool_calls().is_empty() {
                if self.context.has_open_todos().await {
                    chat = chat.append_message(ChatMessage::user(
                        "you have unfinished work on your todo list. please update the list according to your task progression.",
                    ));
                } else {
                    break;
                }
            }
        }

        self.chat = chat;
        self.running = false;
        Ok(())
    }
}

pub enum AgentEvent {
    Message(AgentMessage),
    Permission(PermissionRequest),
    Timeout,
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

#[allow(unused)]
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
            .filter(|entry| matches!(entry.1.status, Status::Completed))
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
