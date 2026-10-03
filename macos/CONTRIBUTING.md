# Contributing

dsh-swiftUI is a thin native shell. The contribution surface is small and the rules are boring on purpose.

## Layout

```
dsh-swiftUI/
├── App/
│   └── DSHShell.xcodeproj/         # Xcode project (regeneratable)
├── Sources/
│   └── DSHShell/                   # SwiftUI app target
│       ├── DSHShellApp.swift       # @main entry
│       ├── Models/                 # Plain value types
│       ├── Services/               # ProcessManager, HealthChecker, EndpointResolver
│       ├── ViewModels/             # @Observable view models
│       ├── Views/                  # SwiftUI views + NSViewRepresentable bridges
│       └── Resources/              # Info.plist, entitlements, Assets
├── Tests/DSHShellCoreTests/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ROADMAP.md
│   └── adr/                        # Architecture Decision Records
├── scripts/                        # Build + dev helpers
└── tools/                          # Misc dev tooling
```

## Build / test

```bash
swift build
swift test
```

Before opening a PR, all of:

- `swift build` succeeds on macOS 27 (Xcode-beta)
- `swift test` passes
- The SwiftUI app launches in Xcode and embeds the dsh web view against a real `dsh web` instance

## Code style

- 4-space indent, trailing newline, LF line endings (enforced by `.gitattributes`).
- One public type per file when the file is non-trivial.
- Prefer SwiftUI observation over `ObservableObject`/`@Published` (we target macOS 14+).
- Anything that touches `Process`, `Pipe`, or `WKWebView` carries a doc comment explaining the lifecycle and the sandbox implications.

## Communication

Issues and PRs happen on GitHub. No CLA is required — the project is MIT.
