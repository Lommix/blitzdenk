use crate::{tool::AiTool, BResult};
use crossbeam::channel::Sender;
use std::collections::HashMap;

#[async_trait::async_trait]
pub trait ChatClient: Send + Sync + 'static {
    async fn list_models(&self) -> BResult<Vec<String>>;
    async fn prompt(&mut self, tx: Sender<Message>) -> BResult<()>;
    fn register_tool(&mut self, tool: &Box<dyn AiTool>);
    fn last_tool_call(&self) -> Option<Vec<FunctionCall>>;
    fn last_content(&self) -> &str;
    fn push_message(&mut self, msg: Message);
    fn clear(&mut self);
    fn fresh(&self) -> Box<dyn ChatClient>;
}

pub enum ArgType {
    Str,
    Int,
    Float,
}

impl Into<String> for &ArgType {
    fn into(self) -> String {
        match self {
            ArgType::Str => "string".into(),
            ArgType::Int => "int".into(),
            ArgType::Float => "float".into(),
        }
    }
}

pub struct Argument {
    pub name: String,
    pub description: String,
    pub ty: ArgType,
    pub required: bool,
    pub options: Option<Vec<String>>,
}

impl Argument {
    pub fn new(name: impl Into<String>, description: impl Into<String>, ty: ArgType) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            ty,
            options: None,
            required: true,
        }
    }
}

#[derive(PartialEq, Eq, Clone, Copy, Debug, Default)]
pub enum Role {
    #[default]
    Assistant,
    System,
    User,
    Tool,
}

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Role::Assistant => write!(f, "[ASSISTANT]"),
            Role::System => write!(f, "[SYSTEM]"),
            Role::User => write!(f, "[USER]"),
            Role::Tool => write!(f, "[TOOL]"),
        }
    }
}

impl Into<&'static str> for Role {
    fn into(self) -> &'static str {
        match self {
            Role::Assistant => "[ASSISTANT]",
            Role::System => "[SYSTEM]",
            Role::User => "[USER]",
            Role::Tool => "[TOOL]",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Message {
    pub role: Role,
    pub content: String,
    pub tool_calls: Vec<FunctionCall>,
    pub tool_call_id: Option<String>,
    pub images: Option<Vec<Vec<u8>>>,
}

impl Message {
    pub fn user(content: String) -> Self {
        Self {
            role: Role::User,
            content,
            tool_calls: vec![],
            tool_call_id: None,
            images: None,
        }
    }
    pub fn tool(content: String, call_id: Option<String>) -> Self {
        Self {
            role: Role::Tool,
            content,
            tool_calls: vec![],
            tool_call_id: call_id,
            images: None,
        }
    }
    pub fn system(content: String) -> Self {
        Self {
            role: Role::System,
            content,
            tool_calls: vec![],
            tool_call_id: None,
            images: None,
        }
    }
}

impl std::fmt::Display for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.role {
            Role::Assistant => {
                if let Some(call) = self.tool_calls.first().as_ref() {
                    write!(f, "[ASSISTANT]\nfunc: {} args: {:?}", call.name, call.args)
                } else {
                    write!(f, "[ASSISTANT]\n{}", self.content)
                }
            }
            Role::System => write!(f, "[SYSTEM]"),
            Role::User => write!(f, "[USER]\n{}", self.content),
            Role::Tool => write!(f, "[TOOL]\n{}", self.content),
        }
    }
}

#[derive(Clone, Debug)]
pub struct FunctionCall {
    pub id: Option<String>,
    pub name: String,
    pub args: HashMap<String, String>,
}
