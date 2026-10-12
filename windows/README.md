# dsh-shell

A native desktop shell for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) web UI: a real window instead of a browser tab, and real ownership of the
`dsh` process behind it.

![dsh-shell running the dsh web UI](docs/screenshot.png)

> **Pure shell.** dsh-shell does not modify dsh, does not bundle dsh, and does
> not write a dsh client plugin. It talks to dsh exactly the way a browser does:
> one HTTP origin on `127.0.0.1`.

## Status

Verified on Windows 11 with dsh `0.2.0-rc.2` and WebView2, 2026-10-02.

| Area | |
|---|---|
| Endpoint resolution (stdout URL line, token, port check) | verified, incl. against real dsh |
| `spawn` mode: fork `dsh web`, wait for the authenticated URL | verified |
| `attach` mode: adopt an already-running dsh, never kill it | verified |
| Exit: window close → dsh tree gone → port freed | verified |
| Hide to tray: ✕ hides, dsh keeps running, tray menu exits | ✕ needs your click; the other two verified |
| Second launch raises the running window instead of starting a rival | verified: the second process exits |
| External `http(s)` links open in the default browser | verified for the rule; the click needs your eyes |
| Toast when dsh fails to start or dies on its own | verified against real dsh |
| A dsh plugin's notifications work (dsh-notification) | `Notification.permission` reaches `granted`; the toast itself needs your eyes |
| No console window while dsh starts or while we reap it | verified (zero visible console windows over a full run) |
| File drag-and-drop onto the page | `disable_drag_drop_handler()`; needs your eyes on a real drop |
| Frameless window with an injected title bar | injected, geometry asserted against the live DOM |
| Content column inset so nothing is occluded | verified: `inset centerCol by 32px`, sidebar left at full height |
| Page zoom 50–200% in 10% steps, persisted | verified: bar measures 32 logical px at 100% *and* at 50% |
| Anti-nest guard (refuses to run inside a harness session) | verified |
| Port-ownership guard (points at `attach` instead of dying) | verified |
| `cargo test` → 82 hermetic tests against `stub-dsh` | green |
| `cargo clippy --all-targets -- -D warnings` | clean |
| `cargo build --release` | clean |
| `.msi` + `.nsis` bundles | built |
| macOS / Linux | core compiles; not exercised |

## Requirements

- **Windows 10+ with the WebView2 Runtime** (preinstalled on Windows 11)
- **Rust 1.78+** — a `.cmd` shim is spawned as `cmd.exe`, which older toolchains
  refuse to do. Current stable is fine.
- A working **dsh**: `dsh --version` prints a version.
  ```powershell
  npm install -g @deepseek-ai/dsh
  ```

Node is *not* required: `cargo-tauri` does the packaging.

## Build

```powershell
cd windows\src-tauri        # from the repository root
cargo test                 # hermetic; never starts a real dsh
cargo clippy --all-targets -- -D warnings
cargo tauri build          # -> target\release\bundle\{msi,nsis}
```

For a quick run, `cargo run` is enough. There is deliberately **no dev server**:
the window is created in `setup()` with a URL that only exists at runtime, so
`tauri dev` (which wants a `devUrl`) has nothing to load.

## Configuration

`%APPDATA%\deepseek\dsh-shell\config\settings.json`. Written only if you create
it; the defaults below apply when it is missing.

```json
{
  "dsh_binary_path": "C:\\Users\\<you>\\AppData\\Roaming\\npm\\dsh.cmd",
  "launch_mode": "spawn",
  "listen_host": "127.0.0.1",
  "preferred_port": 3080,
  "trusted_hosts": ["127.0.0.1", "localhost"],
  "poll_interval_seconds": 0.5,
  "spawn_timeout_seconds": 120,
  "auto_restart_on_crash": true,
  "zoom_percent": 100
}
```

