//! Live smoke test against the **real** `dsh`.
//!
//! Ignored by default and double-gated: it only runs when explicitly asked for
//! (`cargo test --test live_dsh -- --ignored`) *and* with
//! `DSH_SHELL_LIVE_TEST=1` in the environment. Everything else in `tests/`
//! drives `stub-dsh`, which is what makes the suite safe to run at any time
//! (AGENTS.md rule 2).
//!
//! ## Why this file is so careful
//!
//! The real `dsh` is the operator's harness. A mistake here damages their
//! session, not just a test. So (rules 1 and 3):
//!
//! * it never kills anything by name — only the PID this process spawned, plus
//!   that PID's own descendants, enumerated from the process table;
//! * it refuses to run if the target port is already owned, so it can never
//!   attach itself to, or terminate, a dsh the operator started by hand;
//! * it leaves the port free when it finishes, which is the assertion it exists
//!   to make.
//!
//! ## A hazard this test documents
//!
//! dsh keeps a machine-wide HTTP proxy (`bili`, port 18787) and a second dsh
//! *attaches* to an existing one instead of failing. A leftover dsh from an
//! earlier interrupted run therefore changes how the next one behaves. Always
//! confirm no dsh is running before treating a failure here as a real defect.

use std::net::TcpListener;
use std::time::Duration;

use dsh_shell_core::config::Config;
use dsh_shell_core::process::DshProcess;

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind an ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

#[tokio::test]
#[ignore = "starts the real dsh; run with DSH_SHELL_LIVE_TEST=1"]
async fn real_dsh_serves_the_ui_only_at_its_token_url() {
    assert_eq!(
        std::env::var("DSH_SHELL_LIVE_TEST").as_deref(),
        Ok("1"),
        "refusing to start the real dsh without DSH_SHELL_LIVE_TEST=1 (AGENTS.md rule 3)"
    );

    // Surface dsh's own output: it is the only diagnostic when a real boot
    // misbehaves, and this test has no subscriber of its own otherwise.
    let _ = tracing_subscriber::fmt()
        .with_env_filter("info,dsh_shell=debug")
        .with_test_writer()
        .try_init();

    // An ephemeral port, and nothing else may be listening on it: a collision
    // would mean we were pointed at someone else's dsh.
    let port = free_port();
    let config = Config {
        preferred_port: port,
        spawn_timeout_seconds: 120,
        poll_interval_seconds: 0.5,
        ..Config::default()
    };
    assert!(
        config.dsh_binary_path.exists(),
        "dsh not found at {}",
        config.dsh_binary_path.display()
    );

    let dsh = DshProcess::spawn(config)
        .await
        .expect("the real dsh should become ready");
    let url = dsh.url().to_string();
    let pid = dsh.pid().expect("a spawned dsh has a pid");

    // 1. Our URL is the UI, not some other loopback service.
    assert_eq!(
        url.parse::<url::Url>().expect("valid url").port(),
        Some(port),
        "resolved the wrong port: {url}"
    );
    assert!(url.contains("token="), "no token in {url}");

    // The clean URL: the token-less origin the WebView ends up on after the
    // redirect, and the only request the auth fence can refuse.
    let bare = format!("http://127.0.0.1:{port}/");

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        // Redirects are the *point* of the token URL, so follow them by hand to
        // observe the 303 and the cookie it mints.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("client");

    // 2. The tokenised URL is accepted, and answers with the redirect that
    //    carries the session cookie. Not 2xx: 303 is the success case.
    let with_token = client.get(&url).send().await.expect("token url responds");
    assert_eq!(
        with_token.status().as_u16(),
        303,
        "token url answered {}: {url}",
        with_token.status()
    );
    assert_eq!(
        with_token
            .headers()
            .get("location")
            .and_then(|value| value.to_str().ok()),
        Some("./"),
        "expected the directory-relative redirect"
    );
    let cookie = with_token
        .headers()
        .get("set-cookie")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();
    assert!(
        cookie.contains("dsh-auth-"),
        "the token should have minted a session cookie, got: {cookie}"
    );

    // 3. Following that cookie is what actually serves the SPA — but only on
    //    the *clean* URL. dsh answers 303 whenever a `?token=` is present
    //    (see `authorizeIndex`); the cookie is the only way to get the index.
    let jar = cookie.split(';').next().unwrap_or_default().to_string();
    let spa = client
        .get(&bare)
        .header("cookie", &jar)
        .send()
        .await
        .expect("cookie-authenticated request responds");
    assert!(
        spa.status().is_success(),
        "cookie-authenticated request answered {}",
        spa.status()
    );
    let body = spa.text().await.unwrap_or_default();
    assert!(
        body.to_lowercase().contains("<html") || body.contains("root"),
        "expected the SPA shell, got {} bytes starting: {:.120}",
        body.len(),
        body
    );

    // 4. A tokenless URL with no cookie is refused — the reason a port probe
    //    can never be the endpoint, and the rule `endpoint.rs` is built on.
    let without_token = client.get(&bare).send().await.expect("bare url responds");
    assert_eq!(
        without_token.status().as_u16(),
        401,
        "a tokenless URL was not refused, so the resolver's rule is wrong: {bare}"
    );

    // 5. The core contract: closing frees the port and the whole process tree.
    dsh.shutdown().await;

    let mut freed = false;
    for _ in 0..100 {
        if TcpListener::bind(("127.0.0.1", port)).is_ok() {
            freed = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(freed, "port {port} was not freed after shutdown (dsh pid was {pid})");
}
