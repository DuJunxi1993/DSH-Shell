# The Windows desktop contract

How to tell dsh that this host is drawing the window caption, and what dsh does
in return. Two statements, and dsh reserves the caption height, paints its own
drag strip, rounds the content corner and publishes the clearances other parts
of the UI position themselves from.

Written for the Windows/Tauri work. The contract is not Windows-specific — it
exists because dsh supports desktop hosts generally — but only this side uses
the Windows branch of it, and the injection timing below is a WebView2 problem.

Measured against dsh `0.2.0-rc.2`. Numbers and raw JSON are in
[`docs/probe/report.json`](probe/report.json) under `modes.windows`; the narrative
is in [`dsh-desktop-contract.md`](dsh-desktop-contract.md) §2.3.

---

## 1. Where it lives

### The interface

Two statements on `<html>`, and nothing else:

```js
document.documentElement.setAttribute('data-windows-titlebar', '')
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '32px')
```

The attribute is the switch. The custom property is a **CSS length that the host
owns** — dsh reads it and never writes it. (By contrast it *does* publish
`--dsh-frame-*` and `--dsh-windows-sidebar-width`; see §3.)

### The authoritative implementation

dsh's code, not this repository's description of it:

| Where | What |
|---|---|
| `@deepseek-ai/dsh-client-ui-layout/lib/client.js` | **The contract itself** — every CSS rule and the JS that reads the height |
| `@deepseek-ai/dsh-web-frontend/dist/assets/index-*.css` | The compiled stylesheet (the floating-panel rule, §3) |
| `@deepseek-ai/dsh-client-ui-sidebar/lib/client.js` | Consumer — positions the sidebar toggle from the height |
| `@deepseek-ai/dsh-client-ui-sidebar-right/lib/client.js` | Consumer |
| `@deepseek-ai/dsh-client-ui-settings-account/lib/client.js` | Consumer |

Installed at
`<npm prefix>/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/`.

**The class names are CSS-Modules hashes and change every build.** They read
`pI_x6G_frame`, `hHd-Xa_toggle`, `_float_6nhg2_156` in `0.2.0-rc.2`. Nothing in
this document should be copied into code as a selector — the contract is the
`data-windows-titlebar` attribute, and dsh's own stylesheet does the matching.

### Where this repository records it

| Where | What |
|---|---|
| `windows/platform_adapt.js` → `declareDesktopContract()` | This side's application of it |
| `windows/src-tauri/src/chrome.rs` | The injected-chrome geometry and the zoom compensation |
| `docs/dsh-desktop-contract.md` §2.3 | The measurements and the reasoning |
| `docs/probe/report.json` → `modes.windows` | The raw evidence |
| `windows/AGENTS.md` | The windowing facts this contract sits inside |

---

## 2. How to apply it

### The two statements, and when to send them

```js
document.documentElement.setAttribute('data-windows-titlebar', '')
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '32px')
```

**They must be idempotent.** dsh has two injection paths on Windows and both
run:

- `initialization_script` runs on every navigation, but **only reaches our own
  local placeholder page** — dsh serves its own Content-Security-Policy and a
  WebView2 document-created injection is subject to it.
- `on_page_load` + `window.eval` reaches the real dsh origin, because the call
  comes from the host side and CSP does not apply to it.

So the real page gets the contract through the second path, and the script has to
survive being run by both. `declareDesktopContract()` guards with
`if (!html.hasAttribute(...))`; the `setProperty` is naturally idempotent.

### The height is a CSS length, not a design pixel

The page is zoomed (Ctrl +/−/0) and the chrome is not, so a design length `D`
that must render as `D` logical pixels has to be sent as `D / zoom`.

Every length in the injected script goes through one pair of helpers:

```js
function cssPx(designPx) { return designPx / z; }   // z = current zoom factor
function px(designPx) { return cssPx(designPx) + "px"; }
```

