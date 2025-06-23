use thiserror::Error;

#[derive(Error, Debug)]
pub enum AiError {
    #[error("api fail {0}")]
    RequestError(#[from] genai::Error),
    #[error("io fail {0}")]
    IoError(#[from] std::io::Error),
    #[error("tool call is missing argument `{0}`")]
    MissingArgument(String),
    #[error("Failed to parse argument `{0}`")]
    ArgumentParseFailed(String),
    #[error("Failed to parse json `{0}`")]
    JsonError(#[from] serde_json::Error),
    #[error("the broadcast channel went down")]
    ChannelDown,
    #[error("the agent is already running")]
    AlreadyRunning,
    #[error(transparent)]
    TokioRecErr(#[from] tokio::sync::oneshot::error::RecvError),
    #[error("{0}")]
    ToolFailed(String),
    #[error(transparent)]
    FetchError(#[from] reqwest::Error),
    #[error(transparent)]
    GlobError(#[from] glob::PatternError),
}

impl<T> From<crossbeam::channel::SendError<T>> for AiError {
    fn from(_: crossbeam::channel::SendError<T>) -> Self {
        AiError::ChannelDown
    }
}

impl From<crossbeam::channel::RecvError> for AiError {
    fn from(_: crossbeam::channel::RecvError) -> Self {
        AiError::ChannelDown
    }
}
