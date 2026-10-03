//! Owning the dsh child process for the lifetime of the window.

use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config::{Config, LaunchMode};
use crate::endpoint;
use crate::error::{Result, ShellError};
use crate::platform;
use crate::preflight;

/// A running (or attached) dsh, plus the URL the WebView must load.
///
/// Explicit shutdown via [`DshProcess::shutdown`] is the normal path. [`Drop`]
/// is the backstop for a panic or an early return: a leaked dsh would keep the
/// port bound with no window left to close it. The `Command` also carries
/// `kill_on_drop`, so the child cannot outlive this value even if the mutex is
/// held when we drop.
pub struct DshProcess {
    child: Arc<Mutex<Option<Child>>>,
    pid: Option<u32>,
    url: String,
    config: Config,
}

/// The answer from [`DshProcess::poll_exit`].
///
/// Two variants rather than `Option<Option<i32>>`: "still running" and "died
/// without an exit code" are different facts, and a watcher that conflated them
/// would stop watching a dsh killed by a signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exited {
    No,
    /// Gone. The code is `None` when it was killed by a signal.
    Yes(Option<i32>),
}

impl std::fmt::Debug for DshProcess {
    /// Hand-written: `Child` is not `Debug`, and the interesting fields are the
    /// ones a failure message needs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DshProcess")
            .field("url", &self.url)
            .field("pid", &self.pid)
            .field("mode", &self.config.launch_mode)
            .finish()
    }
}

impl Drop for DshProcess {
    fn drop(&mut self) {
        // The tree kill is what actually matters. `start_kill` on the direct
        // child is not enough: dsh.cmd runs as cmd.exe, so by the time we are
        // dropping, cmd.exe may already be gone and node — a grandchild — is
        // still holding the port. Killing a dead child is a no-op, which is how
        // a dsh survived a panicking shell.
        if let Some(pid) = self.pid {
            platform::terminate_tree_sync(pid);
        }
        if let Ok(mut guard) = self.child.try_lock() {
            if let Some(child) = guard.as_mut() {
                let _ = child.start_kill();
            }
        }
        tracing::info!(target: "dsh_shell", "DshProcess dropped; child tree reaped");
    }
}

impl DshProcess {
    /// Build the command for `dsh web`.
    ///
    /// `--no-open` is not optional: without it dsh also launches the system
    /// browser, and the user would get two windows for one harness.
    pub fn build_command(config: &Config) -> Command {
        let mut cmd = Command::new(&config.dsh_binary_path);
        cmd.arg("web")
            .arg("--no-open")
            .arg("--host")
            .arg(&config.listen_host);
        if config.preferred_port != 0 {
            cmd.arg("--port").arg(config.preferred_port.to_string());
        }
        // Repeated rather than variadic: `--trusted-host <authority...>` would
        // swallow every following flag into its own list.
        for host in &config.trusted_hosts {
            cmd.arg("--trusted-host").arg(host);
        }
        cmd.stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null())
            .kill_on_drop(true);

