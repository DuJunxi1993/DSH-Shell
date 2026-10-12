# AGENTS.md — working rules for dsh-shell

## What this project is

This is the **Windows** side of a two-implementation repository: this Tauri 2.x
shell, and a SwiftUI shell for macOS under `macos/`. They are independent
builds of the same idea, kept as siblings rather than as one product. Anything
in this file is about `windows/` only.

A Tauri 2.x desktop shell for the DeepSeek Harness (`dsh`) web UI. It forks
`dsh web`, captures the authenticated URL it prints, and points a WebView2
window at it. The core contract is: **the app exits → dsh dies → the port is
freed.** Nothing else in this repo matters more.

"Exits" is deliberately not "the window closes". The title bar is our own DOM, so
the ✕ in it hides to the tray and dsh keeps running; `Alt+F4` and the tray's
退出（关闭 dsh）are the two real exits. Both run the shutdown path, and both are
covered by tests. A dsh left behind by the *first* run of this shell is what
produced the orphaned port this rule exists to prevent — do not reintroduce a
third way out that skips the tree kill.

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
Set-Location windows\src-tauri                      # from the repository root
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

Paths below are relative to this implementation's root, `windows/`. The
repository also holds a macOS SwiftUI implementation under `macos/`; the two
share nothing but the idea, and neither one is built from the other's files.

| Path | Role |
|---|---|
| `src/lib.rs` | core crate root; `dsh_shell_core` |
| `src/config.rs` | `settings.json` schema, load/save, defaults |
| `src/endpoint.rs` | turns dsh's stdout into the authenticated URL |
| `src/process.rs` | `DshProcess`: spawn / attach / shutdown / tree kill |
| `src/preflight.rs` | anti-nest + port-ownership checks run before spawning |
| `src/platform.rs` | OS-specific kill primitives |
| `src/navigate.rs` | which URLs the webview may show; external ones go to the browser |
| `src/chrome.rs` | injected-chrome geometry and the zoom compensation |
| `src/error.rs` | `ShellError` |
| `src/main.rs` | Tauri entry, window creation, tray, exit handling |
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

## Windows windowing facts

Each of these cost a full build-and-look cycle to establish. They are not
obvious and the Tauri docs do not put them together.

1. **A GUI-subsystem parent has no console**, so every console child gets a
   brand-new console *window* unless spawned with `CREATE_NO_WINDOW`
   (`platform::hide_child_console`). Apply it to `taskkill` too. This is
   independent of packaging: the bundled exe behaves exactly like the one in
   `target\release`.
2. **Tauri replaces WebView2's drop handler.** Without
   `WebviewWindowBuilder::disable_drag_drop_handler()` the remote page never
   receives HTML5 `drop` events, so files cannot be dragged onto it. Tauri's own
   doc comment on that method says it is *required* for HTML5 drag and drop on
   Windows.
3. **`initialization_script` does not reach a remote origin.** It only reaches
   our own local boot page. dsh serves its own Content-Security-Policy, and a
   WebView2 document-created injection is subject to it, so the chrome for the
   real page is injected from `on_page_load` via `window.eval`, which comes from
   the host side and is not. This is why the script is idempotent and runs from
   both places.
4. **The ACL is checked for app commands too**, not only plugin commands, and
   the context is the webview's *current URL*. So on the dsh origin:
   `plugin:window|toggle_maximize` passes when `capabilities/chrome.json` lists
   it, `plugin:window|is_maximized` is refused because it does not, and an app
   command needs an `allow-<name>` permission generated by
   `tauri_build::AppManifest::new().commands(&[...])` in `build.rs`. Also note
   `tauri::State` requires `.manage()`; without it the command fails at invoke
   time and the page cannot see the error.
5. **A frameless window keeps edge resizing.** Wry attaches a manual hit-test
   handler for undecorated windows, so dragging the border still resizes. The
   chrome leaves the top few pixels of its drag strip free for that hit test.
6. **Apply the 1/zoom correction exactly once.** The page zoom multiplies every
   CSS length in the document, so a design length `D` that must render as `D`
   logical pixels needs `D / zoom` — that is `chrome::css_len`, and it is the
   only place the division may live. Dividing the lengths *and* counter-scaling
   the clusters with a transform applied it twice, so at 50% zoom the window
   buttons rendered at 92 logical pixels instead of 46: "the menu bar grows when
   I zoom out". `chrome::css_len` is unit-tested and `chrome_report` re-checks
   the live DOM against the constants, so this cannot fail silently again.
