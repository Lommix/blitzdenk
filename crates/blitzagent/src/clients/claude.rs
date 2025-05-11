use crate::{
    chat::{ChatClient, FunctionCall, Message, Role},
    tool::AiTool,
    BResult,
};
use crossbeam::channel::Sender;
use serde::*;
use std::collections::HashMap;

pub const CLAUDE_CHAT: &str = "https://api.anthropic.com/v1/messages";
pub const CLAUDE_MODEL: &str = "https://api.anthropic.com/v1/models";

pub struct ClaudeClient {
    chat: OChat,
    key: String,
}

impl ClaudeClient {
    pub fn new(model: impl Into<String>, key: impl Into<String>) -> Self {
        return Self {
            key: key.into(),
            chat: OChat {
                model: model.into(),
                messages: vec![],
                tools: vec![],
                system: "".into(),
                max_tokens: 1024,
                temperature: 1.0,
            },
        };
    }
}

#[async_trait::async_trait]
impl ChatClient for ClaudeClient {
    fn register_tool(&mut self, tool: &Box<dyn AiTool>) {
        let mut properties: HashMap<String, OProp> = HashMap::new();
        let mut required: Vec<String> = Vec::new();

        tool.args().iter().for_each(|arg| {
            let o = OProp {
                ty: (&arg.ty).into(),
                description: arg.description.clone(),
            };

            properties.insert(arg.name.clone(), o);

            if arg.required {
                required.push(arg.name.clone());
            }
        });

        self.chat.tools.push(OTool {
            name: tool.name().into(),
            description: tool.description().into(),
            input_schema: OParameters {
                ty: "object".into(),
                required,
                properties,
            },
        });
    }

    async fn list_models(&self) -> BResult<Vec<String>> {
        let raw = reqwest::Client::new()
            .get(CLAUDE_MODEL)
            .header("x-api-key", format!("{}", &self.key))
            .header("anthropic-version", "2023-06-01")
            .send()
            .await?
            .text()
            .await?;

        let Ok(res) = serde_json::from_str::<ModelResponse>(&raw) else {
            return Err(crate::BlitzError::ApiError(raw));
        };

        Ok(res.data.iter().map(|m| m.id.clone()).collect())
    }

    fn last_tool_call(&self) -> Option<Vec<FunctionCall>> {
        let content = self.chat.messages.last()?.content.last()?;

        match content.ty {
            ContentType::ToolUse => Some(vec![FunctionCall {
                id: Some(content.id.as_ref().unwrap().clone()),
                name: content.name.as_ref().unwrap().clone(),
                args: content.input.as_ref().unwrap().clone(),
            }]),
            _ => None,
        }
    }

    fn set_sys_prompt(&mut self, content: String) {
        self.chat.system = content;
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
            .post(CLAUDE_CHAT)
            .header("x-api-key", format!("{}", &self.key.trim_matches('"')))
            .header("anthropic-version", "2023-06-01")
            .json(&self.chat)
            .send()
            .await?
            .text()
            .await?;

        let res = match serde_json::from_str::<ChatResponse>(&raw) {
            Ok(r) => r,
            Err(err) => {
                tx.send(Message::system(format!(
                    "[Error] {}\n{}",
                    err.to_string(),
                    serde_json::to_string(&self.chat).unwrap(),
                )))
                .unwrap();

                return Err(crate::error::BlitzError::ApiError(format!(
                    "[Error] {}\n{}",
                    err.to_string(),
                    raw
                )));
            }
        };

        let msg = OMessage {
            role: ORole::Assistant,
            content: res.content,
        };

        tx.send(msg.clone().into())?;
        self.chat.messages.push(msg);

        return Ok(());
    }

    fn last_content(&self) -> &str {
        let Some(last) = self.chat.messages.last() else {
            return "";
        };

        for p in last.content.iter() {
            if p.text.is_some() {
                return p.text.as_deref().unwrap();
            }
        }

        return "";
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
            Role::System => ORole::Assistant,
            Role::User => ORole::User,
            Role::Tool => ORole::User,
        }
    }
}

impl From<ORole> for Role {
    fn from(value: ORole) -> Self {
        match value {
            ORole::Assistant => Role::Assistant,
            ORole::User => Role::User,
        }
    }
}

impl From<Message> for OMessage {
    fn from(value: Message) -> Self {
        let mut content = Content {
            ty: ContentType::Text,
            ..Default::default()
        };

        if let Some(call) = value.tool_calls.first() {
            content.name = Some(call.name.clone());
            content.input = Some(call.args.clone());
            content.id = call.id.clone();
        }

        if value.role == Role::Tool {
            content.ty = ContentType::ToolResult;
            content.tool_use_id = value.tool_call_id.clone();
            content.id = None;
            content.content = Some(value.content);
            OMessage {
                role: value.role.into(),
                content: vec![content],
            }
        } else {
            if value.content.len() > 0 {
                content.text = Some(value.content);
            }
            OMessage {
                role: value.role.into(),
                content: vec![content],
            }
        }
    }
}

impl From<OMessage> for Message {
    fn from(value: OMessage) -> Self {
        let mut msg = Message {
            role: value.role.into(),
            content: String::new(),
            tool_calls: vec![],
            tool_call_id: None,
            images: None,
        };

        for p in value.content.iter() {
            if let Some(str) = p.text.clone() {
                msg.content = str;
            }

            let Some(name) = p.name.clone() else {
                continue;
            };

            let Some(args) = p.input.clone() else {
                continue;
            };

            msg.tool_call_id = p.id.clone();
            msg.tool_calls.push(FunctionCall {
                id: p.id.clone(),
                name,
                args,
            });
        }

        msg
    }
}

// --------------------------
// json

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct OChat {
    pub model: String,
    pub messages: Vec<OMessage>,
    pub tools: Vec<OTool>,
    pub system: String,
    pub temperature: f32,
    pub max_tokens: u32,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct ChatResponse {
    pub model: String,
    pub role: ORole,
    pub content: Vec<Content>,
}

#[derive(Deserialize, Default, Serialize, Clone, Debug)]
pub enum ContentType {
    #[default]
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "image")]
    Image,
    #[serde(rename = "tool_use")]
    ToolUse,
    #[serde(rename = "tool_result")]
    ToolResult,
}

#[derive(Deserialize, Default, Serialize, Clone, Debug)]
pub struct Content {
    #[serde(rename = "type")]
    pub ty: ContentType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Serialize)]
pub struct OCall {
    pub name: String,
    pub arguments: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct OMessage {
    pub role: ORole,
    pub content: Vec<Content>,
    // #[serde(skip_serializing_if = "Option::is_none")]
    // pub tool_use: Option<OToolCall>,
    // #[serde(skip_serializing_if = "Option::is_none")]
    // pub tool_call_id: Option<String>,
}

#[derive(Deserialize, PartialEq, Eq, Serialize, Debug, Clone, Copy)]
pub enum ORole {
    #[serde(rename = "assistant")]
    Assistant,
    #[serde(rename = "user")]
    User,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
pub struct OToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub name: String,
    pub input: String,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
pub enum ToolType {
    #[serde(rename = "object")]
    Object,
    #[serde(rename = "function")]
    Function,
    Unknown,
}

#[derive(Deserialize, Clone, Serialize, Debug)]
pub struct OTool {
    pub name: String,
    pub description: String,
    pub input_schema: OParameters,
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
    pub description: Option<String>,
    // #[serde(rename = "enum")]
    // pub options: Option<Vec<String>>,
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
