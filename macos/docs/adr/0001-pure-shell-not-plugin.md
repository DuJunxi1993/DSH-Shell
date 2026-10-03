# ADR 0001: Pure shell, not a dsh client plugin

- Status: Accepted
- Date: 2026-01-01
- Deciders: dsh-swiftUI maintainers

## Context

dsh exposes a "client plugin" extension point that lets a third-party React panel live inside the dsh SPA. The temptation is to use it to embed our native panels (Git, file tree, terminal) directly into the dsh UI.

## Decision

We will **not** write a dsh client plugin in the first milestone, and the default branch's policy is to prefer the pure-shell path when both are possible.

## Consequences

- We couple to dsh's external contract (HTTP, WebSocket, the `dsh web:` URL line), not to its internal cordis API.
- When dsh ships a breaking change to the client-plugin API, we don't notice.
- Native panels communicate with dsh via the **file system** (the workspace) and via the **same WebSocket** they would have used as a plugin — but we get to use SwiftUI for the UI instead of React.
- Future panels can still ship as dsh client plugins if they need deeper integration. This ADR doesn't forbid the escape hatch; it just makes the default non-coupling.

## Alternatives considered

- **Always use the client plugin path.** Cleaner UI, but couples us to dsh's compiler and patch-layer conventions. Rejected.
- **Fork dsh.** Hard no — the brief is "respect DeepSeek's philosophy".
- **Wrap dsh in a remote dev container and proxy.** Way too heavy for a Mac native shell.
