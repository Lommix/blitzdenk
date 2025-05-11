#![allow(unused)]

use crate::{
    chat::{ChatClient, FunctionCall, Message, Role},
    tool::AiTool,
    BResult, BlitzError,
};
use crossbeam::channel::Sender;
use serde::*;
use serde_json::Value;
use std::{collections::HashMap, vec};

#[derive(Clone, Debug)]
pub struct GeminiClient {
    model: String,
    key: String,
    chat: GenerateContentRequest,
}

pub const BASE_URL: &'static str = "https://generativelanguage.googleapis.com/v1beta";

impl GeminiClient {
    pub fn new(key: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            model: model.into(),
            key: key.into(),
            chat: GenerateContentRequest {
                system_instruction: None,
                contents: vec![],
                tools: None,
            },
        }
    }
}

#[async_trait::async_trait]
impl ChatClient for GeminiClient {
    async fn list_models(&self) -> BResult<Vec<String>> {
        let client = reqwest::Client::new();
        let url = format!("{}/models?key={}", BASE_URL, self.key);
        let req = client
            .get(url)
            .send()
            .await?
            .json::<ModelListRepsone>()
            .await?;

        Ok(req.models.into_iter().map(|m| m.name).collect())
    }

    async fn prompt(&mut self, tx: Sender<Message>) -> BResult<()> {
        let client = reqwest::Client::new();
        let url = format!(
            "{}/{}:generateContent?key={}",
            BASE_URL, self.model, self.key
        );

        let req = client
            .post(url)
            .json(&self.chat)
            .header("Content-Type", "application/json")
            .send()
            .await?
            .text()
            .await?;

        let mut res = match serde_json::from_str::<GenerateContentResponse>(&req) {
            Ok(res) => res,
            Err(err) => {
                let err_msg = format!("{}\n{}", err.to_string(), req);
                tx.send(Message::system(err_msg.clone())).unwrap();
                return Err(BlitzError::ApiError(err_msg));
            }
        };

        let mut op = res
            .candidates
            .take()
            .ok_or(BlitzError::ApiError("no options".into()))?
            .remove(0);

        let content = Content {
            role: GRole::Model,
            parts: op
                .content
                .parts
                .drain(..)
                .map(|p| ContentPart::from(p))
                .collect(),
        };

        tx.send(Message::from(&content)).unwrap();
        self.chat.contents.push(content);

        Ok(())
    }

    fn register_tool(&mut self, tool: &Box<dyn AiTool>) {
        let mut properties: HashMap<String, ParameterProperty> = HashMap::new();
        let mut required: Vec<String> = Vec::new();

        tool.args().iter().for_each(|arg| {
            let o = ParameterProperty {
                property_type: (&arg.ty).into(),
                description: arg.description.as_ref().cloned().unwrap_or_default(),
                enum_values: None,
            };

            properties.insert(arg.name.clone(), o);
            if arg.required {
                required.push(arg.name.clone());
            }
        });

        let decl = ToolConfigFunctionDeclaration {
            function_declarations: vec![FunctionDeclaration {
                name: tool.name().into(),
                description: tool.description().into(),
                parameters: FunctionParameters {
                    parameter_type: "object".into(),
                    properties,
                    required: if required.len() > 0 {
                        Some(required)
                    } else {
                        None
                    },
                },
            }],
        };

        let mut configs = match self.chat.tools.as_mut() {
            Some(c) => c,
            None => {
                self.chat.tools = Some(vec![]);
                self.chat.tools.as_mut().unwrap()
            }
        };

        configs.push(ToolConfig::FunctionDeclaration(decl));
    }

    fn set_sys_prompt(&mut self, content: String) {
        self.chat.system_instruction = Some(Content {
            parts: vec![ContentPart::Text(content)],
            role: GRole::System,
        });
    }

