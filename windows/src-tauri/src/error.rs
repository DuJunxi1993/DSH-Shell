//! Shared error surface for dsh-shell core.
//!
//! Every variant is one actionable failure mode, because the app runs without a
//! console: whatever the user sees in the log has to be enough to act on.

use std::time::Duration;
use thiserror::Error;

pub type Result<T> = std::result::Result<T, ShellError>;

#[derive(Debug, Error)]
pub enum ShellError {
    /// The `dsh` binary could not be started at all (bad path, access denied).
    #[error("failed to spawn dsh: {0}")]
    Spawn(std::io::Error),

    /// dsh exited before printing its URL. `tail` carries the last lines it
    /// wrote, because the reason is almost always in there.
    #[error("dsh exited (status {code:?}) before printing an authenticated URL:\n{tail}")]
    DshExitedBeforeReady { code: Option<i32>, tail: String },

    /// dsh stayed alive but never printed a usable URL line.
    #[error(
        "timed out after {waited:?} waiting for dsh at {host}:{port} to print an authenticated URL:\n{tail}"
    )]
    EndpointTimeout {
        host: String,
        port: u16,
        waited: Duration,
        tail: String,
    },

    /// We are running inside a dsh session. Spawning a nested harness from the
    /// harness destroys the parent session, so we refuse instead.
    #[error(
        "refusing to start a nested dsh: this shell was launched from inside a dsh session ({vars}). \
         Start dsh-shell from a normal terminal, or set launch_mode = \"attach\"."
    )]
    NestedSession { vars: String },

    /// Something already owns the port we were asked to bind.
    #[error("port {port} on {host} is already in use; another dsh is probably running. \
         Set launch_mode = \"attach\" to use it, or choose a different preferred_port.")]
    PortInUse { host: String, port: u16 },

    /// Attach mode was selected but there is nothing to attach to.
    #[error("no dsh answered on {0}")]
    NoAttachTarget(String),

    /// The HTTP client used for liveness probing could not be constructed.
    #[error("failed to build the http probe client: {0}")]
    HttpClient(reqwest::Error),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("config error: {0}")]
    Config(#[from] crate::config::ConfigError),
}
