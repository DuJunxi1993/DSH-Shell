//! dsh-shell core: a pure shell around the dsh web UI.
//!
//! Public surface:
//!
//! - [`config`]: settings schema, load/save, defaults
//! - [`endpoint`]: dsh's stdout → the authenticated WebView URL
//! - [`chrome`]: injected window-chrome geometry and the zoom compensation
//! - [`preflight`]: the checks that keep us from nesting or double-binding
//! - [`process`]: spawn / attach / wait / shutdown
//! - [`platform`]: OS-specific termination
//! - [`navigate`]: which URLs the webview is allowed to show
//! - [`error`]: the shared error surface

pub mod chrome;
pub mod config;
pub mod endpoint;
pub mod error;
pub mod navigate;
pub mod platform;
pub mod preflight;
pub mod process;

pub use config::{Config, LaunchMode};
pub use error::{Result, ShellError};
pub use preflight::{inside_harness_session, port_is_free};
pub use process::{launch, DshProcess};
