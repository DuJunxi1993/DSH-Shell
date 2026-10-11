# dsh-swiftUI

A native macOS shell for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) web UI.

`dsh` ships its product as a CLI that boots a local HTTP server and serves a SPA front-end. `dsh-swiftUI` wraps that experience in a native SwiftUI application: it owns the window, the menu, the lifecycle, and (by default) forks `dsh web` itself. The dsh SPA is rendered inside a `WKWebView`; the native side stays out of dsh's way.

> **Pure shell.** dsh-swiftUI does not modify dsh, does not bundle dsh, and does not write any dsh client plugin. It talks to dsh the same way a browser does: a single HTTP/WebSocket origin on `127.0.0.1`.

This first milestone delivers the **main panel only** — the WKWebView pointing at the dsh SPA, with a transparent titlebar and a floating status badge. The roadmap for future native panels (Git, file tree, in-process terminal) is captured in [`docs/ROADMAP.md`](docs/ROADMAP.md); that work is intentionally deferred.

![dsh-swiftUI main window](docs/screenshots/main-window.png)

---

## What works

| Stage | State |
|---|---|
| Repository skeleton + docs | ✅ |
| SwiftPM package + Xcode project (XcodeGen-generated) | ✅ |
| `DSHShellCore` framework — process manager, endpoint resolver, health/attach probes, settings store | ✅ |
| SwiftUI `DSHShell` app — `AppDelegate`-owned `AppCoordinator`, native window, `WKWebView` surface | ✅ |
| `DSHProcessManager` — fork `dsh web`, capture URL, crash-time auto-restart, **clean shutdown via `kill`/`waitpid`** | ✅ |
| `launchMode == .attach` fallback (probe the configured loopback port only) | ✅ |
| App icon, transparent titlebar, floating status badge | ✅ |
| Preferences (binary path, listen host/port, trusted hosts, timeouts, auto-restart) | ✅ |
| Unit tests for `DSHShellCore` | ✅ 63 passing, 0 failing |
| Hermetic lifecycle tests against `stub-dsh` | ✅ 13, every one ends by asserting the port is bindable again |
| `swift build` and `xcodebuild` both clean | ✅ 0 errors |
| Preflight: refuse to nest inside a harness session | ✅ |
| Preflight: refuse a port someone else owns, never kill it | ✅ |
| Preflight: `SO_REUSEADDR` on the port probe | ✅ so `TIME_WAIT` cannot fake a collision |
| Git / File tree / Terminal panels | ⏳ Roadmap only |

---

## Requirements

- **macOS 15+** (built and tested on macOS 27 with the Xcode-beta SDK)
- **Xcode-beta** (the bundled Swift 6.4 toolchain is the target compiler)
- A working **dsh** install — `dsh --version` should print `0.1.0-rc.6` or later.
  ```sh
  npm install -g @deepseek-ai/dsh
  ```
  The first launch needs the dsh front-end dist to be built (`pnpm run build` from the dsh repo). dsh-swiftUI does **not** ship the dsh dist.

If you have multiple Xcode versions installed, point the active developer directory at the beta once:
```sh
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

---

## Building

### Option A — Xcode

```sh
brew install xcodegen              # one-time
./scripts/generate-xcodeproj.sh    # regenerates DSHShell.xcodeproj
open DSHShell.xcodeproj
```

Then ⌘R. The first build expects a signing identity. For a local-only build, set the team to "None" and enable "Sign to Run Locally"; the project already disables Hardened Runtime because ad-hoc-signed frameworks would otherwise fail dyld library validation (no shared Team ID).

### Option B — Swift Package

```sh
swift build -c release           # builds DSHShellCore + DSHShell
swift test                       # runs the 10 unit tests
```

To produce a `.app` bundle, use the Xcode project (Option A).

---

## Configuration

Settings live at `~/Library/Application Support/dsh-swiftUI/settings.json`. Defaults:

```json
{
  "dshBinaryPath": "/Users/djx/.npm-global/bin/dsh",
  "launchMode": "spawn",
  "listenHost": "127.0.0.1",
  "preferredPort": 34247,
  "trustedHosts": ["127.0.0.1", "localhost"],
  "pollIntervalSeconds": 0.5,
  "spawnTimeoutSeconds": 60,
  "autoRestartOnCrash": true
}
```

| Field | Meaning |
|---|---|
| `dshBinaryPath` | Absolute path to the `dsh` executable. |
| `launchMode` | `spawn` → fork `dsh web` ourselves; `attach` → only connect to an already-running instance. |
| `listenHost` | Local host passed to `dsh web --host`. `0.0.0.0` is **not** supported (mirrors dsh's own policy). |
| `preferredPort` | Fixed port forwarded to `dsh web --port`. A fixed port lets preflight refuse to start over somebody else's listener instead of killing it, and lets `attach` know where to look. `0` → the flag is omitted entirely and the OS assigns a port. |
| `trustedHosts` | Hosts appended to `dsh web --trusted-host` (repeatable). |
| `spawnTimeoutSeconds` | How long to wait for the `dsh web:` URL line on stdout before probing the fixed port as a fallback. |
| `autoRestartOnCrash` | Bounded exponential back-off restart on unexpected child exit: 3 attempts at 2s, 4s and 8s. The counter resets once an endpoint resolves, so a dsh that crashes once an hour is not treated as a crash loop. |

The shell forwards no working directory to `dsh web` — the dsh SPA picks its own workspace inside the browser UI.

---

## Lifecycle

```
+-----------+   fork    +----------+    http   +-----------+
| DSHShell  | --------▶ | dsh web  | --------▶ | WKWebView |
| (macOS)   |           | (child)  |           |  + SPA    |
+-----------+           +----------+           +-----------+
       │                      │
       │  ⌘Q / terminate    │  crash
       ▼                      ▼
   kill+waitpid         respawn w/ backoff
```

- On launch the app forks `dsh web`, captures the `dsh web: http://127.0.0.1:NNNN/` line, and points the `WKWebView` at it.
- If the child crashes, the manager restarts it up to 3 times with exponential back-off (2s, 4s, 8s), then gives up and **says so** — both in the UI and as a notification. A window that keeps showing a dead conversation over a server that is gone is the failure this exists to prevent.
- On `applicationWillTerminate` the `AppDelegate` calls `AppCoordinator.shutdownBlocking()`: it signals the child with `SIGTERM`, escalates to `SIGKILL` after 5s, and uses `waitpid` to confirm the child has reaped before the process exits. **This is the path that prevents orphan dsh processes** — a Swift `Task` would not have run in time during runtime teardown.

---

## Diagnostics

Lifecycle events flow through `OSLog` with subsystem `ai.deepseek.dsh-shell`. To see them:

```sh
log stream --predicate 'subsystem == "ai.deepseek.dsh-shell"' --info --debug
```

Or read the last minute:

```sh
log show --predicate 'subsystem == "ai.deepseek.dsh-shell"' --last 1m --info --debug
```

If the configured port is already owned, the shell **refuses to start and names `attach`** as the alternative. It never kills a process it did not spawn: that would destroy a `dsh web` you started by hand, possibly one you were using, merely by opening the app.

The error message deliberately does not suggest `pkill`. Killing dsh by name is forbidden throughout this repository — see [`AGENTS.md` in the Windows implementation](../../windows/AGENTS.md) rule 1, which records what happened when a previous agent did it.

---

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the layered view, the dsh integration boundary, the process model, and the App Sandbox stance. The roadmap for native panels lives in [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## License

MIT. See [`LICENSE`](LICENSE).
