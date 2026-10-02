/* dsh-shell window chrome, injected into every document the webview loads.
 *
 * The page is REMOTE and we do not control its stylesheet, so this file is
 * written to lose gracefully:
 *
 *  * Every length that decides where something is or how big it is is an inline
 *    style. Inline styles beat any host rule that is not `!important`, so the
 *    dsh app's reset, its CSS custom properties and any future restyle cannot
 *    move or collapse the bar.
 *  * The bar hangs off `document.documentElement`, not `body`, so nothing the
 *    page does to its own root container can capture it.
 *  * The injected stylesheet carries hover colours only. Losing it costs
 *    affordance, not layout.
 *  * It is injected twice on purpose. `initialization_script` does not survive
 *    dsh's Content-Security-Policy, so the real page gets this from Rust via
 *    `eval` on page load; the early return below makes that idempotent.
 *
 * ## Zoom
 *
 * The page is zoomed; the chrome is not. The geometry arrives from Rust
 * (`window.__DSH_SHELL__`) and every length goes through `px()`, which divides
 * by the page zoom exactly once. Do not also counter-scale with a transform:
 * that was the bug where zooming out made the window buttons grow.
 * `chrome_report` re-measures the live DOM and Rust fails the run if
 * `height * zoom !== barH`.
 *
 * ## The page's own layout
 *
 * There is no stable selector to hook - dsh's app shell has no semantic id and
 * no ARIA landmarks, and its class names are hashed per build - so the reserved
 * corner is handled by hit-testing: find the row that actually occupies it and
 * pad its right edge. It is a heuristic, so it is marked, re-checked, logged,
 * and reversible by removing one attribute.
 */