`--dsh-windows-titlebar-height` is declared through `px()` like every other
length — dsh reads it as a CSS length and the page zoom multiplies it, exactly
like the lengths around it.

**That division is the only one allowed.** Dividing the lengths *and*
counter-scaling with a transform applied the correction twice, and at 50% zoom
the window buttons rendered at 92 logical pixels instead of 46 — "the menu bar
grows when I zoom out". `windows/AGENTS.md` fact 6 and `chrome.rs`'s tests hold
this in place.

### How to know it took effect

Do not check that your own attribute is present — that only means you set it.

Check that **dsh answered**:

```js
function contractState() {
  if (html.hasAttribute("data-dsh-shell-placeholder")) return "contractMissing";
  var published = getComputedStyle(html).getPropertyValue("--dsh-frame-chrome-top").trim();
  return published ? "contractActive" : "contractMissing";
}
```

`--dsh-frame-chrome-top` is empty until dsh's stylesheet applies, and non-empty
once it has. That is the difference between "I asked" and "it happened", and it
is the field to check before adding geometry of your own.

The placeholder clause matters because the local boot page is not dsh and will
never answer. Without it, every report during startup would warn about a missing
contract that was never going to be there.

### The cost of a wrong number

The height is not only the frame's padding. dsh positions the sidebar toggle
from it:

```css
[data-windows-titlebar] .toggle {
  top: calc((var(--dsh-windows-titlebar-height) - 28px) / 2);
  left: 12px;
}
```

Get it wrong and the caption is the wrong height *and* the toggle is vertically
off inside it.

---

## 3. What dsh does in return

Quoted from `dsh-client-ui-layout/lib/client.js`, with the hashed class names
kept so the correspondence is checkable. Read `[data-windows-titlebar] .frame`
etc.; the hashes are noise.

### It reserves the caption height and paints behind it

```css
[data-windows-titlebar] .frame {
  --dsh-windows-content-radius: 16px;
  box-sizing: border-box;
  padding-top: var(--dsh-windows-titlebar-height);
  background: var(--dsw-specific-sidebar-fill);
  grid-template-rows: minmax(0, 1fr);
}
```

Note `--dsh-windows-content-radius` is **dsh's own constant**, not something the
host supplies. The host's only number is the titlebar height.

### It paints its own drag strip

```css
[data-windows-titlebar] .frame::before {
  content: "";
  height: var(--dsh-windows-titlebar-height);
  background: var(--dsw-specific-sidebar-fill);
  -webkit-app-region: drag;
  position: absolute;
  inset: 0 0 auto;
}
```

This is the part that replaces a native caption's drag behaviour.
`-webkit-app-region` is a WebKit/WebView2 property — WKWebView exposes no such
thing, which is why the macOS shell has to forward drags natively instead of
getting them here. The two sides get the same reserved space by different means.

### It rounds the content corner

```css
[data-windows-titlebar] .centerCol {
  background: var(--dsw-alias-bg-base);
  border-radius: var(--dsh-windows-content-radius) 0 0 0;
  corner-shape: round;
}

[data-windows-titlebar] .sidebarCol { border-right: none; }
[data-windows-titlebar] .handle    { top: var(--dsh-windows-titlebar-height); }
```

Measured: the content column's `border-top-left-radius` comes out `16px`, the
rest `0`.

### It publishes the clearances

```css
html[data-windows-titlebar] {
  --dsh-frame-top-clearance: var(--dsh-windows-titlebar-height);
  --dsh-frame-chrome-top:    var(--dsh-windows-titlebar-height);
}

html[data-platform=darwin], html[data-windows-titlebar] {
  --dsh-frame-overlay-top: calc(var(--dsh-frame-top-clearance) + 20px);
}
```

Measured on `:root` with a 32px height:

| Variable | Value |
|---|---|
| `--dsh-frame-top-clearance` | `32px` |
| `--dsh-frame-chrome-top` | `32px` |
| `--dsh-frame-overlay-top` | `calc(32px + 20px)` |

Fullscreen modal overlays consume `--dsh-frame-overlay-top`, so they are inset
by the caption height plus 20px without the host doing anything. The right-hand
dock is inset too, from the compiled stylesheet:

```css
html[data-windows-titlebar] .float {
  --dsh-dockkit-float-top: calc(var(--dsh-windows-titlebar-height) + 20px);
}
```

### Fullscreen converges — asymmetrically

```css
html[data-platform=darwin][data-fullscreen],
html[data-windows-titlebar][data-fullscreen] {
  --dsh-frame-overlay-top: 20px;
  --dsh-frame-chrome-top:   0px;
}
```

Measured in fullscreen:

```
chromeTop = 0px      ← reset
overlay   = 20px     ← reset
top       = 32px     ← NOT reset
```

**`--dsh-frame-chrome-top` goes to zero; `--dsh-frame-top-clearance` does not.**
They hold the same value in the normal case and this is the one state where they
diverge, so a consumer that reads `top-clearance` will inset by 32px in
fullscreen when it should inset by nothing.

**Use `--dsh-frame-chrome-top`.** That is also what `contractState()` reads.

---

## 4. Traps

### The fullscreen divergence, and one measurement that does not fit

The rule above is read straight out of dsh's CSS and confirmed by the probe's
variable readings. But the probe also recorded the frame's `padding-top` as
`0px` in fullscreen, and dsh's rule for that padding is unconditional:

```css
[data-windows-titlebar] .frame { padding-top: var(--dsh-windows-titlebar-height); }
```

Nothing in the stylesheet resets it. Either the probe sampled a different element
once the layout changed, or there is a rule that was not found. **Unresolved;
worth re-measuring on real Windows before relying on the frame's padding in
fullscreen.** Recorded rather than explained away.

### Windows mode has three drag regions, darwin has four

Measured: `dragRegionCount = 3` on the Windows branch against 4 on darwin. On
darwin the extra one is the strip beside the traffic lights, which dsh adds
because macOS puts them there. Windows has no equivalent, so one fewer is
expected — but it is a measured difference, not an equivalence. If the caption
stops being draggable in some region, this is the first number to check.

### The three `--dsh-windows-*` variables are not one family

They look like a set and are not:

| Variable | Who owns it |
|---|---|
| `--dsh-windows-titlebar-height` | **The host.** dsh reads it, never writes it. |
| `--dsh-windows-content-radius` | dsh. Defined by dsh's own stylesheet; the host does not supply it. |
| `--dsh-windows-sidebar-width` | dsh. Published by dsh, so the host can read it. |

Reading all three from `:root` returns `32px`, `""` and `""` — the empty ones are
not failures, they are defined on other elements or published elsewhere. Only
the first is the host's to set.

### The contract is not the same thing as a Windows host

The probe's `modes.windows` was a **simulated injection run on macOS**: the
attribute and the style were set by the probe, then measured. It establishes the
contract — "set these and dsh does that" — which is what it was for. It does not
cover the Windows host integration, where the separate problems are CSP and
injection timing (`windows/AGENTS.md` fact 3) and the per-origin ACL (facts 4 and
9).

### `initialization_script` will look like it worked

The local placeholder page receives it. The real dsh origin does not. If the
contract is declared only through `initialization_script`, the chrome appears
correct while the dsh page ignores it — see `contract=` in the `chrome_report`
output before assuming the attribute is reaching the page.

---

## The short version

```js
// From the host, on the real dsh origin, idempotently:
document.documentElement.setAttribute('data-windows-titlebar', '');
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', px(BAR_H));
```

Then check `--dsh-frame-chrome-top` is non-empty. dsh does the rest; the host's
job is the number, and the only number that is wrong is one that has not been
divided by the page zoom exactly once.
