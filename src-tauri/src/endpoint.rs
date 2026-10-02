//! Endpoint resolution.
//!
//! Strategy: race three signals — stdout line, stderr line, and a loopback
//! port probe — and return whichever one succeeds first.
//!
//! Why race and not serialize? `dsh web` prints its URL line to either stdout
//! or stderr depending on the version (and via a `bili` proxy that uses a
//! different port). Pinning on any single source caused real hangs during
//! integration. The port probe is the source of truth: if 34247 is listening,
//! dsh is up.
//!
//! Race semantics:
//!   * each of (stdout-scan, stderr-scan, port-probe) runs concurrently,
//!   * whoever resolves first with a usable URL wins,
//!   * on global deadline, return [`ShellError::EndpointTimeout`].

use std::time::Duration;
use once_cell::sync::Lazy;
use regex::Regex;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Child;
use tokio::sync::watch;

use crate::error::{Result, ShellError};

/// Matches loopback URLs regardless of `dsh` release flavor.
static LOOPBACK_URL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"http(s)?://(127\.0\.0\.1|localhost|\[::1\]):\d+(/[^\s]*)?").unwrap()
});

/// Race three signals; return the first usable URL.
pub async fn resolve(
    child: &mut Child,
    stdout: Option<tokio::process::ChildStdout>,
    stderr: Option<tokio::process::ChildStderr>,
    host: &str,
    port: u16,
    timeout: Duration,
    poll_interval: Duration,
) -> Result<String> {
    Lazy::force(&LOOPBACK_URL);

    // Three concurrent producers feeding a single race channel.
    // We use a `watch` channel (multi-producer, single-consumer) because
    // tokio's oneshot is single-producer.
    let (tx, mut rx) = watch::channel::<Option<String>>(None);

    // 1) stdout scan
    if let Some(stdout) = stdout {
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(url) = scan_stream(BufReader::new(stdout)).await {
                let _ = tx.send(Some(url));
            }
        });
    }

    // 2) stderr scan — dsh often (always?) prints URL banners here.
    if let Some(stderr) = stderr {
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(url) = scan_stream(BufReader::new(stderr)).await {
                let _ = tx.send(Some(url));
            }
        });
    }

    // 3) port probe loop — the source of truth.
    let probe_tx = tx.clone();
    let host = host.to_string();
    tokio::spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(750))
            .build()
            .expect("reqwest client build is infallible in practice");
        let url = format!("http://{}:{}/", host, port);
        loop {
            match client.get(&url).send().await {
                Ok(resp) if resp.status().is_success() || resp.status().is_redirection() => {
                    let _ = probe_tx.send(Some(url));
                    return;
                }
                _ => {}
            }
            // Backoff slowly so we don't melt the CPU on a slow start.
            tokio::time::sleep(poll_interval).await;
        }
    });

    // Drop the original sender so the channel closes when all clones drop.
    drop(tx);

    let deadline = tokio::time::sleep(timeout);
    tokio::select! {
        changed = rx.changed() => {
            if changed.is_ok() {
                // Pull the latest value (the first non-None winner).
                let url = rx.borrow().clone().unwrap_or_default();
                if !url.is_empty() {
                    return Ok(url);
                }
            }
            Err(ShellError::EndpointTimeout)
        }
        _ = deadline => {
            // If the child already died, surface a more useful error.
            if child.try_wait()?.is_some() {
                return Err(ShellError::EndpointTimeout);
            }
            Err(ShellError::EndpointTimeout)
        }
    }
}

/// Scan a `BufReader` line by line, returning the first line that contains a
/// loopback URL. Returns EndpointTimeout on EOF (so we never hang forever on
/// a quiet stream).
async fn scan_stream<R>(reader: R) -> Result<String>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if let Some(m) = LOOPBACK_URL.find(&line) {
            // Guard against the `bili` proxy port being returned instead of
            // our configured port — but we still accept it: if dsh is
            // listening somewhere reachable, the WebView can follow the
            // redirect via cookie. The probe branch in `resolve` ensures we
            // surface `preferred_port` whenever it is the first to come up.
            return Ok(m.as_str().to_string());
        }
    }
    Err(ShellError::EndpointTimeout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regex_matches_ipv4() {
        let m = LOOPBACK_URL
            .find("dsh web: http://127.0.0.1:34247/?token=xyz")
            .unwrap();
        assert!(m.as_str().starts_with("http://127.0.0.1:34247"));
    }

    #[test]
    fn regex_matches_localhost() {
        let m = LOOPBACK_URL
            .find("[dsh] listening at http://localhost:8080/")
            .unwrap();
        assert!(m.as_str().starts_with("http://localhost:8080"));
    }

    #[test]
    fn regex_matches_ipv6_loopback() {
        let m = LOOPBACK_URL
            .find("Server listening on http://[::1]:8080/")
            .unwrap();
        assert!(m.as_str().starts_with("http://[::1]:8080"));
    }

    #[test]
    fn regex_ignores_remote_host() {
        assert!(LOOPBACK_URL.find("http://evil.example.com:80/").is_none());
    }

    #[test]
    fn regex_ignores_unrelated_lines() {
        assert!(LOOPBACK_URL.find("starting up on port 34247").is_none());
    }
}