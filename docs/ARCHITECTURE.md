# Architecture

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│ Tauri entry — src/main.rs                                    │
│   window (placeholder → navigate)  ·  ExitRequested shutdown │
└──────────────────────────────────────────────────────────────┘
        │ launch(config)                    │ window.navigate(url)
        ▼                                   ▼
┌────────────────────────────────┐   ┌──────────────────────────┐
│ process.rs — owns the child    │──▶│ WebView2 + dsh SPA       │
│ build_command · spawn · attach │   │ 127.0.0.1:3080/?token=… │
│ wait · shutdown                │   └──────────────────────────┘
└────────────────────────────────┘
        │ preflight                ▲
        ▼                          │ stdout, mirrored to tracing
┌────────────────────────────────┐  │
│ preflight.rs                   │  │
│  · nested-session guard        │  │
│  · port-ownership guard        │  │
└────────────────────────────────┘  │
        │                            │
        │ resolve()                  │
        ▼                            │
┌────────────────────────────────┐  │
│ endpoint.rs                    │──┘
│  parse `dsh web:` → URL+token  │
│  tail buffer · liveness probe  │
└────────────────────────────────┘
        │
        ▼
   ┌──────────────────────────────────────────────┐
   │ platform.rs   terminate_tree(pid) — by PID   │
   │ config.rs     settings.json                  │
   │ error.rs      ShellError + dsh output tail   │
   └──────────────────────────────────────────────┘
```

`lib.rs` exposes the whole core as `dsh_shell_core`, so the process lifecycle can
be tested without a window. `main.rs` is the only part that needs Tauri.

## The window

There is exactly one window, created in `setup()` — **not** declared in
`tauri.conf.json`. Declaring it in both places is what the previous build did,
and it is fatal: `WebviewWindowBuilder::build` returns
`Error::WindowLabelAlreadyExists` (`tauri/src/manager/window.rs`), so the app
died immediately after logging its endpoint. The symptom in the log was the last
line being `dsh up at …`, with nothing after it.

The window loads `src/index.html` (a boot placeholder) and is then navigated to
the dsh URL. The placeholder exists so a cold dsh start reads as progress rather
than a hung application, and it doubles as the surface a startup failure is
reported on — a release build has no console, so a silent exit would be
indistinguishable from a hang.

`platform_adapt.js` is attached with `initialization_script`, not `eval`. It runs
before any page script on every navigation, so it cannot lose a race with the SPA
booting. (It was previously `platform_adapt.css` — a file containing a
JavaScript IIFE, `eval`'d into a document that had not been parsed yet.)

It is also injected from `on_page_load`, because `initialization_script` does not
reach a remote origin: dsh serves its own CSP, and a document-created injection
is subject to it. Both copies are the same generated script, and it is idempotent.

### Where the window is allowed to go

`on_navigation` allows exactly two origins: the app's own, which serves the
placeholder, and the dsh origin, recorded in `AppState::dsh_origin` the moment the
URL is resolved. Everything else goes to the default browser through the opener
plugin — a link, or a server-side redirect off dsh's origin, would otherwise
replace the contents of the window with someone else's website, with no title bar,
no tray and no way back. `on_new_window` denies every second webview for the same
reason, and only passes an *external* URL on: a dsh URL sent to the browser would
have no token, and the index answers 401 without one.

The rule itself is `navigate::is_internal`, which is free of Tauri so it can be
tested directly — a false *deny* is a blank window, which is the failure that
matters. `navigate::is_openable` is the second half: only `http(s)` is ever handed
to the OS, because anything else is a way to make it launch something with this
process's identity.

## The tray, and the three exits

The title bar is our own DOM, so there is no native caption and the ✕ in it cannot
be the only way out. It hides the window instead. The tray icon — left click to
toggle, right click for 显示/隐藏, 缩放复位 100% and 退出（关闭 dsh）— is what
makes that reversible.

`Alt+F4` and the tray's 退出 are the two real exits, and both go through
`ExitRequested`, which is the only place the shutdown path runs. Keeping one
non-hidden exit is deliberate: requiring the tray for *every* exit would mean a
window that can be hidden into a state the user has to know about.

A second launch is not a second window. `tauri-plugin-single-instance` makes the
new process exit and hands the argv to the running one, which raises its window.
Without it, two shells race for the port and the loser dies with "address already
in use" — which is a confusing way to learn that the app is already running.

`auto_restart_on_crash` is deliberately still inert, and `auto_restart_on_crash`
is not the only such field: the config is accepted for schema compatibility. What
the shell *does* do is notice a dsh that dies on its own, via
`DshProcess::poll_exit` once a second, and say so with a toast. It cannot use
`wait()`, which holds the child lock for dsh's whole life and would make
`shutdown()` unreachable from any other task.

## Endpoint resolution

`endpoint::resolve` runs two line readers over dsh's stdout and stderr and one
liveness probe, and returns the first *acceptable* URL.

Acceptable means, in `endpoint_from_line`:

| Requirement | Why |
|---|---|
| the `dsh web:` prefix | stderr carries loopback URLs that are not the UI (`bili: … http://127.0.0.1:18787`, the internal HTTP proxy) |
| a loopback host | dsh binds loopback only; anything else is not our server |
| the port we asked for | the proxy, or a stale dsh, may answer on another port |
| a non-empty `?token=` | `authorizeIndex` answers 401 without it — a tokenless URL can never load the SPA |

The port probe deliberately *cannot* produce a URL. It exists only to log "the
socket is listening, still waiting for the token", which is the difference
between "dsh is slow" and "dsh is broken" in the log. The socket binds long
before the Loader settles and the URL line appears, so a resolver that races them
loses to the probe and shows the user a 401.

