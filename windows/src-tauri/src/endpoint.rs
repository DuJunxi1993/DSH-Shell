//! Endpoint resolution: dsh's stdout → the URL the WebView must load.
//!
//! # Why this file is so picky
//!
//! `dsh web` says something useful exactly once, on **stdout**, and only after
//! the plugin Loader has fully settled — which is *seconds* after the socket is
//! bound:
//!
//! ```text
//! dsh web: http://127.0.0.1:3080/?token=<launchToken>
//! ```
//!
//! Three facts from dsh's own source drive the whole design:
//!
//! 1. `dsh-web-app/lib/index.js` prints that line with `console.log`, i.e.
//!    stdout. It also prints, on **stderr**, lines that contain loopback URLs
//!    which are *not* the UI — `bili: attaching to running proxy at
//!    http://127.0.0.1:18787` is dsh's internal HTTP proxy. An earlier version
//!    of this file scanned both streams with one loose loopback regex and
//!    returned that proxy port; the app then pointed its WebView at a proxy.
//! 2. `dsh-client-connection`'s `authorizeIndex` answers **401** to any request
//!    carrying neither a valid `?token=` query nor a `dsh-auth-` cookie. A
//!    "the port answers, therefore use `http://host:port/`" fallback can never
//!    load the SPA, so a tokenless URL is never acceptable here.
//! 3. The token is minted per dsh process, so a URL captured from an earlier
//!    dsh is worthless — resolve once, against the child we just spawned.
//!
//! So: parse the `dsh web:` prefix, demand loopback, demand our own port, and
//! demand the token. The port probe is demoted to a log line because "the
//! socket is listening" and "the UI is reachable" are different facts.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use regex::Regex;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdout};
use tokio::sync::mpsc;
use url::Url;

use crate::error::{Result, ShellError};

/// The only line we accept, in any of the shapes dsh has used.
static URL_LINE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)^\s*dsh\s+web\s*:\s*(?P<url>\S+)").expect("url line regex"));

/// How many of dsh's output lines to keep for the error message.
const TAIL_LINES: usize = 40;

/// Rolling capture of dsh's output, so a failure can explain itself.
#[derive(Debug, Clone, Default)]
pub struct OutputTail(Arc<Mutex<VecDeque<String>>>);

impl OutputTail {
    fn push(&self, line: &str) {
        let line = line.trim_end();
        if line.is_empty() {
            return;
        }
        if let Ok(mut q) = self.0.lock() {
            if q.len() == TAIL_LINES {
                q.pop_front();
            }
            q.push_back(line.to_string());
        }
    }

    /// Newest-last rendering for an error message, oldest first.
    pub fn snapshot(&self) -> String {
        match self.0.lock() {
            Ok(q) if q.is_empty() => "(dsh printed nothing)".to_string(),
            Ok(q) => q.iter().cloned().collect::<Vec<_>>().join("\n"),
            Err(_) => "(output unavailable)".to_string(),
        }
    }
}

/// Extract a loadable endpoint from one line of dsh output.
///
/// Returns `None` for anything that is not *our* authenticated UI URL: other
/// loopback ports (the `bili` proxy), remote hosts, mismatched ports, and
/// tokenless URLs (which dsh would answer with 401).
pub fn endpoint_from_line(line: &str, expected_port: u16) -> Option<String> {
    let captures = URL_LINE.captures(line.trim())?;
    let url = Url::parse(captures.name("url")?.as_str()).ok()?;

    match url.host_str() {
        Some("127.0.0.1" | "localhost" | "::1" | "[::1]") => {}
        _ => return None,
    }

    // The port we asked for is the port we must load. `expected_port == 0` means
    // "let the OS pick", in which case any loopback port is fair game.
    if expected_port != 0 && url.port() != Some(expected_port) {
        return None;
    }

    // Mandatory. Without it dsh answers 401 and the SPA never loads.
    let token = url
        .query_pairs()
        .find(|(key, _)| key == "token")
        .map(|(_, value)| value.into_owned())?;
    if token.is_empty() {
        return None;
    }

    Some(url.to_string())
}

/// Watch dsh until it prints an authenticated URL, it dies, or we time out.
///
/// Both pipes are consumed and mirrored into `tracing`, because dsh's output is
/// the only diagnostic a console-less release build has. The scanner tasks are
/// always aborted before returning, so a resolved shell does not leak a reader
/// per pipe.
pub async fn resolve(
    child: &mut Child,
    stdout: Option<ChildStdout>,
    stderr: Option<ChildStderr>,
    host: &str,
    port: u16,
    timeout: Duration,
    poll_interval: Duration,
) -> Result<String> {
    let tail = OutputTail::default();
    let (found_tx, mut found_rx) = mpsc::unbounded_channel::<String>();

    let mut readers: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    if let Some(stdout) = stdout {
        let (tx, tail) = (found_tx.clone(), tail.clone());
        readers.push(tokio::spawn(async move {
            for_each_line(stdout, |line| {
                tracing::info!(target: "dsh_shell::dsh", "{line}");
                tail.push(line);
                if let Some(url) = endpoint_from_line(line, port) {
                    let _ = tx.send(url);
                }
            })
            .await;
        }));
    }

    if let Some(stderr) = stderr {
        let tail = tail.clone();
        readers.push(tokio::spawn(async move {
            // Not a URL source: dsh logs unrelated loopback URLs here. Logged
            // only, because it is the first place a real fault shows up.
            for_each_line(stderr, |line| {
                tracing::info!(target: "dsh_shell::dsh", "[stderr] {line}");
                tail.push(line);
            })
            .await;
        }));
    }

    let result = wait_for_endpoint(child, &mut found_rx, host, port, timeout, poll_interval, &tail)
        .await;

    for reader in readers {
        reader.abort();
    }

    result
}

