# Architecture

## Layered view

```
┌────────────────────────────────────────────────────────┐
│ UI layer                                               │
│  └─ Tauri window (WebView2 on Windows)                 │
│       ├─ loads DSH SPA URL                             │
│       └─ eval(platform_adapt.css) after page load      │
└────────────────────────────────────────────────────────┘
                       ▲
                       │ webview_url
                       │
┌────────────────────────────────────────────────────────┐
│ dsh_shell_core (Rust, platform-agnostic)               │
│                                                        │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │ config.rs  │  │endpoint.rs │  │process.rs  │        │
│  │ JSON load  │  │ URL regex  │  │ spawn/     │        │
│  │ JSON save  │  │ port probe │  │ attach     │        │
│  └────────────┘  └────────────┘  └────────────┘        │
│                                                        │
│  ┌────────────┐  ┌────────────┐                        │
│  │ platform.rs│  │  error.rs  │                        │
│  │ POSIX/Win  │  │ ShellError │                        │
│  └────────────┘  └────────────┘                        │
└────────────────────────────────────────────────────────┘
                       ▲
                       │ cfg(target_os = "...")
                       │
┌────────────────────────────────────────────────────────┐
│ Platform layer                                         │
│  ├─ Windows: tokio::process::Child + TerminateProcess  │
│  ├─ macOS:   tokio::process::Child + killpg(SIGTERM)   │
│  └─ Linux:   tokio::process::Child + killpg(SIGTERM)   │
└────────────────────────────────────────────────────────┘
                       ▲
                       │ stdout pipe + signal
                       │
                  ┌────────────┐
                  │   dsh web  │  (external process)
                  └────────────┘
```

## Process model

The shell **owns** dsh for the lifetime of the Tauri window. There is exactly one child process at a time. Two launch modes are supported:

- **`spawn`** (default): the shell forks `dsh web --no-open --host 127.0.0.1 --port 34247 ...`. The first of `stdout URL line` or `port probe` to succeed defines the endpoint URL. The window only opens after this URL is known.
- **`attach`**: the shell never forks dsh. It probes `http://127.0.0.1:34247/` until 200/302/303. If nothing answers within `spawn_timeout_seconds`, the shell exits with `NoAttachTarget`.

Both modes share the same `DshProcess` type so the shutdown path is identical.

## dsh integration boundary

- The shell **only** speaks HTTP and WebSocket to dsh.
- The shell **never** depends on `dsh web:` stdout prefixes or any other CLI output shape — the URL regex matches any `http(s)://(127.0.0.1|localhost|[::1]):NNNN/` substring.
- The shell **never** imports a dsh client plugin.

This makes the shell robust to upstream renaming of log lines, additional flags, and new plugins. The shell would still work if dsh renamed its package tomorrow — as long as the binary path resolves and the loopback HTTP port is reachable.

## Anti-nest guard

`main()` sets `DSH_SHELL_CHILD=1` on itself before any dsh interaction. `DshProcess::spawn` refuses to run when this variable is set, so even if dsh ever tried to spawn another shell the cascade would stop at depth 2.

## Shutdown contract

`WindowEvent::CloseRequested` runs `DshProcess::shutdown`, which on Windows is:

1. `child.start_kill()` — best-effort polite termination.
2. Wait up to 5 s for the child to exit.
3. `child.kill()` — hard terminate.
4. `child.wait()` — reap the zombie.

`start_kill` + `kill` are both `tokio::process::Child` operations; their behavior on Windows maps to `TerminateProcess`, on POSIX to signal delivery to the process group. The 5-second grace period matches `dsh-swiftUI`'s SIGTERM escalation.

## App Sandbox stance

The Tauri app does not enable code-signing or sandboxing by default. To match dsh-swiftUI's "Sign to Run Locally" stance, the bundle is ad-hoc signed. Add a real signing identity before shipping.

## Files

| Path | Purpose |
|---|---|
| `src-tauri/Cargo.toml` | Rust deps + binary target |
| `src-tauri/tauri.conf.json` | Window + bundle + CSP |
| `src-tauri/src/main.rs` | Tauri entry, lifecycle wiring |
| `src-tauri/src/lib.rs` | Re-exports for the core crate |
| `src-tauri/src/config.rs` | Settings JSON |
| `src-tauri/src/endpoint.rs` | URL resolution |
| `src-tauri/src/process.rs` | DshProcess |
| `src-tauri/src/platform.rs` | Windows/POSIX shutdown helpers |
| `src-tauri/src/error.rs` | ShellError |
| `platform_adapt.css` | Injected into the SPA at runtime |
| `scripts/verify-shutdown.ps1` | Manual verification helper |
| `src/index.html` | Boot placeholder (only shown before dsh is reachable) |
