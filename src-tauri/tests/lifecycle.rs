//! Lifecycle guards: nesting, port ownership, and attach mode.
//!
//! These are the checks that keep dsh-shell from harming a harness the operator
//! already has open — the failure mode that killed the previous agent's
//! session. Again: `stub-dsh` only, never a real dsh.

use std::net::TcpListener;

use dsh_shell_core::config::{Config, LaunchMode};
use dsh_shell_core::error::ShellError;
use dsh_shell_core::preflight;
use dsh_shell_core::process::DshProcess;

mod common;
use common::EnvGuard;

fn stub_config(port: u16) -> Config {
    Config {
        dsh_binary_path: std::path::PathBuf::from(env!("CARGO_BIN_EXE_stub-dsh")),
        listen_host: "127.0.0.1".to_string(),
        preferred_port: port,
        trusted_hosts: vec![],
        poll_interval_seconds: 0.05,
        spawn_timeout_seconds: 10,
        launch_mode: LaunchMode::Spawn,
        ..Config::default()
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind an ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

#[test]
fn a_clean_environment_is_not_nested() {
    // Takes the lock so the nesting test below cannot be mid-flight.
    let _env = EnvGuard::set(&[]);
    assert!(
        !preflight::inside_harness_session(),
        "the test process inherited harness markers: {:?}",
        preflight::harness_session_vars()
    );
    assert!(preflight::check_spawn(&stub_config(free_port())).is_ok());
}

#[tokio::test]
async fn refuses_to_nest_inside_a_harness_session() {
    // dsh injects these into every model-facing shell call. A shell started from
    // inside a session must not fork a second harness.
    let _env = EnvGuard::set(&[
        ("DSH_SESSION_ID", "sess-test-0001"),
        ("DSH_PROFILE", "web"),
    ]);

    match DshProcess::spawn(stub_config(free_port())).await {
        Err(ShellError::NestedSession { vars }) => {
            assert!(vars.contains("DSH_SESSION_ID"), "{vars}");
        }
        other => panic!("expected NestedSession, got {other:?}"),
    }
}

#[tokio::test]
async fn refuses_to_spawn_over_a_port_someone_owns() {
    // A second dsh cannot bind the same port; the user should be told to use
    // attach mode instead of watching a dead window.
    let _env = EnvGuard::set(&[]);
    let held = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = held.local_addr().expect("addr").port();

    match DshProcess::spawn(stub_config(port)).await {
        Err(ShellError::PortInUse { port: at, host }) => {
            assert_eq!(at, port);
            assert_eq!(host, "127.0.0.1");
        }
        other => panic!("expected PortInUse, got {other:?}"),
    }
}

#[tokio::test]
async fn attach_mode_forks_nothing_and_fails_cleanly() {
    // attach on a free port must time out with a helpful error and, crucially,
    // must not have started anything.
    let _env = EnvGuard::set(&[]);
    let port = free_port();
    let config = Config {
        launch_mode: LaunchMode::Attach,
        spawn_timeout_seconds: 1,
        ..stub_config(port)
    };

    match DshProcess::attach(config).await {
        Err(ShellError::NoAttachTarget(url)) => assert!(url.contains(&port.to_string())),
        other => panic!("expected NoAttachTarget, got {other:?}"),
    }

    // Nothing was forked, so the port is still free.
    TcpListener::bind(("127.0.0.1", port)).expect("attach mode must not occupy the port");
}

#[tokio::test]
async fn attach_mode_adopts_a_listening_dsh() {
    // A stub already on the port stands in for a dsh the operator started by
    // hand. attach must adopt it, and — this is the point — must not kill it.
    let _env = EnvGuard::set(&[]);
    let port = free_port();
    let dsh = DshProcess::spawn(stub_config(port)).await.expect("stub ready");

    let attached = DshProcess::attach(Config {
        launch_mode: LaunchMode::Attach,
        poll_interval_seconds: 0.05,
        spawn_timeout_seconds: 5,
        ..stub_config(port)
    })
    .await
    .expect("attach to the running stub");

    assert!(attached.url().contains(&format!("127.0.0.1:{port}")));
    assert_eq!(attached.pid(), None, "attach owns no child process");

    // Shutting the shell down must leave the adopted dsh running: it is not ours.
    attached.shutdown().await;
    assert!(
        dsh.pid().is_some(),
        "the original process object must still be usable"
    );
    dsh.shutdown().await;
    TcpListener::bind(("127.0.0.1", port)).expect("port freed once the owner exits");
}
