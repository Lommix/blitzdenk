use crate::chat::{ChatClient, Message};
use crate::tool::AiTool;
use crate::{BResult, BlitzError};
use crossbeam::channel::{Receiver, Sender};
use std::{collections::HashMap, sync::Arc};

#[derive(Clone, Default)]
pub struct Blackboard {
    pub inner: Arc<String>,
}

#[derive(Clone)]
pub struct AgentContext {
    pub blackboard: Blackboard,
    pub broadcast: Sender<Message>,
    pub cwd: std::path::PathBuf,
    new_chat: Arc<dyn Fn() -> Box<dyn ChatClient> + Send + Sync + 'static>,
}

impl AgentContext {
    pub fn new<C: ChatClient>(
        root: impl Into<std::path::PathBuf>,
        client: C,
    ) -> (Self, Receiver<Message>) {
        let mem = std::fs::read_to_string("memo.md").unwrap_or_default();
        let (tx, rx) = crossbeam::channel::unbounded();
        return (
            Self {
                blackboard: Blackboard {
                    inner: Arc::new(mem),
                },
                cwd: root.into(),
                broadcast: tx,
                new_chat: Arc::new(move || client.fresh()),
            },
            rx,
        );
    }

    pub fn new_agent<A: AgentInstruction + Default>(&self) -> Agent {
        let mut chat = (self.new_chat)();
        let task = Box::new(A::default());
        chat.push_message(Message::system(task.sys_prompt().into()));

        chat.push_message(Message::system(format!(
            "<context>\n{}\n</context>",
            self.blackboard.inner
        )));

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
            self.chat.prompt(self.context.broadcast.clone()).await?;
            if let Some(mut calls) = self.chat.last_tool_call() {
                for call in calls.drain(..) {
                    let Some(func) = self
                        .task
                        .toolset()
                        .into_iter()
                        .find(|f| f.name() == &call.name)
                    else {
                        let m = Message::tool(format!("[ERROR]: function not found"), call.id);
                        self.context.broadcast.send(m.clone())?;
                        self.chat.push_message(m);
                        continue;
                    };

                    let args = AgentArgs {
                        inner: Arc::new(call.args.clone()),
                    };

                    match func.run(self.context.clone(), args).await {
                        Ok(mut msg) => {
                            msg.tool_call_id = call.id;
                            self.context.broadcast.send(msg.clone())?;
                            self.chat.push_message(msg);
                        }
                        Err(err) => {
                            let m = Message::tool(format!("[ERROR]: {}", err.to_string()), call.id);
                            self.context.broadcast.send(m.clone())?;
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
