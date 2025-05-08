use crate::chat::{ChatClient, Message};
use crate::tool::AiTool;
use crate::{BResult, BlitzError};
use crossbeam::channel::{Receiver, Sender};
use serde_json::from_slice;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::oneshot;

#[derive(Clone, Default)]
pub struct Blackboard {
    pub inner: Arc<String>,
}

#[derive(Clone)]
pub struct AgentContext {
    pub memory: Blackboard,
    pub message_tx: Sender<Message>,
    pub confirm_tx: Sender<Confirmation>,
    pub cwd: std::path::PathBuf,
    new_chat: Arc<dyn Fn() -> Box<dyn ChatClient> + Send + Sync + 'static>,
}

impl AgentContext {
    pub fn new<C: ChatClient>(
        root: impl Into<std::path::PathBuf>,
        client: C,
    ) -> (Self, Receiver<Message>, Receiver<Confirmation>) {
        let mem = std::fs::read_to_string("memo.md").unwrap_or_default();
        let (tx, rx) = crossbeam::channel::unbounded();
        let (ctx, crx) = crossbeam::channel::unbounded();
        return (
            Self {
                memory: Blackboard {
                    inner: Arc::new(mem),
                },
                cwd: root.into(),
                message_tx: tx,
                new_chat: Arc::new(move || client.fresh()),
                confirm_tx: ctx,
            },
            rx,
            crx,
        );
    }

    pub fn new_agent<A: AgentInstruction + Default>(&self) -> Agent {
        let mut chat = (self.new_chat)();
        let task = Box::new(A::default());

        chat.set_sys_prompt(format!(
            "{}\n\n<memory.md>{}</memory.md>",
            task.sys_prompt(),
            self.memory.inner
        ));

        task.toolset().iter().for_each(|tool| {
            chat.register_tool(tool);
        });

        return Agent {
            context: self.clone(),
            chat,
            task,
        };
    }
}

pub struct Confirmation {
    pub message: String,
    pub responder: oneshot::Sender<bool>,
}
impl Confirmation {
    pub fn new(message: impl Into<String>) -> (Self, oneshot::Receiver<bool>) {
        let (tx, rx) = oneshot::channel();
        (
            Self {
                message: message.into(),
                responder: tx,
            },
            rx,
        )
    }
}

#[derive(Clone, Debug)]
pub struct AgentArgs {
    inner: Arc<HashMap<String, String>>,
}

impl AgentArgs {
    pub fn get(&self, key: &str) -> BResult<&String> {
        self.inner
            .get(key)
            .ok_or(BlitzError::MissingArgument(format!(
                "Missing argument `{}`",
                key
            )))
    }
}

impl Into<AgentArgs> for HashMap<String, String> {
    fn into(self) -> AgentArgs {
        AgentArgs {
            inner: Arc::new(self),
        }
    }
}

pub struct Agent {
    pub context: AgentContext,
    pub chat: Box<dyn ChatClient>,
    pub task: Box<dyn AgentInstruction>,
}

impl Agent {
    pub async fn run(&mut self) -> BResult<()> {
        loop {
            self.chat.prompt(self.context.message_tx.clone()).await?;
            if let Some(mut calls) = self.chat.last_tool_call() {
                for call in calls.drain(..) {
                    let Some(func) = self
                        .task
                        .toolset()
                        .into_iter()
                        .find(|f| f.name() == &call.name)
                    else {
                        let m = Message::tool(format!("[ERROR]: function not found"), call.id);
                        self.context.message_tx.send(m.clone())?;
                        self.chat.push_message(m);
                        continue;
                    };

                    let args = AgentArgs {
                        inner: Arc::new(call.args.clone()),
                    };

                    match func.run(self.context.clone(), args, call.id.clone()).await {
                        Ok(mut msg) => {
                            msg.tool_call_id = call.id;
                            self.context.message_tx.send(msg.clone())?;
                            self.chat.push_message(msg);
                        }
                        Err(err) => {
                            let m = Message::tool(format!("[ERROR]: {}", err.to_string()), call.id);
                            self.context.message_tx.send(m.clone())?;
                            self.chat.push_message(m);
                        }
                    }
                }
            } else {
                return Ok(());
            }
        }
    }
}

pub trait AgentInstruction: Send + Sync + 'static {
    fn sys_prompt(&self) -> &'static str;

    fn steps(&self) -> Option<Box<dyn Iterator<Item = &'static str>>> {
        None
    }

    fn toolset(&self) -> Vec<Box<dyn AiTool>> {
        vec![]
    }
}
