# Architecture

> **A SwiftUI window that owns a `WKWebView`, plus a `Process` that owns `dsh web`. Everything else is glue.**

## 1. Goals

1. Be a **native shell** for the dsh web UI on macOS 27.
2. Default to **forking `dsh web` ourselves** so the experience is "open the app, get the agent".
3. **Fall back** to attaching to an already-running `dsh web` when spawning is not appropriate (CI, dev, sandboxed launches).
4. Stay out of dsh's way: no plugins, no patches, no fork of the upstream repo.
5. Leave the door open for native panels (Git, file tree, terminal) without committing to them yet.

## 2. Non-goals

- Editing dsh. We do not patch `cordis.yml`, do not write dsh client plugins, do not ship the dsh dist.
- Supporting platforms other than macOS. There is no Catalyst path, no iOS, no Linux.
- A native re-implementation of the dsh agent UI. The SPA is the only UI.

## 3. Layered view

```
┌───────────────────────────────────────────────────────────────┐
│ SwiftUI App (DSHShell)                                        │
│   ├── DSHShellApp.swift  (@main, App scene, window group)     │
│   ├── Views/ShellScene.swift                                 │
│   │     ├─ WebSurfaceView (NSViewRepresentable → WKWebView)  │
│   │     ├─ LoadingView     (until endpoint resolves)         │
│   │     └─ ErrorView       (dsh failed to start)             │
│   ├── ViewModels/AppCoordinator (@MainActor, ObservableObject)│
│   └── DSHShellCore/                                          │
│         ├── Preflight        (anti-nest, port ownership)      │
│         ├── DSHProcessManager (forks `dsh web`, supervises)  │
│         ├── EndpointResolver  (the four acceptance rules)    │
│         ├── HealthProbe       (port liveness, logging only)   │
│         └── AttachProbe       (the configured port only)     │
└───────────────────────────────────────────────────────────────┘
                            │
                            │  Process (stdout/stderr)
                            ▼
┌───────────────────────────────────────────────────────────────┐
│ child process:  `dsh web --host 127.0.0.1 --port 34247 …`     │
│   ├── node:http server (default bundle)                       │
│   ├── /api HTTP routes + WebSocket upgrade routes             │
│   ├── SPA fallback (dist/index.html)                          │
│   └── prints `dsh web: http://127.0.0.1:NNNN/` on stdout     │
└───────────────────────────────────────────────────────────────┘
```

## 4. The dsh contract

dsh-swiftUI talks to dsh exclusively through the public HTTP/WebSocket surface that dsh already exposes. The contract is small:

| Surface | Source of truth | What we use it for |
|---|---|---|
| `dsh --help` / `dsh web --help` | CLI grammar | Stable enough; we parse flags ourselves instead of shelling out, because the boot event doubles as a health check. |
| `dsh web:` URL line on stdout | `dsh-web-app` runtime plugin | Endpoint the WKWebView points at. Parsed by `EndpointResolver`. |
| `GET /` on the resolved origin | `dsh-host-frontend-static` | Health probe target. |
| Everything else | (future) | Out of scope for the main-panel milestone. |

**Why we don't write a dsh client plugin.** The brief is "pure shell, respect dsh's philosophy". A client plugin would couple us to dsh's internal cordis API and the surface-context prompt. The web UI is the contract; we honour it.

## 5. Process management

`DSHProcessManager` is the only place that fork()s. It:

- validates the configured `dshBinaryPath` is absolute and executable,
- constructs the argv without going through a shell,
- gives the child a null stdin, so it never inherits the app's,
- rebuilds the child's `PATH` (below) and **strips the `DSH_*` harness markers** from its environment,
- runs both preflight guards before spawning, and nothing else does,
- pipes stdout/stderr to an `AsyncStream<String>` consumed by the UI (for the loading overlay and the "Open Console" debug menu),
- resolves the `dsh web:` URL line from **stdout only**, applying all four acceptance rules,
- supervises lifetime: SIGTERM on graceful exit, SIGKILL after 5s, bounded exponential back-off on crash (3 attempts, 2/4/8s, counter reset once an endpoint resolves),
- refuses to spawn more than one child at a time,
- records the child's PID the instant it exists, not when `start()` returns.

The launch arguments we send:

```
dsh web
  --no-open
  --host 127.0.0.1
  --port <preferredPort; 0 or absent means the OS picks>
  --trusted-host <each entry in trustedHosts>
