//! Configuration types and persistence.
//!
//! Mirrors dsh-swiftUI's `settings.json` schema 1:1.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// How the shell should connect to a dsh instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LaunchMode {
    /// Fork `dsh web` ourselves, capture URL, render into WebView.
    #[default]
    Spawn,
    /// Only connect to an already-running dsh; do not fork.
    Attach,
}

/// Top-level configuration. Persisted as JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Absolute path to the `dsh` executable.
    pub dsh_binary_path: PathBuf,
    /// Spawn vs. attach mode.
    pub launch_mode: LaunchMode,
    /// Loopback host passed to `dsh web --host`.
    pub listen_host: String,
    /// Fixed port forwarded to `dsh web --port`. `0` = OS-assigned.
    pub preferred_port: u16,
    /// Extra trusted hosts appended to `dsh web --trusted-host`.
    pub trusted_hosts: Vec<String>,
    /// Polling interval for port probe / endpoint resolution.
    pub poll_interval_seconds: f64,
    /// How long to wait for the URL line on stdout before probing the port.
    pub spawn_timeout_seconds: u64,
    /// Whether to restart dsh on unexpected child exit.
    pub auto_restart_on_crash: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            dsh_binary_path: default_dsh_binary_path(),
            launch_mode: LaunchMode::Spawn,
            listen_host: "127.0.0.1".to_string(),
            preferred_port: 34247,
            trusted_hosts: vec!["127.0.0.1".to_string(), "localhost".to_string()],
            poll_interval_seconds: 0.5,
            spawn_timeout_seconds: 60,
            auto_restart_on_crash: true,
        }
    }
}

impl Config {
    /// Resolve the configuration file path under the platform's data dir.
    pub fn config_path() -> Result<PathBuf, ConfigError> {
        let dirs = directories::ProjectDirs::from("ai", "deepseek", "dsh-shell")
            .ok_or(ConfigError::NoDataDir)?;
        Ok(dirs.config_dir().join("settings.json"))
    }

    /// Load from the default location, or return `Config::default()` if missing.
    pub fn load_or_default() -> Self {
        match Self::config_path() {
            Ok(path) if path.exists() => Self::load_from(&path).unwrap_or_default(),
            _ => Self::default(),
        }
    }

    /// Load from an explicit path. Returns an error if the file is malformed.
    pub fn load_from(path: &Path) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path).map_err(ConfigError::Io)?;
        serde_json::from_str(&raw).map_err(ConfigError::Json)
    }

    /// Persist to the default location. Creates parent directories if missing.
    pub fn save(&self) -> Result<(), ConfigError> {
        let path = Self::config_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(ConfigError::Io)?;
        }
        let serialized = serde_json::to_string_pretty(self).map_err(ConfigError::Json)?;
        std::fs::write(&path, serialized).map_err(ConfigError::Io)?;
        Ok(())
    }
}

/// Platform-default dsh binary path. Falls back to the npm-global dsh.cmd on Windows.
fn default_dsh_binary_path() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        // %APPDATA%\npm\dsh.cmd is the canonical npm-global install location.
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return PathBuf::from(appdata).join("npm").join("dsh.cmd");
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        if let Ok(home) = std::env::var("HOME") {
            // ~/.npm-global/bin/dsh is the safest global install (avoids /usr/local requiring sudo).
            let candidate = PathBuf::from(&home).join(".npm-global").join("bin").join("dsh");
            if candidate.exists() {
                return candidate;
            }
        }
    }
    PathBuf::from("dsh") // last-resort: rely on PATH
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("could not determine platform data directory")]
    NoDataDir,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialize/parse error: {0}")]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_serializes_round_trip() {
        let cfg = Config::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let parsed: Config = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.preferred_port, cfg.preferred_port);
        assert_eq!(parsed.launch_mode, cfg.launch_mode);
    }

    #[test]
    fn load_or_default_when_missing() {
        // Just exercise the missing-file branch; do not write any real config.
        let cfg = Config::load_or_default();
        // Default port is the SwiftUI default (34247) — proof of 1:1 parity.
        assert_eq!(cfg.preferred_port, 34247);
    }
}
