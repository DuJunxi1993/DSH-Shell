/* dsh-shell window chrome, injected into every document the webview loads.
 *
 * The page is REMOTE and we do not control its stylesheet, so this file is
 * written to lose gracefully:
 *
 *  * The stylesheet carries background and hover colours only. Sizes and radii
 *    are inline, because they are geometry and have to track the page zoom, and
 *    because an inline `background` would beat every `:hover` rule in the
 *    stylesheet - which is exactly how the hover highlights went missing once.
 *  * The bar hangs off `document.documentElement`, not `body`, so nothing the
 *    page does to its own root container can capture it.
 *  * It is injected twice on purpose. `initialization_script` does not survive
 *    dsh's Content-Security-Policy, so the real page gets this from Rust via
 *    `eval` on page load; the early return below makes that idempotent.
 *
 * ## Zoom
 *
 * The page is zoomed (Ctrl +/-/0); the chrome is not. The geometry arrives from
 * Rust (`window.__DSH_SHELL__`) and every length goes through `px()`, which
 * divides by the page zoom exactly once. Do not also counter-scale with a
 * transform: that was the bug where zooming out made the buttons grow.
 * `chrome_report` re-measures the live DOM and Rust fails the run if
 * `height * zoom !== barH`.
 *
 * ## Clicking through
 *
 * Only a `GRAB_H` strip at the very top drags the window. The rest of the bar
 * is `pointer-events: none`, because a full-height drag strip silently swallows
 * every click on the page's own top row.
 *
 * ## The page's own layout
 *
 * There is no stable selector to hook - dsh's app shell has no semantic id and
 * no ARIA landmarks, and its class names are hashed per build - so the reserved
 * corner is handled by geometry. The inset prefers `margin-top` on the topmost
 * child over `padding-top` on the column, because the dock panel's tab strip is
 * not in normal flow and a parent padding does not move it.
 */
