# Roadmap

Last updated 2026-10-02, against dsh `0.2.0-rc.2`.

## Shipped, verified

| Area | Evidence |
|---|---|
| Authenticated endpoint resolution (`dsh web:` line, token, port check) | `endpoint.rs` + 10 unit tests, `tests/endpoint_resolution.rs`, `tests/live_dsh.rs` |
| stderr is logged but never trusted as a URL source | `tests/endpoint_resolution.rs::ignores_the_bili_proxy_url_on_stderr` |
| dsh's own output mirrored to the log, tail attached to every error | `endpoint::OutputTail` |
| `spawn` mode, `attach` mode, adopted instances never killed | `tests/lifecycle.rs` |
| Process-tree termination by PID, including the `Drop` backstop | `tests/lifecycle.rs`, `tests/live_dsh.rs` |
| Nested-session and port-ownership guards | `src/preflight.rs`, `tests/lifecycle.rs` |
| Single window created in `setup`, navigated to dsh | `src/main.rs` |
| Boot placeholder and in-window failure reporting | `src/index.html` |
| `initialization_script` platform adaptation | `platform_adapt.js` |
| Exit-time shutdown on the async runtime, with a deadline | `src/main.rs` |
| Daily rolling logs in debug and release | `%APPDATA%\deepseek\dsh-shell\data\logs` |
| Multi-resolution icon (16/24/32/48/64/256) + reproducible generator | `scripts/make-icon.py` |
| `.msi` and `.nsis` bundles | `cargo tauri build` |
| 38 hermetic tests, clippy clean, release build clean | `cargo test`, `cargo clippy` |

## Next

Ordered by what a user would notice.

1. **A settings UI.** `settings.json` is hand-edited today. The obvious minimum
   is a tray/menu entry that opens the file; a real panel wants `tauri-plugin-`
   dialog + a saved-and-relaunched config change.
2. **Crash-loop backoff.** `auto_restart_on_crash` is accepted and ignored. It is
   deliberately inert: restarting dsh behind a window the user is looking at
   fights the "close the window, dsh dies" contract. It becomes safe once there
   is a visible status affordance saying "reconnecting", which is also what makes
   a mid-session dsh crash tolerable at all.
3. **Adopt a running dsh automatically.** If the port is in use, offer
   `attach` in the failure message instead of only naming it. The guard already
   detects the condition; the offer is UI.
4. **A visible connection state.** The window title is the only signal today.
   A subtle badge for "starting / ready / reloading" would cover the cold-start
   window and any future reload.
5. **Code signing.** Unsigned bundles trigger SmartScreen. Out of scope until
   there is a distribution channel.

## Deferred

- **macOS / Linux.** The core is platform-agnostic and `platform.rs` has both
  branches, but only Windows is compiled and exercised. `attach` mode and the
  endpoint tests would transfer unchanged; the kill path would not.
- **Transparent titlebar / custom chrome.** Cosmetic, and it fights the WebView2
  resize behaviour.
- **Multi-instance.** Out of scope by the pure-shell principle: one window, one
  dsh.
- **dsh client-plugin integration.** Explicitly not doing this. The shell stays
  an HTTP consumer.

## Known limitations

- `auto_restart_on_crash` does nothing (see above).
- A dsh that dies while the window is open leaves the window on its last page
  with no retry. Detecting that needs the child-exit signal wired into the UI;
  the child is already reaped correctly either way.
- The `bili` proxy on port 18787 is shared machine-wide, and a second dsh
  attaches to an existing one rather than failing. dsh-shell's port guard does
  not cover that case: it only checks the web port it was asked to bind.
- macOS: the `dsh` shim is not a `.cmd`, so the cmd.exe indirection the Windows
  kill path compensates for does not apply there.
