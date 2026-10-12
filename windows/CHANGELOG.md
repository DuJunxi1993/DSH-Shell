## [Unreleased]

### Added

- A **menu button** in the caption, opening a zoom panel: enlarge / current
  percentage / shrink / reset 100%. It sits at 48px from the left edge because
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
  a candidate must satisfy three independent facts: it owns our port, it has no
  living parent, and its command line names the harness derived from our own
  `dsh_binary_path`.

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

- **Two bugs that made the orphan reclaim inert.** It compared the port owner's
  executable with the configured `dsh_binary_path` — `node.exe` against
  `dsh.cmd`, which never matches — and it required `parent_pid == 1`, while
  Windows records the *dead* parent's PID instead of reparenting to 1. Both meant
  no real dsh was ever reclaimed, and the refusal was logged at info, so it
  looked like a working feature. Identity is now matched on the command line, and
  "orphaned" means "no living parent".
- The zoom ladder is consistent again at its new 200% ceiling. The script's
  fallback still said 100 while `config.rs` said 200, and two tests had the old
  ceiling written in as literals — which is the assertion shape the zoom tests
  exist to avoid, since they stated the old ladder rather than the rule.
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
