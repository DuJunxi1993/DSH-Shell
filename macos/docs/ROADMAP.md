# Roadmap

This document captures the **native panels** that the brief lists as goals and the order in which we plan to add them. **None of them are part of the first milestone.** The first milestone is the WKWebView shell only.

The roadmap is intentionally a wishlist, not a commitment. We will re-prioritise when we see the first month of usage.

## Capability matrix

| Capability | Trigger | Pure-shell-friendly? | Notes |
|---|---|---|---|
| **Git panel** | The dsh agent does not surface a first-class Git UI. | ✅ | Native shell can add one without touching dsh. |
| **File tree** | The dsh SPA has its own file picker, but it is bounded to the workspace dsh was launched in. | ✅ | A native tree can browse any directory the user has access to. |
| **In-process terminal** | The dsh SPA has a terminal panel, but it is a child of the embedded HTML. Host-native terminal gives us split-screen, tmux, and iTerm-killer features. | ✅ | We can host a PTY in the SwiftUI process and share it with dsh via the workspace. |

## Sequencing

### Phase 1 — main shell (this milestone)

- `WKWebView` surface
- `dsh web` spawn + supervise
- attach fallback
- preferences + persistence
- AppKit window menu integration

Exit criteria: open the app, talk to the agent, close the app, the child shuts down cleanly.

### Phase 2 — Git panel (lightweight)

In priority order:

1. **Status badge** in the title bar that turns red on dirty. Reads `git status --porcelain` and `git rev-parse --abbrev-ref HEAD` against the workspace.
2. **Changes palette** (`⇧⌘G`) — a SwiftUI `List` showing modified / staged / untracked files with diff stats.
3. **Diff viewer** — a `WebView` (or `TextEditor`) for `git diff`. Use Xcode-style gutter rendering.
4. **Commit sheet** — a native modal that takes the message, runs `git commit -F -`, and refreshes.
5. **Branch switcher** — picker over `git branch --all`, runs `git switch`.
6. **Push/Pull** — buttons that wrap the obvious commands.

Implementation constraints:

- Lightweight: shell out to `git` via `Process`; no SwiftGit2 yet.
- All commands are synchronous and small. Async only for the diff scan.
- The panel reads from the same workspace root that dsh was launched with. If dsh was launched with `--workspace <other>`, we follow.

Out of scope for Phase 2 (deferred to a later phase if ever):

- Conflict resolution UI
- Interactive rebase
- Worktrees
- Submodules

### Phase 3 — File tree

In priority order:

1. **Native sidebar** rooted at the workspace. `FileManager` enumeration, lazy expansion, `.gitignore` honouring via `git check-ignore` (one shell-out per probe, cached).
2. **Reveal in Finder** + **Open with default editor** contextual menu.
3. **Quick Open** (`⌘P`) — fuzzy finder over a SQLite index that's built off the file tree.
4. **Multi-root** — let the user pin several project folders.

Out of scope:

- File *operations* (create, rename, delete). dsh already covers those. We will not silently fork the workspace.

### Phase 4 — In-process terminal

In priority order:

1. **Embedded PTY** — `posix_openpt` + `forkpty` + `Process` + `Pipe`. Render via `WKWebView` (`xterm.js`) for v1; consider a Metal renderer in v2.
2. **Default shell** — `zsh -l` against the user's normal `$SHELL` and `$PATH`.
3. **Workspace cwd** — match dsh's `--workspace`.
4. **Tabbed terminals** — defer until we feel the single-tab pain.

Out of scope (for the foreseeable future):

- Anything that requires a custom Mach kernel module or a helper tool. We will **not** ship a suid root helper.

## What we will deliberately not do

- **No dsh client plugin.** The brief is "pure shell, respect dsh's philosophy". If a later panel needs to peek at dsh internals, we will surface that as a separate decision and document it.
- **No native re-implementation of the agent UI.** The SPA is the contract.
- **No crafting of dsh's prompt context.** ditto.

## Risks

- **dsh protocol drift.** dsh is pre-1.0. We depend on the `dsh web:` URL line and the SPA fallback serving `index.html`. If either changes, the shell will lose the page. We will react fast, but this is the single biggest concrete risk.
- **App Sandbox.** Listed as a deferred fight. If we ship to the Mac App Store we will revisit.

## Tracking

Work items will be filed as GitHub issues with the labels `phase-2`, `phase-3`, `phase-4`, and milestone-tagged accordingly. The first milestone is tagged `phase-1`.