#[allow(clippy::too_many_arguments)]
async fn wait_for_endpoint(
    child: &mut Child,
    found_rx: &mut mpsc::UnboundedReceiver<String>,
    host: &str,
    port: u16,
    timeout: Duration,
    poll_interval: Duration,
    tail: &OutputTail,
) -> Result<String> {
    let probe_url = format!("http://{host}:{port}/");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(750))
        .build()
        .map_err(ShellError::HttpClient)?;

    let deadline = Instant::now() + timeout;
    let mut announced_listening = false;

    loop {
        if let Ok(url) = found_rx.try_recv() {
            tracing::info!(target: "dsh_shell", "resolved dsh endpoint: {url}");
            return Ok(url);
        }

        if let Some(status) = child.try_wait()? {
            return Err(ShellError::DshExitedBeforeReady {
                code: status.code(),
                tail: tail.snapshot(),
            });
        }

        if !announced_listening && port != 0 {
            // Any answer at all — including the 401 from the auth fence — means
            // dsh's web server is up. It is *not* the endpoint: keep waiting
            // for the line that carries the token.
            if let Ok(response) = client.get(&probe_url).send().await {
                tracing::info!(
                    target: "dsh_shell",
                    "port {port} is listening ({}); waiting for the authenticated URL line",
                    response.status()
                );
                announced_listening = true;
            }
        }

        if Instant::now() >= deadline {
            return Err(ShellError::EndpointTimeout {
                host: host.to_string(),
                port,
                waited: timeout,
                tail: tail.snapshot(),
            });
        }

        tokio::time::sleep(poll_interval).await;
    }
}

async fn for_each_line<R, F>(reader: R, mut handle: F)
where
    R: tokio::io::AsyncRead + Unpin,
    F: FnMut(&str),
{
    let mut lines = BufReader::new(reader).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => handle(&line),
            Ok(None) | Err(_) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PORT: u16 = 3080;

    #[test]
    fn accepts_the_canonical_dsh_web_line() {
        let url = endpoint_from_line("dsh web: http://127.0.0.1:3080/?token=abc123", PORT)
            .expect("must accept");
        assert_eq!(url, "http://127.0.0.1:3080/?token=abc123");
    }

    #[test]
    fn accepts_a_lan_suffix() {
        let line = "dsh web: http://127.0.0.1:3080/?token=abc123 (LAN: http://192.168.1.5:3080/?token=abc123)";
        let url = endpoint_from_line(line, PORT).expect("must accept");
        assert_eq!(url, "http://127.0.0.1:3080/?token=abc123");
    }

    #[test]
    fn rejects_the_bili_proxy_decoy() {
        // This is the line the shipped build actually matched. It is dsh's
        // internal HTTP proxy, not the UI, and it has no token.
        let line = "bili: attaching to running proxy at http://127.0.0.1:18787 (pid 24028)";
        assert_eq!(endpoint_from_line(line, PORT), None);
    }

    #[test]
    fn rejects_a_dsh_web_line_without_a_token() {
        // dsh answers 401 to this; loading it would show the user a blank page.
        assert_eq!(endpoint_from_line("dsh web: http://127.0.0.1:3080/", PORT), None);
    }

    #[test]
    fn rejects_a_tokenless_url_on_another_port() {
        assert_eq!(endpoint_from_line("dsh web: http://127.0.0.1:9999/?token=x", PORT), None);
    }

    #[test]
    fn rejects_an_empty_token() {
        assert_eq!(endpoint_from_line("dsh web: http://127.0.0.1:3080/?token=", PORT), None);
    }

    #[test]
    fn rejects_a_remote_host_even_with_a_token() {
        assert_eq!(
            endpoint_from_line("dsh web: http://evil.example.com:3080/?token=x", PORT),
            None
        );
    }

    #[test]
    fn rejects_unrelated_chatter() {
        for line in [
            "starting up on port 3080",
            "opening the default browser; pass --no-open to disable",
            "dsh web: not-a-url",
            "dsh-web: http://127.0.0.1:3080/?token=x", // hyphen is a different tool
        ] {
            assert_eq!(endpoint_from_line(line, PORT), None, "should reject: {line}");
        }
    }

    #[test]
    fn accepts_any_port_when_the_os_picks_one() {
        let url = endpoint_from_line("dsh web: http://127.0.0.1:51234/?token=x", 0)
            .expect("port 0 means any port");
        assert_eq!(url, "http://127.0.0.1:51234/?token=x");
    }

    #[test]
    fn accepts_localhost_and_ipv6_loopback() {
        assert!(endpoint_from_line("dsh web: http://localhost:3080/?token=x", PORT).is_some());
        assert!(endpoint_from_line("dsh web: http://[::1]:3080/?token=x", PORT).is_some());
    }

    #[test]
    fn tail_keeps_only_the_newest_lines() {
        let tail = OutputTail::default();
        for i in 0..(TAIL_LINES + 10) {
            tail.push(&format!("line {i}"));
        }
        let snapshot = tail.snapshot();
        assert_eq!(snapshot.lines().count(), TAIL_LINES);
        assert!(snapshot.starts_with("line 10\n"), "{snapshot}");
        assert!(snapshot.ends_with(&format!("line {}", TAIL_LINES + 9)), "{snapshot}");
    }

    #[test]
    fn tail_reports_silence_explicitly() {
        assert_eq!(OutputTail::default().snapshot(), "(dsh printed nothing)");
    }
}
