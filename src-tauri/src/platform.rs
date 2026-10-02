//! OS-specific process termination.
//!
//! The contract is "closing the window frees the port", and on Windows the
//! naive implementation breaks it. `dsh_binary_path` points at `dsh.cmd`, so
//! what we actually spawn is `cmd.exe`, and the real harness is a **grandchild**
//! `node.exe` underneath it. `TerminateProcess` on the direct child kills
//! `cmd.exe` alone: node survives holding port 3080, the window is gone, and
//! nothing will ever reap it. So on Windows we terminate the whole tree we
//! spawned, by PID.
//!
//! That is why nothing in this file may kill by name. `taskkill /IM node.exe`
//! is precisely the mistake that destroyed the previous agent's host process;
//! `/PID <n> /T` can only ever reach the subtree under a PID we captured from
//! `child.id()` ourselves.

use std::time::Duration;
use tokio::process::Child;

#[cfg(windows)]
const TASKKILL: &str = "taskkill";

/// `CREATE_NO_WINDOW` (winuser.h).
///
/// A GUI-subsystem parent has no console of its own, so every console child we
/// spawn otherwise gets a brand-new console *window* — the black rectangle that
/// flashes on startup, and again for `taskkill` on shutdown. It is invisible to
/// whether the binary is the one in `target\release` or the one an installer put
/// in Program Files: the cause is the child spawn flags, not the packaging.
#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Hide the console of a child process we spawn.
///
/// Apply to every Windows child, not just dsh. `taskkill` is a console
/// application too.
#[cfg(windows)]
pub fn hide_child_console(command: &mut tokio::process::Command) -> &mut tokio::process::Command {
    command.creation_flags(CREATE_NO_WINDOW)
}

/// The blocking twin, for the `Drop` path, which cannot await.
#[cfg(windows)]
pub fn hide_child_console_sync(
    command: &mut std::process::Command,
) -> &mut std::process::Command {
    use std::os::windows::process::CommandExt;
    command.creation_flags(CREATE_NO_WINDOW)
}

/// No-op off Windows: a child there inherits the parent's terminal instead of
/// opening a window of its own.
#[cfg(not(windows))]
pub fn hide_child_console(command: &mut tokio::process::Command) -> &mut tokio::process::Command {
    command
}

#[cfg(not(windows))]
pub fn hide_child_console_sync(
    command: &mut std::process::Command,
) -> &mut std::process::Command {
    command
}

/// How long to wait for a polite exit before escalating.
pub fn default_grace_period() -> Duration {
    Duration::from_secs(5)
}

/// Best-effort: has the child already been reaped?
pub fn is_dead(child: &Child) -> bool {
    child.id().is_none()
}

/// Synchronous tree termination, for the `Drop` backstop.
///
/// `Drop` cannot await, and that is exactly when it is needed: the observed
/// failure is a dsh that outlived the shell because its `cmd.exe` parent had
/// already exited, leaving `start_kill` aimed at a dead process while node kept
/// the port bound. `terminate_tree` is async, so this is the same PID-scoped
/// call run blocking — acceptable because it only runs while the process is
/// already on its way out.
#[cfg(windows)]
pub fn terminate_tree_sync(pid: u32) {
    let _ = hide_child_console_sync(
        std::process::Command::new(TASKKILL)
            .args(["/PID", &pid.to_string(), "/T", "/F"]),
    )
    .stdin(std::process::Stdio::null())
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::null())
    .status();
}

#[cfg(unix)]
pub fn terminate_tree_sync(pid: u32) {
    // SIGKILL: we are already unwinding, so there is no grace period to honour.
    unsafe {
        libc::killpg(pid as libc::pid_t, libc::SIGKILL);
    }
}

/// Terminate the child and everything below it, then reap it.
pub async fn graceful_shutdown(child: &mut Child, pid: Option<u32>, grace: Duration) {
    if let Some(pid) = pid {
        if terminate_tree(pid).await {
            tracing::info!(target: "dsh_shell", "terminated dsh process tree (pid {pid})");
            if wait_bounded(child, grace).await {
                return;
            }
        }
    }

    // Fallbacks, in increasing force. Each one is scoped to the child handle we
    // already own, so none of them can reach an unrelated process.
    if is_dead(child) {
        return;
    }
    if let Err(err) = child.start_kill() {
        tracing::warn!(target: "dsh_shell", "stage 1 (kill child) failed: {err}");
    }
    if wait_bounded(child, grace).await {
        return;
    }

    tracing::warn!(target: "dsh_shell", "grace period elapsed; escalating");
    if let Err(err) = child.kill().await {
        tracing::warn!(target: "dsh_shell", "stage 2 (force kill) failed: {err}");
    }
    let _ = child.wait().await;
}

/// Wait for the child, giving up after `grace`.
async fn wait_bounded(child: &mut Child, grace: Duration) -> bool {
    matches!(tokio::time::timeout(grace, child.wait()).await, Ok(Ok(_)))
}

#[cfg(windows)]
async fn terminate_tree(pid: u32) -> bool {
    use tokio::process::Command;

    let result = tokio::time::timeout(
        Duration::from_secs(10),
        hide_child_console(
            Command::new(TASKKILL)
                // PID-scoped on purpose. Never /IM, never a name pattern.
                .args(["/PID", &pid.to_string(), "/T", "/F"]),
        )
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status(),
    )
    .await;

    match result {
        Ok(Ok(status)) if status.success() => true,
        Ok(Ok(status)) => {
            tracing::warn!(target: "dsh_shell", "taskkill exited with {status}");
            false
        }
        Ok(Err(err)) => {
            tracing::warn!(target: "dsh_shell", "taskkill could not run: {err}");
            false
        }
        Err(_) => {
            tracing::warn!(target: "dsh_shell", "taskkill timed out");
            false
        }
    }
}

#[cfg(unix)]
async fn terminate_tree(pid: u32) -> bool {
    // Negative pid addresses the process group, which is how dsh and its own
    // children get reached in one signal.
    if unsafe { libc::killpg(pid as libc::pid_t, libc::SIGTERM) } != 0 {
        return false;
    }
    true
}