    fn last_tool_call(&self) -> Option<Vec<FunctionCall>> {
        let msg = self.chat.contents.last()?;

        let mut calls = Vec::new();

        for part in msg.parts.iter() {
            match part {
                ContentPart::FunctionCall(f) => {
                    calls.push(f.into());
                }
                _ => (),
            }
        }

        return if calls.len() > 0 { Some(calls) } else { None };
    }

    fn last_content(&self) -> &str {
        self.chat
            .contents
            .last()
            .map(|c| {
                for p in c.parts.iter() {
                    match p {
                        ContentPart::Text(s) => {
                            return s.as_str();
                        }
                        _ => (),
                    }
                }
                ""
            })
            .unwrap()
    }

    fn push_message(&mut self, msg: Message) {
        self.chat.contents.push(Content::from(msg));
    }

    fn clear(&mut self) {
        self.chat.contents.clear();
    }

    fn fresh(&self) -> Box<dyn ChatClient> {
        let mut n = self.clone();
        Box::new(n)
    }
}

impl From<Role> for GRole {
    fn from(value: Role) -> Self {
        match value {
            Role::Assistant => GRole::Model,
            Role::System => GRole::System,
            Role::User => GRole::User,
            Role::Tool => GRole::Tool,
        }
    }
}

impl From<GRole> for Role {
    fn from(value: GRole) -> Self {
        match value {
            GRole::Model => Role::Assistant,
            GRole::System => Role::System,
            GRole::User => Role::User,
            GRole::Tool => Role::Tool,
        }
    }
}

impl From<&Content> for Message {
    fn from(value: &Content) -> Self {
        let mut calls = Vec::new();
        let mut files = Vec::new();
        let mut text = String::new();
        let mut tool_call_id = None;

        for part in value.parts.iter() {
            match part {
                ContentPart::Text(s) => text.push_str(s),
                ContentPart::FunctionCall(call) => calls.push(call.into()),
                ContentPart::FunctionResponse(res) => {
                    tool_call_id = Some(res.name.to_string());
                    text.push_str(res.response.content.as_str().unwrap()); //@todo: fix
                }
                // ContentPart::ExecutableCode(_) => (),
                // ContentPart::CodeExecutionResult(_) => (),
                // ContentPart::InlineData(_) => (),
                // ContentPart::FileData(_) => (),
                _ => (),
            }
        }

        Message {
            role: value.role.into(),
            content: text,
            tool_calls: calls,
            tool_call_id,
            images: if files.len() > 0 { Some(files) } else { None },
        }
    }
}

impl From<&GFunctionCall> for FunctionCall {
    fn from(value: &GFunctionCall) -> Self {
        Self {
            id: Some(value.name.clone()),
            name: value.name.clone(),
            args: serde_json::from_value(value.arguments.clone()).unwrap(),
        }
    }
}

impl From<&FunctionCall> for GFunctionCall {
    fn from(value: &FunctionCall) -> Self {
        Self {
            name: value.name.clone(),
            arguments: serde_json::to_value(value.args.clone()).unwrap(),
        }
    }
}

impl From<Message> for Content {
    fn from(value: Message) -> Self {
        let mut parts = Vec::new();

        for call in value.tool_calls.iter() {
            parts.push(ContentPart::FunctionCall(call.into()));
        }

        if let Some(files) = value.images {
            //@todo:lol
        }

        if !value.content.is_empty() {}

        if value.role == Role::Tool {
            parts.push(ContentPart::FunctionResponse(FunctionResponse {
                name: value.tool_call_id.unwrap_or_default(),
                response: FunctionResponsePayload {
                    content: serde_json::to_value(value.content).unwrap(),
                },
            }));
        } else {
            parts.push(ContentPart::Text(value.content));
        }

        Self {
            parts,
            role: value.role.into(),
        }
    }
}

impl From<PartResponse> for ContentPart {
    fn from(value: PartResponse) -> Self {
        match value {
            PartResponse::Text(s) => ContentPart::Text(s),
            PartResponse::FunctionCall(gfunction_call) => ContentPart::FunctionCall(gfunction_call),
            PartResponse::FunctionResponse(function_response) => {
                ContentPart::FunctionResponse(function_response)
            }
            PartResponse::ExecutableCode(executable_code) => {
                ContentPart::ExecutableCode(executable_code)
            }
            PartResponse::CodeExecutionResult(value) => {
                ContentPart::ExecutableCode(ExecutableCode {
                    code: value.to_string(),
                })
            }
        }
    }
}

