## [0.2.0] - 2026-10-13

### Added

- The **start-up failure page** now shows the evidence and offers a way out.
  Previously it set two text nodes and stopped, so a deliberate refusal to end
  somebody else's process was indistinguishable from a hang. It now lists what
  holds our port — PID, command line, and why it is or is not ours — and offers
  **Retry** plus **Close leftovers and retry**. The cleanup button is only shown
  when the reclaim rule agreed there was something of ours to close, and it
  re-runs the reclaim on demand: it exists for the launch where the automatic one
  declined, so it must not be a no-op because an earlier one succeeded.
  Deliberately scoped to *our* port. Listing every `node.exe` on the machine would
  be mostly irrelevant processes with alarming names, and the one that matters
  would be buried.
  - The **caption menu lists the whole page-zoom ladder** — 50%–200% in 10% steps,
    the current rung ticked, then a reset to 100% behind a rule. A list of rungs
    rather than 放大/缩小 because the ladder has sixteen steps and the ones worth
    reaching are not adjacent: 50% for a dense transcript, 200% for text across a
    room. Enumerated from `config::zoom_rungs()`, the same list the ladder
    arithmetic uses, so the menu cannot offer a percentage nothing can produce.
  - **Zoom survives a restart.** `zoom_percent` is a real setting again, mirrored
    from `zoomPercent` in the macOS shell, and the menu writes it. It had been
    demoted to a read-and-ignore tombstone, which meant a zoom picked from the
    menu was silently forgotten on the next save.
  - A **menu button** in the caption, opening that panel. It sits at 48px from the
    left edge because
  the desktop contract pins dsh's own sidebar toggle to `left: 12px`, and 48 is
  the first column past it — the same column dsh puts its collapsed new-session
  button in.
- A **status line**, centred in the caption: which dsh we are attached to and
  whether it is still answering.
- `auto_restart_on_crash` is no longer a dead config field. A dsh that dies on its
  own is restarted, bounded to three attempts with a 2s -> 4s -> 8s backoff. The
  budget resets only after dsh has stayed up a full minute, so a crash at lunchtime
  and again at nine are two failures rather than one long one. After the budget is
  spent the shell stops and says so, instead of respawning forever.
- A dsh orphaned by an **earlier** run is now reclaimed — at start-up when it
  holds the port we need, and at exit when it is *still* holding our port after
  our own tree kill. Because it means killing a process this shell never spawned,
  a candidate must satisfy three independent facts: it owns our port, nothing
  outside our own launch chain is still alive above it, and its command line names
  the harness derived from our own `dsh_binary_path`.
- The menu button and the window buttons carry hover highlights, a press
  animation, a focus ring, and a 160ms rotation when the panel opens.


### Changed

- **The caption is 36px, and the caption is dsh's.** The bar height is the one
  number the desktop contract makes the host own, and dsh centres its 28px
  sidebar toggle with `top: calc((var(--dsh-windows-titlebar-height) - 28px) /
  2)`. At 28 that formula returns 0 and the toggle ends up flush against the
  window's top edge; at 36 it lands on the same top edge as our own button row.
- **Page zoom is WebView2's.** The hotkeys are Chromium's own and the chrome
  scales with the page, exactly as dsh's reserved band does. The 1/zoom division
  that kept the chrome a fixed physical size is gone — it was the single most
  bug-prone line in the file, and it was never needed, because
  `--dsh-windows-titlebar-height` is a CSS length and scales with everything
  else. Dividing the chrome out while dsh scaled in is what would have separated
  them.
- The geometric fallback (`findRightColumns`, `insetColumn`, `clearCorner`,
  `gutterTopRow`, `layoutSignature`) and our own drag strip are **deleted**, and
  `platform_adapt.js` now does exactly two things to dsh's document: declare the
  contract. The pass found columns by geometry in a document whose CSS-Modules
  class names are rehashed every dsh build and wrote padding onto whatever it
  believed was a column.

### Removed

