# Changelog

All notable changes to the **Windows** implementation of DSH Shell (the Tauri
app under `windows/`). The macOS implementation keeps its own history under
`macos/`; the repository-level layout is described in the root `README.md`.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged with a `windows-` prefix (`windows-v0.1.1`) because Git tags
share one namespace with the macOS implementation's tags.

## [Unreleased]

### Added

- `auto_restart_on_crash` is no longer a dead config field. A dsh that dies on its
  own is restarted, bounded to three attempts with a 2s → 4s → 8s backoff. The
  budget resets only after dsh has stayed up a full minute, so a crash at lunchtime
  and again at nine are two failures rather than one long one. After the budget is
  spent the shell stops and says so, instead of respawning forever.
- A dsh orphaned by an **earlier** run — a crash, a kill, an upgrade from under a
  running dsh — is now reclaimed instead of making the next launch refuse to start
  and point at `attach`. Because it means killing a process this shell never
  spawned, a candidate has to satisfy three independent facts: it owns our port,
  its parent is PID 1 (orphaned, not in use), and it is the `dsh_binary_path` we
  are configured to run.

### Fixed

- The zoom ladder is consistent again at its new 200% ceiling. The script's
  fallback still said 100 while `config.rs` said 200, and two tests had the old
  ceiling written in as literals — which is the assertion shape the zoom tests
  exist to avoid, since they stated the old ladder rather than the rule.
- The port probe is proven able to see a live server, not merely its own socket.
  The macOS shell shipped a probe that could not fail and thirteen green tests
  asserting a property that could not hold; Windows passed here for the wrong
  reason and nobody checked.

### Known limitations

- The desktop contract (`data-windows-titlebar`) is **not implemented by dsh
  `0.2.0-rc.2`**, so the chrome continues to compensate geometrically. This is the
  fallback working, not a regression: the chrome declares the contract, reads back
  whether dsh answered, logs `contractMissing` and carries on. When dsh ships it,
  the switch is automatic.

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
