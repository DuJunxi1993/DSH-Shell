# ADR 0003: WKWebView, not Electron / Tauri / Wails

- Status: Accepted
- Date: 2026-01-01
- Deciders: dsh-swiftUI maintainers

## Context

The dsh SPA is already a WebKit-targeting React app. We need a host to embed it. The candidate hosts are:

- **WKWebView** (Apple platform-native, SwiftUI bridged via `NSViewRepresentable`).
- **Electron** (Chromium + Node.js).
- **Tauri** (system WebView + Rust).
- **Wails** (system WebView + Go).

## Decision

Use **WKWebView**.

## Rationale

- **Same engine.** dsh tunes its build for WebKit. Using Chromium introduces a second rendering pipeline we have to test against.
- **No extra runtime.** We don't need to ship a Node.js with our app; dsh itself needs Node, and the user has it (via npm). Adding another Node runtime for the host doubles the disk footprint for no benefit.
- **SwiftUI is the value.** We are a *native shell*. The native part is the SwiftUI window, the menu, the lifecycle, and the future panels. WKWebView is the smallest plausible host that lets us stay native everywhere else.
- **Sandbox story.** WKWebView is App Sandbox-friendly when the rest of the app is; Electron requires extra privileges; Tauri adds a Rust toolchain.

## Consequences

- We are macOS-only. iOS follows for free (we will not pursue it).
- We are committing to the macOS 27 SDK. Anything WKWebView-only on macOS 27 is on the table.
- Anyone wanting a Linux/Windows build is out of luck. The contributions page notes this.
