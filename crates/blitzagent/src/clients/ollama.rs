use crate::{
    chat::{ChatClient, FunctionCall, Message, Role},
    tool::AiTool,
    BResult,
};
use crossbeam::channel::Sender;
use serde::*;
use std::collections::HashMap;

pub struct OllamaClient {
    url: String,
    chat: OChat,
}

impl OllamaClient {
    pub fn new(model: impl Into<String>, url: impl Into<String>) -> Self {
        return Self {
            url: url.into(),
            chat: OChat::new(model),
        };
    }
}

#[async_trait::async_trait]
impl ChatClient for OllamaClient {
    async fn list_models(&self) -> BResult<Vec<String>> {
        let client = reqwest::Client::new();

        let url = format!("{}/{}", self.url, "/tags");
        let req = client.get(url);
        let res = req.send().await?.json::<ModelResponse>().await?;

        Ok(res.models.iter().map(|m| m.name.clone()).collect())
    }

    async fn prompt(&mut self, tx: Sender<Message>) -> BResult<()> {
        let client = reqwest::Client::new();

        let url = format!("{}/{}", self.url, "/chat");
        let req = client.post(&url).json(&self.chat);
        let res = req.send().await?.text().await?;

        let mut msg = Message {
            tool_call_id: None,
            role: Role::Assistant,
            content: String::new(),
            tool_calls: vec![],
            images: None,
        };

        res.split('\n')
            .flat_map(|slice| serde_json::from_str::<OChatResponse>(slice))
            .for_each(|re| {
                let _m: Message = re.message.into();
                msg.tool_calls.extend(_m.tool_calls);
                msg.content.push_str(&_m.content);
            });

        tx.send(msg.clone())?;
        self.push_message(msg);
        Ok(())
    }

    fn last_content(&self) -> &str {
        self.chat
            .messages
            .last()
            .map(|m| m.content.as_ref().map(|s| s.as_str()).unwrap_or(""))
            .unwrap_or("")
    }

    fn register_tool(&mut self, tool: &Box<dyn AiTool>) {
        let mut properties: HashMap<String, OProp> = HashMap::new();
        let mut required: Vec<String> = Vec::new();

        tool.args().iter().for_each(|arg| {
            let o = OProp {
                ty: (&arg.ty).into(),
                description: arg.description.clone(),
            };

            properties.insert(arg.name.clone(), o);
            required.push(arg.name.clone());
        });

        self.chat.tools.push(OTool {
            ty: ToolType::Function,
            function: OFunc {
                name: tool.name().into(),
                description: tool.description().into(),
                parameters: OParameters {
                    ty: "object".into(),
                    required,
                    properties,
                },
            },
        });
    }

    fn last_tool_call(&self) -> Option<Vec<FunctionCall>> {
        let msg = self.chat.messages.last()?;
        let calls = msg.tool_calls.as_ref()?;
        Some(
            calls
                .iter()
                .map(|c| FunctionCall {
                    id: None,
                    name: c.function.name.clone(),
                    args: c.function.arguments.clone(),
                })
                .collect(),
        )
    }

    fn push_message(&mut self, msg: Message) {
        self.chat.messages.push(msg.into());
    }

    fn clear(&mut self) {
        while self.chat.messages.iter().len() > 2 {
            _ = self.chat.messages.pop();
        }
    }

    fn fresh(&self) -> Box<dyn ChatClient> {
        Box::new(Self::new(&self.chat.model, &self.url))
    }
}

impl From<Role> for ORole {
    fn from(value: Role) -> Self {
        match value {
            Role::Assistant => ORole::Assistant,
            Role::System => ORole::System,
            Role::User => ORole::User,
            Role::Tool => ORole::Tool,
        }
    }
}

impl From<ORole> for Role {
    fn from(value: ORole) -> Self {
        match value {
            ORole::Assistant => Role::Assistant,
            ORole::System => Role::System,
            ORole::User => Role::User,
            ORole::Tool => Role::Tool,
        }
    }
}

