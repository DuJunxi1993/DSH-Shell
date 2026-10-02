# dsh-shell Roadmap

This document tracks what is shipped, what is in flight, and what is intentionally deferred.
It mirrors the spirit of `dsh-swiftUI/docs/roadmap.md` but adapted to the Tauri / Rust port.

## Shipped ✅

| Area | Evidence |
|---|---|
| Cross-platform Rust core (`config` / `endpoint` / `process` / `platform` / `error`) | `src-tauri/src/*.rs` |
| `spawn` mode — fork `dsh web`, capture URL via regex, port-probe fallback | `process.rs` + `endpoint.rs` |
| `attach` mode — probe loopback for an already-running dsh | `process.rs::attach` |
| Graceful shutdown (`start_kill` → 5 s → `kill` → `wait`) | `platform.rs::graceful_shutdown` |
| Tauri 2.x window + WebView2 load of dsh URL | `main.rs::setup` |
| `DSH_SHELL_CHILD` anti-nest guard (passive, env-gated) | `process.rs::anti_nest_check` |
| `cargo build --release` clean (0 warning / 0 error) | Verified at commit |
| `cargo test` clean (10 unit + 9 integration) | Verified at commit |
| `cargo clippy -- -D warnings` clean | Verified at commit |
| 1:1 port of dsh-swiftUI defaults (port 34247, launch_mode `spawn`) | `config.rs::default` |
| 1:1 port of dsh-swiftUI config schema (deny_unknown_fields) | `config.rs::Config` |
| Platform CSS injection | `src/platform_adapt.css` |

## In flight ⏳

- `.msi` / `.nsis` bundle via `npm run build` (needs tauri-cli install)
- Real application icon (current is a placeholder teal "D" generated via .NET System.Drawing)
- README manual-verification checklist (drafted; awaiting operator sign-off)

## Deferred 📌

- Crash-loop backoff (mirrors dsh-swiftUI's exponential 30 s cap) — gated behind `auto_restart_on_crash`
- Transparent titlebar + status badge overlay
- macOS / Linux WebView targets (core compiles; final wiring not exercised)
- Multi-instance / multi-workspace support (out of scope per the "pure shell" principle)
- DSH client-plugin integration (explicitly forbidden)

## Open follow-up tickets (not blocking release)

- [ ] Replace placeholder ICO with a designed asset (1024×1024 master, 16/32/48/64/256/512 ICO entries)
- [ ] Resolve "dsh stderr" log noise (currently echoed at WARN level — should be INFO for normal startup chatter)
- [ ] Decide whether to keep `Cargo.lock` in VCS (currently ignored — flip once we hit 1.0)