- **BREAKING (config):** `zoom_percent`. Zoom is no longer persisted in
  `settings.json` — WebView2 restores the last zoom per origin by itself. A
  settings file written by an earlier build still loads: the key is accepted,
  ignored, and not written back. Because the struct uses `deny_unknown_fields`,
  deleting the key outright would have made every existing file unparseable, and
  `load_or_default` answers a parse failure with defaults — quietly handing the
  user a different port and launch mode than the one they chose.
- `zoom_step` and `zoom_reset` are replaced by one `set_page_zoom(percent)`. The
  hotkeys are Chromium's, so the shell no longer knows the current zoom and
  cannot step from it; the page derives it from `devicePixelRatio` over the
  system scale factor and asks for the rung it wants.

### Fixed

- **The menu button's bars changed thickness with the zoom.** They are now three
  stroked SVG lines; they were three `<span>`s at `height:1.5px` with
  `border-radius:0.75px`. A fractional CSS height spans more than one physical
  pixel row at any non-integral scale, the compositor antialiases across the
  boundary, and the bar is painted up to a pixel fatter — which way it rounds
  depends on the fractional part of the scale. A zoom hotkey moves in Chromium's
  *zoom levels* (a logarithmic ladder) while the menu calls `set_zoom` with an
  exact factor, so the two land on different phases at the same nominal zoom and
  looked different: the hotkey path made the bars visibly thicker and a menu click
  corrected them. The window buttons have always been SVG and never showed it.
- The caption's status line shows the zoom again — `● dsh 127.0.0.1:3080 · 130%`.
  The figure is `zoom_percent`, the same value the menu's check mark and the push
  onto the webview use, so the three cannot disagree; it is not measured from
  `devicePixelRatio`, which needs a display scale no API here will name.
- **Three bugs in the menu button, all of them visible only by looking at it.**
  It rendered as a black rectangle, because the glyph was one `border-top` plus
  two `box-shadow`s, and a shadow is cast from the element's *border box* — give
  the element the height centring needs and the two "lines" become a filled block.
  It had no hover highlight, because its inline `background:transparent` outranks
  the stylesheet's `:hover` rule. And it could not be closed, because the
  dismiss-alongside handler compared `event.target === menuButton` while a click
  lands on the glyph *inside* it: the handler closed the panel and the button's
  own handler immediately reopened it.
- The same inline-background mistake was also on the zoom panel's rows, found by
  the new test rather than by a screenshot.
- **The window buttons no longer maximise the window when double-clicked.** The
  contract paints dsh's drag strip across the whole caption and our controls sit
  on top of it; Chromium collects drag regions by bounds, so a control without its
  own `app-region` does not mask the strip underneath. Two quick clicks on the
  button read as a double-click on a drag region. Fixed with
  `-webkit-app-region: no-drag` on every control we own — the same remedy dsh
  applies to its own sidebar toggle.
- The caption's controls are inset 10px from the window's right edge, so ✕ no
  longer reads as part of the page.
