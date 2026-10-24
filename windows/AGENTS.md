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

# The icon, only when the whale or the plate changes:
python scripts/extract-dsh-whale.py   # refresh the whale from the installed dsh
python scripts/make-icon.py           # plate + whale -> icons/dsh-shell.png
cargo tauri icon src-tauri/icons/dsh-shell.png
python scripts/icon-sample.py         # optional: candidates into %TEMP%
```

`extract-dsh-whale.py` and `make-icon.py` both commit their output, so the build
never needs dsh installed. See `docs/cross-platform-lessons.md` §1 for why the
whale comes from `FISH_LOGO_PATH` and not from dsh's favicon, and
`windows/scripts/make-icon.py` for how the plate's corner was measured.

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
   chrome does not need to leave room for it — the hit test is at the window
   level, above the webview — so there is no reserved strip and nothing in the
     bar that is there only to be dragged.

   **But the caption has no drag region before dsh loads, and the boot page has
   to supply its own.** On the dsh page the contract paints
   `.frame::before { -webkit-app-region: drag }`; our own boot placeholder is not
   dsh, so until dsh arrived the window could be resized but not moved. The shell
   therefore paints the same band on the placeholder only, guarded by
   `isOwnBootPage()`.

   Two details are load-bearing, and both were got wrong first:

   - **It must be a sibling of the bar, not a child.** The bar is
     `pointer-events: none` so the page shows through it, and a drag region inside
     a `pointer-events: none` subtree is *never hit-tested*. The element was
     present, `-webkit-app-region: drag` was set, the report said so, and the
     window still did not move. dsh's own strip is a `::before` on an ordinary
     interactive element, which is the shape that works.
   - **No region on the dsh page.** dsh paints its own; a second one overlapping
     would be another thing to keep in step. `chrome_report`'s `drag=` field
     reports `true` only for the boot page, and `chrome::tests` asserts that the
     declaration lives inside the `isOwnBootPage()` guard.

   `-webkit-app-region` still needs `no-drag` on every control we own (fact 12
   below), because Chromium collects drag regions by bounds and does not let a
   child mask one underneath it.

6. **Zoom is the webview's, and the menu lists the ladder rather than measuring
   it.** `zoom_hotkeys_enabled(true)` — written out, because the default is a
   `#[serde(default)]` bool and therefore false, so omitting it silently kills
   `Ctrl`+`±`/`0`. The hotkeys are **not** intercepted: letting Chromium handle
   them is what keeps `Ctrl`+`=` and a click on a rung the same operation, and it
   is what the macOS shell does (`WKWebView` cannot suppress its own, and its
   comment says a percentage that drifts from the real zoom is worse than no
   percentage at all).

   `set_page_zoom` takes an **absolute** percentage, and that is the whole design:
   WebView2 reports its current zoom to nobody, so a command that stepped from a
   remembered value would drift the first time the user pressed `Ctrl`+`=`. The
   page measures what it can — `devicePixelRatio` over the display scale — and asks
   for the rung it wants; Rust clamps it onto the ladder. `set_page_zoom` is the
   only zoom command; there is no `zoom_step`, because the menu offers rungs
   directly rather than a direction.

   **The menu enumerates `config::zoom_rungs()` and marks the current one.** It
   does not display a derived percentage, and that is the whole point. The
   derivation would be `devicePixelRatio / display scale`, and measured at three
   zoom levels on this machine:

   ```
   zoom  50%  -> dpr 0.63
   zoom 100%  -> dpr 1.25
   zoom 150%  -> dpr 1.88
   ```

   `dpr = 1.25 x zoom`, exactly. So the 1.25 is a **display** factor, independent
   of the page zoom — the opposite of what was assumed for two rounds of
   debugging. And no Windows API reports it: `GetDpiForSystem`, `GetDpiForWindow`
   on the real window, `GetDpiForMonitor`, `LOGPIXELSX` and the registry's
   `PerMonitorSettings\...\DpiValue=1` all say 96, and they say 96 from a process
   that has just set `PER_MONITOR_AWARE_V2`.

   So **nothing reachable names the divisor** — the derivation needs a `scale` that
   no API will give up. That is also why clicking 缩小 appeared to *enlarge* the
   page: the real zoom fell while a percentage divided by 1.0 rose. Two traps on
   the way there: `HKCU\Control Panel\Desktop\LogPixels` is the DPI-*awareness*
   setting, not the scale, and a "correction" claiming `GetDpiForWindow` returns
   120 was wrong too — it returns 96 like everything else.

   **It is still recoverable, because no API is needed.** The shell pushes a known
   zoom before the page script runs, so the page has one known point on that
   curve: `scale = devicePixelRatio / (pushedZoom / 100)`. `learnZoomScale` samples
   it twice ~250 ms apart (the push is not synchronous), rejects an implausible
   result, and `probeZoom` then reads the page's zoom back out every second and
   moves the readout with it. So a `Ctrl`+`=` or `Ctrl`+wheel updates the status
   line and the menu's tick instead of leaving both on the configured value
   forever.

   The value is **not** snapped onto the ladder when shown. Chromium's hotkey rungs
   (110, 125, 150, …) are not ours (100, 110, 120, …), so the readout can legitimately
   show 125% while no menu rung is ticked — which is the honest reading of "off the
   ladder". The menu's tick and the status line are drawn from the same
   `currentPercent`, so they cannot disagree with each other.

   `settings.json`'s `zoom_percent` is the **anchor** rather than the whole answer:
   it is what gets pushed on page load, and what survives a restart. A hotkey is
   session-local — dsh is a SPA, so its client-side routing never reaches
   `on_page_load`, and the next reload re-pushes the config. `chrome::tests` holds
   the shape with `the_page_measures_its_own_display_scale`, which asserts the
   divisor is *measured* and would catch it being hardcoded or handed in from Rust.

   **A scale factor must not come back through the injected config.** That was the
   original `osScale`, and the reason it fails is that a factor from Rust can only
   come from an API, and every API lies here. Measuring it in the page is what
   makes it right.

   **The push is unconditional, on every page load**, which is the second half of
   the decision and the half that needed measuring. WebView2 remembers a zoom
   *per origin*, and there are two: the placeholder is `tauri.localhost`, dsh is
   `127.0.0.1:3080`. The macOS `ZoomDecision` rule — push only when our own
   preference moved — pushed 100% to the placeholder, recorded "already applied",
   and skipped the dsh page, which still carried its own 125%. The menu ticked
   100% over a page rendered at 125%. The cost: a `Ctrl`+`=` is session-local
   (dsh is a SPA, so its client-side routing never reaches `on_page_load`).

   **A 16-rung list, not 放大/缩小.** The ladder is 50–200 by 10 and the rungs worth
   reaching are not adjacent: 50% for a dense transcript, 200% for text across a
   room. Stepping there one press at a time is why the ladder used to stop at 100 —
   the far rungs were not worth walking to. Enumerated from Rust so the menu cannot
   offer a rung `zoom_ladder_step` cannot produce, and cannot miss one either.

   ### The failed detour: dsh's own `fontSize`

   This went in and came out, and the reason is worth keeping.

   dsh has a real, persisted text-size preference — `dsh-client-ui-theme`,
   `Schema.number().step(1).min(10).max(22).default(14)`, applied as
   `--dsh-content-font-size` and consumed by twelve of its packages. Using it
   instead of the webview's zoom looked obviously right: one truth, dsh's own
   document, changeable from dsh's settings page.

   It is the wrong mechanism. `fontSize` changes the *font*; it does not change
   how much of dsh fits on screen. Line heights grow, the content column narrows,
   cards reflow — and the amount of information in the window is unchanged, just
   spread over more pixels. That is a font preference. The thing users mean by
   放大 is the one this shell already had, and the one the macOS shell has.

   The implementation was removed in full. What survives is the method note,
   because the failure was in the reading and it is easy to repeat:

   - **dsh's Typert descriptors are the wire contract, and they are generated.**
     `typert.host.js` in `dsh-api-settings-controller` carries every real
     signature: `namespace: 'settings'`, `method: 'mutate'`, and
     `parameters: [{name: 'ns', wire: 'ns'}, {name: 'ops'}, {name: 'expectedRevision'}]`.
     `ctx.remote.settings.describe()` is a *caller* of that, not its definition.
     The wire call was inferred from the caller and got three things wrong: the
     endpoint is `settings/mutate` with a slash (`endpointOf` is
     `` `${namespace}/${method}` ``), the payload is wrapped (`{args: {...}}`), and
     the parameter names are `ns`/`ops`/`expectedRevision`. It answered HTTP 404,
     which is what a wrong URL looks like and what a right-looking abstraction does
     not.
   - **A second attempt at the same mistake**: `EnumDisplaySettings` was read as
     the display scale, and `LogPixels=119` as the scale. Both were wrong for
     reasons that took a full measurement round each. When a number is disputed,
     measure it from the layer that defines it.