| Field | Meaning |
|---|---|
| `dsh_binary_path` | Absolute path to dsh. Defaults to the npm-global `dsh.cmd` if present, else plain `dsh` on `PATH`. |
| `launch_mode` | `spawn` → fork `dsh web` ourselves. `attach` → adopt an instance that is already running, and never kill it. |
| `listen_host` | Loopback only. dsh refuses `0.0.0.0` and so does the config. |
| `preferred_port` | Passed to `dsh web --port`. `0` lets the OS choose. 3080 is dsh's own default. |
| `trusted_hosts` | Repeated as `--trusted-host <host>`; they feed dsh's `/api` browser-trust fence. |
| `poll_interval_seconds` | How often the liveness probe asks the port. |
| `spawn_timeout_seconds` | How long to wait for dsh's URL line. dsh's Loader can take that long on a cold profile, so this is generous. |
| `auto_restart_on_crash` | Restart dsh if it dies on its own. Bounded: three attempts, backing off 2s → 4s → 8s, and the budget resets only after dsh has been up a full minute. After that it stops and tells you, rather than respawning forever. |
| `zoom_percent` | Page zoom, 50–200 in steps of 10. Normalised on read, so a hand-edited 57 behaves like 60. Carries a serde default, so a settings file written before this field existed still loads. |

## How the endpoint is found

This is the part worth reading, because getting it wrong is invisible: the app
starts, logs a URL, and shows you a blank window.

dsh prints exactly one useful line, on **stdout**, and only after its plugin
Loader has fully settled — which is seconds *after* the socket is bound:

```
dsh web: http://127.0.0.1:3080/?token=<launchToken>
```

Three facts from dsh's own source shape the implementation:

1. **`?token=` is mandatory.** `dsh-client-connection`'s `authorizeIndex` serves
   the SPA only for a request carrying a valid `?token=` query (which it trades
   for a `dsh-auth-` cookie and a 303 to `./`) or that cookie. A tokenless URL
   from a port probe gets a 401 and a white window. So "the port answers, let's
   use it" can never work, and the port probe is a log line, not a fallback.
2. **stderr contains loopback URLs that are not the UI.** dsh logs
   `bili: attaching to running proxy at http://127.0.0.1:18787` — its internal
   HTTP proxy. An earlier version of this shell scanned both streams with one
   loose loopback regex and returned that proxy port. Only the `dsh web:` line
   is a URL source now, and the port must be the one we asked for.
3. **The token is per-process.** A URL captured from an earlier dsh is
   worthless, so it is resolved once, against the child we just spawned.

dsh's own output is mirrored into the log with a 40-line tail attached to every
error, because a release build has no console and a silent exit is
indistinguishable from a hang.

## Lifecycle

```
+--------------------+   fork    +-----------+    http    +----------------+
|  DSH Shell (Tauri) | --------> |  dsh web  | ---------> | WebView2 + SPA |
|  placeholder -> dsh|           | cmd.exe + |             |                |
|                    |           | node      |             |                |
+--------------------+           +-----------+             +----------------+
     |    ^                            |
     |    |                            |
     |  tray / 2nd launch              | dsh dies on its own
     v    |                            v
  window hidden              toast; the port is released
  dsh keeps running
     |
     | Alt+F4, or tray -> 退出（关闭 dsh）
     v
terminate the tree by PID
(taskkill /PID <n> /T)  ->  port freed
```

**Three different exits, and they are not interchangeable.** The window has no
native caption — the title bar is our own DOM — so the ✕ in it *hides* rather than
closes: dsh stays up and keeps the port, and the tray is the way back. `Alt+F4`
still closes the window for real, so there is always an exit that does not require
finding the tray icon, and the tray's 退出 does the same. Only those two run the
shutdown path below.

The tree kill is not optional on Windows. `dsh_binary_path` is a `.cmd` shim, so
what we spawn is `cmd.exe` and the harness is a **grandchild** `node.exe`.
Terminating the direct child kills `cmd.exe` alone: node survives holding the
port, the window is gone, and nothing will ever reap it. This is not
hypothetical — the first live run of this shell left exactly that behind, which
is why `Drop` kills the tree too, synchronously, because `Drop` cannot await.

The same reasoning closes a second window: a dsh that has been spawned but is not
yet owned by the exit path — during startup, and in the gap between `launch`
returning and the child being stored — has its PID recorded for exactly that
reason. The record is cleared only once the `DshProcess` owns the child, because
clearing it any earlier re-opens the same leak.

Closing the window runs `RunEvent::ExitRequested` with `prevent_exit`, shuts dsh
down on the async runtime, then exits. It does *not* use
`WindowEvent::CloseRequested`: blocking the event loop there deadlocks the very
loop that has to service the exit. `panic = "abort"` is also deliberately not
set — abort skips every `Drop`, which is the one way to strand a live dsh.

## Safety rails

The failure that shapes this repo: an earlier agent working here killed the
harness it was running inside, most likely with a name-based kill
(`taskkill /IM node.exe`). So:

- **dsh-shell only ever kills PIDs it spawned itself**, from `child.id()`.
- **It refuses to start inside a harness session.** dsh injects
  `DSH_SESSION_ID` / `DSH_PROFILE` / `DSH_WEB_URL` into every model-facing
  shell call, and scrubs ambient `DSH_*` first, so those variables are a
  reliable signal. A second harness started from inside a session contends for
  the same ports, proxy and session store, and the damage lands on the outer
  session.
- **It refuses to start when the port is already owned**, and tells you to use
  `attach` instead.
- **Tests never start a real dsh.** They drive `stub-dsh`, a test double that
  reproduces the URL line, the 401 fence and the decoy proxy banner.

`AGENTS.md` has the full rules, including how to run the one test that does
touch the real harness.

## Logs

```
%APPDATA%\deepseek\dsh-shell\data\logs\dsh-shell.log.<date>   daily, all builds
%APPDATA%\deepseek\dsh-shell\data\logs\crash.log              startup failures
```

`RUST_LOG=debug` adds dsh's own chatter. Debug builds also print to the console.

## Window chrome

The window is frameless. The title bar is a 32px strip of DOM injected into
whatever page is loaded, so the dsh sidebar can reach the very top of the window
and only the three buttons sit on top of the content. The dsh app's own top
area stays visible through the drag strip, and the button cluster sits in a
surface colour read from the page's own CSS variables, so it follows the dsh
light/dark theme.

- **Drag** the strip, or double-click it to maximize.
- **− / +** and the percentage step the page zoom, 50–200% in 10% steps, and the
  choice is remembered. `Ctrl+Alt+↑` / `Ctrl+Alt+↓` do the same. Chromium's own
  `Ctrl+=` zoom is disabled so the percentage cannot drift from the real zoom.
- The bar keeps its 32 logical pixels at every zoom level, so the buttons stay
  usable at 50%. This is asserted, not eyeballed: the chrome reports its measured
  geometry back to the shell, which compares it against the constants in
  `chrome.rs` and logs a warning on any mismatch.
- The **content area is inset by the bar height** so the dsh app's own top-right
  controls — including the right-hand dock panel — are never underneath the
  buttons. The sidebar keeps its full height and still reaches the top edge.
- Hover highlights every button; the close button's is a light red, and hover
  backgrounds are rounded to match the window.

Two things make this work at all, and both are non-obvious:

- The injection cannot go through Tauri's `initialization_script`, because dsh
  serves its own Content-Security-Policy and a WebView2 document-created script
  is subject to it. The real page gets the chrome from Rust via `eval` on page
  load; our own boot page gets it from the initialization script. The script is
  idempotent, so running it in both places is free — and necessary, because a
  frameless window with no title bar during startup has no close button.
- The title bar's buttons and the zoom command reach Rust over IPC, and the ACL
  is enforced against the webview's *current URL*. `capabilities/chrome.json`
  therefore grants exactly four window commands plus our two commands, and only
  for `http://127.0.0.1:*` and `http://localhost:*`. No fs, shell, clipboard or
  path access. If the chrome ever fails to install — a future dsh release could
  break the injection — the log says so, because a frameless window with no close
  button is a trap.

## Manual verification

```powershell
$env:RUST_LOG = "info,dsh_shell=debug"
cd windows\src-tauri        # from the repository root
cargo run
```

1. A window appears immediately showing "Starting dsh…", with a title bar.
2. Within a few seconds the dsh UI loads and the sidebar reaches the very top of
   the window. It is a real UI, not a 401 page.
3. Drag the title bar: the window moves. Drag the window border: it resizes.
4. Drag a file from Explorer onto the page: it lands in the chat composer.
5. Click −/+, or press `Ctrl+Alt+↓`: the page scales and the percentage changes.
   The title bar does not change size. Restart: the zoom is remembered.
6. Close the window with the ✕. Within ~1s dsh is gone and the port is free:
   ```powershell
   Get-NetTCPConnection -State Listen -LocalPort 3080
   ```

If a step fails, the log has the reason and dsh's own output with it. For a
chrome problem specifically, `RUST_LOG=debug` prints the measured bounding box
of every part of the title bar, which distinguishes "element missing" from
"element there but not painted".

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and
[`AGENTS.md`](AGENTS.md) for the working rules.

## License

MIT. See [`LICENSE`](LICENSE).