- **The orphan reclaim asked the wrong question, and then a second one.**
  "Is the parent alive?" is always true for a real orphan on Windows, because
  `dsh.cmd` is a batch shim: the `node.exe` holding the port is a child of a
  `cmd.exe` that stays alive waiting on it. Measured, `node 1868` → `cmd 5340`
  (alive) → `11688` (dead). One step of only saw a living parent and refused, so
  the retry button cleared nothing and the port stayed busy. The rule now walks
  the ancestor chain and asks *whose* ancestor is alive: a living `cmd.exe` whose
  command line contains the configured shim is ours to step over, anything else
  alive means somebody is using it, and the first positively-dead parent is the
  break. Underneath that sat a second defect, invisible because the first returned
  early: Windows reports command-line separators doubled
  (`npm\\node_modules\\...`), so the harness marker built from `dsh_binary_path`
  never matched and every real dsh was refused as "not the dsh this shell is
  configured to". Both are fixed; a terminal-launched dsh is still refused.
  This is the third round of "the reclaim never worked", and the reason is always
  the same — a safety check refuses silently and correctly-looking, so only the
  positive path against the real process table shows the truth.
  - **The caption no longer shows a zoom percentage, and why that matters.** The
    readout was `devicePixelRatio` divided by the display's scale, and that
    divisor is not obtainable on the machine it was measured on. At three zoom
    levels:

    ```text
    zoom  50%  -> dpr 0.63
    zoom 100%  -> dpr 1.25
    zoom 150%  -> dpr 1.88
    ```

    `dpr = 1.25 x zoom` exactly, so the 1.25 is a *display* factor independent of
    the page zoom — which is the opposite of what two rounds of debugging assumed
    ("`dpr` above 1 means Chromium is at 125%, so the caption is lying"). Meanwhile
    `GetDpiForSystem`, `GetDpiForWindow` on the real window, `GetDpiForMonitor`,
    `LOGPIXELSX` and the registry's `DpiValue=1` all report 96, and report 96 from
    a process that has just set `PER_MONITOR_AWARE_V2`. The derivation is
    underdetermined rather than merely wrong: the divisor exists and nothing
    reachable will name it. Two traps on the way: `HKCU\Control Panel\Desktop\
    LogPixels` is the DPI-*awareness* setting rather than the scale, and a
    "correction" claiming `GetDpiForWindow` returns 120 was wrong too — it returns
    96, as does everything else.

    So the menu now marks the rung `settings.json` says and shows no number at
    all: there is nothing to be wrong. All of `osScale`, `GetDpiForWindow`, the
    per-page `__DSH_SHELL_OS_SCALE__` injection and the `ScaleFactorChanged`
    handler are gone with it; `declare_dpi_awareness` stays, because a
    DPI-unaware *window* is laid out at 96 DPI and stretched, which puts the
    controls in the wrong place. This is also the real reason clicking 缩小
    appeared to enlarge the page: the zoom really did fall, while a percentage
    divided by 1.0 rose.
  - **A zoom chosen in the menu is now applied on every page load, unconditionally.**
    WebView2 remembers a zoom *per origin*, and there are two: the placeholder is
    `tauri.localhost`, dsh is `127.0.0.1:3080`. The macOS `ZoomDecision` rule — push
    only when our own preference moved — pushed 100% to the placeholder, recorded
    "already applied", and then skipped the dsh page, which still carried its own
    125% from an earlier session. The menu ticked 100% over a page rendered at
    125%. The cost is that `Ctrl`+`=` is session-local: it holds until you
    navigate (dsh's client-side routing never reaches `on_page_load`) and is gone
    after a reload. The configured rung is what survives a restart, which is the
    only meaning "keep the zoom I had last time" can have when two origins can
    each remember one.
  - **The zoom ladder could skip a step**: from 125%, "放大" landed on 150%. The
    arithmetic rounded to the nearest rung and *then* added the direction, so
    whenever the two disagreed it moved twice. The step function now uses floor for
    shrink and ceil for enlarge, in Rust where it is unit-tested against every
    rung — including the exact f64 trap that motivated moving it, since 130/10 is
    12.999999999999998 and would floor to 12.
  - `Ctrl`+`±`/`0` are Chromium's own and are deliberately not intercepted, so a
    hotkey and a click on a rung are the same operation; `zoom_hotkeys_enabled`
    is written out explicitly because its default is a `serde(default)` bool and
    therefore false.
- `boot.json` still granted `allow-zoom-step`/`allow-zoom-reset` after those
  commands were replaced by `set_page_zoom`, which stopped the build. The remote
  origin's capability file had been updated; the local one had not.
- **Two bugs in the orphan reclaim made it inert.** It compared the port owner's
  executable with the configured `dsh_binary_path` — `node.exe` against
  `dsh.cmd`, which never matches — and it required `parent_pid == 1`, while
  Windows records the *dead* parent's PID instead of reparenting to 1. Both meant
  no real dsh was ever reclaimed, and the refusal was logged at info, so it
  looked like a working feature. Identity is now matched on the command line.
- The port probe is proven able to see a live server, not merely its own socket.
  The macOS shell shipped a probe that could not fail and thirteen green tests
  asserting a property that could not hold; Windows passed here for the wrong
  reason and nobody checked.

### Known limitations

- The desktop contract takes about 1.4 s to answer, so `chrome_report` logs
  `contract=contractMissing` until dsh's stylesheet lands. It is a sample of a
  moment, not a verdict about the dsh; `top_clearance` is the field that shows
  what dsh actually reserved.

## [0.1.1] - 2026-10-11

### Fixed

- The window buttons are now legible on a dark page. The glyphs are
  `currentColor` and resolve to the bar's `color: var(--dsw-alias-label-primary,
  #16181d)`; that fallback is near-black, so on a dark dsh page — which does not
  always define the alias — the buttons disappeared. The chrome now measures the
  surface the bar sits on and picks a foreground with contrast against it, so it
  follows a theme switch without knowing anything about dsh's theme tokens.
- Clicking one of the shell's own toasts (a failed startup, a dsh that exited on
  its own) now raises the window. `tauri-plugin-notification` shows the toast and
  drops the handle, so the activation handler dies with it and the click was
  swallowed; the shell's toasts now keep the handle and act on the click.

