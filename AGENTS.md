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

## The dsh page has no hook to grab on

dsh's app shell cannot be addressed directly, and any change to the page layout
has to be geometric:

- No stable selector. No semantic `id` on the shell, and CSS-Modules class
  names are hashed per build (`pI_x6G_centerCol` in one release, something else
  in the next). Only `#root` survives.
- No ARIA landmarks: no `banner`, `main`, `complementary` or `toolbar` anywhere
  in the bundle, so accessibility cannot be used as an anchor either.
- Hit-testing is not a substitute. `elementsFromPoint` skips anything under a
  `pointer-events: none` overlay, and app headers routinely have one, so the row
  being covered is invisible to it exactly when it matters.

What does work, and what `platform_adapt.js` relies on: the shell is the widest
left-anchored column that is not the full window width, and the content column is
its sibling reaching the right edge. Insetting that content column by the bar
height clears the chrome for *anything* the app puts in the corner, now and after
a dsh upgrade. Note that the right-hand dock panel (`P3OORG_panel` in one
release) is a sibling of the content column and shares its right edge, so it is
covered by the same inset — which is what the user wanted, since that panel holds
the buttons that were being hidden.

Do not add a per-row padding fallback. It was tried: it padded list items and
conversation bubbles, which breaks the layout rather than protecting it.

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



