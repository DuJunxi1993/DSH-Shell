//! Endpoint resolution: parse `dsh web: http://...` from stdout, fall back to port probe.

use crate::error::ShellError;
use regex::Regex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStdout};

/// Loopback URL pattern: `http(s)?://127.0.0.1:NNNN/` or `http(s)?://localhost:NNNN/`.
/// We accept loopback hosts only — dsh explicitly refuses to bind 0.0.0.0.
fn url_regex() -> &'static Regex {
    use once_cell::sync::Lazy;
    static RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d{1,5}/")
            .expect("url regex must compile")
    });
}

/// Try to resolve the dsh endpoint by reading stdout for a URL line, with a port-probe fallback.
///
/// Strategy:
/// 1. Concurrently read stdout line-by-line looking for `http://127.0.0.1:PORT/`.
/// 2. In parallel, if `port != 0`, poll `http://127.0.0.1:{port}/` until 200/302/303.
/// 3. The first to succeed wins. Stdout reading is bounded by `spawn_timeout`.
pub async fn resolve(
    child: &mut Child,
    stdout: Option<ChildStdout>,
    host: &str,
    port: u16,
    spawn_timeout: Duration,
    poll_interval: Duration,
) -> Result<String, ShellError> {
    // Take stdout by reference so the caller can still own the Child.
    let url_from_stdout = if let Some(stdout) = stdout {
        let task = tokio::spawn(read_url_from_stdout(stdout));
        Some(task)
    } else {
        None
    };

    let probe_fut = async {
        if port == 0 {
            // Port-assigned mode: we must rely on stdout only.
            return None;
        }
        let probe_url = format!("http://{}:{}/", host, port);
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(ShellError::HttpClient)?;
        let deadline = Instant::now() + spawn_timeout;
        loop {
            if Instant::now() >= deadline {
                return None;
            }
            match client.get(&probe_url).send().await {
                Ok(resp) if resp.status().is_success() || resp.status().is_redirection() => {
                    return Some(probe_url);
                }
                _ => {
                    tokio::time::sleep(poll_interval).await;
                }
            }
        }
    };

    // Race the two strategies.
    let probe_task = tokio::spawn(probe_fut);

    let timeout_at = Instant::now() + spawn_timeout;
    loop {
        if let Some(task) = &url_from_stdout {
            if task.is_finished() {
                match task.await {
                    Ok(Some(url)) => return Ok(url),
                    Ok(None) => {
                        // Reader ended without a URL line; fall back to probe only.
                    }
                    Err(_) => {
                        // JoinError: treat as no-stdout.
                    }
                }
            }
        }
        if probe_task.is_finished() {
            if let Ok(Some(url)) = probe_task.await {
                return Ok(url);
            }
        }
        if Instant::now() >= timeout_at {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // Final fallback: ask the probe task once more.
    if let Ok(Some(url)) = probe_task.await {
        return Ok(url);
    }

    Err(ShellError::EndpointTimeout {
        host: host.to_string(),
        port,
        waited: spawn_timeout,
    })
}

async fn read_url_from_stdout(stdout: ChildStdout) -> Option<String> {
    let mut lines = BufReader::new(stdout).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        tracing::debug!(target: "dsh_shell", "stdout: {}", line);
        if let Some(mat) = url_regex().find(&line) {
            return Some(mat.as_str().to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_regex_matches_canonical_dsh_url() {
        let s = "dsh web: http://127.0.0.1:34247/";
        let m = url_regex().find(s).expect("must match");
        assert_eq!(m.as_str(), "http://127.0.0.1:34247/");
    }

    #[test]
    fn url_regex_matches_ipv6_loopback() {
        let s = "dsh web: http://[::1]:34247/";
        let m = url_regex().find(s).expect("must match");
        assert_eq!(m.as_str(), "http://[::1]:34247/");
    }

    #[test]
    fn url_regex_ignores_non_loopback_hosts() {
        // dsh policy refuses to bind 0.0.0.0; we should not match.
        let s = "dsh web: http://example.com:34247/";
        assert!(url_regex().find(s).is_none());
    }

    #[test]
    fn url_regex_ignores_non_url_garbage() {
        let s = "opening the default browser; pass --no-open to disable";
        assert!(url_regex().find(s).is_none());
    }

    #[test]
    fn url_regex_works_even_without_dsh_prefix() {
        // Defensive: if dsh renames the prefix line, we still find the URL.
        let s = "weird prefix http://127.0.0.1:12345/some/path more text";
        let m = url_regex().find(s).expect("must match");
        assert_eq!(m.as_str(), "http://127.0.0.1:12345/");
    }
}