7. **The injected script's own fallbacks are a second copy of every constant.**
   `platform_adapt.js` reads `window.__DSH_SHELL__`, but each value also has a
   literal fallback for the case where the script runs without it. Those literals
   drifted (a 28px bar against a 24px constant) and the chrome looked right only
   because the injected value always won. Two tests in `chrome.rs` now hold the
   two sides together.
8. **A synthetic click from another process never reaches the webview.**
   `mouse_event` from PowerShell is refused by the foreground lock, so
   minimize/maximize/✕ and the menu button cannot be verified that way — the
   button appears dead while it is fine. Use `PostMessage(WM_SYSCOMMAND, SC_CLOSE)`
   for the real close path, and ask the user for anything that needs a click.
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
12. **dsh `0.2.0-rc.2` *does* answer the desktop contract — about 1.4 s after the
    page loads.** This corrects an earlier entry in this file, which claimed the
    opposite and was wrong in a way that survived two rounds of re-measurement.

    Measured, from the running app's own log:

        chrome ok: … placeholder=false contract=contractMissing top_clearance=None
        chrome ok: … placeholder=false contract=contractActive   top_clearance=Some(28.0)

    `top_clearance` coming back as exactly the height we declared is the proof:
    dsh is echoing `--dsh-windows-titlebar-height` into
    `--dsh-frame-top-clearance`. Every report before that catches it mid-flight.
    So `contract=contractMissing` in a log is a **statement about a moment**, not a
    verdict about the dsh — do not read it as "this dsh has no contract".

    Three ways this was measured wrongly, all of which cost real time:

    - **Reading the static CSS.** Fetch the token URL, follow the 303, and read
      `assets/index-*.css`: `--dsh-frame-chrome-top` is there once, as a
      *consumer* (`var(--dsh-frame-chrome-top, 0px)`), never defined. That says
      nothing about whether the contract works, because the publishing rules are
      not in the compiled stylesheet at all.
    - **Grepping the npm tree.** The rules are in
      `node_modules/@deepseek-ai/dsh-client-ui-layout/lib/client.js`. Grepping the
      installed tree is also the wrong question — but it fails *open*, i.e. it
      suggests the contract exists, which is why it produced a confident wrong
      answer rather than a confident right one.
    - **Sampling too early.** `contractState()` runs at install and 1.5 s later.
      That second sample is not late enough. A `chrome_report` logged *after* the
      page has settled is the only trustworthy reading, which is why
      `top_clearance` is now in the log line: `contract` without the value it
      published means only "we asked and something came back".

    Two things this entry used to get wrong that are now settled:
    - `row=none brandRow=none no left column found` was never about the page
      failing to boot. It said the *content column's top row* was not found by
      the geometric layer. The geometric layer has since been deleted, so that
      line no longer appears — and reading it as "the page did not boot" was
      wrong regardless; the screenshot showed a fully working UI.
    - The contract also **claims part of the caption**: dsh pins its sidebar
      toggle to `left: 12px` and centres it with
      `top: calc((var(--dsh-windows-titlebar-height) - 28px) / 2)`. That formula is
      why `BAR_H` is 36 — at 28 it returns 0 and the toggle ends up flush against
      the window's top edge — and why our menu button starts at 48, the first
      column past the toggle's 12..40. `chrome::tests` asserts both relationships
      rather than the numbers, so the reason survives the next edit.

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
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '36px')
```

Measured against real dsh `0.2.0-rc.2`, not assumed
(`docs/dsh-desktop-contract.md` §2.3): the frame then reserves the caption
height itself, dsh paints its own drag strip, the content column gets its 16px
top-left radius, and `--dsh-frame-chrome-top` / `--dsh-frame-overlay-top` are
published.

Fullscreen converges **asymmetrically**: `--dsh-frame-chrome-top` resets to
`0px`, but `--dsh-frame-top-clearance` keeps its value. They agree in the normal
case and this is the one state where they diverge — read `chrome-top`, which is
also what `contractState()` reads. Where the contract lives and how to apply it
are in **`docs/dsh-windows-contract.md`**.

`--dsh-windows-titlebar-height` is **read** by dsh and never set by it, so the
host owns the number. Declare it through `px()` like every other length: dsh reads
it as a CSS length and the page zoom multiplies it — which is the point, since
that is also why our own bar scales in step instead of being divided out (fact 6).

**The whole of `platform_adapt.js` is the contract layer now.** There is one
thing it does to dsh: those two properties. Everything else it touches is inside
its own `#dsh-shell-chrome` subtree or is a read.