```

`--port` is **omitted entirely** when the port is OS-assigned. The previous code
passed a literal `--port 0` on the strength of an assumption that dsh reads it
as "ask the kernel"; that was never verified against a real dsh, and a literal 0
is ambiguous — it could equally mean "bind port zero". Omitting the flag is the
spelling that cannot be misread, and it is what `dsh web --help` documents.

dsh's web profile accepts exactly those flags; anything else is rejected as an
unknown option. The SPA picks its own workspace inside the browser UI, so the
shell forwards no working directory and `dsh web` defaults to its invoking cwd.

### 5.1 Endpoint resolution: four rules, no exceptions

Only stdout is a URL source. stderr carries dsh's internal `bili` proxy
(`http://127.0.0.1:18787`), and a loose "any loopback URL" match points the
webview at the proxy and shows a white window — the bug this repository once
shipped with. A line is accepted only when it is a `dsh web:` line, on loopback,
on the port we asked for, and carries a **non-empty `?token=`**.

That last rule is the load-bearing one, and it was verified against real dsh:
a tokenized URL answers `303` plus a `dsh-auth-` cookie; the cookied clean URL
answers `200` and serves the SPA; a bare URL answers `401`. **A tokenless URL can
never load the SPA.**

### 5.2 The port probe is a log line, not a fallback

The earlier design raced the URL line against an HTTP probe of the known port
and adopted whatever answered first. It cannot work: the probe's URL has no
token, so dsh answers `401`. The feature was therefore either inert or
dependent on the dsh version — the worst place for behaviour to live.

What the port probe *is* good for is the difference between "dsh is slow" and
"dsh is broken" in the log, because the socket binds seconds before dsh's plugin
Loader settles and prints its URL. So it is logged, and never adopted:

```
port 3080 is listening (HTTP 401); still waiting for the authenticated URL line
```

### 5.3 Orphaned dsh: refuse, do not reap

With a fixed preferred port, a `dsh web` left over from a previous session
would make the next spawn die with `EADDRINUSE`. The previous code resolved this
by finding the listener with `lsof` and **killing it**, if it answered an
unauthenticated request with the dsh SPA.

That is wrong twice over. It destroyed a dsh the operator started by hand —
possibly one they were using — merely by opening the app. And its
identification test could not succeed against a current dsh, which answers
`401` to exactly that unauthenticated probe, so the reaper never fired and the
scenario it was sold as solving could not occur through it either.

The replacement refuses to start and names `attach` as the alternative. A second
dsh cannot share a port anyway, and the user's alternative is already
implemented. See §7.

## 6. App Sandbox stance

The first milestone ships **without** the App Sandbox entitlement. Reasons:

- dsh's child process writes to `~/.dsh/profiles/web/cordis.yml` on every boot. A sandboxed app can grant only `container` writes, which `~/.dsh` is not. Sandbox would force us to relocate dsh's profile directory, which is a hack.
- The future native panels (Git, file tree, terminal) need to read arbitrary project directories.
- swiftUI on macOS does not require the sandbox; the Mac App Store *does* require it, but that is a delivery decision deferred to a later milestone.

When we eventually ship on the Mac App Store we will move to:

- App Sandbox enabled,
- `com.apple.security.files.user-selected.read-write`,
- `com.apple.security.network.client` (so we can talk to `127.0.0.1`),
- bundled `dsh` invoked through a `LaunchAgent` so the child runs outside the sandbox.

That fight is intentionally postponed.

## 7. Attachment fallback