        // Unix only: make dsh its own process-group leader, so that
        // `platform::terminate_tree`'s `killpg(pid)` addresses *its* group rather
        // than ours. Without this the pid is not a group id at all - killpg
        // returns ESRCH, and where it does not, it can signal our own group.
        // Windows has no equivalent: the tree walk there is `taskkill /T`, and
        // `hide_child_console` covers the console need.
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }

        // Without this a console window flashes open for the whole life of dsh,
        // because a GUI-subsystem parent has no console for the child to share.
        platform::hide_child_console(&mut cmd);
        cmd
    }

    /// Fork dsh and wait until it can tell us its authenticated URL.
    pub async fn spawn(config: Config) -> Result<Self> {
        Self::spawn_with_pid_hook(config, |_| {}).await
    }

    /// [`Self::spawn`], but reports the child's PID as soon as it exists.
    ///
    /// The window can be closed while this is still waiting for the URL line,
    /// and by then the caller holds nothing that would terminate the child on
    /// drop. The hook is how the shell keeps a handle on a dsh it does not own
    /// yet.
    pub async fn spawn_with_pid_hook<F: FnOnce(u32) + Send>(
        config: Config,
        on_pid: F,
    ) -> Result<Self> {
        preflight::check_spawn(&config)?;

        let mut cmd = Self::build_command(&config);
        let mut child = cmd.spawn().map_err(ShellError::Spawn)?;
        if let Some(pid) = child.id() {
            on_pid(pid);
        }
        let pid = child.id();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let resolved = endpoint::resolve(
            &mut child,
            stdout,
            stderr,
            &config.listen_host,
            config.preferred_port,
            Duration::from_secs(config.spawn_timeout_seconds),
            Duration::from_secs_f64(config.poll_interval_seconds.clamp(0.05, 5.0)),
        )
        .await;

        let url = match resolved {
            Ok(url) => url,
            Err(err) => {
                // A dsh that never became usable is still holding our port.
                // Nobody is left to close it, so we clean up here.
                platform::graceful_shutdown(&mut child, pid, platform::default_grace_period())
                    .await;
                return Err(err);
            }
        };

        Ok(Self {
            child: Arc::new(Mutex::new(Some(child))),
            pid,
            url,
            config,
        })
    }

    /// Attach to an already-running dsh. Forks nothing, so it cannot collide
    /// with — or damage — a harness the operator already has open.
    pub async fn attach(config: Config) -> Result<Self> {
        if config.preferred_port == 0 {
            return Err(ShellError::NoAttachTarget(format!(
                "{}/0 (attach needs a fixed port to probe)",
                config.listen_host
            )));
        }

        let url = format!("http://{}:{}/", config.listen_host, config.preferred_port);
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(ShellError::HttpClient)?;
        let deadline = Instant::now() + Duration::from_secs(config.spawn_timeout_seconds);

        loop {
            // A 401 counts: that is dsh's auth fence answering, which proves a
            // harness is listening.
            if let Ok(response) = client.get(&url).send().await {
                tracing::info!(target: "dsh_shell", "attached to dsh at {url} ({})", response.status());
                return Ok(Self {
                    child: Arc::new(Mutex::new(None)),
                    pid: None,
                    url,
                    config,
                });
            }
            if Instant::now() >= deadline {
                return Err(ShellError::NoAttachTarget(url));
            }
            tokio::time::sleep(Duration::from_secs_f64(config.poll_interval_seconds.clamp(0.1, 5.0)))
                .await;
        }
    }

    /// The URL the WebView must load, token included.
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Block until dsh exits, returning its exit code if it had one.
    pub async fn wait(&self) -> Result<Option<i32>> {
        let mut guard = self.child.lock().await;
        let Some(child) = guard.as_mut() else {
            return Ok(None);
        };
        child.wait().await.map(|status| status.code()).map_err(ShellError::Io)
    }

    /// Check whether dsh has exited, without blocking and without giving up the
    /// ability to shut it down.
    ///
    /// [`wait`] cannot be used for this: it holds the child lock for the whole
    /// lifetime of dsh, which would make [`shutdown`] unreachable from any other
    /// task — and that deadlock is why nothing used to watch dsh at all.
    pub async fn poll_exit(&self) -> Result<Exited> {
        let mut guard = self.child.lock().await;
        // Attach mode: the dsh we found was never ours, so there is nothing whose
        // exit is ours to report.
        let Some(child) = guard.as_mut() else {
            return Ok(Exited::No);
        };
        match child.try_wait() {
            Ok(None) => Ok(Exited::No),
            Ok(Some(status)) => Ok(Exited::Yes(status.code())),
            Err(err) => Err(ShellError::Io(err)),
        }
    }

    /// Terminate dsh, then reap it. Idempotent, and a no-op in attach mode
    /// (there is nothing of ours to kill).
    pub async fn shutdown(&self) {
        let mut guard = self.child.lock().await;
        let Some(child) = guard.as_mut() else {
            return;
        };
        platform::graceful_shutdown(child, self.pid, platform::default_grace_period()).await;
    }
}

/// Pick spawn vs attach from the config.
pub async fn launch(config: Config) -> Result<DshProcess> {
    match config.launch_mode {
        LaunchMode::Spawn => DshProcess::spawn(config).await,
        LaunchMode::Attach => DshProcess::attach(config).await,
    }
}

/// [`launch`], reporting a spawned child's PID before the caller owns it.
pub async fn launch_with_pid_hook<F: FnOnce(u32) + Send>(
    config: Config,
    on_pid: F,
) -> Result<DshProcess> {
    match config.launch_mode {
        LaunchMode::Spawn => DshProcess::spawn_with_pid_hook(config, on_pid).await,
        // Attach mode forks nothing, so there is no PID to report.
        LaunchMode::Attach => {
            let _ = on_pid;
            DshProcess::attach(config).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args_of(config: &Config) -> Vec<String> {
        DshProcess::build_command(config)
            .as_std()
            .get_args()
            .filter_map(|arg| arg.to_str().map(str::to_string))
            .collect()
    }

    #[test]
    fn build_command_omits_port_when_zero() {
        let config = Config {
            preferred_port: 0,
            ..Config::default()
        };
        assert!(!args_of(&config).contains(&"--port".to_string()));
    }

    #[test]
    fn build_command_includes_port_when_nonzero() {
        let args = args_of(&Config::default());
        let at = args.iter().position(|arg| arg == "--port").expect("--port");
        assert_eq!(args[at + 1], "3080");
    }

    #[test]
    fn build_command_passes_trusted_hosts_one_flag_each() {
        let config = Config {
            trusted_hosts: vec!["a".into(), "b".into(), "c".into()],
            ..Config::default()
        };
        let args = args_of(&config);
        let flags: Vec<&String> = args.iter().filter(|arg| *arg == "--trusted-host").collect();
        assert_eq!(flags.len(), 3, "{args:?}");
        // Variadic parsing would break if a value ever landed after a flag.
        assert_eq!(args[0], "web");
        assert!(args.contains(&"--no-open".to_string()));
    }

    #[test]
    fn build_command_never_targets_itself() {
        // A shell that re-executed itself would fork forever.
        let program = DshProcess::build_command(&Config::default())
            .as_std()
            .get_program()
            .to_string_lossy()
            .to_string();
        assert!(!program.contains("dsh-shell"), "{program}");
    }
}