Failure modes are specific, and carry the last 40 lines dsh wrote, because that
is where the reason lives:

- `DshExitedBeforeReady { code, tail }` — dsh died during boot
- `EndpointTimeout { host, port, waited, tail }` — alive, but never announced
- `NestedSession { vars }`, `PortInUse { host, port }` — from preflight

Both reader tasks are aborted when `resolve` returns. The previous implementation
spawned them and forgot, so every launch leaked a reader per pipe for the life
of the process.

## Preflight

Run before `spawn` only; `attach` forks nothing and so cannot collide.

**Nested session.** `dsh-shell-env` injects `DSH_SESSION_ID`, `DSH_PROFILE`,
`DSH_PROFILE_DIR` and `DSH_WEB_URL` into every model-facing shell call, and
scrubs ambient `DSH_*` before doing so — which is what makes them a reliable
signal rather than a guess. A lone `DSH_PROFILE` is treated as ambiguous (a user
may have exported one); a session id, or any two markers, is decisive.

Note there is no `DSH_SHELL_CHILD` variable, despite what an earlier README and
ARCHITECTURE claimed. It would be useless: the same scrubbing that makes the
markers trustworthy would strip a value we set for ourselves before dsh ever saw
it.

**Port ownership.** Tested by binding, not by scraping `netstat`, so it observes
what dsh's own bind would observe. On failure the error names `attach` as the
fix, because a second dsh cannot share a port and the user's alternative is
already implemented.

## Shutdown

`RunEvent::ExitRequested` → `api.prevent_exit()` → shut dsh down on the async
runtime → `app_handle.exit(0)`. A re-entrancy flag makes the second
`ExitRequested` (raised by `exit()`) fall through so the process can actually
leave, and a 15s deadline means a wedged child can never wedge the app.

`WindowEvent::CloseRequested` is deliberately not used: it runs on the event loop,
where blocking on the async runtime to reap a child would deadlock the loop that
has to service the exit.

### Why the tree, and not the child

| Platform | What we spawn | What owns the port |
|---|---|---|
| Windows | `cmd.exe` (from the `dsh.cmd` shim) | `node.exe`, a **grandchild** |
| POSIX | `node` (a process group leader) | the group |

On Windows, `taskkill /PID <pid> /T /F` reaches `cmd.exe` and everything under
it. `start_kill` on the direct child is not enough, and this is not a theoretical
concern: the first live run left a `node` holding ports 3274 and 18787 because
`cmd.exe` had already exited and the kill hit a dead process.

`Drop` is the backstop for a panic or an early return, and it terminates the tree
**synchronously** — `Drop` cannot await, and a leaked dsh is the one outcome
this application exists to prevent. This is why the release profile does not set
`panic = "abort"`: abort skips every `Drop`.

Everything here is scoped to a PID captured from `child.id()`. Nothing in this
repository kills by name. See `AGENTS.md` rule 1 for why that is not negotiable.

### The gap between spawning and owning

`Drop` can only run for a `DshProcess` that exists, and it does not exist between
`Command::spawn` and the return of `launch` — which is several seconds, because
`launch` waits for dsh's URL line. Closing the window in that window leaves
nothing to drop, and the dsh survives holding the port. That is observed, not
theoretical.

`AppState::starting_pid` is the record that closes it, and its lifetime is the
subtle part: it is cleared by `point_at_dsh`, *after* the `DshProcess` is stored,
and not when `launch` returns. Clearing it at the return opens a second gap of
the same kind, one that is easy to miss because the code looks correct — the exit
path finds neither a `DshProcess` nor a PID, concludes there is nothing to reap,
and exits. The invariant is: while we own, or are about to own, a dsh, its PID is
recorded.

The exit path logs which of the three it took, because "no dsh running at exit" and
"terminated recorded pid" look identical from outside the process.

## Testing

`tests/` drives `stub-dsh` (`src/bin/stub-dsh.rs`), a std-only test double that
reproduces the URL line, the 401 auth fence, the decoy proxy banner, a slow
Loader, and an early exit. Tests therefore never start a real harness and are
safe to run at any time.

`tests/live_dsh.rs` is the exception: `#[ignore]`d, and additionally gated on
`DSH_SHELL_LIVE_TEST=1`. It asserts the things only the real thing can answer —
that the printed token URL yields 303 plus a `dsh-auth-` cookie, that the cookie
serves the SPA, that a tokenless URL is refused, and that shutdown frees the
port. It runs in about 4.5 seconds and leaves nothing behind.

A hazard it documents: dsh keeps a machine-wide HTTP proxy (`bili`, port 18787)
and a second dsh *attaches* to an existing one instead of failing. A dsh left
behind by an interrupted run therefore silently changes how the next boot
behaves, so confirm none is running before believing a live-test failure.

### What the automated tests cannot reach

Three things are verified by hand, and the log is what makes them diagnosable:

- **The ✕, the tray menu, and any link click.** A synthetic click from another
  process does not reach the webview — `mouse_event` is refused by the foreground
  lock — so a button that works looks dead under test. Minimize, maximize and
  close were all "broken" this way before the bridge bug behind them was found.
- **The real close path** is testable, but only via `WM_SYSCOMMAND`/`SC_CLOSE`
  aimed at the *visible* window. The process owns several top-level windows, and
  posting to the wrong one does nothing at all.
- **A real dsh session.** The layout geometry can only be judged with a session
  open and the dock expanded, which no script here can arrange.

So `chrome_report` exists: the page measures its own bar, clusters, insets and
content columns and sends the numbers back. It reports twice on purpose, because
the first two reports land on dsh's boot screen before any session header exists,
and "nothing matched" is only useful next to the rejection reasons and the
measured column rectangles.
