# dsh-shell (Tauri)

A native desktop shell for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) web UI.

This is the Tauri 2.x port of [dsh-swiftUI](https://github.com/DuJunxi1993/dsh-swiftUI). It mirrors the macOS SwiftUI shell design 1:1 — same lifecycle model, same config schema, same "pure shell" principle — but targets **Windows** first (via WebView2), with macOS and Linux also buildable from the same Rust core.

> **Pure shell.** dsh-shell does not modify dsh, does not bundle dsh, and does not write any dsh client plugin. It talks to dsh the same way a browser does: a single HTTP/WebSocket origin on `127.0.0.1`.

## Status

| Stage | State |
|---|---|
| Rust core: `process` / `endpoint` / `config` / `platform` / `error` | ✅ |
| `spawn` mode (fork `dsh web`, capture URL, port-probe fallback) | ✅ |
| `attach` mode (probe loopback for an already-running dsh) | ✅ |
| Graceful shutdown (`start_kill` → 5 s → `kill` → `wait`) | ✅ |
| Tauri 2.x window + WebView2 load of dsh URL | ✅ |
| Platform CSS injection (Windows / macOS / Linux) | ✅ |
| Anti-nest self-protection (kill-loop guard) | ✅ (env-gated, off unless `DSH_SHELL_CHILD=1` is already set in the parent environment) |
| Unit tests for core (URL regex, command builder, config round-trip) | ✅ |
| `cargo build --release` clean (0 warning / 0 error) | ✅ |
| `cargo test` clean (19/19 unit + integration) | ✅ |
| `cargo clippy -- -D warnings` clean | ✅ |
| `.msi` / `.nsis` bundle | ⏳ Run `npm run build` |
| App icon (placeholder teal "D"), transparent titlebar, status badge | ⏳ Roadmap only |

## Requirements

- **Windows 10+ with WebView2 Runtime** (preinstalled on Windows 11)
- **Rust 1.77+** (`rustup update stable`)
- **Node.js 18+** (only needed for `npm run build` to package)
- A working **dsh** install — `dsh --version` should print a version.
  ```powershell
  npm install -g @deepseek-ai/dsh
  ```

## Building

```powershell
cd D:\Development\DSH-Shell
npm install                  # one-time
npm run build                # produces .msi / .nsis in src-tauri\target\release\bundle
```

For dev:

```powershell
npm run dev
```

## Configuration

Settings live at `%APPDATA%\deepseek\dsh-shell\config\settings.json`. Defaults:

```json
{
  "dsh_binary_path": "C:\\Users\\<you>\\AppData\\Roaming\\npm\\dsh.cmd",
  "launch_mode": "spawn",
  "listen_host": "127.0.0.1",
  "preferred_port": 34247,
  "trusted_hosts": ["127.0.0.1", "localhost"],
  "poll_interval_seconds": 0.5,
  "spawn_timeout_seconds": 60,
  "auto_restart_on_crash": true
}
```

| Field | Meaning |
|---|---|
| `dsh_binary_path` | Absolute path to the `dsh` executable. |
| `launch_mode` | `spawn` → fork `dsh web` ourselves; `attach` → only connect to an already-running instance. |
| `listen_host` | Loopback host passed to `dsh web --host`. `0.0.0.0` is **not** supported (mirrors dsh's own policy). |
| `preferred_port` | Fixed port forwarded to `dsh web --port`. `0` → OS-assigned (URL-line-only startup). |
| `trusted_hosts` | Hosts appended to `dsh web --trusted-host` (repeatable). |
| `spawn_timeout_seconds` | How long to wait for the `dsh web:` URL line on stdout before probing the fixed port as a fallback. |
| `auto_restart_on_crash` | Reserved for future use; current binary exits on crash to keep shutdown semantics simple. |

The shell forwards no working directory to `dsh web` — the dsh SPA picks its own workspace inside the browser UI.

## Lifecycle

```
+-----------+   fork    +----------+    http   +-----------+
| DSHShell  | --------▶ | dsh web  | --------▶ | WebView2  |
| (Tauri)   |           | (child)  |           | + DSH SPA |
+-----------+           +----------+           +-----------+
       │                      │
       │  window close        │  crash
       ▼                      ▼
   shutdownBlocking      window stays blank,
   SIGTERM-equivalent    user closes app,
   → 5s → SIGKILL        shell reaps child
```

- On launch the app forks `dsh web`, captures the `dsh web: http://127.0.0.1:NNNN/` line, and points the WebView at it.
- On window close the `WindowEvent::CloseRequested` handler synchronously terminates dsh before the window is destroyed.

## Diagnostics

```powershell
$env:RUST_LOG = "info,dsh_shell=debug"
npm run dev
```

Logs flow through the `tracing` crate to stderr.

## Anti-nest protection

`DshProcess::spawn` refuses to fork `dsh` when the environment variable `DSH_SHELL_CHILD=1` is already set. This guard is **passive** — it does not set the variable on its own — and only fires if a parent `dsh` instance explicitly propagated that variable when spawning us. In normal use the variable is unset and the guard is a no-op. The guard exists so a future dsh feature (e.g. a child-shell escape hatch) cannot accidentally trigger a kill cascade.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md).

## Manual verification checklist

The agent that built this shell cannot run `cargo tauri dev` or `cargo run` itself (it would be detected as nested), so the human operator must verify on a clean shell. Run from an **elevated PowerShell** that does **not** have `DSH_SHELL_CHILD` set:

```powershell
$env:DSH_SHELL_CHILD = $null   # ensure clean env
Set-Location D:\Development\DSH-Shell\src-tauri
cargo test --release           # 19/19 must be green
cargo clippy --release --all-targets -- -D warnings
cargo build --release
.\target\release\dsh-shell.exe # opens WebView2 window pointed at dsh
```

Expected behavior:

1. A WebView2 window titled "DSH Shell — dsh @ 127.0.0.1" appears.
2. The dsh SPA loads (the token URL is consumed in-process via cookie).
4. Within 1 s of closing the window, `dsh` exits and port 34247 is freed (verify with `Get-NetTCPConnection -LocalPort 34247`).

If any step fails, capture stderr (`2> err.log`) and file an issue with the log attached.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

MIT. See [`LICENSE`](LICENSE).