7. **The injected script's own fallbacks are a second copy of every constant.**
   `platform_adapt.js` reads `window.__DSH_SHELL__`, but each value also has a
   literal fallback for the case where the script runs without it. Those literals
   drifted (a 28px bar against a 24px constant) and the chrome looked right only
   because the injected value always won. Two tests in `chrome.rs` now hold the
   two sides together, and the zoom ladder is injected from `config.rs` instead
   of being restated in the script.
8. **A synthetic click from another process never reaches the webview.**
   `mouse_event` from PowerShell is refused by the foreground lock, so
   minimize/maximize/✕ cannot be verified that way — the button appears dead
   while it is fine. Use `PostMessage(WM_SYSCOMMAND, SC_CLOSE)` for the real
   close path, and ask the user for anything that needs a click.
9. **The capabilities are per origin, and the remote one is not optional.**
   The chrome is DOM inside dsh's page, so `capabilities/chrome.json` must list
   the commands the title bar invokes or the buttons silently do nothing. The
   split is now explicit: `boot.json` for the local placeholder, `chrome.json`
   for loopback remote, `default.json` reduced to `core:default`. An app command
   additionally needs the `allow-<name>` permission from `build.rs`; the
   notification plugin's Rust-side `show()` needs none, because it does not
   consult the ACL — only its JS commands do, which is fact 10.
10. **The page's `Notification` is not the browser's, and the ACL is the real
    gate.** `tauri-plugin-notification` injects `init-iife.js` into every page,
    and it *replaces* `window.Notification` with a shim that forwards to
    `plugin:notification|notify`, `|request_permission` and
    `|is_permission_granted` over IPC. Three consequences, each of which cost a
    build-and-measure cycle:
    - WebView2's notification permission is a dead end here. Microsoft's docs are
      true — WebView2 shows no prompt for it and the host must answer
      `PermissionRequested` via `on_permission_request` — but *nothing in the page
      ever reaches WebView2's API*, because the shim shadowed it. The hook can
      never fire. Do not add it back on the grounds that it "should" work.
    - What actually refuses is the ACL. The dsh origin needs
      `notification:allow-notify`, `notification:allow-request-permission` and
      `notification:allow-is-permission-granted`; without them every call is
      rejected with `notification.request_permission not allowed`, which the page
      cannot show you.
    - On Windows the shim still starts each document at `"denied"` even with the
      ACL granted: its init short-circuits (`|| __TEMPLATE_windows__`) and never
      asks, so something has to call `requestPermission()`. The injected script
      does that once per load on the dsh origin. `desktop.rs::request_permission`
      answers `Granted` unconditionally, so this is a no-op gate, not a prompt.
    A persisted WebView2 decision is a red herring too: `Preferences` under
    `%LOCALAPPDATA%\ai.deepseek.dsh-shell\EBWebView` holds a `setting: 2` (block)
    for the origin from before the ACL was granted, and it is irrelevant once the
    shim is in play. `chrome_report`'s `notifications=` field is how to tell
    "granted" from "silently refused".
11. **A toast whose handle is dropped cannot be clicked, and a page-owned toast
    cannot be fixed from here.** `tauri-plugin-notification` calls
    `notification.show()` and throws the `NotificationHandle` away; the WinRT
    `ToastNotification` object holding the `Activated` handler dies with it, so
    the click reaches a dead callback and the window is never raised. The shell's
    own toasts therefore go through notify-rust directly and keep the handle
    (`src/toast.rs`). A dsh plugin's toast cannot: the plugin owns it end to end,
    `RegisterToastNotificationActivator` and `IToastNotificationActivator` exist
    in **no** available `windows` crate version (they are the packaged-app API),
    and the toast carries no launch argument to fall back on. Do not spend time
    re-deriving this. Claim an AUMID only for an installed build, the way the
    plugin does — an unregistered AUMID makes the toast fail to appear at all.

## The repo has two implementations and one contract

`windows/` (Tauri + WebView2) and `macos/` (SwiftUI + WKWebView) are independent
builds of the same idea. They import nothing from each other, but they must
agree about dsh, and the file that says how is **`docs/dsh-shell-contract.md`**
at the repository root. It covers endpoint resolution, the `stub-dsh` fixture
table, the preflight guards, PID ownership, and configuration compatibility.

When you change a rule there, change both sides and add a test on each. The
measurements behind the current rules are in `docs/dsh-desktop-contract.md`,
with screenshots and raw JSON under `docs/probe/`.

A third file sits beside those two:
**`docs/cross-platform-lessons.md`** — what went wrong building either shell, and
which parts of it are portable. Read it before designing anything that touches
dsh's desktop contract, the tray/caption icon, close-window semantics, port
probes, or orphans; it records both the failures and the places where this
implementation already got it right, which is the quickest way to know whether a
macOS lesson is a to-do or a confirmation.

