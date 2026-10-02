# AGENTS.md — working rules for dsh-shell

## What this project is

A Tauri 2.x desktop shell for the DeepSeek Harness (`dsh`) web UI. It forks
`dsh web`, captures the authenticated URL it prints, and points a WebView2
window at it. The core contract is: **close the window → dsh dies → the port
is freed.** Nothing else in this repo matters more.

## Hard safety rules

These exist because a previous agent working on this repo destroyed its own
host process. Read them before running anything that touches processes.

1. **Never kill a process by name.** `taskkill /IM node.exe`, `Stop-Process -Name
   dsh`, and `pkill -f dsh` are forbidden. If you are running inside a `dsh`
   session, killing `node.exe` kills the harness you are running in. Only ever
   kill a PID you captured yourself, from `child.id()`.
2. **Automated tests must never boot the real `dsh`.** They use the
   `stub-dsh` bin target (`src/bin/stub-dsh.rs`) via
   `env!("CARGO_BIN_EXE_stub-dsh")`. It mimics the URL line, the 401 fence, and
   the decoy stderr banner, with no harness, no sessions, no API keys.
3. **The real `dsh web` may only be started for a manual smoke test**, and only
   after `Get-CimInstance Win32_Process` confirms which `node` PIDs existed
   beforehand. Record them, and afterwards confirm the new PID is gone by PID,
   never by name.
4. **Never set `DSH_SHELL_CHILD` (or any `DSH_*` variable) on our own child
   process.** `dsh-shell-env` scrubs ambient `DSH_*` before injecting the
   session snapshot, so writing a fake one is both useless and confusing. The
   guard in `src/preflight.rs` only *reads* the environment.

## Build and test

```powershell
Set-Location D:\Development\DSH-Shell\src-tauri
cargo test                                          # hermetic; never boots real dsh
cargo clippy --all-targets -- -D warnings
cargo build --release
```

The one test that does touch the real harness is `tests/live_dsh.rs`. It is
`#[ignore]`d *and* gated on `DSH_SHELL_LIVE_TEST=1`:

```powershell
$env:DSH_SHELL_LIVE_TEST = "1"
cargo test --test live_dsh -- --ignored --nocapture   # ~5 s, leaves nothing behind
```

Confirm no dsh is running first (rule 3), and remember that a stray dsh
attaching to the shared `bili` proxy will change the result.

`cargo-tauri` 2.11.4 is already installed, so the Node toolchain is not
required for anything:

```powershell
cargo tauri build          # -> src-tauri/target/release/bundle/{msi,nsis}
cargo tauri icon src/icon.svg
```

There is no dev server. `tauri.conf.json` declares no `devUrl` on purpose —
the window is created in `setup()` with a runtime URL, so `tauri dev` would only
ever show a blank page. Use `cargo run` for a debug build.

## Layout

| Path | Role |
|---|---|
| `src/lib.rs` | core crate root; `dsh_shell_core` |
| `src/config.rs` | `settings.json` schema, load/save, defaults |
| `src/endpoint.rs` | turns dsh's stdout into the authenticated URL |
| `src/process.rs` | `DshProcess`: spawn / attach / shutdown / tree kill |
| `src/preflight.rs` | anti-nest + port-ownership checks run before spawning |
| `src/platform.rs` | OS-specific kill primitives |
| `src/error.rs` | `ShellError` |
| `src/main.rs` | Tauri entry, window creation, exit handling |
| `src/bin/stub-dsh.rs` | test double for `dsh web` (never shipped) |
| `tests/` | integration tests, all against `stub-dsh` |

## Endpoint resolution — the thing that is easy to get wrong

`dsh web` prints exactly one useful line, on **stdout**, after the plugin
Loader has fully settled (which can be seconds after the port is bound):

```
dsh web: http://127.0.0.1:3080/?token=<launchToken>
```

Rules that follow from reading dsh's source (`dsh-web-app`, `dsh-client-connection`):

- The `?token=` query is **mandatory**. `authorizeIndex` answers `401` to any
  request that has neither a valid token query nor a `dsh-auth-` cookie, so a
  tokenless URL from a port probe can never load the SPA. Never accept one.
- A request that *has* the token always gets `303` + `Location: ./` + a
  `dsh-auth-` cookie. The index is served only on the **clean** URL with that
  cookie. A test that keeps `?token=` in the URL will loop on 303s and think it
  is broken.
- The token is per-process. A URL captured from an *earlier* dsh is worthless.
- `dsh` also prints `bili: attaching to running proxy at http://127.0.0.1:18787`
  on **stderr**. That is an internal HTTP proxy, not the UI. A loose
  "any loopback URL" regex will happily point the WebView at it — which is
  exactly the bug this repo shipped with. Match the `dsh web:` prefix and
  require the port to be the one we asked for.
- `bili` is a **machine-wide** proxy. A second dsh *attaches* to an existing one
  instead of failing, so a dsh left behind by an interrupted run silently
  changes how the next boot behaves. Check for strays before believing a live
  test failure.

## Killing the child

`dsh_binary_path` is a `.cmd` shim, so on Windows we spawn `cmd.exe` and the
harness is a **grandchild** `node.exe`. `start_kill` on the direct child kills
`cmd.exe` alone, leaving node holding the port — observed in practice, not
theoretical. Terminate the tree by PID, in both the async path and `Drop`
(which cannot await, so it shells out to `taskkill /PID <pid> /T /F`
synchronously). Never by name.

