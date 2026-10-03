//! `stub-dsh` — a test double for `dsh web`. **Never shipped, never real.**
//!
//! It exists so the whole spawn → resolve → shutdown pipeline can be exercised
//! without booting a harness. See `AGENTS.md` rule 2: automated tests must not
//! start the real dsh.
//!
//! It reproduces the parts of dsh that `endpoint.rs` has to cope with:
//!
//! * the `dsh web: http://host:port/?token=…` line on **stdout**,
//! * the 401 auth fence for any request without that token,
//! * the `bili: attaching to running proxy at http://127.0.0.1:18787` decoy on
//!   **stderr** that the shipped build mistook for the UI,
//! * a token that is per-process, so a stale URL is rejected.
//!
//! Knobs, all optional:
//!
//! | Env var | Meaning | Default |
//! |---|---|---|
//! | `STUB_MODE`       | `ok` \| `no-url-line` \| `tokenless` \| `die-early` | `ok` |
//! | `STUB_URL_DELAY_MS` | delay before printing the URL line | 250 |
//! | `STUB_TOKEN`      | the token to hand out | `stub-token` |
//! | `STUB_LIFETIME_MS`| hard self-exit so a failed test cannot leak a process | 120000 |

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

const DECOY: &str = "bili: attaching to running proxy at http://127.0.0.1:18787 (pid 4242)";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let host = flag(&args, "--host").unwrap_or_else(|| "127.0.0.1".to_string());
    let port: u16 = flag(&args, "--port")
        .and_then(|raw| raw.parse().ok())
        .unwrap_or_default();

    let mode = env("STUB_MODE", "ok");
    let token = env("STUB_TOKEN", "stub-token");
    let url_delay: u64 = env("STUB_URL_DELAY_MS", "250").parse().unwrap_or(250);
    let lifetime: u64 = env("STUB_LIFETIME_MS", "120000").parse().unwrap_or(120_000);

    let stderr = std::io::stderr();
    let mut stderr = stderr.lock();

    if mode == "die-early" {
        let _ = writeln!(stderr, "{DECOY}");
        let _ = writeln!(stderr, "web-app: could not resolve the frontend dist: boom");
        let _ = stderr.flush();
        std::process::exit(3);
    }

    let listener = match TcpListener::bind((host.as_str(), port)) {
        Ok(listener) => listener,
        Err(err) => {
            let _ = writeln!(stderr, "stub-dsh: cannot bind {host}:{port}: {err}");
            std::process::exit(4);
        }
    };
    let bound = listener.local_addr().expect("local addr").port();

    let _ = writeln!(stderr, "{DECOY}");
    let _ = writeln!(stderr, "web-app: composed profile 'web' in 3.10s");
    let _ = stderr.flush();

    let authority = format!("{host}:{bound}");
    let server_token = token.clone();
    let server_authority = authority.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { break };
            let token = server_token.clone();
            let authority = server_authority.clone();
            std::thread::spawn(move || serve(stream, &authority, &token));
        }
    });

    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    match mode.as_str() {
        "no-url-line" => {
            // Bound and quiet: dsh never gets far enough to announce itself.
        }
        "tokenless" => {
            let _ = writeln!(stdout, "dsh web: http://{authority}/");
            let _ = stdout.flush();
        }
        _ => {
            std::thread::sleep(Duration::from_millis(url_delay));
            let _ = writeln!(stdout, "dsh web: http://{authority}/?token={token}");
            let _ = stdout.flush();
        }
    }
    drop(stdout);

    // Hold the port until we are killed, with a ceiling so a leaked test child
    // cannot outlive the test run. There is no stdin handshake on purpose: the
    // shell spawns us with a null stdin, which is immediately at EOF.
    let deadline = std::time::Instant::now() + Duration::from_millis(lifetime);
    while std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    std::process::exit(0);
}

fn serve(mut stream: TcpStream, expected_authority: &str, token: &str) {
    let Ok(peer) = stream.try_clone() else { return };
    let mut reader = BufReader::new(peer);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() || request_line.is_empty() {
        return;
    }
    // Drain headers so the client never sees a reset mid-response.
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap_or(0) > 2 {
        line.clear();
    }

    let authorized = request_has_valid_token(&request_line, expected_authority, token);
    let (status, body) = if authorized {
        (
            "200 OK",
            format!("<!doctype html><title>stub dsh</title><p>token accepted: {request_line}"),
        )
    } else {
        ("401 Unauthorized", "unauthorized".to_string())
    };

    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

/// Mirror dsh's fence: a `?token=` query on *our* authority, with the
/// process-local token, is the only way in. A token from another stub process
/// is rejected, exactly as a stale URL from a previous dsh is.
fn request_has_valid_token(request_line: &str, authority: &str, token: &str) -> bool {
    let Some((path, _)) = request_line.split_once(' ') else {
        return false;
    };
    if !path.starts_with('/') {
        return false;
    }
    let (path, query) = match path.split_once('?') {
        Some((path, query)) => (path, query),
        None => (path, ""),
    };
    if !authority.contains(path.trim_end_matches('/')) && !path.trim_end_matches('/').is_empty() {
        return false;
    }
    query.split('&').any(|pair| pair == format!("token={token}"))
}

fn flag(args: &[String], name: &str) -> Option<String> {
    let at = args.iter().position(|arg| arg == name)?;
    args.get(at + 1).cloned()
}

fn env(key: &str, fallback: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| fallback.to_string())
}
