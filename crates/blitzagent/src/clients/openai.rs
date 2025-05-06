use crate::{
    chat::{ChatClient, FunctionCall, Message, Role},
    tool::AiTool,
    BResult,
};
use crossbeam::channel::Sender;
use serde::*;
use std::collections::HashMap;

pub const COMPLETION_URL: &'static str = "https://api.openai.com/v1/chat/completions";
pub const MODEL_LIST_URL: &'static str = "https://api.openai.com/v1/models";

pub struct OpenApiClient {
    chat: OChat,
    key: String,
}

impl OpenApiClient {
    pub fn new(model: impl Into<String>, key: impl Into<String>) -> Self {
        return Self {
            key: key.into(),
            chat: OChat {
                model: model.into(),
                messages: vec![],
                tools: vec![],
                tool_choice: "auto".into(),
            },
        };
    }
}

#[async_trait::async_trait]
impl ChatClient for OpenApiClient {
    fn register_tool(&mut self, tool: &Box<dyn AiTool>) {
        let mut properties: HashMap<String, OProp> = HashMap::new();
        let mut required: Vec<String> = Vec::new();

        tool.args().iter().for_each(|arg| {
            let o = OProp {
                ty: (&arg.ty).into(),
                description: arg.description.clone(),
                options: arg.options.clone(),
            };

            properties.insert(arg.name.clone(), o);

            if arg.required {
                required.push(arg.name.clone());
            }
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

    async fn list_models(&self) -> BResult<Vec<String>> {
        let res = reqwest::Client::new()
            .get(MODEL_LIST_URL)
            .header("Authorization", format!("Bearer {}", &self.key))
            .send()
            .await?
            .json::<ModelResponse>()
            .await?;

        Ok(res.data.iter().map(|m| m.id.clone()).collect())
    }

    fn last_tool_call(&self) -> Option<Vec<FunctionCall>> {
        let tool_calls = self.chat.messages.last()?.tool_calls.as_ref()?;
        if tool_calls.len() == 0 {
            return None;
        };

        Some(
            tool_calls
                .iter()
                .map(|c| FunctionCall {
                    id: Some(c.id.clone()),
                    name: c.function.name.clone(),
                    args: serde_json::from_str::<HashMap<String, String>>(&c.function.arguments)
                        .unwrap(),
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

    async fn prompt(&mut self, tx: Sender<Message>) -> BResult<()> {
        let raw = reqwest::Client::new()
            .post(COMPLETION_URL)
            .header("Authorization", format!("Bearer {}", &self.key))
            .json(&self.chat)
            .send()
            .await?
            .text()
            .await?;

        let res = match serde_json::from_str::<ChatResponse>(&raw) {
            Ok(r) => r,
            Err(err) => {
                return Err(crate::error::BlitzError::ApiError(format!(
                    "[Error] {}\n{}",
                    err.to_string(),
                    raw
                )));
            }
        };

        self.chat.messages.push(res.choices[0].message.clone());
        let m: Message = res.choices[0].message.clone().into();
        tx.send(m)?;

        return Ok(());
    }

    fn last_content(&self) -> &str {
        self.chat
            .messages
            .last()
            .map(|m| m.content.as_ref().map(|s| s.as_str()).unwrap_or(""))
            .unwrap_or("")
    }

    fn fresh(&self) -> Box<dyn ChatClient> {
        Box::new(Self::new(&self.chat.model, &self.key))
    }
}

#[derive(Serialize, Deserialize)]
pub struct Ofix {
    role: ORole,
    content: String,
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
        let calls = value
            .tool_calls
            .drain(..)
            .map(|c| OToolCall {
                id: c.id.unwrap_or_default(),
                ty: "function".into(),
                function: OCall {
                    name: c.name,
                    arguments: serde_json::to_string(&c.args).unwrap(),
                },
            })
            .collect::<Vec<_>>();

        OMessage {
            role: value.role.into(),
            content: Some(value.content),
            tool_call_id: value.tool_call_id,
            tool_calls: if calls.len() > 0 { Some(calls) } else { None },
        }
    }
}

impl From<OMessage> for Message {
    fn from(value: OMessage) -> Self {
        Message {
            tool_call_id: None,
            role: value.role.into(),
            content: value.content.unwrap_or_default(),
            images: None,
            tool_calls: value
                .tool_calls
                .unwrap_or_default()
                .drain(..)
                .map(|call| FunctionCall {
                    id: Some(call.id),
                    name: call.function.name,
                    args: serde_json::from_str::<HashMap<String, String>>(&call.function.arguments)
                        .unwrap(),
                })
                .collect(),
        }
    }
}

// --------------------------
// json

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct OChat {
    pub model: String,
    pub messages: Vec<OMessage>,
    pub tools: Vec<OTool>,
    pub tool_choice: String,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct ChatResponse {
    pub model: String,
    pub choices: Vec<Choice>,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct Choice {
    pub index: i64,
    pub message: OMessage,
}

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OCall {
    pub name: String,
    pub arguments: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct OMessage {
    pub role: ORole,
    pub content: Option<String>,
    pub tool_calls: Option<Vec<OToolCall>>,
    pub tool_call_id: Option<String>,
}

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

#[derive(Deserialize, Clone, Serialize, Debug)]
pub struct OToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub function: OCall,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
pub enum ToolType {
    #[serde(rename = "function")]
    Function,
    Unknown,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
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

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OFunc {
    pub name: String, // `type' object
    pub description: String,
    pub parameters: OParameters,
}

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OParameters {
    #[serde(rename = "type")]
    pub ty: String, // `type' object
    pub properties: HashMap<String, OProp>,
    pub required: Vec<String>,
}

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OProp {
    #[serde(rename = "type")]
    pub ty: String, // `type' object
    pub description: String,
    // @not comp with open ai
    #[serde(rename = "enum")]
    pub options: Option<Vec<String>>,
}

#[derive(Deserialize, Serialize)]
pub struct OResponse {
    pub model: String,
    pub created_at: String,
    pub respone: String,
    pub done: bool,
}

#[derive(Deserialize, Serialize)]
pub struct ModelResponse {
    data: Vec<Model>,
}

#[derive(Deserialize, Serialize)]
pub struct Model {
    id: String,
}
