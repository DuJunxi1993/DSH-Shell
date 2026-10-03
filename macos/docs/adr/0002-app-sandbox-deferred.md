# ADR 0002: App Sandbox is deferred

- Status: Accepted
- Date: 2026-01-01
- Deciders: dsh-swiftUI maintainers

## Context

The macOS App Sandbox is the default entitlement for Mac App Store apps. It restricts the app to a per-user container and to explicitly granted entitlements (file access, network access, etc.).

dsh's child process writes to `~/.dsh/profiles/<name>/cordis.yml` on every boot. A sandboxed app can grant writes only inside its own container; `~/.dsh` is outside that container. So spawning `dsh web` from a sandboxed process would either fail or require us to relocate dsh's profile directory, which is a hack.

The future native panels (Git, file tree, terminal) need read access to arbitrary project directories. The sandbox's `user-selected.read-write` only unlocks files the user picked in an `NSOpenPanel` — not arbitrary CLI invocations like `git status`.

## Decision

Ship the first milestone **without** the App Sandbox entitlement. Distribute as a directly downloadable `.app` (or via Homebrew Cask, or via `xcodebuild` output). The Mac App Store path is deferred.

## Consequences

- We can spawn `dsh web` freely.
- We can read the user's project directories without going through `NSOpenPanel`.
- We must self-distribute and self-notarize. Users get a less polished installer than the App Store route.
- Code signing must still be valid; we use a Developer ID identity.

## Migration plan (when we eventually ship to the App Store)

- Enable App Sandbox.
- Add `com.apple.security.network.client` (so we can talk to `127.0.0.1`).
- Add `com.apple.security.files.user-selected.read-write` (for the worktree picker).
- Move `dsh` to a `LaunchAgent` we install separately. The agent runs outside the sandbox; the app talks to it via the loopback socket.
- Inside the sandbox, write the dsh profile directory to `~/Library/Containers/<bundle-id>/Data/Library/Application Support/dsh-swiftUI/dsh-home` and pass `DSH_HOME` to the child.

Until then, the app is a private developer build.