(function () {
  "use strict";

  if (window.__DSH_SHELL_CHROME__) {
    return;
  }

  var CFG = window.__DSH_SHELL__ || {};
  var BAR_H = num(CFG.barH, 32);
  var WIN_W = num(CFG.winW, 46);
  var ZOOM_W = num(CFG.zoomW, 96);
  var RESIZE_BORDER = num(CFG.resizeBorder, 6);
  var CORNER_R = num(CFG.cornerR, 8);
  var RESERVED_W = ZOOM_W + 3 * WIN_W;

  var MIN = 50;
  var MAX = 100;
  var STEP = 10;

  var STYLE_ID = "dsh-shell-chrome-style";
  var ROOT_ID = "dsh-shell-chrome";
  var INSET_FLAG = "data-dsh-shell-inset";

  var zoom = clampZoom(num(CFG.zoom, 100));
  var z = zoom / 100;

  function num(value, fallback) {
    var parsed = Number(value);
    return isFinite(parsed) && parsed > 0 ? parsed : fallback;
  }

  function clampZoom(value) {
    if (!isFinite(value)) return MAX;
    if (value < MIN) return MIN;
    if (value > MAX) return MAX;
    return value;
  }

  /* The one place page zoom is divided out. See chrome::css_len.
     Two forms, because the two callers want different things: `cssPx` for
     arithmetic and hit-testing, `px` for a CSS length. Using the string form
     in arithmetic yields NaN, which is what `elementsFromPoint` rejects. */
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

  /* Hover colours only. Radius and sizes are inline, because they are geometry
     and have to track the zoom. */
  function installStylesheet() {
    if (document.getElementById(STYLE_ID)) {
      return;
    }
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = [
      "#" + ROOT_ID + " button { outline: none; }",
      "#" + ROOT_ID + " svg { display: block; }",
      /* Every self-drawn button gets a hover highlight. */
      "#" + ROOT_ID + " .dss-win button:hover,",
      "#" + ROOT_ID + " .dss-zoom button:hover:not(:disabled) {",
      "  background: rgba(127,127,127,0.22);",
      "}",
      /* Close is a light red, not a solid one: the cluster behind it is the
         page's own surface colour, so a solid fill reads as a foreign panel. */
      "#" + ROOT_ID + " .dss-win button[data-dss-close]:hover {",
      "  background: rgba(214,45,45,0.18);",
      "}",
      "#" + ROOT_ID + " .dss-win button[data-dss-close]:hover svg g {",
      "  stroke: #c0392b;",
      "}",
      "#" + ROOT_ID + " .dss-zoom button:disabled,",
      "#" + ROOT_ID + " .dss-zoom button:disabled:hover {",
      "  background: transparent;",
      "  opacity: 0.3;",
      "}"
    ].join("\n");
    (document.head || document.documentElement).appendChild(style);
  }

  /* A window glyph in a 10x10 viewBox. `currentColor` so it follows the host
     page's foreground. */
  function glyph(kind) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 10 10");
    svg.setAttribute("width", px(11));
    svg.setAttribute("height", px(11));
    svg.setAttribute("aria-hidden", "true");

    var shape = document.createElementNS(ns, "g");
    shape.setAttribute("stroke", "currentColor");
    shape.setAttribute("stroke-width", "1");
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

  function cluster(className, widthPx) {
    var el = document.createElement("div");
    el.className = className;
    el.style.cssText = [
      "display:flex",
      "align-items:stretch",
      "pointer-events:auto",
      "width:" + px(widthPx),
      "height:" + px(BAR_H),
      "flex:0 0 auto",
      /* The page's own surface colour, so the bar follows the dsh light/dark
         theme instead of guessing. Opaque: a see-through control cluster over an
         arbitrary page is unreadable, and `color-mix` is a needless
         compatibility risk. */
      "background:var(--dsw-alias-bg-base, #ffffff)"
    ].join(";");
    return el;
  }

  function control(className, title, widthPx, child) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = className;
    button.title = title;
    button.setAttribute("aria-label", title);
    button.style.cssText = [
      "appearance:none",
      "-webkit-appearance:none",
      "border:0",
      "margin:0",
      "padding:0",
      "background:transparent",
      "color:inherit",
      "cursor:default",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      /* Geometry, all of it inline so it tracks the zoom from one place. */
      "width:" + px(widthPx),
      "height:" + px(BAR_H),
      "border-radius:" + px(CORNER_R),
      "font:500 " + px(13) + "/1 'Segoe UI', system-ui, sans-serif"
    ].join(";");
    button.appendChild(child);
    return button;
  }

  function describe(el) {
    if (!el) {
      return "none";
    }
    var r = el.getBoundingClientRect();
    var name = typeof el.className === "string" ? el.className : "";
    if (name.length > 60) {
      name = name.slice(0, 60) + "…";
    }
    return (
      el.tagName.toLowerCase() +
      (el.id ? "#" + el.id : "") +
      (name ? "." + name : "") +
      " [" + Math.round(r.left) + "," + Math.round(r.top) +
      " " + Math.round(r.width) + "x" + Math.round(r.height) + "]"
    );
  }

  /* --- reserved-corner avoidance -------------------------------------------
   *
   * The chrome covers the top-right corner, and the dsh app puts real controls
   * there. Rather than guessing at hashed class names, hit-test the reserved
   * rectangle and pad whichever row is actually sitting in it.
   *
   * `elementsFromPoint` is used instead of walking the DOM because it is
   * proportional to the handful of elements in one rectangle rather than to the
   * size of the app, and because it only ever returns elements that genuinely
   * occupy that space. It is also re-run on resize and after SPA re-renders, so
   * a stale choice self-corrects.
   */
  /* --- content-column inset -------------------------------------------------
   *
   * The chrome is a full-width strip at the top, so the only principled way to
   * keep the page clear of it is to inset the *content column* by the bar height
   * while leaving the sidebar full height, which is also how a native app looks.
   * Anything the dsh app puts in the top right of that column is then below the
   * bar, whatever it happens to be this release.
   *
   * Finding the column is geometry too - there is no stable selector - but the
   * relationship is simple and stable: the sidebar is the tall column pinned to
   * the left edge, and the content column is its sibling that reaches the right
   * edge. There is deliberately no per-row fallback. Guessing at "the row" found
   * list items and conversation bubbles, and padding one of those would break
   * the layout rather than protect it. When no column can be identified nothing
   * is touched, and the reason travels into the log.
   */
  function findColumns() {
    var viewportW = document.documentElement.clientWidth;
    var viewportH = document.documentElement.clientHeight;
    var notes = [];
    var result = { sidebar: null, content: null, notes: notes };
    if (!viewportW || !viewportH) {
      notes.push("no viewport size");
      return result;
    }
    var tall = [];
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
      /* Columns, not the app shell: a candidate must sit inside the viewport. */
      if (r.left < 0 || r.right > viewportW + 1) {
        continue;
      }
      if (r.height < viewportH * 0.4) {
        continue;
      }
      tall.push({ el: el, rect: r });
    }
    if (notes.length < 12) {
      notes.push("viewport " + viewportW + "x" + viewportH + ", " + tall.length +
        " tall column(s): " + tall.map(function (c) {
          return describe(c.el);
        }).join(", "));
    }
    if (!tall.length) {
      return result;
    }

    /* Sidebar: the widest column touching the left edge that is *not* the whole
       window. The app shell also touches the left edge and is wider than the
       sidebar, so without the width bound the shell gets picked and then every
       other column looks like it is "inside the sidebar". */
    var sidebar = null;
    for (var s = 0; s < tall.length; s++) {
      var rect = tall[s].rect;
      if (rect.left > 2) {
        continue;
      }
      if (rect.width >= viewportW - 2 || rect.width < 40) {
        continue; /* the shell, or something too thin to be a sidebar */
      }
      if (!sidebar || rect.width > sidebar.rect.width) {
        sidebar = tall[s];
      }
    }
    if (!sidebar) {
      notes.push("no column touches the left edge");
      return result;
    }
    result.sidebar = sidebar.el;

    /* Content: a column that starts where the sidebar ends and reaches the right
       edge, and that is not an ancestor of the sidebar (which would make it the
       app shell rather than a sibling column). */
    for (var c = 0; c < tall.length; c++) {
      var candidate = tall[c];
      if (candidate.el === sidebar.el || sidebar.el.contains(candidate.el)) {
        continue;
      }
      var why = "";
      if (candidate.rect.left < sidebar.rect.right - 4) {
        why = "left " + Math.round(candidate.rect.left) + " is inside the sidebar";
      } else if (candidate.rect.right < viewportW - 28) {
        /* A scrollbar, or a gap, keeps the column short of the window edge, so
           this cannot demand a flush right edge. */
        why = "right " + Math.round(candidate.rect.right) + " stops short of the window edge " +
          viewportW;
      }
      if (why) {
        if (notes.length < 12) {
          notes.push(describe(candidate.el) + " rejected: " + why);
        }
        continue;
      }
      if (!result.content ||
          candidate.rect.left < result.content.getBoundingClientRect().left) {
        result.content = candidate.el;
      }
    }
    return result;
  }

  function applyColumnInset() {
    var columns = findColumns();
    if (!columns.content) {
      return { ok: false, why: "no content column found: " + columns.notes.join(" | ") };
    }
    var content = columns.content;
    var previous = document.querySelector("[" + INSET_FLAG + "]");
    if (previous && previous !== content && previous.isConnected) {
      previous.style.paddingTop = "";
      previous.removeAttribute(INSET_FLAG);
    }
    /* Start from the element's own padding so the adjustment is additive. */
    if (previous !== content) {
      content.style.paddingTop = "";
    }
    content.style.paddingTop = px(BAR_H);
    content.setAttribute(INSET_FLAG, "1");
    return {
      ok: true,
      text: "inset " + describe(content) + " by " + Math.round(cssPx(BAR_H)) +
        "px css; sidebar " + Math.round(columns.sidebar.getBoundingClientRect().width) + "px"
    };
  }

  function applyCornerAvoidance() {
    var inset = applyColumnInset();
    if (inset.ok) {
      return inset.text;
    }
    return "skipped: " + inset.why;
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
      /* stretch, spelled out: the drag strip is an empty element and would
         otherwise collapse to zero height, which silently makes a frameless
         window undraggable. */
      "align-items:flex-start",
      "height:" + px(BAR_H),
      "z-index:2147483647",
      "pointer-events:none", /* the children opt back in */
      "color:var(--dsw-alias-label-primary, #16181d)",
      "-webkit-user-select:none",
      "user-select:none",
      "font:500 " + px(11.5) + "/1 'Segoe UI', system-ui, sans-serif"
    ].join(";");

    var drag = document.createElement("div");
    drag.className = "dss-drag";
    drag.style.cssText = [
      "flex:1 1 auto",
      "align-self:stretch",
      "pointer-events:auto",
      /* Give the top few logical pixels back to the OS resize border: a
         frameless window cannot otherwise be resized from its top edge. */
      "margin-top:" + px(RESIZE_BORDER),
      "background:transparent"
    ].join(";");
    /* Our own drag rather than `data-tauri-drag-region`, so the drag area is
       exactly what we drew and the page keeps every other pixel. */
    drag.addEventListener("mousedown", function (event) {
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
    bar.appendChild(drag);

    /* --- zoom control --- */
    var zoomCluster = cluster("dss-cluster dss-zoom", ZOOM_W);

    var zoomOut = control("dss-btn dss-zoom-btn", "Zoom out (Ctrl+Alt+Down)", 30,
      document.createTextNode("\u2212"));
    zoomOut.id = "dss-zoom-out";

    var zoomLabel = document.createElement("span");
    zoomLabel.id = "dss-zoom-label";
    zoomLabel.style.cssText = [
      "flex:1 1 auto",
      "text-align:center",
      "align-self:center",
      "height:" + px(BAR_H),
      "line-height:" + px(BAR_H),
      "font-variant-numeric:tabular-nums",
      "font-size:" + px(12),
      "opacity:0.85"
    ].join(";");

    var zoomIn = control("dss-btn dss-zoom-btn", "Zoom in (Ctrl+Alt+Up)", 30,
      document.createTextNode("+"));
    zoomIn.id = "dss-zoom-in";

    function paint(value) {
      zoom = clampZoom(value);
      z = zoom / 100;
      zoomLabel.textContent = zoom + "%";
      zoomOut.disabled = zoom <= MIN;
      zoomIn.disabled = zoom >= MAX;
      /* Every length is derived from px(), so one recompute covers the bar, the
         drag strip, both clusters, all five buttons, the label and the radius. */
      bar.style.height = px(BAR_H);
      drag.style.marginTop = px(RESIZE_BORDER);
      zoomCluster.style.width = px(ZOOM_W);
      zoomCluster.style.height = px(BAR_H);
      winCluster.style.width = px(RESERVED_W - ZOOM_W);
      winCluster.style.height = px(BAR_H);
      var buttons = [zoomOut, zoomIn, minimize, maximize, close];
      for (var i = 0; i < buttons.length; i++) {
        var isZoom = buttons[i] === zoomOut || buttons[i] === zoomIn;
        buttons[i].style.width = px(isZoom ? 30 : WIN_W);
        buttons[i].style.height = px(BAR_H);
        buttons[i].style.borderRadius = px(CORNER_R);
        buttons[i].style.fontSize = px(isZoom ? 13 : 11.5);
      }
      zoomLabel.style.height = px(BAR_H);
      zoomLabel.style.lineHeight = px(BAR_H);
      zoomLabel.style.fontSize = px(12);
      var glyphs = winCluster.querySelectorAll("svg");
      for (var g = 0; g < glyphs.length; g++) {
        glyphs[g].setAttribute("width", px(11));
        glyphs[g].setAttribute("height", px(11));
      }
      /* The reserved corner changed width, so the page has to be re-checked.
         A rescan: the padding we applied is now the wrong size. */
      scheduleAvoidance(true);
    }

    function step(delta) {
      invoke("zoom_step", { delta: delta })
        .then(paint)
        .catch(function () {});
    }

    zoomOut.addEventListener("click", function () { step(-STEP); });
    zoomIn.addEventListener("click", function () { step(STEP); });

    zoomCluster.appendChild(zoomOut);
    zoomCluster.appendChild(zoomLabel);
    zoomCluster.appendChild(zoomIn);
    bar.appendChild(zoomCluster);

    /* --- window buttons --- */
    var winCluster = cluster("dss-cluster dss-win", RESERVED_W - ZOOM_W);

    var minimize = control("dss-btn", "Minimize", WIN_W, glyph("min"));
    var maximize = control("dss-btn", "Maximize", WIN_W, glyph("max"));
    var close = control("dss-btn", "Close", WIN_W, glyph("close"));
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
    paint(zoom);

    /* --- reserved-corner avoidance, kept current --- */
    var avoidance = "not run yet";
    var pending = null;
    var lastReported = null;
    var lastReportAt = 0;

    /* Re-report whenever the avoidance settles on something different.
       The first two reports land while dsh is still showing its boot screen,
       before a session header exists at all, so without this the log only ever
       describes the page before it was interesting. */
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

    function scheduleAvoidance(rescan) {
      /* A rescan walks the DOM; a liveness check is one querySelector. The
         observer fires constantly on a SPA, so it only does the cheap one. */
      if (pending) {
        clearTimeout(pending);
      }
      pending = setTimeout(function () {
        pending = null;
        try {
          if (rescan) {
            avoidance = applyCornerAvoidance();
            reportAvoidance(false);
            return;
          }
          var marked = document.querySelector("[" + INSET_FLAG + "]");
          if (marked && marked.isConnected) {
            return;
          }
          /* The SPA replaced the padded element on a navigation, or there never
             was one. Re-check, but not on every single mutation. */
          avoidance = applyCornerAvoidance();
          reportAvoidance(false);
        } catch (error) {
          avoidance = "error: " + String((error && error.message) || error);
          reportAvoidance(false);
        }
      }, 250);
    }

    if (window.MutationObserver && document.body) {
      new MutationObserver(function () {
        scheduleAvoidance(false);
      }).observe(document.body, { childList: true, subtree: true });
    }
    window.addEventListener("resize", function () {
      scheduleAvoidance(true);
    });
    scheduleAvoidance(true);

    window.__DSH_SHELL_CHROME__ = {
      setZoom: paint,
      setMaximized: function (isMaximized) {
        maximize.title = isMaximized ? "Restore" : "Maximize";
        maximize.setAttribute("aria-label", maximize.title);
        var old = maximize.querySelector("svg");
        var fresh = glyph(isMaximized ? "restore" : "max");
        fresh.setAttribute("width", px(11));
        fresh.setAttribute("height", px(11));
        if (old) {
          maximize.replaceChild(fresh, old);
        } else {
          maximize.appendChild(fresh);
        }
      }
    };

    /* Tell Rust what happened. The chrome lives in a document we do not own, so
       this is how a broken injection becomes a log line instead of a frameless
       window with no close button. Re-checked after a tick, because a SPA that
       rewrites <body> would otherwise drop the bar silently. */
    function report(stillPresent) {
      var node = document.getElementById(ROOT_ID);
      var barBox = node && stillPresent ? node.getBoundingClientRect() : null;
      var zoomBox = stillPresent ? zoomCluster.getBoundingClientRect() : null;
      var winBox = stillPresent ? winCluster.getBoundingClientRect() : null;
      invoke("chrome_report", {
        report: {
          installed: true,
          still_present: !!node && stillPresent,
          /* Multiplied by the page zoom so Rust can compare against the design
             constants it owns: a mismatch means the 1/zoom correction was
             applied a different number of times than exactly once. */
          measured_bar_h: barBox ? barBox.height * z : 0,
          measured_zoom_w: zoomBox ? zoomBox.width * z : 0,
          measured_win_w: winBox ? winBox.width * z : 0,
          zoom: z,
          placeholder: document.documentElement.hasAttribute("data-dsh-shell-placeholder"),
          ready_state: document.readyState,
          origin: location.origin,
          boxes: "bar=" + describe(node && stillPresent ? node : null) +
            " drag=" + describe(drag) +
            " zoomc=" + describe(zoomCluster) +
            " minus=" + describe(zoomOut) +
            " plus=" + describe(zoomIn) +
            " winc=" + describe(winCluster) +
            " close=" + describe(close),
          avoid: avoidance,
          color: getComputedStyle(bar).color
        }
      }).catch(function () {});
    }

    report(true);
    setTimeout(function () {
      report(!!document.getElementById(ROOT_ID));
    }, 1500);
  }

  /* Keyboard: handled here because focus is inside the page, not the window.
     Synthesising a click on our own buttons keeps the zoom ladder in Rust
     alone. `code` rather than `key`, so it does not depend on the layout. */
  document.addEventListener("keydown", function (event) {
    if (!event.ctrlKey || !event.altKey) {
      return;
    }
    var delta = 0;
    if (event.code === "ArrowUp" || event.code === "NumpadAdd" || event.code === "Equal") {
      delta = STEP;
    } else if (event.code === "ArrowDown" || event.code === "NumpadSubtract" || event.code === "Minus") {
      delta = -STEP;
    }
    if (delta === 0) {
      return;
    }
    event.preventDefault();
    var button = document.getElementById(delta > 0 ? "dss-zoom-in" : "dss-zoom-out");
    if (button) {
      button.click();
    }
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
