//! Endpoint resolution, end to end, against `stub-dsh`.
//!
//! These are the tests that would have caught every bug the shipped build had.
//! They never start a real dsh (AGENTS.md rule 2): `stub-dsh` reproduces the
//! three things `endpoint.rs` has to get right — the stdout URL line, the 401
//! auth fence, and the `bili` proxy decoy on stderr.
//!
//! Each test owns its own port, so the suite is safe to run in parallel.

use std::net::TcpListener;
use std::path::PathBuf;
use std::time::Duration;

use dsh_shell_core::config::Config;
use dsh_shell_core::error::ShellError;
use dsh_shell_core::process::DshProcess;

mod common;
use common::EnvGuard;

const TOKEN: &str = "stub-token";

fn stub_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_stub-dsh"))
}

/// A port nothing is using. Bound-then-released, so the stub's own bind cannot
/// collide with a parallel test.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind an ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

fn config_for(port: u16) -> Config {
    Config {
        dsh_binary_path: stub_binary(),
        listen_host: "127.0.0.1".to_string(),
        preferred_port: port,
        trusted_hosts: vec![],
        poll_interval_seconds: 0.05,
        spawn_timeout_seconds: 20,
        ..Config::default()
    }
}

/// Pins the stub's configuration. Every knob is set explicitly, including the
/// ones this test wants left at default, so behaviour does not depend on what a
/// sibling test did first.
fn stub_env(mode: &str, url_delay_ms: &str) -> EnvGuard {
    EnvGuard::set(&[
        ("STUB_MODE", mode),
        ("STUB_URL_DELAY_MS", url_delay_ms),
        ("STUB_TOKEN", TOKEN),
    ])
}

/// A port stays free only while the stub is not holding it. This is the
/// "close the window → the port is freed" contract in one assertion.
fn assert_port_free(port: u16) {
    TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|err| {
        panic!("port {port} is still held after shutdown: {err}");
    });
}

#[tokio::test]
async fn resolves_the_authenticated_url_from_stdout() {
    let _env = stub_env("ok", "250");
    let port = free_port();
    let dsh = DshProcess::spawn(config_for(port))
        .await
        .expect("stub should become ready");

    let url = dsh.url();
    assert!(
        url.starts_with(&format!("http://127.0.0.1:{port}/")),
        "wrong origin: {url}"
    );
    assert!(
        url.contains(&format!("token={TOKEN}")),
        "the token is mandatory: without it dsh answers 401. got {url}"
    );

    dsh.shutdown().await;
    assert_port_free(port);
}

#[tokio::test]
async fn ignores_the_bili_proxy_url_on_stderr() {
    // Regression test for the shipped bug: the resolver returned
    // http://127.0.0.1:18787 — dsh's internal HTTP proxy — and pointed the
    // WebView at it. The stub always emits that decoy line, so this test also
    // proves the happy path above is not accidental.
    let _env = stub_env("ok", "250");
    let port = free_port();
    let dsh = DshProcess::spawn(config_for(port))
        .await
        .expect("stub should become ready");

    assert!(!dsh.url().contains("18787"), "picked the proxy: {}", dsh.url());
    assert_eq!(
        dsh.url().parse::<url::Url>().expect("valid url").port(),
        Some(port)
    );

    dsh.shutdown().await;
    assert_port_free(port);
}

#[tokio::test]
async fn refuses_a_tokenless_url() {
    // dsh answers 401 to anything without ?token=, so a tokenless URL is a
    // guaranteed blank window. We must time out rather than hand it over.
    let _env = stub_env("tokenless", "250");
    let port = free_port();
    let config = Config {
        spawn_timeout_seconds: 3,
        ..config_for(port)
    };

    match DshProcess::spawn(config).await {
        Err(ShellError::EndpointTimeout { tail, .. }) => {
            assert!(tail.contains("dsh web:"), "tail should quote dsh: {tail}");
        }
        other => panic!("expected a timeout, got {other:?}"),
    }
    assert_port_free(port);
}

#[tokio::test]
async fn surfaces_an_early_exit_with_dsh_output() {
    let _env = stub_env("die-early", "250");
    let port = free_port();

    match DshProcess::spawn(config_for(port)).await {
        Err(ShellError::DshExitedBeforeReady { code, tail }) => {
            assert_eq!(code, Some(3));
            assert!(tail.contains("boom"), "tail must carry the reason: {tail}");
            assert!(tail.contains("18787"), "tail must carry the decoy: {tail}");
        }
        other => panic!("expected an early-exit error, got {other:?}"),
    }
    assert_port_free(port);
}

#[tokio::test]
async fn waits_for_a_slow_url_line_instead_of_racing_the_port() {
    // The real dsh binds its socket long before the Loader settles and the URL
    // line appears. A resolver that accepts the bare port as the endpoint loses
    // the race and shows the user a 401. Here the port is listening for 2.5s
    // before the URL shows up, and we must still return the tokenised URL.
    let _env = stub_env("ok", "2500");
    let port = free_port();
    let config = Config {
        spawn_timeout_seconds: 30,
        ..config_for(port)
    };

    let dsh = DshProcess::spawn(config)
        .await
        .expect("stub should become ready");

    assert!(dsh.url().contains(&format!("token={TOKEN}")), "{}", dsh.url());
    dsh.shutdown().await;
    assert_port_free(port);
}

#[tokio::test]
async fn times_out_when_dsh_never_announces_itself() {
    let _env = stub_env("no-url-line", "250");
    let port = free_port();
    let config = Config {
        spawn_timeout_seconds: 2,
        ..config_for(port)
    };

    match DshProcess::spawn(config).await {
        Err(ShellError::EndpointTimeout { host, port: at, tail, .. }) => {
            assert_eq!(host, "127.0.0.1");
            assert_eq!(at, port);
            // The decoy is on stderr and is *not* accepted as the endpoint, but
            // it must still be captured for diagnosis.
            assert!(tail.contains("18787"), "{tail}");
        }
        other => panic!("expected a timeout, got {other:?}"),
    }
    assert_port_free(port);
}

#[tokio::test]
async fn a_failed_start_does_not_leave_dsh_holding_the_port() {
    // Startup failure cleanup: a dsh that is up but unusable would otherwise
    // keep the port bound with no window to close it.
    let _env = stub_env("no-url-line", "250");
    let port = free_port();
    let config = Config {
        spawn_timeout_seconds: 2,
        ..config_for(port)
    };

    let _ = DshProcess::spawn(config).await;

    // The stub self-exits on a ceiling, but the shell must not depend on that.
    let mut freed = false;
    for _ in 0..20 {
        if TcpListener::bind(("127.0.0.1", port)).is_ok() {
            freed = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(freed, "port {port} was never released after a failed start");
}
