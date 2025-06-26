use thiserror::Error;

/// The top-level error type for the application.
#[derive(Error, Debug)]
pub enum AiError {
    /// An error occurred while making a request to the AI API.
    #[error("api fail {0}")]
    RequestError(#[from] genai::Error),

    /// An I/O error occurred.
    #[error("io fail {0}")]
    IoError(#[from] std::io::Error),

    /// A required argument for a tool call is missing.
    #[error("tool call is missing argument `{0}`")]
    MissingArgument(String),

    /// An argument for a tool call could not be parsed.
    #[error("Failed to parse argument `{0}`")]
    ArgumentParseFailed(String),

    /// An error occurred while serializing or deserializing JSON.
    #[error("Failed to parse json `{0}`")]
    JsonError(#[from] serde_json::Error),

    /// A broadcast channel is down.
    #[error("the broadcast channel went down")]
    ChannelDown,

    /// The agent is already running.
    #[error("the agent is already running")]
    AlreadyRunning,

    /// An error occurred while receiving from a oneshot channel.
    #[error(transparent)]
    TokioRecErr(#[from] tokio::sync::oneshot::error::RecvError),

    /// A tool failed to execute.
    #[error("{0}")]
    ToolFailed(String),

    /// An error occurred while making an HTTP request.
    #[error(transparent)]
    FetchError(#[from] reqwest::Error),

    /// An error occurred while parsing a glob pattern.
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
