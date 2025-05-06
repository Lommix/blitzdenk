use thiserror::Error;

#[derive(Error, Debug)]
pub enum BlitzError {
    #[error("not found")]
    NotFound,

    #[error("channel failed")]
    ChannelDown,

    #[error("{0}")]
    ApiError(String),

    #[error(transparent)]
    RequestError(#[from] reqwest::Error),

    #[error(transparent)]
    IoError(#[from] std::io::Error),

    #[error(transparent)]
    TokioRecErr(#[from] tokio::sync::oneshot::error::RecvError),

    #[error("{0}")]
    MissingArgument(String),
}

impl<T> From<crossbeam::channel::SendError<T>> for BlitzError {
    fn from(_: crossbeam::channel::SendError<T>) -> Self {
        BlitzError::ChannelDown
    }
}

impl From<crossbeam::channel::RecvError> for BlitzError {
    fn from(_: crossbeam::channel::RecvError) -> Self {
        BlitzError::ChannelDown
    }
}