## The dsh page has a hook — use it before you guess

dsh ships a **desktop-host contract**. Setting two properties on `<html>` is
enough to make it do the window-chrome work itself:

```js
document.documentElement.setAttribute('data-windows-titlebar', '')
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '32px')
```

Measured against real dsh `0.2.0-rc.2`, not assumed
(`docs/dsh-desktop-contract.md` §2.3): the frame then reserves the caption
height itself, dsh paints its own drag strip, the content column gets its 16px
top-left radius, `--dsh-frame-chrome-top` and `--dsh-frame-overlay-top` are
published, fullscreen modal overlays are inset by the same amount, and both
custom properties converge when the window goes fullscreen.

`--dsh-windows-titlebar-height` is **read** by dsh and never set by it, so the
host owns the number. Declare it through `px()` like every other length: dsh
reads it as a CSS length and the page zoom multiplies it.

`platform_adapt.js` is therefore two layers:

- **the contract layer**, which declares the host and reads dsh's published
  clearances;
- **the geometric fallback** (`findRightColumns`, `insetColumn`, `clearCorner`,
  `gutterTopRow`, `layoutSignature`), which runs only when
  `contractState()` reports `contractMissing` — an older dsh, or our own boot
  placeholder, which is not dsh and never will be.

`chrome_report` now logs `contract=` and `contract_top_clearance=` on every
report, and `chrome_report` warns when the contract goes unanswered on a
non-placeholder document. **If you are about to add a fourth geometric pass,
check that field first** — the answer is usually that no pass is needed.

dsh does *not* provide the caption's buttons. It reserves the space and offers a
drag region; the three window buttons stay ours, because they are the only part
of a native caption that talks to the window manager.

### Why the fallback exists at all

"The page has no contract" is still true for a dsh that predates one, and the
fallback is the only thing standing between that dsh and a chrome drawn on top
of its controls. It is a fallback, not the strategy.

What it cannot be is correct-by-default. Insetting a column found by its
geometry is a guess about a document whose class names are rehashed every
build, and a wrong guess displaces the page's own layout. The pass that once
"padded list items and conversation bubbles" was this code with the wrong
anchor.

### What the fallback still has to do, and why geometry is the only option

When the contract is absent, dsh's app shell still cannot be addressed
directly, so the corner has to be handled geometrically:

- No stable selector. No semantic `id` on the shell, and CSS-Modules class
  names are hashed per build (`pI_x6G_centerCol` in one release, something else
  in the next). Only `#root` survives.
- No ARIA landmarks: no `banner`, `main`, `complementary` or `toolbar` anywhere
  in the bundle, so accessibility cannot be used as an anchor either.
- Hit-testing is not a substitute. `elementsFromPoint` skips anything under a
  `pointer-events: none` overlay, and app headers routinely have one, so the row
  being covered is invisible to it exactly when it matters.

The heuristic the fallback relies on: the shell is the widest left-anchored
column that is not the full window width, and the content column is its sibling
reaching the right edge. Note that the right-hand dock panel is a sibling of
the content column and shares its right edge, so it is covered by the same
inset — which is what the user wanted, since that panel holds the buttons that
were being hidden.

Do not add a per-row padding fallback. It was tried: it padded list items and
conversation bubbles, which breaks the layout rather than protecting it.

### macOS cannot have this for free

On macOS the same contract has a catch: `document.documentElement.dataset.platform`
is not a CSS hook but a **runtime switch** — its presence puts dsh into the
desktop runtime, which then requires a trusted preload
(`window.dshDesktop` / `window.dshDesktopBoot`). Setting it alone makes the Web
UI fail to boot with 24 entries never activating. The measured preload surface
is five entry points; see `docs/dsh-shell-contract.md` §7.

## Chrome self-diagnosis

`platform_adapt.js` reports to the `chrome_report` command: the measured bar
height and cluster widths multiplied back through the zoom, what the content
inset did, and the layout box of every part of the chrome. This exists because a
frameless window with a missing or invisible title bar is a trap, and a
screenshot cannot tell "element missing" from "element present but not painted".

Two reasons this is worth having, learned the hard way:

- The first two reports always land while dsh is still on its boot screen
  (`_boot_*`, a centred wordmark and spinner), before any session header exists.
  The report is re-sent whenever the inset result changes, or the log only ever
  describes the page before it was interesting.
- "Nothing matched" on its own is useless. The rejection reasons and the measured
  column rects travel into the log, which is how the sidebar was found to have
  been misidentified as the 1024px-wide app shell.

Check the log before touching the CSS:

```powershell
Select-String -Path "$env:APPDATA\deepseek\dsh-shell\data\logs\dsh-shell.log.*" -Pattern "chrome"
```