`attach` means: do not fork; adopt something already listening on the configured
loopback port. It requires a fixed `preferredPort`, and it probes exactly that
one port.

The previous implementation swept the entire macOS ephemeral range — all 16384
ports from 49152 — with 32-way concurrency, ignored `preferredPort` entirely,
identified a hit by scraping the SPA's HTML for a marker, and returned whatever
URL it found. Three separate problems: it ignored the only port the user
configured; 16k outbound loopback connections is visible to anything watching
`lsof` and trips local network tooling; and it could adopt a dsh belonging to a
*different* session, which it then — by design — never kills.

**Attach has a real limit, and it should be stated rather than worked around.**
The URL it adopts carries no token, so a token-fenced dsh answers `401` to it.
That is information, not a defect to engineer around: the authenticated URL can
only be printed by the dsh that owns the token. Attach therefore suits a dsh
whose fence is already satisfied — a LaunchAgent, or one sharing a cookie jar —
and for a fresh `dsh web` the answer is to print its URL line and use it.
Preflight skips both guards in attach mode, since attach forks nothing and
cannot collide with anything.

## 8. Threading and concurrency

- All process-management code runs on a dedicated detached `Task` to keep the main actor free.
- SwiftUI state mutation is done via `@Observable` view models and `@MainActor` isolation.
- `WKWebView` is touched only on the main thread (enforced by `WebSurfaceView`).
- Child stdout/stderr lines are funneled through an `AsyncStream<String>` and consumed by a `@MainActor` consumer; we never block the UI on the child's pipe.
## 9. Why not Electron / Tauri / Wails?

> **Superseded in part.** The reasoning below is kept because the ADR it came
> from (`0003-wkwebview-not-electron-or-tauri`) is still "Accepted", and it
> contains a claim that measurement has since refuted: it says Tauri brings "a
> different security model" and a different engine. On macOS, Tauri renders
> through **WKWebView** — the same engine this shell uses. So on macOS the two
> routes are not separated by rendering at all, and the only real difference is
> code sharing with the Windows implementation. That is a live question, not a
> settled one; see `docs/dsh-shell-contract.md`.

The original reasoning, for the record:

- **Electron**: ships its own Chromium and a parallel Node runtime. We already
  need to give users a Node runtime for dsh. Two engines double the disk
  footprint and the rendering surface.
- **Tauri**: brings a Rust toolchain. dsh is Node-native, and putting Rust in
  front of dsh was read as a smell.
- **Wails**: also Go. Same argument.

`WKWebView` remains the right primitive for *this* shell: it is the same WebKit
dsh was built for, and the SwiftUI side is the value we add.
## 10. Open questions

- **Homepage URL detection.** Resolved, not open. `dsh web` prints its URL line
  when `printUrl` is true, which is the default; the shell reads stdout and
  requires the line to carry a token. The port probe can never substitute for
  it, so there is no listening-based fallback to design.
- **Keyboard shortcut surface.** dsh's SPA has its own shortcuts; macOS expects
  ⌘ to do native things. A discoverable shortcut map is still wanted.
- **The desktop-host contract.** dsh publishes one for macOS as well
  (`html[data-platform='darwin']`, `--dsh-frame-top-clearance`, a
  `shell.leading` seat), but it is **not** a CSS hook: the attribute's presence
  flips dsh into its desktop runtime, which then demands a trusted preload
  supplying `window.dshDesktop` / `window.dshDesktopBoot`. Setting it alone
  stops the Web UI from booting. The measured preload surface is five entry
  points, so this is a decision rather than an obstacle — see
  `docs/dsh-shell-contract.md` §7 and `docs/dsh-desktop-contract.md` §2.4.
- **The window-chrome shim is currently inert.** `bridge.js` patches
  `#root [data-dsh-frame] > [data-pane="sidebar"]`, and neither attribute exists
  anywhere in dsh `0.2.0-rc.2`. It degrades to a no-op rather than breaking
  anything, which is the right failure mode and the wrong feature.