impl From<Message> for OMessage {
    fn from(mut value: Message) -> Self {
        OMessage {
            role: value.role.into(),
            images: value.images,
            content: value
                .content
                .is_empty()
                .then_some(None)
                .unwrap_or(Some(value.content)),
            tool_calls: if value.tool_calls.len() > 0 {
                Some(
                    value
                        .tool_calls
                        .drain(..)
                        .map(|c| OToolCall {
                            function: OCall {
                                name: c.name,
                                arguments: c.args,
                            },
                        })
                        .collect(),
                )
            } else {
                None
            },
        }
    }
}

impl From<OMessage> for Message {
    fn from(mut value: OMessage) -> Self {
        Message {
            tool_call_id: None,
            role: value.role.into(),
            content: value.content.take().unwrap_or_default(),
            images: value.images,
            tool_calls: value
                .tool_calls
                .map(|mut calls| {
                    calls
                        .drain(..)
                        .map(|c| FunctionCall {
                            id: None,
                            name: c.function.name,
                            args: c.function.arguments,
                        })
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

// -------------------------------------------------------------
// JSON def
// -------------------------------------------------------------

#[derive(Deserialize, PartialEq, Eq, Serialize, Debug, Clone, Copy)]
pub enum ORole {
    #[serde(rename = "assistant")]
    Assistant,
    #[serde(rename = "system")]
    System,
    #[serde(rename = "user")]
    User,
    #[serde(rename = "tool")]
    Tool,
}

#[derive(Deserialize, PartialEq, Eq, Serialize, Debug, Clone, Copy)]
pub enum ChatStatus {
    ResolveFunction,
    AwaitUserResponse,
    AwaitAiResponse,
}

#[derive(Deserialize, Serialize)]
pub struct OChat {
    pub model: String,
    pub messages: Vec<OMessage>,
    pub tools: Vec<OTool>,
    pub streaming: bool,
    pub options: Option<OOption>,
}

impl OChat {
    pub fn new(model: impl Into<String>) -> Self {
        return OChat {
            model: model.into(),
            messages: vec![],
            tools: vec![],
            streaming: false,
            options: Some(OOption {
                enable_thinking: Some(false),
                temperature: None,
                seed: None,
            }),
        };
    }
}

#[derive(Deserialize, Serialize)]
pub struct OOption {
    pub enable_thinking: Option<bool>,
    pub temperature: Option<f32>,
    pub seed: Option<u64>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct OMessage {
    pub role: ORole,
    pub content: Option<String>,
    pub tool_calls: Option<Vec<OToolCall>>,
    pub images: Option<Vec<Vec<u8>>>,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
pub struct OToolCall {
    pub function: OCall,
}

#[derive(Deserialize, Serialize, Debug)]
pub enum ToolType {
    #[serde(rename = "function")]
    Function,
    Unknown,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct OTool {
    #[serde(rename = "type")]
    pub ty: ToolType,
    pub function: OFunc,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct OFuncCall {
    pub name: String, // `type' object
    pub parameters: HashMap<String, String>,
}

#[derive(Deserialize, Debug, Serialize)]
pub struct OFunc {
    pub name: String, // `type' object
    pub description: String,
    pub parameters: OParameters,
}

#[derive(Deserialize, Debug, Serialize)]
pub struct OParameters {
    #[serde(rename = "type")]
    pub ty: String, // `type' object
    pub properties: HashMap<String, OProp>,
    pub required: Vec<String>,
}

#[derive(Deserialize, Debug, Serialize)]
pub struct OProp {
    #[serde(rename = "type")]
    pub ty: String,
    pub description: String,
}

#[derive(Deserialize, Serialize)]
pub struct OResponse {
    pub model: String,
    pub created_at: String,
    pub respone: String,
    pub done: bool,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct OChatResponse {
    pub model: String,
    pub created_at: String,
    pub message: OMessage,
    pub done: bool,
    pub total_duration: Option<i64>,
    pub load_duration: Option<i64>,
    pub prompt_eval_duration: Option<i64>,
    pub eval_count: Option<i64>,
    pub eval_duration: Option<i64>,
}

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OCall {
    pub name: String,
    pub arguments: HashMap<String, String>,
}

#[derive(Serialize, Debug, Deserialize, Clone)]
pub struct ModelResponse {
    models: Vec<OModel>,
}

#[derive(Serialize, Debug, Deserialize, Clone)]
pub struct OModel {
    name: String,
}