The geometric fallback (`findRightColumns`, `insetColumn`, `clearCorner`,
`gutterTopRow`, `layoutSignature`, and the `dss-grab` drag strip) has been
deleted, along with `chrome::css_len`. It existed to compensate for a contract
that turns out to work, and it was the most likely thing in the file to break:
it found columns by geometry in a document whose CSS-Modules class names are
rehashed every dsh build, then wrote padding and transforms onto whatever it
believed was a column. The pass that once "padded list items and conversation
bubbles" was that code with the wrong anchor.

Worth knowing before anyone rewrites it, since all of it is still true about the
dsh page itself:

- No stable selector. No semantic `id` on the shell, and CSS-Modules class names
  are hashed per build (`pI_x6G_centerCol` in one release, something else in the
  next). Only `#root` survives.
- No ARIA landmarks: no `banner`, `main`, `complementary` or `toolbar` anywhere in
  the bundle, so accessibility cannot be used as an anchor either.
- Hit-testing is not a substitute. `elementsFromPoint` skips anything under a
  `pointer-events: none` overlay, and app headers routinely have one.

`chrome_report` logs `contract=` **and** `contract_top_clearance=` on every
report, and warns when the contract goes unanswered on a non-placeholder
document. Read both together: `contract` alone is a sample of a moment (fact 12),
and `top_clearance` is dsh telling you what it actually reserved.