// ---------------------------

#[derive(Debug, Copy, PartialEq, Eq, Clone, Serialize, Deserialize)]
pub enum GRole {
    #[serde(rename = "user")]
    User,
    #[serde(rename = "system")]
    System,
    #[serde(rename = "model")]
    Model,
    #[serde(rename = "tool")]
    Tool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelListRepsone {
    models: Vec<GModel>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GModel {
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateContentRequest {
    pub system_instruction: Option<Content>,
    pub contents: Vec<Content>,
    pub tools: Option<Vec<ToolConfig>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ToolConfig {
    // will work for both v1 and v2 models
    #[serde(rename = "function_declaration")]
    FunctionDeclaration(ToolConfigFunctionDeclaration),

    /* NOTE: For v1 models will be depreciated by google in 2025 */
    DynamicRetieval {
        google_search_retrieval: DynamicRetrieval,
    },

    /* NOTE: Used by v2 models if they have search built in */
    GoogleSearch {
        google_search: serde_json::Value,
    },

    /* NOTE: Used by v2 models if they have the code execution built in */
    CodeExecution {
        code_execution: serde_json::Value,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Content {
    pub parts: Vec<ContentPart>,
    pub role: GRole,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ContentPart {
    #[serde(rename = "text")]
    Text(String),
    #[serde(rename = "inlineData")]
    InlineData(InlineData),
    #[serde(rename = "fileData")]
    FileData(FileData),
    #[serde(rename = "functionCall")]
    FunctionCall(GFunctionCall),
    #[serde(rename = "functionResponse")]
    FunctionResponse(FunctionResponse),
    #[serde(rename = "executableCode")]
    ExecutableCode(ExecutableCode),
    #[serde(rename = "codeExecutionResult")]
    CodeExecutionResult(Value),
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ToolConfigFunctionDeclaration {
    pub function_declarations: Vec<FunctionDeclaration>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename = "google_search_retrieval")]
pub struct DynamicRetrieval {
    pub dynamic_retrieval_config: DynamicRetrievalConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename = "dynamic_retrieval_config")]
pub struct DynamicRetrievalConfig {
    pub mode: String,
    pub dynamic_threshold: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FunctionDeclaration {
    pub name: String,
    pub description: String,
    pub parameters: FunctionParameters,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FunctionParameters {
    #[serde(rename = "type")]
    pub parameter_type: String,
    pub properties: HashMap<String, ParameterProperty>,
    pub required: Option<Vec<String>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ParameterProperty {
    #[serde(rename = "type")]
    pub property_type: String,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enum_values: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateContentResponse {
    pub candidates: Option<Vec<Candidate>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Candidate {
    pub content: ContentResponse,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContentResponse {
    pub parts: Vec<PartResponse>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PartResponse {
    #[serde(rename = "text")]
    Text(String),
    #[serde(rename = "functionCall")]
    FunctionCall(GFunctionCall),
    #[serde(rename = "functionResponse")]
    FunctionResponse(FunctionResponse),
    #[serde(rename = "executableCode")]
    ExecutableCode(ExecutableCode),
    #[serde(rename = "codeExecutionResult")]
    CodeExecutionResult(Value),
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct GFunctionCall {
    pub name: String,
    #[serde(rename = "args")]
    pub arguments: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionResponse {
    pub name: String,
    pub response: FunctionResponsePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionResponsePayload {
    pub content: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutableCode {
    pub code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InlineData {
    #[serde(rename = "mimeType")]
    mime_type: String,
    data: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileData {
    #[serde(rename = "mimeType")]
    mime_type: String,
    #[serde(rename = "fileUri")]
    file_uri: String,
}
