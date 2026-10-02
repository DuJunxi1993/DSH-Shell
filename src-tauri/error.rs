//! Error types used across dsh-shell.

use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum ShellError {
    #[error("failed to spawn dsh: {0}")]
    Spawn(#[source] std::io::Error),

    #[error("failed to build HTTP probe client: {0}")]
    HttpClient(#[source] reqwest::Error),

    #[error("dsh did not emit a reachable endpoint at {host}:{port} within {waited:?}")]
    EndpointTimeout {
        host: String,
        port: u16,
        waited: Duration,
    },

    #[error("dsh exited before becoming healthy: status={0:?}")]
    DshExitedBeforeReady(Option<i32>),

    #[error("config error: {0}")]
    Config(#[from] crate::config::ConfigError),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("self-protection: refusing to run inside a dsh child process")]
    RefusingToNest,

    #[error("no dsh instance found on loopback for attach mode")]
    NoAttachTarget,
}

pub type Result<T> = std::result::Result<T, ShellError>;
