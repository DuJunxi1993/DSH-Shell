//! Shared error types for dsh-shell core.

use thiserror::Error;

/// Top-level error surface. Each variant maps to one actionable failure mode
/// so callers (CLI, Tauri setup, tests) can react sensibly.
#[derive(Debug, Error)]
pub enum ShellError {
    /// `dsh` binary failed to start (path wrong, permission denied, …).
    #[error("failed to spawn dsh: {0}")]
    Spawn(std::io::Error),

    /// `dsh` did not produce a recognizable URL line within the configured timeout.
    #[error("timed out waiting for dsh to print its URL")]
    EndpointTimeout,

    /// Could not construct an HTTP client for the attach-mode probe.
    #[error("failed to build http client: {0}")]
    HttpClient(reqwest::Error),

    /// Attach mode was selected without a port to probe.
    #[error("attach mode requires preferred_port != 0")]
    NoAttachTarget,

    /// Generic IO error (waiting on child, etc.).
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    /// Regex compilation failed (treated as fatal at startup).
    #[error("invalid url regex: {0}")]
    InvalidRegex(regex::Error),

    /// Could not parse the URL `dsh` printed.
    #[error("could not parse endpoint url: {0}")]
    InvalidUrl(url::ParseError),
}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, ShellError>;