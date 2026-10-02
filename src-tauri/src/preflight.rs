//! Checks that run *before* we fork dsh.
//!
//! Both checks exist to protect the user's harness, not our own process:
//!
//! * **Nested session.** dsh injects `DSH_SESSION_ID` / `DSH_PROFILE` /
//!   `DSH_WEB_URL` into every model-facing shell call (`dsh-shell-env`), and
//!   scrubs ambient `DSH_*` first so nothing leaks in from outside. Those
//!   variables therefore prove that dsh-shell was started from inside a running
//!   harness session. Starting a second harness there contends for the same
//!   ports, proxy and session store, and the damage lands on the *outer*
//!   session — which is the session the operator is sitting in.
//! * **Port ownership.** dsh refuses to share a port; a second bind fails with
//!   EADDRINUSE and the user is left staring at a dead window. Pointing them at
//!   `attach` is the useful answer.

use std::net::TcpListener;

use crate::config::Config;
use crate::error::{Result, ShellError};

/// Ambient variables that only a harness session sets. A `DSH_SHELL_*` name is
/// deliberately absent: dsh scrubs ambient `DSH_*` on the way to a child, so a
/// variable we set for ourselves would never survive to be read anyway.
const HARNESS_MARKERS: &[&str] = &[
    "DSH_SESSION_ID",
    "DSH_PROFILE",
    "DSH_PROFILE_DIR",
    "DSH_WEB_URL",
];

/// The harness variables visible in our environment, if any.
pub fn harness_session_vars() -> Vec<&'static str> {
    HARNESS_MARKERS
        .iter()
        .copied()
        .filter(|name| std::env::var_os(name).is_some())
        .collect()
}

/// True when we are provably running inside a harness session.
///
/// A session id on its own is decisive. A lone `DSH_PROFILE` / `DSH_WEB_URL` is
/// not — a user may well have exported one in a normal terminal — so those only
/// count when a second marker agrees.
pub fn inside_harness_session() -> bool {
    is_nested_session(&harness_session_vars())
}

/// The rule behind [`inside_harness_session`], as a pure function so it can be
/// tested without mutating the environment.
fn is_nested_session(vars: &[&str]) -> bool {
    vars.contains(&"DSH_SESSION_ID") || vars.len() >= 2
}

/// Whether we can bind `host:port` right now. Checked by binding, not by
/// scraping `netstat`, so it sees the same thing dsh's own bind would see.
pub fn port_is_free(host: &str, port: u16) -> bool {
    TcpListener::bind((host, port)).is_ok()
}

/// Validate the preconditions for [`crate::process::DshProcess::spawn`].
///
/// `attach` mode skips this: it forks nothing, so it cannot collide with or
/// damage a running harness.
pub fn check_spawn(config: &Config) -> Result<()> {
    if inside_harness_session() {
        return Err(ShellError::NestedSession {
            vars: harness_session_vars().join(", "),
        });
    }

    if config.preferred_port != 0 && !port_is_free(&config.listen_host, config.preferred_port) {
        return Err(ShellError::PortInUse {
            host: config.listen_host.clone(),
            port: config.preferred_port,
        });
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_harness_markers_means_not_nested() {
        // The test process inherits our env, which has no DSH_* set.
        assert!(harness_session_vars().is_empty());
        assert!(!inside_harness_session());
    }

    #[test]
    fn one_ambiguous_marker_is_not_proof() {
        // A user may legitimately have DSH_PROFILE exported in a normal
        // terminal. Locking them out of the app would be worse than the nesting
        // risk, so a single marker has to be enough to prove nothing.
        assert!(!is_nested_session(&[]));
        assert!(!is_nested_session(&["DSH_PROFILE"]));
        assert!(!is_nested_session(&["DSH_WEB_URL"]));
    }

    #[test]
    fn a_session_id_is_decisive() {
        assert!(is_nested_session(&["DSH_SESSION_ID"]));
        assert!(is_nested_session(&["DSH_SESSION_ID", "DSH_PROFILE"]));
        // Two independent markers also count.
        assert!(is_nested_session(&["DSH_PROFILE", "DSH_WEB_URL"]));
    }

    #[test]
    fn a_bound_port_is_reported_as_in_use() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind an ephemeral port");
        let port = listener.local_addr().expect("addr").port();
        assert!(!port_is_free("127.0.0.1", port));
        drop(listener);
        assert!(port_is_free("127.0.0.1", port));
    }
}