(function () {
  "use strict";

  if (window.__DSH_SHELL_CHROME__) {
    return;
  }

  var CFG = window.__DSH_SHELL__ || {};
  var BAR_H = num(CFG.barH, 28);
  var WIN_W = num(CFG.winW, 40);
  /* The drag strip spans the full bar again. It used to be halved to stop it
     swallowing clicks on the page's top row, but the real fix was to move the
     page's top row down to the session list's brand line - which sits well below
     the bar - so the strip can be as tall as the bar without covering anything
     clickable. */
  var GRAB_H = num(CFG.grabH, 28);
  var RESIZE_BORDER = num(CFG.resizeBorder, 4);
  var CORNER_R = num(CFG.cornerR, 6);
  var RESERVED_W = 3 * WIN_W;

  var ZOOM_MIN = 50;
  var ZOOM_MAX = 100;
  var ZOOM_STEP = 10;

  /* Narrowest thing that counts as a column. The sidebar's resize handle is 8px
     wide and full height, and it is a sibling of the content area, so it has to
     be excluded or it takes the content area's slot. */
  var MIN_COLUMN_W = 40;

  /* Clearance for the content row's right-hand buttons, beyond the width our own
     buttons occupy, so the page's controls are visibly separated from the
     chrome rather than butting against it. */
  var GUTTER_EXTRA = 16;

  /* Gap between the top of the window and the button row. Native captions are
     flush against the frame, but on a frameless window the buttons sit on the
     page and read as glued to the edge without it. The drag strip keeps the full
     bar height so grabbing the very top still moves the window. */
  var BUTTON_GAP = 4;

  /* Depth the dock's own header sits at, measured from the window top. The bar
     is all it has to clear - basing this on the content row's depth instead put
     the dock 84px down and left a chasm, and 44px still read as empty. */
  var DOCK_TOP = 28;

  var STYLE_ID = "dsh-shell-chrome-style";
  var ROOT_ID = "dsh-shell-chrome";

  /* The content column's top row, republished by every avoidance pass so the
     status line can read the session title out of it. Module scope on purpose:
     `applyCornerAvoidance` is a top-level function and could not see a variable
     declared inside `install`, which made every pass throw and silently
     cancelled both the gutter and the dock inset. */
  var topRow = null;
  /* The session list's brand row, published for the layout report. */
  var brandRow = null;
  var INSET_FLAG = "data-dsh-shell-inset";

  var zoom = clampZoom(num(CFG.zoom, 100));
  var z = zoom / 100;

  function num(value, fallback) {
    var parsed = Number(value);
    return isFinite(parsed) && parsed > 0 ? parsed : fallback;
  }

  function clampZoom(value) {
    if (!isFinite(value)) return ZOOM_MAX;
    if (value < ZOOM_MIN) return ZOOM_MIN;
    if (value > ZOOM_MAX) return ZOOM_MAX;
    return value;
  }

  /* The one place page zoom is divided out. See chrome::css_len.
     Two forms: `cssPx` for arithmetic and hit-testing, `px` for a CSS length.
     Using the string form in arithmetic yields NaN. */
  function cssPx(designPx) {
    return designPx / z;
  }

  function px(designPx) {
    return cssPx(designPx) + "px";
  }

  function invoke(cmd, args) {
    // `withGlobalTauri` is off, so the bridge is the internals object. Fall back
    // to the global API in case a future config turns it on.
    var internals = window.__TAURI_INTERNALS__;
    if (internals && typeof internals.invoke === "function") {
      return internals.invoke(cmd, args || {});
    }
    if (window.__TAURI__ && window.__TAURI__.core) {
      return window.__TAURI__.core.invoke(cmd, args || {});
    }
    return Promise.reject(new Error("no tauri bridge on this origin"));
  }

  /* Backgrounds and hover states live here, not inline: an inline background
     would beat every `:hover` rule in the stylesheet and the highlight would
     never show. The zoom and the sizes are still inline, because they are
     geometry and have to track the page zoom from one place.
   *
   * A constructed stylesheet is used rather than a `<style>` element because our
   * own boot page's CSP drops injected style elements - the buttons then fell
   * back to the UA default grey border and fill, which is the white outline seen
   * during startup. Constructed sheets are not subject to the page's CSP. */
  function installStylesheet() {
    var css = [
      "#" + ROOT_ID + " button {",
      "  background: transparent;",
      "  border: 0;",
      "  outline: none;",
      "  color: inherit;",
      "  cursor: default;",
      "}",
      "#" + ROOT_ID + " button:hover {",
      "  background: rgba(127,127,127,0.22);",
      "}",
      /* Light red, not a solid fill: the cluster behind it is the page's own
         surface colour, and a solid block there reads as a foreign panel. */
      "#" + ROOT_ID + " .dss-win button[data-dss-close]:hover {",
      "  background: rgba(214,45,45,0.18);",
      "}",
      "#" + ROOT_ID + " .dss-win button[data-dss-close]:hover svg g {",
      "  stroke: #c0392b;",
      "}",
      "#" + ROOT_ID + " svg { display: block; }"
    ].join("\n");

    try {
      if (window.CSSStyleSheet) {
        var sheet = new CSSStyleSheet();
        sheet.replaceSync(css);
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
        return;
      }
    } catch (error) {
      /* Older engines, or a document that forbids constructed sheets: the
         element below still works on the dsh origin. */
    }

    if (document.getElementById(STYLE_ID)) {
      return;
    }
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }

  /* A window glyph in a 10x10 viewBox. `currentColor` so it follows the host
     page's foreground, and a presentation attribute rather than an inline style
     so the close hover can override the colour from the stylesheet. */
  function glyph(kind) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 10 10");
    svg.setAttribute("width", px(10));
    svg.setAttribute("height", px(10));
    svg.setAttribute("aria-hidden", "true");

    var shape = document.createElementNS(ns, "g");
    shape.setAttribute("stroke", "currentColor");
    shape.setAttribute("stroke-width", "1.1");
    shape.setAttribute("fill", "none");
    shape.setAttribute("stroke-linecap", "round");

    function node(tag, attrs) {
      var el = document.createElementNS(ns, tag);
      for (var key in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, key)) {
          el.setAttribute(key, attrs[key]);
        }
      }
      shape.appendChild(el);
      return el;
    }

    if (kind === "min") {
      node("line", { x1: 0, y1: 5, x2: 10, y2: 5 });
    } else if (kind === "max") {
      node("rect", { x: 0.5, y: 0.5, width: 9, height: 9 });
    } else if (kind === "restore") {
      node("rect", { x: 0.5, y: 2.5, width: 7, height: 7 });
      node("rect", { x: 2.5, y: 0.5, width: 7, height: 7 });
    } else {
      node("line", { x1: 0, y1: 0, x2: 10, y2: 10 });
      node("line", { x1: 10, y1: 0, x2: 0, y2: 10 });
    }
    svg.appendChild(shape);
    return svg;
  }

  function describe(el) {
    if (!el) {
      return "none";
    }
    var r = el.getBoundingClientRect();
    var name = typeof el.className === "string" ? el.className : "";
    if (name.length > 40) {
      name = name.slice(0, 40) + "…";
    }
    return (
      el.tagName.toLowerCase() +
      (el.id ? "#" + el.id : "") +
      (name ? "." + name : "") +
      " [" + Math.round(r.left) + "," + Math.round(r.top) +
      " " + Math.round(r.width) + "x" + Math.round(r.height) + "]"
    );
  }

  function positionOf(el) {
    try {
      return getComputedStyle(el).position;
    } catch (error) {
      return "?";
    }
  }

  /* --- columns ---------------------------------------------------------------
   *
   * See findRightColumns below. The left column is deliberately not modelled:
   * nothing is ever occluded there, so it keeps the full window height.
   */
  /* --- the right-hand column that owns the corner ----------------------------
   *
   * The dsh page has a session list down the left edge and, on the right, a dock
   * panel that starts as a strip of buttons and expands into a full-height
   * drawer. Only the right side is ever occluded: our buttons sit in the top-right
   * corner, so in both states of the panel something of the page is underneath
   * them. The left column is therefore never touched - it keeps the full window
   * height, which is what it should have all along.
   *
   * Finding it is geometry because the page offers nothing else: no stable
   * selector, no ARIA landmarks, class names hashed per build.
   */
  function findRightColumns() {
    var viewportW = document.documentElement.clientWidth;
    var viewportH = document.documentElement.clientHeight;
    var notes = [];
    var result = { left: null, content: null, dock: [], columns: [], notes: notes };
    if (!viewportW || !viewportH) {
      notes.push("no viewport size");
      return result;
    }

    var candidates = [];
    var nodes;
    try {
      nodes = document.querySelectorAll("#root *");
    } catch (error) {
      notes.push("scan failed: " + error);
      return result;
    }
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.id === "root" || el.closest("#" + ROOT_ID)) {
        continue;
      }
      var r = el.getBoundingClientRect();
      if (r.width <= 0) {
        continue;
      }
      /* Columns, sitting inside the viewport and tall enough to be a column. */
      if (r.left < 0 || r.right > viewportW + 1) {
        continue;
      }
      if (r.height < viewportH * 0.4) {
        continue;
      }
      /* Slivers are not columns. The sidebar's resize handle is 8px wide and
         full height, so without this it wins the "first column right of the
         sidebar" slot and every decision after it shifts by one: the content
         area gets treated as the dock and sunk, and the top row is never found.
         The same bound is applied to the left anchor below. */
      if (r.width < MIN_COLUMN_W) {
        continue;
      }
      candidates.push({ el: el, rect: r });
    }
    if (notes.length < 8) {
      notes.push("viewport " + viewportW + "x" + viewportH + ", " + candidates.length +
        " column candidate(s)");
    }

    /* The left column is the anchor, and it is never inset.
     *
     * Anchoring on the window edges instead is what failed twice: with the dock
     * open the content column's right edge is pushed left by the dock and no
     * longer touches the window, so a "reaches the right edge" test dropped it
     * and its top row never got the gutter that moves its buttons clear. And a
     * "not full width" test is not enough to exclude the app shell, which is
     * full width *and* contains the left column, so insetting it dragged the
     * session list down with it. */
    var leftColumn = null;
    for (var s = 0; s < candidates.length; s++) {
      var r = candidates[s].rect;
      if (r.left > 2) {
        continue;
      }
      if (r.width >= viewportW * 0.9 || r.width < MIN_COLUMN_W) {
        continue; /* the shell, or something too thin to be the session list */
      }
      if (!leftColumn || r.width > leftColumn.rect.width) {
        leftColumn = candidates[s];
      }
    }
    if (!leftColumn) {
      notes.push("no left column found");
      return result;
    }
    result.left = leftColumn.el;
    notes.push("anchor " + describe(leftColumn.el));

    var divider = leftColumn.rect.right;

    /* Everything to the right of the session list, left to right. The first is
       the content area; the rest are the dock, collapsed or expanded. */
    var right = [];
    for (var c = 0; c < candidates.length; c++) {
      var el = candidates[c].el;
      var rect = candidates[c].rect;
      if (el === leftColumn.el || leftColumn.el.contains(el)) {
        continue; /* the anchor, or the shell around it */
      }
      if (rect.left < divider - 4) {
        continue;
      }
      var shadowed = false;
      for (var o = 0; o < right.length; o++) {
        if (right[o].el.contains(el)) {
          shadowed = true;
          break;
        }
      }
      if (shadowed) {
        continue;
      }
      for (var k = right.length - 1; k >= 0; k--) {
        if (el.contains(right[k].el)) {
          right.splice(k, 1);
        }
      }
      right.push({ el: el, rect: rect });
    }
    right.sort(function (a, b) { return a.rect.left - b.rect.left; });

    if (right.length) {
      result.content = right[0].el;
      for (var d = 1; d < right.length; d++) {
        result.dock.push(right[d].el);
      }
      notes.push("content " + describe(result.content));
      for (var n = 0; n < result.dock.length && notes.length < 8; n++) {
        notes.push("dock " + describe(result.dock[n]));
      }
    } else {
      notes.push("nothing right of the session list");
    }
    return result;
  }

  /* Remove every inset this script applied, so a re-run replaces rather than
     accumulates. The first version skipped the already-marked element when
     choosing a target, so each pass moved the column down another 28px. */
  function clearApplied() {
    var marked = document.querySelectorAll("[" + INSET_FLAG + "]");
    for (var i = 0; i < marked.length; i++) {
      marked[i].style.paddingTop = "";
      marked[i].style.marginTop = "";
      marked[i].style.paddingRight = "";
      marked[i].style.transform = "";
      marked[i].removeAttribute(INSET_FLAG);
    }
  }

  /* Last-resort pass: make sure nothing at all is left sitting under the buttons.
   *
   * Neither a parent's padding nor a search inside the column reaches an element
   * that is portalled onto `body` instead, which is how a drawer can easily render
   * its own header. So this looks at the reserved rectangle itself and nudges
   * whatever is still there.
   */
  /* Is this element inside something that scrolls?
   *
   * Used to tell a page header from a message in a conversation: both can be
   * flush against the top of the reserved corner, but only the header belongs
   * there. Moving a scrolled item is a visible bug - the whole thread shifts
   * sideways - and it happened because a list item passed through the corner
   * while the conversation was scrolled.
   */
  function isInsideScroller(el) {
    for (var node = el.parentElement; node && node !== document.body; node = node.parentElement) {
      var overflow = getComputedStyle(node).overflowY;
      if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") {
        return true;
      }
    }
    return false;
  }

  function clearCorner(layout) {
    var barCss = cssPx(BAR_H);
    var reservedCss = cssPx(RESERVED_W);
    var viewportW = document.documentElement.clientWidth;
    if (viewportW <= reservedCss) {
      return "no reserved corner to clear";
    }
    var left = viewportW - reservedCss;
    var found = [];
    var target = null;
    var nodes;
    try {
      nodes = document.querySelectorAll("body *");
    } catch (error) {
      return "scan failed: " + error;
    }
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.closest("#" + ROOT_ID) || el.closest("[" + INSET_FLAG + "]")) {
        continue;
      }
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) {
        continue;
      }
      /* Containers are not corner content. `#root` and the app shell intersect
         the reserved rectangle trivially because they cover the viewport, and
         nudging one of those pushes the whole application down - which is
         exactly the "the sidebar sank a long way" this pass must not cause. */
      if (r.width >= viewportW * 0.9 && r.height >= document.documentElement.clientHeight * 0.9) {
        continue;
      }
      /* Only things that are actually *in* the strip, i.e. a top row or a
         control cluster. A full-height column is the column's business, not
         this pass's. */
      if (r.height > barCss * 3) {
        continue;
      }
      /* Only rows that *start* at the top of the document. A negative top means
         the element is scrolled content - a message list item that happens to
         pass through the corner, say - and moving that is how a conversation
         gets shoved sideways by a page whose header was the actual target.
         A positive top is not enough on its own either: a scrolled list can
         bring an item flush to the top, which is why the scrollable ancestors
         are checked next. */
      if (r.top < -1) {
        continue;
      }
      /* Scrolled containers mean the content is not a header, whatever its
         current position. */
      if (isInsideScroller(el)) {
        continue;
      }
      if (r.right <= left || r.left >= viewportW || r.bottom <= 0 || r.top >= barCss) {
        continue;
      }
      if (found.length < 4) {
        found.push(describe(el) + " (position:" + positionOf(el) + ")");
      }
      if (!target || r.width * r.height > target.getBoundingClientRect().width *
          target.getBoundingClientRect().height) {
        target = el;
      }
    }
    if (!target) {
      return "reserved corner is empty";
    }
    /* Direction depends on which side of the page the element belongs to:
       content moves left, the dock moves down. Getting this wrong is what put a
       content row under the bar instead of beside it. */
    var dockLeft = layout.dock.length
      ? layout.dock[0].getBoundingClientRect().left
      : Infinity;
    var moveDown = target.getBoundingClientRect().left >= dockLeft - 4;
    /* `transform` rather than a margin, so it applies whatever the element's own
       positioning is - which is the whole point, since that is why the padding
       did not reach it. */
    target.style.transform = moveDown
      ? "translateY(" + barCss + "px)"
      : "translateX(-" + reservedCss + "px)";
    target.setAttribute(INSET_FLAG, "1");
    return "corner held [" + found.join(", ") + "]; moved " +
      (moveDown ? "down" : "left") + " " + describe(target) +
      " (position:" + positionOf(target) + ")";
  }

  /* Push a column's content below the bar.
   *
   * `padding-top` on the column moves everything in normal flow. It does not
   * move absolutely positioned children, which is how the dock panel's top row
   * stayed level with the bar, so whatever is still sitting in the strip
   * afterwards gets a `margin-top` of its own.
   */
  /* Push a column's content below the bar, or below the content column's own
   * top row.
   *
   * `clearTo` is the depth to clear, measured from the window top. It is the
   * neighbouring column's top row's bottom edge, because that row is already
   * lifted into the bar's band - clearing only the bar left the dock level with
   * the row, which is how its tabs ended up under the window buttons. With no
   * row to clear, the bar's height is the fallback.
   *
   * `border-box` keeps the column's total height, so its bottom edge does not
   * move. Only normal-flow content is moved by the padding: anything positioned
   * ignores a parent's padding, which is how the dock's own tab strip stayed
   * level with the bar. Those are left to `clearCorner`, so exactly one place
   * displaces elements and none is displaced twice.
   */
  function insetColumn(column, label, clearTo) {
    var pad = clearTo > 0 ? clearTo : cssPx(BAR_H);
    column.style.boxSizing = "border-box";
    column.style.paddingTop = pad + "px";
    column.setAttribute(INSET_FLAG, "1");

    /* `padding-top` only moves normal-flow content. The dock's own icon row is
       positioned, so it stayed put at the top of the column and ended up
       directly under the window buttons - not overlapping them, but crowded
       against them. It is handled here rather than by widening the global
       reserved-corner test, because that test spans the whole top strip and
       would drag the content column's header down with it. */
    var note = "";
    var columnWidth = column.getBoundingClientRect().width;
    var straggler = null;
    var stragglerTop = 0;
    var stragglerWidth = 0;
    var nodes;
    try {
      nodes = column.querySelectorAll("*");
    } catch (error) {
      nodes = [];
    }
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.closest("#" + ROOT_ID)) {
        continue;
      }
      var r = el.getBoundingClientRect();
      /* Still up in the bar's band, wide enough to be a row rather than an
         icon, and therefore not moved by the padding. */
      if (r.width <= 0 || r.height <= 0) {
        continue;
      }
      if (r.top >= pad * 0.7 || r.width < columnWidth * 0.35) {
        continue;
      }
      if (r.width > stragglerWidth) {
        straggler = el;
        stragglerTop = r.top;
        stragglerWidth = r.width;
      }
    }
    if (straggler) {
      straggler.style.transform = "translateY(" + (pad - stragglerTop) + "px)";
      straggler.setAttribute(INSET_FLAG, "1");
      note = " + pushed " + describe(straggler) + " from " +
        Math.round(stragglerTop) + "px to " + Math.round(pad) + "px";
    }

    return "inset " + label + " " + describe(column) +
      " (position:" + positionOf(column) + ", padding-top " +
      Math.round(pad) + "px)" + note;
  }

  /* --- the content area's top row ------------------------------------------
   *
   * The content area does NOT sink: it is the main reading surface, and losing a
   * row of height for every session is a poor trade. Only its top row moves, and
   * only sideways.
   *
   * Two details are load-bearing:
   *
   * - `box-sizing` is set explicitly. Under the host's default `content-box`,
   *   `padding-right` does not move content left at all, it widens the element
   *   and pushes its right edge past the window: a partial-looking shift plus a
   *   clipped right edge.
   * - The row is only touched when it actually reaches into the reserved corner.
   *   This is what makes the two dock states come out right without branching on
   *   "is the dock open": with the dock closed the row ends at the window edge
   *   and needs the gutter; with the dock open the dock holds the corner and the
   *   row stops well short of it, so it is left alone.
   */
  function gutterTopRow(best, reservedCss, anchor) {
    var viewportW = document.documentElement.clientWidth;
    if (!best) {
      return "no top row found in the content column";
    }
    var rect = best.getBoundingClientRect();
    /* Vertical placement is independent of the horizontal gutter, so it is
       applied first and unconditionally. Doing it only on the gutter path meant
       that opening the dock - which releases the gutter - also dropped the row
       back against the window frame, which is the one place the content's top
       padding is actually visible. */
    best.style.transform = shiftTopRow(best, anchor);
    /* The marker means "we own this element's geometry" whether or not a gutter
       is currently applied, so it is found again on the next pass and its
       transform is cleared by `clearApplied` rather than left behind. */
    best.setAttribute(INSET_FLAG, "top-row");

    /* The gutter exists only while this row's right end actually reaches the
       reserved corner. That single condition is what makes both dock states come
       out right without branching on "is the dock open":
       dock closed -> the row ends at the window edge and needs the gutter; dock
       open -> the dock holds the corner, the row stops short of it, and the
       gutter comes *off*. Leaving a stale gutter on is what opened a gap
       between the row's controls and the dock. */
    if (rect.right <= viewportW - reservedCss) {
      best.style.boxSizing = "";
      best.style.paddingRight = "";
      return "top row " + describe(best) + " ends at " + Math.round(rect.right) +
        ", corner held by the dock (starts at " +
        Math.round(viewportW - reservedCss) + "): gutter released; " +
        describeShift(best, anchor);
    }
    var gutter = reservedCss + cssPx(GUTTER_EXTRA);
    best.style.boxSizing = "border-box";
    best.style.paddingRight = gutter + "px";
    return "top row " + describe(best) + " shifted left " +
      Math.round(gutter) + "px; " + describeShift(best, anchor);
  }

  /* Where the row's text actually is.
   *
   * The row is much taller than the bar and renders its text at the top of
   * itself, so the row's box says nothing about the text's position. Lifting the
   * row by half the bar - a guess - is what put the text against the window
   * frame, so the text is found by its own line boxes instead.
   */
  function measureRowText(row) {
    var range = document.createRange();
    range.selectNodeContents(row);
    var boxes = range.getClientRects();
    var top = Infinity;
    var bottom = -Infinity;
    for (var b = 0; b < boxes.length; b++) {
      if (boxes[b].height > 0 && boxes[b].width > 0) {
        top = Math.min(top, boxes[b].top);
        bottom = Math.max(bottom, boxes[b].bottom);
      }
    }
    return isFinite(top) ? { top: top, bottom: bottom } : null;
  }

  /* Vertical centre of our own button row - the fallback when the session list
     has no brand row to line up with. */
  function chromeButtonCentre() {
    return cssPx(BUTTON_GAP) + (cssPx(BAR_H) - cssPx(BUTTON_GAP)) / 2;
  }

  /* The session list's top row: the deepseek brand mark. The content column's
     own top row is placed on this row's centre, so the two columns read as one
     line of chrome and, more usefully, the content row ends up well clear of the
     drag strip instead of underneath it.
   *
   * Found geometrically for the same reason everything else here is: no stable
   * selector survives a dsh release. */
  function brandRowCentre(leftColumn) {
    var row = leftColumn ? topRowInColumn(leftColumn) : null;
    brandRow = row;
    if (!row) {
      return { centre: chromeButtonCentre(), from: "chrome centre (no brand row found)" };
    }
    var rect = row.getBoundingClientRect();
    return { centre: rect.top + rect.height / 2, from: "brand row " + describe(row) };
  }

  /* The topmost short, wide element inside a column - the row that sits at the
     very top of it. */
  function topRowInColumn(column) {
    var best = null;
    var width = column.getBoundingClientRect().width;
    var nodes;
    try {
      nodes = column.querySelectorAll("*");
    } catch (error) {
      return null;
    }
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.closest("#" + ROOT_ID)) {
        continue;
      }
      var r = el.getBoundingClientRect();
      if (r.width < width * 0.5 || r.height <= 0 || r.height > BAR_H * 4) {
        continue;
      }
      if (r.top < -2 || r.top > BAR_H * 3) {
        continue;
      }
      if (!best || r.top < best.getBoundingClientRect().top) {
        best = el;
      }
    }
    return best;
  }

