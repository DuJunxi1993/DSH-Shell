//! dsh-shell core library: platform-agnostic façade.
//!
//! Public surface:
//! - [`config`]: settings.json schema + load/save
//! - [`endpoint`]: URL-line + port-probe resolution
//! - [`process`]: spawn/attach/wait/shutdown for dsh
//! - [`platform`]: OS-specific graceful-shutdown helpers
//! - [`error`]: shared error types

pub mod config;
pub mod endpoint;
pub mod error;
pub mod platform;
pub mod process;

pub use config::{Config, LaunchMode};
pub use error::{Result, ShellError};
pub use process::{launch, DshProcess};
