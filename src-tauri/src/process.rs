//! dsh process manager: spawn, attach, health-probe, and graceful shutdown.

use crate::config::{Config, LaunchMode};
use crate::endpoint;
use crate::error::{Result, ShellError};
use crate::platform;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

/// Owns a dsh child process.
///
/// Explicit shutdown via [`DshProcess::shutdown`] is preferred (graceful term
/// → 5 s → kill). As a **safety net** [`Drop`] hard-kills the child so a panic
/// in the shell cannot leak dsh as an orphan — that would violate the core
/// "close window = kill dsh" contract.
pub struct DshProcess {
    child: Arc<Mutex<Option<Child>>>,
    url: String,
    config: Config,
}

impl Drop for DshProcess {
    fn drop(&mut self) {
        // Try to grab the child synchronously; if we can't get the lock we
        // can't help, but kill_on_drop(true) on the command itself is our
        // last-resort backstop.
        if let Ok(mut guard) = self.child.try_lock() {
            if let Some(child) = guard.as_mut() {
                let _ = child.start_kill();
            }
        }
    }
}

impl DshProcess {
    /// Build a command to launch `dsh web`. Honors `--no-open` so we control the browser.
    pub fn build_command(config: &Config) -> Command {
        let mut cmd = Command::new(&config.dsh_binary_path);
        cmd.arg("web")
            .arg("--no-open")
            .arg("--host")
            .arg(&config.listen_host);
        if config.preferred_port != 0 {
            cmd.arg("--port").arg(config.preferred_port.to_string());
        }
        for host in &config.trusted_hosts {
            cmd.arg("--trusted-host").arg(host);
        }
        cmd.stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null())
            .kill_on_drop(true); // Backstop for the Drop impl.
        cmd
    }

    /// Spawn a new dsh instance and wait for its endpoint.
    pub async fn spawn(config: Config) -> Result<Self> {
        let mut cmd = Self::build_command(&config);
        let mut child = cmd.spawn().map_err(ShellError::Spawn)?;

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let url = endpoint::resolve(
            &mut child,
            stdout,
            stderr,
            &config.listen_host,
            config.preferred_port,
            Duration::from_secs(config.spawn_timeout_seconds),
            Duration::from_secs_f64(config.poll_interval_seconds.max(0.05)),
        )
        .await?;

        Ok(Self {
            child: Arc::new(Mutex::new(Some(child))),
            url,
            config,
        })
    }

    /// Attach to an already-running dsh on the loopback. Currently requires
    /// `preferred_port != 0` (we have nothing else to probe against).
    pub async fn attach(config: Config) -> Result<Self> {
        if config.preferred_port == 0 {
            return Err(ShellError::NoAttachTarget);
        }
        let url = format!(
            "http://{}:{}/",
            config.listen_host, config.preferred_port
        );
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(ShellError::HttpClient)?;
        let deadline = std::time::Instant::now()
            + Duration::from_secs(config.spawn_timeout_seconds);
        loop {
            match client.get(&url).send().await {
                Ok(resp) if resp.status().is_success() || resp.status().is_redirection() => break,
                _ => {}
            }
            if std::time::Instant::now() >= deadline {
                return Err(ShellError::NoAttachTarget);
            }
            tokio::time::sleep(Duration::from_secs_f64(
                config.poll_interval_seconds.max(0.1),
            ))
            .await;
        }
        Ok(Self {
            child: Arc::new(Mutex::new(None)),
            url,
            config,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    /// Block until dsh exits, returning its exit status if available.
    pub async fn wait(&self) -> Result<Option<i32>> {
        let mut guard = self.child.lock().await;
        let Some(child) = guard.as_mut() else {
            return Ok(None);
        };
        match child.wait().await {
            Ok(status) => Ok(status.code()),
            Err(e) => Err(ShellError::Io(e)),
        }
    }

    /// Send a polite termination, wait up to `grace`, then hard-kill.
    pub async fn shutdown(&self) {
        let mut guard = self.child.lock().await;
        let Some(child) = guard.as_mut() else {
            return; // attach mode: nothing to kill
        };
        if platform::is_dead(child) {
            return;
        }
        platform::graceful_shutdown(child, platform::default_grace_period()).await;
    }
}

/// Convenience constructor that picks spawn vs attach from config.
pub async fn launch(config: Config) -> Result<DshProcess> {
    match config.launch_mode {
        LaunchMode::Spawn => DshProcess::spawn(config).await,
        LaunchMode::Attach => DshProcess::attach(config).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_command_omits_port_when_zero() {
        let c = Config {
            preferred_port: 0,
            ..Config::default()
        };
        // Build the command and inspect its args.
        let cmd = DshProcess::build_command(&c);
        let args: Vec<&str> = cmd.as_std().get_args().filter_map(|s| s.to_str()).collect();
        assert!(args.contains(&"--no-open"));
        assert!(!args.contains(&"--port"));
    }

    #[test]
    fn build_command_includes_port_when_nonzero() {
        let c = Config::default();
        let cmd = DshProcess::build_command(&c);
        let args: Vec<String> = cmd
            .as_std()
            .get_args()
            .filter_map(|s| s.to_str().map(|s| s.to_string()))
            .collect();
        let port_idx = args
            .iter()
            .position(|a| a == "--port")
            .expect("--port should be present");
        assert_eq!(args[port_idx + 1], "34247");
    }

    #[test]
    fn build_command_passes_trusted_hosts() {
        let c = Config::default();
        let cmd = DshProcess::build_command(&c);
        let args: Vec<String> = cmd
            .as_std()
            .get_args()
            .filter_map(|s| s.to_str().map(|s| s.to_string()))
            .collect();
        let mut i = 0;
        while let Some(a) = args.get(i) {
            if a == "--trusted-host" {
                assert!(args.get(i + 1).is_some());
            }
            i += 1;
        }
    }
}
