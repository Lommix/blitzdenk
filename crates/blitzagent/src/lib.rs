mod agent;
mod chat;
mod clients;
mod error;
mod tool;

pub type BResult<T> = core::result::Result<T, error::BlitzError>;
pub use agent::{Agent, AgentArgs, AgentContext, AgentInstruction, Confirmation};
pub use chat::{ArgType, Argument, ChatClient, FunctionCall, Message, Role};
pub use clients::{
    claude::ClaudeClient, gemini::GeminiClient, ollama::OllamaClient, openai::OpenApiClient,
};
pub use error::BlitzError;
pub use tool::AiTool;
