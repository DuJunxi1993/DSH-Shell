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
│   │     ├─ LoadingOverlay (until endpoint resolves)          │
│   │     └─ ErrorView (dsh failed to start)                   │
│   ├── ViewModels/ShellViewModel (@Observable)                │
│   └── Services/                                              │
│         ├── DSHProcessManager  (forks `dsh web`, supervises) │
│         ├── EndpointResolver   (parses `dsh web:` URL line)  │
│         ├── HealthProbe        (HTTP GET /, retry)           │
│         └── AttachProbe        (scans 127.0.0.1 ports)       │
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
- pipes stdout/stderr to an `AsyncStream<String>` consumed by the UI (for the loading overlay and the "Open Console" debug menu),
- rescues the `dsh web:` URL line from stdout and forwards it to `EndpointResolver`,
- reclaims the fixed preferred port before spawning: an orphaned `dsh web` from a previous session (pkill/crash leaves no cleanup) would otherwise make the fresh child die with `EADDRINUSE`. `reclaimPort` probes the port, and only if it truly serves the dsh SPA kills the listener (lsof + SIGTERM/SIGKILL), so an unrelated service squatting on the port is left alone,
- adopts the endpoint by health probe when the URL line is late or missing: `dsh web`'s own loader can take 30-60s+ to settle depending on startup work, so after the URL deadline we keep the live child and poll `http://<host>:<preferredPort>/` until it serves the SPA (fixed port only),
- supervises lifetime: SIGTERM on graceful exit, SIGKILL after 5s, exponential back-off on crash (max 30s, single auto-restart),
- refuses to spawn more than one child at a time.

The launch arguments we send:

```
dsh web
  --host 127.0.0.1
  --port <preferredPort, default 34247; 0 = OS-assigned>
  --trusted-host <each entry in trustedHosts>
```

A fixed default port (rather than `0`) is deliberate: it lets the shell adopt
the endpoint by probing even when the URL line never arrives, and lets the
orphan reaper target the right listener. Set `0` in Preferences to opt out
(OS-assigned port, URL-line-only startup).

dsh's web profile accepts exactly those three flags; anything else (e.g. a
`--workspace`) is rejected as an unknown option. The SPA picks its own
workspace inside the browser UI, so the shell forwards no working directory
and `dsh web` defaults to its invoking cwd.

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

If `launchMode == attach` (or if `spawn` fails to deliver a URL within `spawnTimeoutSeconds`), `AttachProbe` walks a small set of ports on `127.0.0.1` and asks each one for `/`. The first server that responds with a 200 whose `Content-Type` is `text/html` and whose body matches the dsh SPA signature is adopted as the upstream.

The probe is intentionally narrow: it only scans well-known ephemeral ports opened within the last minute by a process whose name is `node` (heuristic; not enforced). This is good enough for the lone-dev case and a no-op on multi-user hosts.

## 8. Threading and concurrency

- All process-management code runs on a dedicated detached `Task` to keep the main actor free.
- SwiftUI state mutation is done via `@Observable` view models and `@MainActor` isolation.
- `WKWebView` is touched only on the main thread (enforced by `WebSurfaceView`).
- Child stdout/stderr lines are funneled through an `AsyncStream<String>` and consumed by a `@MainActor` consumer; we never block the UI on the child's pipe.

## 9. Why not Electron / Tauri / Wails?

Neutral summary, captured here so we can revisit it:

- **Electron**: ships its own Chromium and a parallel Node runtime. We already need to give users a Node runtime for dsh. Two engines double the disk footprint and the rendering surface.
- **Tauri**: brings a Rust toolchain and a different security model. dsh is Node-native and the brief is "respect dsh's philosophy"; mixing Rust in front of dsh is a smell.
- **Wails**: also Go. Same argument.

`WKWebView` is the right primitive: it is the same WebKit dsh was already built for, and the SwiftUI side is the value we add.

## 10. Open questions

- Homepage URL detection: dsh prints `dsh web: http://...` only when `printUrl` is true. We will set up a flag, but if dsh ever changes that contract we need to detect by listening (HTTP probe if we know the port, port-scan if we do not).
- Keyboard shortcut surface: dsh's SPA has its own shortcuts; macOS expects ⌘ to do native things. We will eventually need a discoverable shortcut map. Deferred.
