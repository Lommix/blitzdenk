mod agent;
mod chat;
mod clients;
mod error;
mod tool;

pub type BResult<T> = core::result::Result<T, error::BlitzError>;
pub use agent::{Agent,Confirmation, AgentArgs, AgentContext, AgentInstruction};
pub use chat::{ArgType, Argument, ChatClient, FunctionCall, Message, Role};
pub use clients::{ollama::OllamaClient, openai::OpenApiClient};
pub use error::BlitzError;
pub use tool::AiTool;
