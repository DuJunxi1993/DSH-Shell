# DSH Shell

Native desktop shells for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) web UI — a real window instead of a browser tab, and real ownership of
the `dsh` process behind it.

This repository holds **two independent implementations** of that idea:

| Directory | Platform | Stack | Docs |
|---|---|---|---|
| [`windows/`](windows/) | Windows 10+ | Rust · Tauri 2 · WebView2 | [`windows/README.md`](windows/README.md) |
| [`macos/`](macos/) | macOS | Swift · SwiftUI · WKWebView | [`macos/README.md`](macos/README.md) |

They share the goal and nothing else. Neither wraps the other, they import no
code from each other, and each is built, tested and released on its own — so a
directory's own README is the one to read.

## Building

Windows (Rust and `cargo-tauri`):

```powershell
cd windows\src-tauri
cargo test
cargo tauri build      # -> windows\src-tauri\target\release\bundle\{msi,nsis}
```

macOS (Xcode and Swift Package Manager): see
[`macos/README.md`](macos/README.md).

## Releases

Git tags share a single namespace across the repository, so each implementation
prefixes its version with its platform:

- `windows-v0.1.0` — the Tauri shell.
- `v0.1.0`, `v0.1.2`, … — the SwiftUI shell, which predates this layout and
  keeps its unprefixed tags.

Each release's notes name the implementation, and its installers are attached to
that release only.

## License

MIT, per implementation — see [`windows/LICENSE`](windows/LICENSE) and
[`macos/LICENSE`](macos/LICENSE). The two carry different copyright holders, so
there is deliberately no single top-level `LICENSE`.