dsh does *not* provide the caption's buttons. It reserves the space, offers a
drag region, and pins its own sidebar toggle into the band; the window buttons
and our menu button stay ours, because they are the only parts of a caption that
talk to the window manager.

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

## The reclaim rule asked the wrong question, twice

Two defects sat on top of each other, and fixing either alone would have looked
like success. Together they made the retry button do nothing at all.

**1. "Is the parent alive?" is the wrong question on Windows.** `dsh.cmd` is an
npm batch shim, so this shell spawns `cmd.exe` and the `node.exe` that holds the
port is its *child*. That `cmd.exe` stays alive for as long as the dsh does — it
is waiting on it — so "the parent is alive" is true for every real orphan.
Measured:

```text
PID 1868  node.exe   parent=5340   alive   ← held 3080
PID 5340  cmd.exe    parent=11688  dead    ← the dsh.cmd shim
PID 11688            does not exist
```

One step of *only* sees a living parent and refuses. The rule now walks the
ancestor chain and asks **whose** ancestor is alive: a living `cmd.exe` whose
command line contains the configured shim is ours to step over, and anything else
alive means somebody is using it. The walk stops at the first positively-dead
parent, which is the moment the launcher died.

`ProcessInfo::has_living_ancestor` is what the rule decides on;
`parent_alive` is still carried, for the log line.

