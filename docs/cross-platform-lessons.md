# Cross-platform lessons

Implementation experience from building both shells. Not a contract — that is
[`dsh-shell-contract.md`](dsh-shell-contract.md), which says what dsh does and
what both shells must agree about. Not platform facts either — that is
`windows/AGENTS.md`, which owns everything specific to Tauri and WebView2.

This file is the third thing: **what went wrong while building it, and which of
it is portable.** Both shells are independent implementations that share
nothing but the idea, so a lesson only pays for itself if the other side can
act on it.

Every claim here is measured against real dsh `0.2.0-rc.2`, or it is marked as
a question. Measurements live in [`dsh-desktop-contract.md`](dsh-desktop-contract.md)
with raw JSON under `docs/probe/`.

Sections are written so that "Windows already does this, and here is why" is
just as findable as "Windows should check this". A guide that only lists
problems stops being read once its author stops finding new ones.

---

## 1. Taking resources from dsh — the whale logo

The menu bar shows dsh's own mark rather than a stand-in. The asset is not a
file: it is a path inside dsh's `dsh-client-ui-primitives` package.

```
<install>/lib/node_modules/@deepseek-ai/dsh/node_modules/
  @deepseek-ai/dsh-client-ui-primitives/lib/types/FishLogo.d.ts   # the path
  @deepseek-ai/dsh-client-ui-primitives/lib/index.js              # the viewBox
```

On Windows the package sits one level deeper than that, under
`@deepseek-ai/dsh/node_modules/`, because `dsh.cmd` is a shim rather than the
symlink macOS resolves through. Both shapes have to be probed; see
`windows/scripts/extract-dsh-whale.py`.

### dsh ships the whale twice, and they are not the same path

`FISH_LOGO_PATH` and the web app's `favicon.svg` are different drawings:

| Source | Canvas | Path length | Whale aspect |
|---|---|---|---|
| `FISH_LOGO_PATH` (the UI's own mark) | 23.16 × 17.04 | 3448 | 1.3581 |
| `dsh-web-frontend/dist/favicon.svg` | 50 × 50 | 3394 | 1.3298 |

Both parse to `M`×4 / `C`×71 / `Z`×4 — one outline and three holes, the same
topology — so they look alike and a diff of the rendered masks is what it takes to
tell them apart. The Windows icon was originally built from the *favicon*, which
is why it sat ~2% off dsh's UI mark; `FISH_LOGO_PATH` is what the macOS menu bar
draws, and using it is what makes the two shells carry the same whale.

### Both are needed, and they disagree

`FISH_LOGO_PATH` is in the `.d.ts` next to its sibling declaration.
`FISH_LOGO_VIEWBOX` is **not**: the type file declares it as
`{width: number; height: number}` and never fills in the numbers, so only the
bundled `index.js` has them. A script that reads one file for both gets a
compile-shaped empty result rather than an error.

**Use dsh's viewBox. Do not compute the path's bounding box.** Measured:

| Source | Width × height |
|---|---|
| `FISH_LOGO_VIEWBOX` in `index.js` | 23.16 × 17.04 |
| Bounding box of the path's own points | 23.3967 × 17.1921 |

The path's extremes fall *outside* the canvas dsh chose — its minimum x is
negative. Fitting the bounds instead of the viewBox draws the whale a percent
or two larger than the web UI does and nudges it off centre. dsh renders the
overflowing path mapped onto the viewBox, so matching that is what "the same
logo" means.

### Extract at build time, commit the result

`macos/tools/extract-dsh-logo.swift` runs before the build and writes
`DSHFishLogo.generated.swift`. Three rules, all of them about not making the
build depend on the user's machine:

- **The generated file is committed.** A machine without dsh installed must
  still build. That is not hypothetical: `dsh` resolves through `PATH` at
  runtime and the app is expected to work where the CLI is absent or somewhere
  unusual.
- **Extraction failure is not build failure.** Missing dsh, an older dsh without
  the logo, an unparseable path — all print one line and keep the committed
  file. Only "no dsh *and* no committed file to fall back on" fails.
- **Rewrite only on a real change.** An unchanged extraction leaves no git diff,
  so `git status` never lies about whether the logo moved.

The Windows tray icon is the same asset and the same three rules. Its extractor is
`windows/scripts/extract-dsh-whale.py`, which reads the same two declarations and
writes two committed artefacts: the geometry as
`windows/scripts/dsh_whale_geometry.py`, and the rasterised mask as
`windows/src-tauri/icons/dsh-whale.png` that `windows/scripts/make-icon.py` plates
and recolours into `dsh-shell.png` for `cargo tauri icon`.

The only platform-specific part is rendering. macOS draws the path into an
`NSImage` with `isTemplate`; Windows needs a bitmap, so the extractor fills the
path itself. Two things about that:

- **Pillow only.** No `cairosvg`, `resvg`, `rsvg-convert`, `inkscape` or ImageMagick
  is assumed — the icon is built a few times a year on whatever machine has the
  repo, and Pillow is already required. Filling the path is therefore ~80 lines in
  `windows/scripts/svg_path_fill.py`: flatten the cubics, then scanline-fill with
  **nonzero winding**, which is what an SVG fill actually means. Filling the four
  subpaths in order and hoping the outline comes first would break the moment dsh
  reordered them.
- **The mask is square with the viewBox letterboxed inside it**, because
  `make-icon.py` scales the mask to a square. Rendering the 23.16 × 17.04 canvas
  into an already-square raster would squash the mark before anything else saw it.

### The one thing to get wrong quietly

SVG y grows **downwards**. AppKit's and most toolkits' contexts grow **upwards**.
Miss the flip and nothing errors — the whale renders upside down, which reads as
a bug in dsh's artwork rather than in the renderer. macOS therefore does the
coordinate conversion in exactly one function, with a comment saying why.

There is a second, subtler trap: the eye. In the whale it sits at `v = 0.48` of
the viewBox height. Flipped into y-up it lands at `0.52 × height` — the upper
half, where an eye belongs. Unflipped it lands at `0.48`, the lower half. That
asymmetry is a cheap geometric check that does not need a screenshot.

---

## 2. What the desktop contract covers for free

Setting the contract properties on `<html>` makes dsh do a surprising amount of
window-chrome work itself. On darwin that includes **48px of top clearance** and
a **fourth drag region** that yields to the traffic lights.

That clearance is why the macOS window can have no title bar at all
(`.windowStyle(.hiddenTitleBar)`) and still be usable: the traffic lights float
over the page's own reserved strip, and the region dsh reserved for them is
draggable.

### dsh owns ⌘W

Not obvious, and it changes what "close" means. On darwin, dsh registers
`meta+KeyW` as part of its desktop contract:

```
keyboard filter: 7 bound chord(s) across 10 command(s) — …, meta+KeyW, …
```

So ⌘W is delivered to the page, never to the shell's own Close Window item. The
page then calls `closeWindow` over the bridge. The macOS log says so every time
it happens:

```
closeWindow: dsh requested it (revision 4A47A842-…), hiding 13796
```

**Windows: check this against your own key bindings before wiring a caption
button.** The tray shell uses a DOM caption and `Alt+F4`, so it may simply not
be exposed — but if dsh's `meta+KeyW` ever reaches a WebView2 window, whatever
handles `closeWindow` must hide rather than close, for the reason in §3.

### The contract's cost is not optional on darwin

Worth remembering when the two sides are compared. `dataset.platform` on darwin
is a **runtime switch**, not a CSS hook: its presence puts dsh into the desktop
runtime, which then requires a trusted preload (`window.dshDesktop` /
`window.dshDesktopBoot`). Setting it alone makes the Web UI fail to boot with 24
entries never activating. The measured preload surface is five entry points —
see [`dsh-shell-contract.md`](dsh-shell-contract.md) §7.

---

## 3. In a host with a background process, "close" must mean "hide"

The single most expensive macOS bug of the day, and the most portable.

**Symptom:** ⌘W quit the app. So did the status item's Show/Hide. Everything that
touched a window seemed to end the process.

**Cause,** from the log — one line between start and exit:

```
closeWindow: dsh requested it (revision 4A47A842-…), performing close on 13634
DSH Shell exiting
```

Three routes, one outcome:

1. dsh owns `meta+KeyW` (§2), so ⌘W arrives at the page.
2. The page calls `closeWindow`; the bridge ran `performClose`.
3. `performClose` destroys a SwiftUI `Window` scene's window. **Destroying the
   last window ends the process.**

The status item looked like a separate bug and was not. Its toggle used
`orderOut`, which only hides — so the window stayed alive, and the next
`closeWindow` still had something to destroy.

**Windows already gets this right**: the caption's ✕ calls `window.hide()`,
`Alt+F4` and the tray's 退出 are the real exits, and `windows/AGENTS.md` states
the invariant. This is a confirmation, not a to-do.

The transferable part is the trap itself. A menu-bar host has a window, but it
does not *have* a window in the way a document app does — closing the last one
is not a reason to end the process, and dsh's `closeWindow` is a page-initiated
request that must not be able to take the whole app down. If the Windows shell
ever routes dsh's `closeWindow`, it belongs on `hide`.

Also worth keeping: **hide rather than close, because the window is the
session.** One WKWebView holds the live bridge, the scroll position and the
composed draft. Destroying it tears all of that down and rebuilds it on the next
show, which is both slower and visibly lossy.

---

## 4. Startup hangs and orphans

The heaviest debugging of the day, and the part most likely to reach Windows.

### A port probe that lies makes every test a false positive

macOS asked "is the port free?" by binding to it with `SO_REUSEADDR`. The kernel
agreed, the check returned true, and dsh — which does *not* set that option —
then failed to bind. Nothing reported the contradiction.

The damage was not one wrong boolean. **Thirteen lifecycle tests were asserting
a property that could not fail.** They were green because the probe said so.

macOS now probes with `connect` instead: a real attempt to reach something on
that address, which reports what an actual server would see.

`windows/src-tauri/src/preflight.rs` has this:

```rust
/// Whether we can bind `host:port` right now. Checked by binding, not by
/// scraping `netstat`, so it sees the same thing dsh's own bind would see.
pub fn port_is_free(host: &str, port: u16) -> bool {
    TcpListener::bind((host, port)).is_ok()
}
```

The reasoning is sound and the choice over `netstat` is right — scraping a
process table tells you a PID, not whether *that* PID is dsh. But the bind-based
probe still has the shape that failed on macOS: it answers "could *this* socket
have bound", not "is anything listening". No `SO_REUSEADDR` here, so the exact
failure does not reproduce — and that is the point. **The test should be checked
against that question rather than assumed safe from the absence of one option.**

The check that distinguishes the two: make the test bind the port, then assert
that a *second* probe while it is held reports occupied. If both report free,
the probe cannot detect a live listener, and every test built on it is
decorative.

### Orphan identification needs three independent facts

macOS's `PortOccupant` kills nothing on suspicion. A candidate must satisfy all
three:

1. the port is the one our config asked for;
2. **nothing outside our own launch chain is supervising it** — a dsh the user ran
   from a terminal has their terminal above it, and a dsh this shell started has
   nothing above it once the shell is gone;
3. its command line matches the configured `dsh_binary_path`.

Rule 2 is what makes this safe. On a developer machine, ports get occupied by
processes that are very much in use, and the operator is usually sitting in one of
them. A dsh orphaned by a previous run and a dsh the operator launched from a
terminal both hold a port and both are named `node`. The difference is what is
above it, and it is measurable.

**How rule 2 is measured is platform-specific, and getting that wrong makes the
feature inert rather than unsafe.** macOS can ask "is my parent PID 1?": `dsh`
there is a `#!/usr/bin/env node` script, so the kernel runs it as `node` with the
shell as its direct parent, and the parent becomes 1 the moment the shell dies.
`PortOccupant.judge` does exactly that one comparison.

Windows cannot, because `dsh.cmd` is an npm batch shim: the shell spawns
`cmd.exe`, and the `node.exe` holding the port is its *child*. That `cmd.exe`
stays alive for as long as the dsh does, because it is waiting on it — so "is the
parent alive" is **true for every real orphan**. Measured on the machine that
found this:

```text
PID 1868  node.exe   parent=5340   alive   <- held 3080
PID 5340  cmd.exe    parent=11688  dead    <- the dsh.cmd shim
PID 11688            does not exist
```

So Windows walks the **whole** ancestor chain and asks *whose* ancestor is alive.
A living `cmd.exe` whose command line contains the configured shim is ours to
step over — it is alive only because our dsh is — and anything else alive means
somebody is using it. The walk stops at the first positively-dead parent, which
is the moment the launcher died.

The general rule behind all of it: **never act on a name.** This is already
rule 1 in `windows/AGENTS.md` for a much worse reason — killing `node.exe` by name
kills the harness the agent is running inside — but it applies to identification
too. "Exit（关闭 dsh）" is only safe when the process has been positively
attributed.

---

### Two bugs stacked, and the second was invisible because of the first

Fixing the ancestor walk did not make the feature work. Underneath it sat a
second defect that never had a chance to show: Windows reports command-line
separators **doubled**.

```text
"node" "C:\\Users\\x\\AppData\\Roaming\\npm\\\\node_modules\\\\@deepseek-ai\\\\dsh\\\\lib\\bin.js" web ...
```

The harness marker derived from `dsh_binary_path` is spelled with single ones, so
a plain substring match never fired and every real dsh was refused as "not the dsh
this shell is configured to" — the message for a *wrong program*, given to a
process that was exactly right. `orphan.rs::normalize_path_for_match` collapses
runs of separators and unifies `/` and `\` before comparing, which cannot make
two different paths compare equal.

Do not "simplify" it to a substring on the package name: that matches every dsh on
the machine, which is the failure this module exists to prevent.

The reason the second bug survived is the general lesson of this file: **a safety
check refuses silently and looks exactly like a safety check working.** Nothing
crashes, the log says "leaving the port alone", and the only symptom is a feature
that never fires. The evidence in AGENTS.md rule 2 was written by hand, for
exactly that reason. Neither defect is findable by asserting that the refusal
path works — both were found by watching a real orphan survive, and by the port
probe test that proves the probe can see a live server at all.
### The restart ladder is three rules, and each was wrong once

A dsh that dies has to be brought back, and the rules for that are surprisingly
easy to get wrong in ways that all look like "the app is flaky" rather than "the
rule is wrong". They are now stated in `docs/dsh-shell-contract.md` §5.4 and
implemented on both sides.

**A failed respawn is the next rung, not the end of the ladder.** This is the one
that matters most. A respawn that could not start — because the port had not
finished draining — used to end the ladder outright, so a single `EADDRINUSE` from
a socket in `TIME_WAIT` was enough to turn a recoverable crash into an error
page. A failed respawn now consumes a budget unit and continues into the next
back-off. The *first* spawn failing is still fatal: there is no ladder to climb
yet, and the usual cause — the port belongs to something that is not ours — will
not fix itself.

**The budget is reset by uptime, not by the URL line.** A dsh that announces its
endpoint and dies immediately is exactly the loop the ladder exists for, so
resetting the count when the URL arrives forgives it every time. Uptime is the
evidence that counts: `HEALTHY_AFTER` (60s) on Windows, `healthyUptime` on
macOS. The reset has to happen *before* the budget check, or a dsh that lived a
full minute and then crashed is judged against a budget it already paid.

**The reclaim runs before every spawn, not just at start-up.** Waiting cannot
free an orphan. A leftover holding the port is supervised by nothing, so nothing
is ever going to release it, and a respawn that skipped the reclaim met the same
leftover and failed the same way — three attempts, then an error page.

Two things that are easy to break while changing this, both found by writing the
rules down rather than by seeing them fail:

- **A dsh that never started has no uptime and must not inherit the previous
  attempt's.** Carrying the old value forward let a failed respawn be forgiven
  for the long life of the dsh before it, which quietly made the budget
  unlimited in exactly the case it exists to bound.
- **When the budget runs out, the window has to say so.** Windows toasted and
  left the window sitting on a dead page — the "window that lies" failure mode
  this repository is trying to remove. `ShellError::GaveUp` exists so the failure
  page can carry the reason and the attempt count.

### Closing during startup is its own hole

Independent of any crash, there is a window between "spawn returned a PID" and
"the process handle is owned by the app". Close the window in that gap and
nothing terminates the child.

Windows closes it with `starting_pid`, recorded the moment the PID exists and
deliberately **not** cleared on success — clearing it at the wrong moment opens
a second gap between the launch returning and the handle being stored. The
comment at `main.rs:185` spells out that reasoning and is worth reading.

macOS found the same hole from the other end: it never recorded the PID early,
so the fix was added afterwards as `PortOccupant`, which can find and clean up an
orphan left by *any* interrupted run — including runs of the previous shell
version. The two are complementary rather than competing, and the differences
are worth knowing:

| | Windows `starting_pid` | macOS `PortOccupant` |
|---|---|---|
| Catches an orphan from this run | yes | yes |
| Catches one left by a crash | no | yes |
| Catches one left by an older version | no | yes |
| Needs an external attribution check | no | yes (3 facts) |

A shell that has shipped is likely to want both eventually; a new one wants the
early record.

---

## 5. Zoom: the decision must be about the host's intent

macOS zoom stopped working after the first step. Every subsequent +/- was dropped,
the page sat at 60% while `settings.json` already recorded 100, and a restart
appeared to fix it.

The rule was:

```swift
if let applied = coordinator.appliedZoom,
   abs(view.pageZoom - applied) <= 0.01 {
    return          // skip
}
```

which reads as "skip if the page already holds the value we last applied". That
condition describes **nothing having changed** — so it skipped exactly when a new
preference arrived. The log showed the gap plainly: a settings write at 16:37:59,
and no `page zoom -> 100%` between it and the previous `60%`.

macOS now decides on the preference alone (`ZoomDecision` in
`DSHShellCore/Services/ZoomDecision.swift`, with the rule stated as a pure
function so it can be tested). **macOS was the side that had the bug**; Windows is
the port.

What Windows does, in `main.rs`:

```rust
// Every page load, unconditionally.
let preference = config::normalize_zoom(Config::load_or_default().zoom_percent);
apply_page_zoom(&window, state, preference)?;
```

Nothing consults the webview at all. The page zoom is re-applied from
`settings.json` on every navigation, and the menu's tick is drawn from the same
value, so the tick and the page cannot disagree.

The unconditional push is a deliberate second decision, and it is the one that
needed measuring. **WebView2 remembers a zoom per origin**, and the two origins
are different documents: our boot placeholder is `tauri.localhost`, the dsh page is
`127.0.0.1:3080`. A conditional push (the macOS rule, ported literally) pushed
100% to the placeholder, recorded "already applied", and then skipped the dsh page
— which still had its own 125% from an earlier session. The menu showed a tick at
100% over a page rendered at 125%.

The cost of pushing unconditionally: a `Ctrl`+`=` is **session-local**. It holds
until you navigate — dsh's own client-side routing never reaches `on_page_load` —
and is gone after a reload. That is worth stating because it is the one thing
about this behaviour that is surprising, and the alternative is a menu that lies.

The other side effect is worth having too. Because the decision never reads the
page, a pinch-to-zoom inside the webview is left alone for the rest of the
session, and the next menu click takes control back. Keying on the page instead
forces a choice between clobbering the pinch and never applying a preference — a
choice that does not need to exist.

### Measuring the zoom, when no API will tell you the scale

The caption shows a zoom percentage, and it has to stay right even though
Chromium's `Ctrl`+`±`/`0` change the page zoom without telling anyone. Three
attempts; the third is the one that works.

**1. A divisor injected from Rust** (`osScale`), read from a Windows DPI API. This
is what shipped at first, and it was wrong by the ratio between the API's answer
and reality: the caption claimed 125% for a page at 100%, and clicking *shrink*
appeared to enlarge the page, because the real zoom fell while a percentage
divided by 1.0 rose.

**2. No percentage at all.** Cannot be wrong, and cannot follow a hotkey either.
The menu marked a rung and the status line showed nothing.

**3. Measure the scale in the page.** The shell pushes a known zoom before the page
script runs, so the page already holds one known point on the curve.

Measured on the Windows machine, at three zoom levels:

```text
zoom  50%  -> dpr 0.63
zoom 100%  -> dpr 1.25
zoom 150%  -> dpr 1.88
```

`dpr = 1.25 x zoom`, exactly, at every level. So the 1.25 is a **display** factor,
independent of the page zoom — which is worth knowing because for two rounds of
debugging it was assumed to be the opposite ("`dpr` above 1 means Chromium is at
125%, so the caption is lying"). It is the display.

**No Windows API reports that 1.25.** `GetDpiForSystem`, `GetDpiForWindow` on the
real window, `GetDpiForMonitor`, `LOGPIXELSX` and the registry's
`PerMonitorSettings\...\DpiValue=1` all say 96 — and they keep saying it from a
process that has just set `PER_MONITOR_AWARE_V2`, which is what the shell itself
does (successfully; nothing is logged on that path).

But no API is needed. `scale = devicePixelRatio / (pushedZoom / 100)` is arithmetic
from a point the shell already knows, and every later zoom is `scale x the same
dpr`. Two details make it reliable:

- **Sample twice, ~250 ms apart, and require agreement.** `set_zoom` does not
  resize the page synchronously, so the first `devicePixelRatio` read after a push
  can still be the previous value — learning the scale from that puts the readout
  off by exactly the ratio of the two zooms. Two agreeing samples is what "the push
  has landed" looks like.
- **Reject the implausible.** A reading outside 0.5x–4x is a garbage sample, not a
  scale. Leaving the scale unset keeps the readout on the configured value rather
  than inventing a number.

Two further traps on the way there:

- **`HKCU\Control Panel\Desktop\LogPixels` is the DPI-*awareness* setting, not
  the scale.** Reading it as the scale is what turned the first wrong path into a
  second wrong turn.
- A "correction" that reported `GetDpiForWindow` returning 120 was wrong too; it
  returns 96 like everything else. Two rounds of confident measurement, both
  wrong, on a value that never had to be measured.

The readout is **not** snapped onto the ladder. Chromium's hotkey rungs (110, 125,
150, …) are not the menu's (100, 110, 120, …), so 125% can be shown while no rung
is ticked. Rounding it to 130 would report a zoom the page is not at; showing no
tick is the honest reading of "off the ladder".

The general rule: **a value the host cannot ask for is not the same as a value it
cannot know.** One known reference point is enough, and it is usually already in
hand. The older version of this section concluded the opposite — that the
derivation was underdetermined — and that conclusion was the mistake.

### The ladder belongs in one place

macOS raised its ceiling from 100% to 200% and had to change two files; Windows has
`ZOOM_MIN` / `ZOOM_MAX` / `ZOOM_STEP` / `ZOOM_DEFAULT` and `zoom_rungs()` in
`config.rs` and injects the whole list into the page rather than restating it, so
the menu cannot offer a rung the ladder arithmetic cannot produce. `windows/AGENTS.md`
fact 7 already records why a second literal copy drifts. Same reason, same fix.

The ceiling is 200 and not 100 for a measured reason: past ~150% you are choosing
to read dsh as a small window, not making it bigger. Capping at 100% did not
prevent that, it only denied a choice that turns out to be available and safe.

---

## 6. Do not race the platform at runtime

The titlebar flashed a light band across the top of the window on every switch
and minimise. The fix was attempted twice and failed twice:

1. re-assert the configuration from `didBecomeKey` / `didResignKey` /
   `didResize`, plus a 1.5s timer;
2. move that to a `.confirmationAction` toolbar on a parent view.

Both failed because the premise was wrong. AppKit **resets**
`titlebarAppearsTransparent` during key-state transitions — measurable, and the
reason a re-assertion timer existed at all. But:

- a main-queue notification callback runs *after* the frame has composited, so
  the band is already on screen before the correction lands;
- writing `window.styleMask` is itself what makes AppKit rebuild the window's
  chrome, so **the repair caused the condition it was repairing**.

What worked was making the question disappear: `.windowStyle(.hiddenTitleBar)`
hands the configuration to SwiftUI when the window is created, leaving no
window in which AppKit has a state to undo. About 80 lines of workaround went
with it — an `NSViewRepresentable`, three observers, a timer.

**The portable shape:** if a platform API needs to be kept in a particular state
and something else resets it, re-asserting is a losing position. Find the moment
the state is *established* and set it once there.

Windows already reasons this way about the chrome — `windows/AGENTS.md` is
explicit that the geometric fallback is a fallback and not the strategy, and says
to check `contract=` before adding a fourth pass. Same instinct, different API.

---

## 7. The two false signals that cost the most

Both are macOS, both are about a test or a log that should have caught something
and did not. Both apply anywhere.

### Green tests over a probe that cannot fail

Covered in §4. Worth restating as its own lesson because the shape generalises:
when a test asserts the output of a helper, the helper's *correctness* is part of
what is under test. If the probe is wrong in a way that makes the assertion
vacuous, the suite is decoration — and it is decoration precisely when the thing
it watches is broken.

### A log that only goes to a place nobody reads

The titlebar repair logged through a bare `Logger`. `os_log` with no file
redirection is not a diagnostic you can hand to anybody, and none of it appeared
in the app's log file. For several iterations the conclusion drawn from the log
was "no re-assertions are happening, so the fix worked" — when the truth was
"nothing is written there, so this tells us nothing".

macOS now uses `Log.debug`, which writes both. The same pass established the
measurement that finally located the flash: over eight window switches, the
repair ran 11 times and wrote 10 property assignments, down from 33 — because
only `titlebarAppearsTransparent` was ever reverted, while `styleMask` was being
rewritten every time for no reason.

Two rules:

- **A log line nobody has read is not evidence.** Before concluding "the code
  path did not run", confirm the path writes somewhere observable.
- **When a repair is measured, measure the thing that was wrong**, not the
  activity of the repair. "Fewer writes" was the intermediate number; "the band
  is gone" was the claim, and it needed a screenshot.

### The screenshot has to contain the thing

The recording used to diagnose the flash had 310px cut off the top — the window's
upper edge was outside the frame. Every pixel measurement taken from it described
the wrong region, and it took a while to notice that a "menu bar" being analysed
was not a menu bar at all. Worth checking the framing before drawing conclusions
from a recording.

---

## 8. Smaller ones, kept because they will recur

**The traffic lights are the only part of the caption that talks to the window
manager.** dsh reserves the space and offers a drag region; it does not supply
the buttons. Both shells keep that part native.

**Shell chrome is not a place to reimplement dsh.** The macOS sessions panel
listed `~/.dsh/sessions` for search, reveal and delete. dsh's own web UI lists
the same sessions, live, from the same data — and can open one, which the panel
could not. It was deleted. A shell's job is to get out of the way; the test is
whether the feature exists in the Web UI already.

**A toolbar inside a `Settings` scene is not a window toolbar.** `Apply` was a
`.confirmationAction`, which belongs bottom-right. Attached to one tab it became
a fourth tab beside the other three; hoisted onto the parent it still rendered
inside the tab strip, overlapping the labels. It is now a plain `HStack` under a
`Divider`. The SwiftUI-specific outcome matters less than the defect underneath:
the toolbar was attached to *one* tab, so the other two had **no way to save at
all** — their edits lived in `@State` and were discarded on close.

**Put the judgement in a testable function.** The zoom rule shipped broken
because it was two lines inside `updateNSView` and nothing covered it. Extracted
to `ZoomDecision.decide(percent:appliedPercent:)`, seven tests pin the states
that must behave differently, including the one that was wrong.

**An SVG path parser for a known asset does not need to be general.** dsh's whale
uses only `M`, `L`, `C` and `Z` — 4 moves, 71 cubics, 1 line, 4 closes. ~50 lines
covers it; a real SVG parser is hundreds and covers curves the brand mark never
uses. It returns `nil` for anything else, so an unsupported future dsh degrades
to "keep the committed artwork" rather than a whale missing half its curves.

---

## Where to look next

| Question | File |
|---|---|
| What dsh guarantees, and what both shells must agree about | [`dsh-shell-contract.md`](dsh-shell-contract.md) |
| Measured dsh behaviour, with screenshots and raw JSON | [`dsh-desktop-contract.md`](dsh-desktop-contract.md), `docs/probe/` |
| Windows/Tauri/WebView2 specifics, 11 windowing facts | `windows/AGENTS.md` |
| macOS architecture and ADRs | `macos/docs/ARCHITECTURE.md`, `macos/docs/adr/` |

When a lesson here turns out to be wrong, delete it rather than softening it. A
guide that hedges is one nobody can act on.
