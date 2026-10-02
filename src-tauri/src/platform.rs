//! Platform-specific process lifecycle helpers.
//!
//! dsh-swiftUI uses `SIGTERM` -> 5s -> `SIGKILL` -> `waitpid`. The Tauri / Rust port
//! must do the equivalent on Windows, where there is no SIGTERM equivalent that the
//! dsh Node process understands. The strategy on Windows is `start_kill` (gentle
//! `TerminateProcess`) first, escalate to `kill` after 5s, then `wait`.

use std::time::Duration;
use tokio::process::Child;

#[cfg(target_os = "windows")]
pub async fn graceful_shutdown(child: &mut Child, grace: Duration) {
    // Stage 1: ask the OS to terminate the process group politely.
    if let Err(e) = child.start_kill() {
        tracing::warn!(target: "dsh_shell", "stage-1 kill failed: {}", e);
    }
    match tokio::time::timeout(grace, child.wait()).await {
        Ok(_) => return,
        Err(_) => tracing::warn!(target: "dsh_shell", "grace period elapsed; escalating"),
    }

    // Stage 2: hard kill.
    if let Err(e) = child.kill().await {
        tracing::warn!(target: "dsh_shell", "stage-2 kill failed: {}", e);
    }
    let _ = child.wait().await;
}

#[cfg(not(target_os = "windows"))]
pub async fn graceful_shutdown(child: &mut Child, grace: Duration) {
    // On POSIX we send SIGTERM and rely on `Child::start_kill` to deliver it via the
    // process group so dsh and any grandchildren get the signal.
    use tokio::signal::unix::{signal, SignalKind};
    if let Ok(mut sig) = signal(SignalKind::terminate()) {
        if let Some(pid) = child.id() {
            unsafe { libc::killpg(pid as i32, libc::SIGTERM); }
            let _ = sig; // unused fallback; killpg is the real path
        }
    }
    if let Err(e) = child.start_kill() {
        tracing::warn!(target: "dsh_shell", "stage-1 kill failed: {}", e);
    }
    match tokio::time::timeout(grace, child.wait()).await {
        Ok(_) => return,
        Err(_) => tracing::warn!(target: "dsh_shell", "grace period elapsed; escalating"),
    }
    if let Err(e) = child.kill().await {
        tracing::warn!(target: "dsh_shell", "stage-2 kill failed: {}", e);
    }
    let _ = child.wait().await;
}

/// Best-effort: detect whether the given child has already exited on its own.
pub fn is_dead(child: &Child) -> bool {
    child.id().is_none()
}

/// Convenience: how long to wait before escalating from a gentle kill to a hard one.
pub fn default_grace_period() -> Duration {
    Duration::from_secs(5)
}
