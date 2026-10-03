//! Deciding what the webview may navigate to.
//!
//! The window has exactly one job: show dsh. Anything that would take it
//! somewhere else — a link, a server-side redirect, `target="_blank"` — has to go
//! to the system browser instead, or the app silently becomes someone else's
//! website with no title bar, no tray and no way back.
//!
//! Kept separate from the Tauri wiring and free of side effects so it can be
//! tested directly: a false *deny* here is a blank window, which is the failure
//! that matters.

use url::Url;

/// May the webview navigate to `url`?
///
/// Allowed: the app's own origin, which serves the boot placeholder, and the
/// dsh origin once it is known. `dsh_origin` is `scheme://host:port` and is
/// empty until dsh has resolved, because before that nothing off the app's own
/// origin can be the page we are meant to be showing.
pub fn is_internal(url: &Url, dsh_origin: &str) -> bool {
    if is_app_origin(url) {
        return true;
    }
    if dsh_origin.is_empty() {
        return false;
    }
    // Compared as origins, not as string prefixes: `http://127.0.0.1:1` must not
    // match `http://127.0.0.1:12`, and a path or query on the dsh origin is
    // still the dsh origin.
    url.origin().ascii_serialization() == dsh_origin
}

/// Is this a URL of ours? Tauri's own protocol serves the placeholder, and the
/// chrome script runs on it.
fn is_app_origin(url: &Url) -> bool {
    url.scheme() == "tauri" || url.host_str() == Some("tauri.localhost")
}

/// Is this a URL we are willing to hand to the operating system?
///
/// http(s) only. Passing anything else on would be a way to make the OS launch
/// something with this process's identity, and dsh never links those.
pub fn is_openable(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https")
}

#[cfg(test)]
mod tests {
    use super::*;

    const DSH: &str = "http://127.0.0.1:3080";

    #[test]
    fn allows_the_app_origin() {
        assert!(is_internal(&Url::parse("tauri://localhost").unwrap(), DSH));
        assert!(is_internal(&Url::parse("http://tauri.localhost/index.html").unwrap(), DSH));
        // Before dsh resolves the app's own origin is all there is.
        assert!(is_internal(&Url::parse("tauri://localhost").unwrap(), ""));
    }

    #[test]
    fn allows_dsh_itself() {
        assert!(is_internal(&Url::parse(DSH).unwrap(), DSH));
        assert!(is_internal(&Url::parse("http://127.0.0.1:3080/some/path?q=1").unwrap(), DSH));
    }

    #[test]
    fn blocks_external_sites() {
        for url in [
            "https://github.com/anthropics",
            "http://example.com/",
            // A different port on the same host is a different origin, and is
            // exactly the shape of a port-forward or a second dsh.
            "http://127.0.0.1:9999/",
            "http://127.0.0.1:3081/",
            "https://127.0.0.1:3080/",
        ] {
            assert!(
                !is_internal(&Url::parse(url).unwrap(), DSH),
                "{url} should not load in the shell"
            );
        }
    }

    #[test]
    fn blocks_everything_before_dsh_is_known() {
        // A false allow here would show an attacker-chosen page during startup,
        // before the token even exists.
        assert!(!is_internal(&Url::parse("http://127.0.0.1:3080/").unwrap(), ""));
    }

    #[test]
    fn only_http_is_handed_to_the_os() {
        for url in ["https://example.com/", "http://127.0.0.1:3080/"] {
            assert!(is_openable(&Url::parse(url).unwrap()), "{url}");
        }
        for url in [
            "file:///C:/Windows/System32/cmd.exe",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ms-settings:",
            "tauri://localhost",
        ] {
            assert!(!is_openable(&Url::parse(url).unwrap()), "{url} must not be opened");
        }
    }
}