**2. The harness marker never matched a real command line.** Windows reports
separators doubled:

```text
"node" "C:\Users\x\AppData\Roaming\npm\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js" web ...
```

while the marker derived from `dsh_binary_path` is spelled with single ones, so a
plain `contains` never fired and the rule refused every real dsh with the message
for *a wrong program*. `normalize_path_for_match` collapses runs of separators and
unifies `/` and `\` before comparing, which cannot make two different paths
compare equal. Do not "simplify" it to a substring on the package name: that
matches every dsh on the machine, which is the failure this module exists to
prevent.

The second was invisible until the first was fixed, because the parent check
returned early and never reached the marker comparison. When a safety check
refuses, it refuses *silently and correctly-looking* — so verify the positive
path against the real process table, not only that the negative path refuses.

Fails safe at every uncertain step, because wrongly saying "broken" kills
something in use: unreadable parent, unreadable liveness, unreadable command
line, a repeated PID, or reaching `ANCESTOR_WALK_LIMIT` all refuse. Only a fully
walked chain with every step positively observed dead is reclaimable.

The reclaim also has to stay refused for a terminal-launched dsh, which has a
live shell above our shim. `orphan::tests` asserts both directions, and the
`orphan_behind_a_live_shim` fixture exists specifically so the Windows shape
cannot be quietly simplified away.

## The restart ladder has three rules, and each was wrong once

`docs/dsh-shell-contract.md` §5.4 states them for both implementations. They live
in `main.rs::ladder_next`, split out of `supervise_dsh` so they can be tested
without spawning anything — the macOS shell made the same move.

**1. A failed *respawn* is the next rung, not the end of the ladder.** It used to
be fatal, and that is what turned one `EADDRINUSE` from a still-draining socket
into an error page: the port had not finished draining, the respawn could not
bind, and the ladder gave up on the first sign of trouble. A respawn that fails now
consumes a budget unit and continues into the next back-off. The *first* spawn
failing is still fatal — there is no ladder to climb yet, and the usual cause (the
port belongs to something that is not ours) will not fix itself.

**2. The budget is reset by uptime, not by the URL line.** A dsh that lived
`HEALTHY_AFTER` (60s) is forgiven. One that announced its endpoint and died
immediately is not, and that is the exact loop the ladder exists for. The reset
happens **before** the budget check, so a dsh that lived a full minute and then
crashed is not judged against a budget it already paid.

**3. The reclaim runs before *every* spawn, not just at start-up.** Waiting cannot
free an orphan — a leftover holding the port is supervised by nothing, so nothing
is ever going to release it. Reclaiming only at start-up meant a respawn met the
same leftover and failed the same way: three attempts, then an error page.

Doing the reclaim more often does not widen the right to kill: the rule in
`orphan::is_reclaimable_orphan` is unchanged, and it still refuses anything it
cannot prove is ours. A dsh in a terminal has a live terminal above it; our own
just-crashed child still has this app above it.

Two things that are easy to get wrong while changing this:

- **A dsh that never started has no uptime, and must not inherit the previous
  attempt's.** Leaving the old value in place let a failed respawn be forgiven for
  the long life of the dsh before it.
- **When the budget runs out, the window has to say so.** `ShellError::GaveUp`
  exists for that; the old code toasted and left the window on a dead page, which
  is the "window that lies" failure mode this repository is trying to remove.