/* The row's title: its first child that is not a control *and* actually
   occupies space. The zero-size check matters: the row's first child is a
     zero-height wrapper holding the whole row, so without it the session
     title came out as a concatenation of every label in the row. */
  function rowTitle() {
    if (!topRow) {
      return null;
    }
    for (var i = 0; i < topRow.children.length; i++) {
      var child = topRow.children[i];
      if (child.tagName === "BUTTON" || child.getAttribute("role") === "button") {
        continue;
      }
      var rect = child.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) {
        continue;
      }
      if ((child.textContent || "").trim()) {
        return child;
      }
    }
    return null;
  }
  
  /* The row's right-hand control group: the last child holding a button. */
  function rowButtonCluster() {
    if (!topRow) {
      return null;
    }
    for (var i = topRow.children.length - 1; i >= 0; i--) {
      var child = topRow.children[i];
      if (child.tagName === "BUTTON" || child.getAttribute("role") === "button" ||
          (child.querySelector && child.querySelector("button"))) {
        return child;
      }
    }
    return null;
  }
  
  
    /* What the row should be aligned on.
     *
   * Not the row's own box, and not the union of its line boxes: the row is 76px
   * tall - far taller than the bar - and that union spans the title, the model
   * selector and the button group at three different heights, so its centre
   * means nothing. The title element is what the eye reads as the row's line, so
   * that is what is aligned, with the union as the fallback when the row has no
   * separable title. */
  function rowAlignmentTarget(row) {
    var title = rowTitle();
    if (title) {
      var rect = title.getBoundingClientRect();
      if (rect.height > 0) {
        return { top: rect.top, bottom: rect.bottom, from: "title " + describe(title) };
      }
    }
    var text = measureRowText(row);
    if (!text) {
      return null;
    }
    return { top: text.top, bottom: text.bottom, from: "row line boxes" };
  }

  /* Places the content row so it sits on the anchor's centre line - normally the
     session list's brand mark - and clears the bar, so the status line in the bar
     has the band to itself. Returns "" when there is nothing to move. */
  function shiftTopRow(row, anchor) {
    var target = rowAlignmentTarget(row);
    if (!target) {
      return "";
    }
    var shift = anchor.centre - (target.top + target.bottom) / 2;
    /* Clear the whole bar, not just the drag strip.
     *
     * The strip is only two thirds of the bar, so nothing here is about clicks -
     * that was why the strip was narrowed. This floor is about the *status line*,
     * which does occupy the full band with text. A row allowed into that band
     * puts two lines of text on top of each other, which is worse than the 8px
     * the narrower strip gave back. */
    if (target.top + shift < cssPx(BAR_H)) {
      shift = cssPx(BAR_H) - target.top;
    }
    return shift ? "translateY(" + shift + "px)" : "";
  }

  function describeShift(row, anchor) {
    var target = rowAlignmentTarget(row);
    if (!target) {
      return "nothing measurable in this row; left in place (anchor " +
        Math.round(anchor.centre) + "px)";
    }
    return "row " + Math.round(target.top) + ".." + Math.round(target.bottom) +
      "px, centre " + Math.round((target.top + target.bottom) / 2) +
      " (anchor " + Math.round(anchor.centre) + "px from " + anchor.from +
      ", bar 0.." + Math.round(cssPx(BAR_H)) + "px, grab 0.." +
      Math.round(cssPx(GRAB_H)) + "px, from " + target.from + ")";
  }

  function applyCornerAvoidance() {
    /* Replace, never accumulate. */
    clearApplied();
    /* Held at install() scope so the status line can read the session title out of it. */
    topRow = null;
    var gaps = "gaps: gutter+=" + Math.round(cssPx(GUTTER_EXTRA)) +
      "px dock=" + Math.round(cssPx(DOCK_TOP)) +
      "px bar=" + Math.round(cssPx(BAR_H)) +
      "px chrome_centre=" + Math.round(chromeButtonCentre()) + "px";

    var found = findRightColumns();
    if (!found.content && !found.dock.length) {
      return "skipped: " + found.notes.join(" | ");
    }

    var reservedCss = cssPx(RESERVED_W);
    var applied = [gaps, "layout: " + found.notes.join(" | ")];

    /* The content column's top row is found once and shared: the gutter decides
       whether it reaches the reserved corner, and the row is placed on the
       session list's brand line. Measuring it twice is what broke the dock: the
       second scan skipped the row, because the first pass had just marked it. */
    var anchor = brandRowCentre(found.left);
    var row = found.content ? findContentTopRow(found.content) : null;
    topRow = row;
    if (found.content) {
      var gutter = gutterTopRow(row, reservedCss, anchor);
      if (gutter) {
        applied.push(gutter);
      }
    }

    /* The dock clears the chrome bar, not the content row. It has to clear the
       bar because that is where the window buttons are; it does not have to
       clear the content row, which is a separate column entirely, and using its
       depth as the basis dropped the dock 84px down for no gain. */
    var dockPad = cssPx(DOCK_TOP);
    for (var i = 0; i < found.dock.length; i++) {
      applied.push(insetColumn(found.dock[i], "dock", dockPad));
    }

    applied.push(clearCorner(found));
    return applied.join(" | ");
  }

  /* The content column's top row: the wide, short element at the very top.
   *
   * Found once and shared. It used to be re-found for the dock's depth, and that
   * re-scan skipped it - by then it carried the inset marker `gutterTopRow` had
   * just put on it, so the dock was given one bar height instead of the depth
   * the row actually occupies, and ended up level with it.
   */
  function findContentTopRow(content) {
    var barCss = cssPx(BAR_H);
    var contentWidth = content.getBoundingClientRect().width;
    var best = null;
    var nodes;
    try {
      nodes = content.querySelectorAll("*");
    } catch (error) {
      return null;
    }
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.closest("#" + ROOT_ID)) {
        continue;
      }
      var r = el.getBoundingClientRect();
      /* Topmost wins, and never something scrolled out of sight: an earlier
         version preferred the largest element and picked a list item 2500px
         above the viewport. */
      if (r.top < -2 || r.top > barCss * 1.5) {
        continue;
      }
      if (r.height > barCss * 4 || r.width < contentWidth * 0.5) {
        continue;
      }
      if (el.closest("[" + INSET_FLAG + "]") && el.getAttribute(INSET_FLAG) !== "top-row") {
        continue;
      }
      if (!best || r.top < best.getBoundingClientRect().top) {
        best = el;
      }
    }
    return best;
  }

  function install() {
    installStylesheet();

    var bar = document.createElement("div");
    bar.id = ROOT_ID;
    bar.style.cssText = [
      "position:fixed",
      "top:0",
      "left:0",
      "right:0",
      "margin:0",
      "padding:0",
      "border:0",
      "display:flex",
      "align-items:flex-start",
      "height:" + px(BAR_H),
      "z-index:2147483647",
      /* Everything below is click-through except the grab strip and the buttons. */
      "pointer-events:none",
      "color:var(--dsw-alias-label-primary, #16181d)",
      "-webkit-user-select:none",
      "user-select:none"
    ].join(";");

    /* The drag strip: a short band at the very top, not the full bar height. A
       full-height strip swallows every click on the page's own top row, which
       is a control-dense row in this app. */
    var grab = document.createElement("div");
    grab.className = "dss-grab";
    grab.style.cssText = [
      "position:absolute",
      "top:0",
      "left:0",
      "right:" + px(RESERVED_W),
      "height:" + px(GRAB_H),
      /* The first few logical pixels belong to the OS resize border: a frameless
         window cannot otherwise be resized from its top edge. */
      "border-top:" + px(RESIZE_BORDER) + " solid transparent",
      "pointer-events:auto",
      "background:transparent"
    ].join(";");
    grab.addEventListener("mousedown", function (event) {
      if (event.button !== 0 || (event.detail !== 1 && event.detail !== 2)) {
        return;
      }
      event.preventDefault();
      event.stopImmediatePropagation();
      var cmd = event.detail === 2
        ? "plugin:window|internal_toggle_maximize"
        : "plugin:window|start_dragging";
      invoke(cmd).catch(function () {});
    });
    bar.appendChild(grab);

    /* Status, centred in the *window* rather than in the leftover space, so it
     * does not drift as the button cluster's width or the zoom changes. It is
     * click-through: the drag strip underneath has to keep working, and that
     * strip now spans the full bar height again.
     *
     * Three things, all obtained without inventing an API: which dsh we are
     * attached to and whether it is still answering, the session that is open,
     * and the zoom - which has no other UI at all, since the shortcut is the
     * only way to change it.
     *
     * The dot is deliberately three-state. A failed probe only means "down" once
     * a probe has ever succeeded: a page whose own CSP blocked the request would
     * otherwise report dsh as dead while dsh is serving it.
     */
    var status = document.createElement("div");
    status.className = "dss-status";
    status.style.cssText = [
      "position:absolute",
      "top:0",
      "left:50%",
      "transform:translateX(-50%)",
      "height:" + px(BAR_H),
      "line-height:" + px(BAR_H),
      "padding:0 " + px(10),
      "pointer-events:none",
      "white-space:nowrap",
      "overflow:hidden",
      "text-overflow:ellipsis",
      "max-width:60%",
      "font-size:" + px(10.5),
      "opacity:0.75",
      "color:inherit"
    ].join(";");
    bar.appendChild(status);

    var reachable = false;
    var everReached = false;

    function paintStatus() {
      var tint = !everReached ? "inherit" : (reachable ? "#22c55e" : "#ef4444");
      var parts = [
        '<span style="color:' + tint + '">' + (everReached ? "●" : "○") + "</span>",
        "dsh " + (location.host || "?"),
        "· " + zoom + "%"
      ];
      var session = currentSessionTitle();
      if (session) {
        parts.splice(2, 0, "· " + session);
      }
      status.innerHTML = parts.join(" ");
    }

    /* The open session's name, from the first piece of text in the content
       column's top row. Best effort by design: the status line is a nicety and
       that row's internals are not a stable contract. */
    function currentSessionTitle() {
      var title = rowTitle();
      if (!title) {
        return "";
      }
      var text = (title.textContent || "").replace(/\s+/g, " ").trim();
      if (!text) {
        return "";
      }
      return text.length > 26 ? text.slice(0, 25) + "…" : text;
    }

    /* Same-origin probe: any answer at all proves dsh's HTTP server is up, and
       the 401 from its auth fence counts. */
    function probeDsh() {
      fetch(location.origin + "/", { method: "HEAD", cache: "no-store" })
        .then(function () {
          reachable = true;
          everReached = true;
        })
        .catch(function () {
          reachable = false;
        })
        .then(function () {
          paintStatus();
        });
    }

    /* --- window buttons --- */
    var winCluster = document.createElement("div");
    winCluster.className = "dss-cluster dss-win";
    winCluster.style.cssText = [
      "display:flex",
      "align-items:stretch",
      "pointer-events:auto",
      "margin-left:auto",
      /* A small gap so the buttons do not look glued to the top frame. */
      "margin-top:" + px(BUTTON_GAP),
      "width:" + px(RESERVED_W),
      "height:" + px(BAR_H - BUTTON_GAP),
      "flex:0 0 auto",
      /* No background at all. The bar is chrome over the page, and a fill here
         reads as a foreign panel: it did not match the loaded page or the
         content column. Legibility comes from the glyph colour instead, which
         follows the page's own `--dsw-alias-label-primary` and so works on the
         light dsh theme and on the dark boot page alike. */
      "background:transparent"
    ].join(";");

    function control(title, child) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "dss-btn";
      button.title = title;
      button.setAttribute("aria-label", title);
      button.style.cssText = [
        "appearance:none",
        "-webkit-appearance:none",
        "margin:0",
        "padding:0",
        "display:flex",
        "align-items:center",
        "justify-content:center",
        /* Geometry, all inline so it tracks the zoom from one place. The
           background deliberately is not inline: see installStylesheet. */
        "width:" + px(WIN_W),
        "height:" + px(BAR_H),
        "border-radius:" + px(CORNER_R)
      ].join(";");
      button.appendChild(child);
      return button;
    }

    var minimize = control("Minimize", glyph("min"));
    var maximize = control("Maximize", glyph("max"));
    var close = control("Close", glyph("close"));
    close.setAttribute("data-dss-close", "");

    minimize.addEventListener("click", function () {
      invoke("plugin:window|minimize").catch(function () {});
    });
    maximize.addEventListener("click", function () {
      invoke("plugin:window|toggle_maximize").catch(function () {});
    });
    /* Closing raises ExitRequested, which runs the dsh shutdown path, exactly
       like the native close button would. */
    close.addEventListener("click", function () {
      invoke("plugin:window|close").catch(function () {});
    });

    winCluster.appendChild(minimize);
    winCluster.appendChild(maximize);
    winCluster.appendChild(close);
    bar.appendChild(winCluster);

    document.documentElement.appendChild(bar);

    function paint(value) {
      zoom = clampZoom(value);
      z = zoom / 100;
      bar.style.height = px(BAR_H);
      grab.style.right = px(RESERVED_W);
      grab.style.height = px(GRAB_H);
      grab.style.borderTopWidth = px(RESIZE_BORDER);
      winCluster.style.width = px(RESERVED_W);
      winCluster.style.marginTop = px(BUTTON_GAP);
      winCluster.style.height = px(BAR_H - BUTTON_GAP);
      var buttons = [minimize, maximize, close];
      for (var i = 0; i < buttons.length; i++) {
        buttons[i].style.width = px(WIN_W);
        buttons[i].style.height = px(BAR_H - BUTTON_GAP);
        buttons[i].style.borderRadius = px(CORNER_R);
      }
      var glyphs = winCluster.querySelectorAll("svg");
      for (var g = 0; g < glyphs.length; g++) {
        glyphs[g].setAttribute("width", px(10));
        glyphs[g].setAttribute("height", px(10));
      }
      /* The page inset is expressed in CSS pixels, so it has to be re-applied
         whenever the zoom changes. */
      scheduleAvoidance();
    }

    paint(zoom);

    /* --- page inset, kept current --- */
    var avoidance = "not run yet";
    var pending = null;
    var lastReported = null;
    var lastReportAt = 0;

    /* Re-report whenever the inset settles on something different. The first
       reports land while dsh is still on its boot screen, before the columns
       exist, so without this the log only ever describes the page before it was
       interesting. */
    function reportAvoidance(force) {
      var now = Date.now();
      if (!force && avoidance === lastReported) {
        return;
      }
      if (!force && now - lastReportAt < 1500) {
        return;
      }
      lastReported = avoidance;
      lastReportAt = now;
      report(true);
    }

    /* Re-detect on every mutation batch, debounced.
     *
     * There used to be a cheaper path here: skip unless our own marker had been
     * removed from the document. That was wrong, and it is what left the chrome
     * frozen on the boot screen. dsh keeps the same DOM node alive while a
     * session loads and the dock opens, so the marker stayed connected, the
     * detection never ran again, and the dock was never found or inset - the
     * page's own layout had changed underneath a decision made three seconds
     * after launch.
     *
     * The debounce is what keeps this affordable: a SPA mutating constantly
     * still costs one debounced pass, and a pass is a single filtered scan.
     */
    function scheduleAvoidance() {
      if (pending) {
        clearTimeout(pending);
      }
      pending = setTimeout(function () {
        pending = null;
        try {
          if (document.hidden) {
            return;
          }
          avoidance = applyCornerAvoidance();
          paintStatus();
          reportAvoidance(false);
        } catch (error) {
          avoidance = "error: " + String((error && error.message) || error);
          reportAvoidance(false);
        }
      }, 250);
    }

    if (window.MutationObserver && document.body) {
      new MutationObserver(function () {
        scheduleAvoidance();
      }).observe(document.body, { childList: true, subtree: true });
    }
    window.addEventListener("resize", function () {
      scheduleAvoidance();
    });
    paintStatus();
    probeDsh();
    setInterval(probeDsh, 4000);
    scheduleAvoidance();

    window.__DSH_SHELL_CHROME__ = {
      setZoom: paint,
      setMaximized: function (isMaximized) {
        maximize.title = isMaximized ? "Restore" : "Maximize";
        maximize.setAttribute("aria-label", maximize.title);
        var old = maximize.querySelector("svg");
        var fresh = glyph(isMaximized ? "restore" : "max");
        fresh.setAttribute("width", px(10));
        fresh.setAttribute("height", px(10));
        if (old) {
          maximize.replaceChild(fresh, old);
        } else {
          maximize.appendChild(fresh);
        }
      }
    };

    /* Tell Rust what happened. The chrome lives in a document we do not own, so
       this is how a broken injection becomes a log line instead of a frameless
       window with no close button. */
    function report(stillPresent) {
      var node = stillPresent ? document.getElementById(ROOT_ID) : null;
      var barBox = node ? node.getBoundingClientRect() : null;
      var winBox = stillPresent ? winCluster.getBoundingClientRect() : null;
      invoke("chrome_report", {
        report: {
          installed: true,
          still_present: !!node,
          /* Multiplied by the page zoom so Rust can compare against the design
             constants it owns: a mismatch means the 1/zoom correction was
             applied a different number of times than exactly once. */
          measured_bar_h: barBox ? barBox.height * z : 0,
          measured_win_w: winBox ? winBox.width * z : 0,
          zoom: z,
          placeholder: document.documentElement.hasAttribute("data-dsh-shell-placeholder"),
          ready_state: document.readyState,
          origin: location.origin,
          boxes: "bar=" + describe(node) +
            " grab=" + describe(grab) +
            " status=" + describe(status) +
            " winc=" + describe(winCluster) +
            " close=" + describe(close) +
            " row=" + describe(topRow) +
            " rowTitle=" + describe(rowTitle()) +
            " rowBtns=" + describe(rowButtonCluster()) +
            " brandRow=" + describe(brandRow) +
            " color=" + getComputedStyle(node || bar).color,
          avoid: avoidance
        }
      }).catch(function () {});
    }

    report(true);
    setTimeout(function () {
      report(!!document.getElementById(ROOT_ID));
    }, 1500);
  }

  function paintZoom(value) {
    if (window.__DSH_SHELL_CHROME__ && typeof window.__DSH_SHELL_CHROME__.setZoom === "function") {
      window.__DSH_SHELL_CHROME__.setZoom(value);
    }
  }

  /* Zoom shortcuts. Handled here because focus is inside the page, not the
     window, and `code` is used so the bindings do not depend on the keyboard
     layout: Ctrl+= (and Ctrl+Shift+=) zooms in, Ctrl+- out, Ctrl+0 resets.
     Chromium's own zoom hotkeys are disabled in Rust so these cannot double up. */
  document.addEventListener("keydown", function (event) {
    if (!event.ctrlKey || event.altKey || event.metaKey) {
      return;
    }
    var code = event.code;
    var command = null;
    var delta = 0;
    if (code === "Equal" || code === "NumpadAdd") {
      command = "zoom_step";
      delta = ZOOM_STEP;
    } else if (code === "Minus" || code === "NumpadSubtract") {
      command = "zoom_step";
      delta = -ZOOM_STEP;
    } else if (code === "Digit0" || code === "Numpad0") {
      command = "zoom_reset";
    }
    if (!command) {
      return;
    }
    event.preventDefault();
    invoke(command, command === "zoom_reset" ? {} : { delta: delta })
      .then(paintZoom)
      .catch(function () {});
  });

  function run() {
    try {
      install();
    } catch (error) {
      // Without this, a throw here leaves a frameless window with no way to
      // close it and nothing in the log to explain why.
      invoke("chrome_error", { message: String((error && error.stack) || error) }).catch(function () {});
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
  }
})();