### Known limitations

- Click-to-focus requires an **installed** build. An unregistered AUMID makes a
  toast fail to appear at all, so a `cargo run` / `target\release` build claims no
  AUMID and its toasts are shown without an activation path. Launch from the Start
  Menu shortcut after installing.
- A **dsh plugin's** notifications (`new Notification(...)`, e.g.
  dsh-notification) cannot be made clickable from here. The plugin owns that toast
  end to end, the packaged-app activation APIs are absent from every available
  `windows` crate, and the toast carries no launch argument to fall back on.

## [0.1.0] - 2026-10-04

First release.

### Added

- Frameless window with an injected title bar, drawn as DOM inside dsh's own
  page, and a content-column inset that keeps dsh's controls clear of it.
- Page zoom from 50% to 100% in 10% steps, persisted across restarts, with
  `Ctrl` `+` / `-` / `0` on the page and a reset in the tray.
- Tray icon: left click shows or hides the window, right click offers
  show/hide, zoom reset, and quit.
- Single-instance behaviour: a second launch raises the running window instead
  of starting a rival process that would race dsh for its port.
- External `http(s)` links open in the default system browser; the window is
  only ever allowed to navigate to the boot placeholder and the dsh origin.
- Native toasts when dsh fails to start and when it exits unexpectedly.
- Support for dsh plugins that raise system notifications through the
  `Notification` API (verified with `dsh-notification`).
- Chrome self-diagnosis: the injected script reports its measured geometry,
  the inset it applied, and the page's notification permission to the log.

### Changed

- Capabilities are scoped per origin: the local boot page, the loopback dsh
  origin, and a minimal baseline are separate and explicit, rather than one
  broad set for everything.
- The repository was restructured into `windows/` and `macos/`, one directory
  per implementation; this changelog and this implementation moved under
  `windows/`.

### Fixed

- Only the `dsh web:` line on stdout, with the requested port and a non-empty
  `?token=`, is accepted as the UI URL — the loopback URL on stderr belongs to
  the internal `bili` proxy, and a tokenless URL can never load the SPA.
- The window is created in `setup()` only; declaring it in `tauri.conf.json` as
  well made the app die immediately after resolving the endpoint.
- Closing the window while dsh was starting no longer orphans dsh; the spawned
  PID is recorded until the process is actually owned, and the tree is
  terminated by PID.
- The injected script's fallback constants agree with the Rust constants they
  are generated from, enforced by tests, so the two cannot silently drift.
- `next_zoom` clamps at both ends of the ladder instead of jumping to 100% when
  a hand-written or oversized delta underflows.
- Layout avoidance is skipped when the page has not changed, and is forced
  after a zoom change; a continuously mutating page can no longer starve it.

[0.1.1]: https://github.com/DuJunxi1993/DSH-Shell/releases/tag/windows-v0.1.1
[0.1.0]: https://github.com/DuJunxi1993/DSH-Shell/releases/tag/windows-v0.1.0
