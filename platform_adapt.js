/* dsh-shell window chrome, injected into every document the webview loads.
 *
 * The page is REMOTE and we do not control its stylesheet, so this file is
 * written to lose gracefully:
 *
 *  * Every piece of geometry that decides *where* the bar is and how big it is
 *    is an inline style. Inline styles beat any host rule that is not
 *    `!important`, so the dsh app's own reset, its CSS custom properties, and
 *    any future restyle cannot move or collapse the title bar.
 *  * The bar hangs off `document.documentElement`, not `body`, so nothing the
 *    page does to its own root container can capture it.
 *  * The only stylesheet we add is for hover and disabled states, which are
 *    cosmetic and safe to lose.
 *  * It is injected twice on purpose. `initialization_script` does not survive
 *    dsh's Content-Security-Policy, so the real page gets it from Rust via
 *    `eval` on page load; the early return below makes that idempotent.
 *
 * The page is also zoomed, and the chrome must not be: the webview's zoom scales
 * every CSS pixel in the document, so at 50% a 32px bar would be 16 physical
 * pixels with unusable buttons. Hence `BAR_H / z` everywhere, and a
 * counter-scale on the control clusters.
 */
(function () {
  "use strict";

  if (window.__DSH_SHELL_CHROME__) {
    return;
  }

  /* Design-space values: these are the physical pixel sizes the chrome renders
     at, whatever the page zoom is. */
  var BAR_H = 32;
  var WIN_W = 46;
  var ZOOM_W = 96;
  var RESIZE_BORDER = 6;

  var MIN = 50;
  var MAX = 100;
  var STEP = 10;

  var zoom = Number(window.__DSH_SHELL_ZOOM__);
  if (!isFinite(zoom) || zoom < MIN) zoom = 100;
  if (zoom > MAX) zoom = MAX;
  var z = zoom / 100;

  function px(designPx) {
    /* Divide by the page zoom so a CSS pixel of this length is a fixed number
       of physical pixels. */
    return designPx / z + "px";
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

  /* Hover / disabled affordances only; positioning is inline. */
  var style = document.createElement("style");
  style.textContent = [
    "#dsh-shell-chrome button { outline: none; }",
    "#dsh-shell-chrome .dss-win button:hover { background: rgba(127,127,127,0.25); }",
    "#dsh-shell-chrome .dss-win button[data-dss-close]:hover { background: #c42b1c; }",
    "#dsh-shell-chrome .dss-win button[data-dss-close]:hover svg path,",
    "#dsh-shell-chrome .dss-win button[data-dss-close]:hover svg line",
    "#dsh-shell-chrome .dss-win button[data-dss-close]:hover svg polyline { stroke: #fff; }",
    "#dsh-shell-chrome .dss-zoom button:disabled { opacity: 0.3; }",
    "#dsh-shell-chrome svg { display: block; }"
  ].join("\n");
  (document.head || document.documentElement).appendChild(style);

  /* A window glyph, 10x10 in design space. `currentColor` so the host page's
     foreground works, with a light fallback stroke so the bar is legible on a
     dark page too. */
  function glyph(kind) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 10 10");
    svg.setAttribute("width", px(11));
    svg.setAttribute("height", px(11));
    svg.setAttribute("aria-hidden", "true");

    var stroke = document.createElementNS(ns, "g");
    stroke.setAttribute("stroke", "currentColor");
    stroke.setAttribute("stroke-width", "1");
    stroke.setAttribute("fill", "none");
    stroke.setAttribute("stroke-linecap", "round");

    if (kind === "min") {
      var min = document.createElementNS(ns, "line");
      min.setAttribute("x1", "0");
      min.setAttribute("y1", "5");
      min.setAttribute("x2", "10");
      min.setAttribute("y2", "5");
      stroke.appendChild(min);
    } else if (kind === "max") {
      var max = document.createElementNS(ns, "rect");
      max.setAttribute("x", "0.5");
      max.setAttribute("y", "0.5");
      max.setAttribute("width", "9");
      max.setAttribute("height", "9");
      stroke.appendChild(max);
    } else if (kind === "restore") {
      var back = document.createElementNS(ns, "rect");
      back.setAttribute("x", "0.5");
      back.setAttribute("y", "2.5");
      back.setAttribute("width", "7");
      back.setAttribute("height", "7");
      stroke.appendChild(back);
      var front = document.createElementNS(ns, "rect");
      front.setAttribute("x", "2.5");
      front.setAttribute("y", "0.5");
      front.setAttribute("width", "7");
      front.setAttribute("height", "7");
      stroke.appendChild(front);
    } else {
      var a = document.createElementNS(ns, "line");
      a.setAttribute("x1", "0");
      a.setAttribute("y1", "0");
      a.setAttribute("x2", "10");
      a.setAttribute("y2", "10");
      var b = document.createElementNS(ns, "line");
      b.setAttribute("x1", "10");
      b.setAttribute("y1", "0");
      b.setAttribute("x2", "0");
      b.setAttribute("y2", "10");
      stroke.appendChild(a);
      stroke.appendChild(b);
    }
    svg.appendChild(stroke);
    return svg;
  }

  function cluster(className, widthPx) {
    var el = document.createElement("div");
    el.className = className;
    /* Counter-scale: the page is already scaled by z, so this returns the
       contents to their design size. transform-origin is set per cluster.
       The background is the page's own surface colour, read from its CSS
       variables, so the bar follows the dsh light/dark theme instead of
       guessing. Opaque rather than translucent: a see-through bar over an
       arbitrary page is unreadable, and `color-mix` is a needless
       compatibility risk. */
    el.style.cssText = [
      "display:flex",
      "align-items:stretch",
      "pointer-events:auto",
      "width:" + px(widthPx),
      "flex:0 0 auto",
      "transform:scale(" + 1 / z + ")",
      "background:var(--dsw-alias-bg-base, #ffffff)",
      "box-shadow:inset 1px 0 0 var(--dsw-alias-border, rgba(0,0,0,0.08))"
    ].join(";");
    return el;
  }

  function control(className, title, child) {
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
      "width:" + px(30),
      "height:" + px(BAR_H),
      "font:500 " + px(13) + "/1 'Segoe UI', system-ui, sans-serif"
    ].join(";");
    button.appendChild(child);
    return button;
  }

  function install() {
    var bar = document.createElement("div");
    bar.id = "dsh-shell-chrome";
    bar.style.cssText = [
      "position:fixed",
      "top:0",
      "left:0",
      "right:0",
      "margin:0",
      "padding:0",
      "border:0",
      "display:flex",
      "align-items:flex-start", /* stretch, spelled explicitly: the drag strip
                                   is an empty element and would otherwise
                                   collapse and make the window undraggable */
      "height:" + px(BAR_H),
      "z-index:2147483647",
      "pointer-events:none", /* the children opt back in */
      "color:var(--dsw-alias-label-primary, #16181d)",
      /* A hairline, not a band: the bar has to read as 32px of chrome rather
         than as a solid strip, and the dsh app already defines a border colour
         for its own surfaces. */
      "border-bottom:1px solid var(--dsw-alias-border, rgba(0,0,0,0.10))",
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
      /* Give the top few physical pixels back to the OS resize border: a
         frameless window cannot otherwise be resized from the top edge. */
      "margin-top:" + px(RESIZE_BORDER),
      "background:transparent"
    ].join(";");
    /* Our own drag, rather than `data-tauri-drag-region`, so the drag area is
       exactly what we drew and the page keeps every other pixel. */
    drag.addEventListener("mousedown", function (event) {
      if (event.button !== 0 || (event.detail !== 1 && event.detail !== 2)) {
        return;
      }
      event.preventDefault();
      event.stopImmediatePropagation();
      var cmd = event.detail === 2 ? "plugin:window|internal_toggle_maximize" : "plugin:window|start_dragging";
      invoke(cmd).catch(function () {});
    });
    bar.appendChild(drag);

    var zoomCluster = cluster("dss-cluster dss-zoom", ZOOM_W);
    zoomCluster.style.transformOrigin = "right top";

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

    var zoomOut = control("dss-btn", "Zoom out (Ctrl+Alt+Down)", document.createTextNode("\u2212"));
    zoomOut.id = "dss-zoom-out";
    var zoomIn = control("dss-btn", "Zoom in (Ctrl+Alt+Up)", document.createTextNode("+"));
    zoomIn.id = "dss-zoom-in";

    function paint(value) {
      zoom = value;
      z = value / 100;
      zoomLabel.textContent = value + "%";
      zoomOut.disabled = value <= MIN;
      zoomIn.disabled = value >= MAX;
      /* Every length that carries the design size has to be recomputed. */
      bar.style.height = px(BAR_H);
      drag.style.marginTop = px(RESIZE_BORDER);
      zoomCluster.style.width = px(ZOOM_W);
      winCluster.style.width = px(WIN_W * 3);
      /* One transform per cluster, and the SVG glyphs scale with the buttons. */
      zoomCluster.style.transform = "scale(" + 1 / z + ")";
      winCluster.style.transform = "scale(" + 1 / z + ")";
      [zoomOut, zoomIn, minimize, maximize, close].forEach(function (button) {
        button.style.width = button.id.indexOf("dss-zoom") === 0 ? px(30) : px(WIN_W);
        button.style.height = px(BAR_H);
        button.style.fontSize = px(button.id.indexOf("dss-zoom") === 0 ? 13 : 11.5);
      });
      var svg = winCluster.querySelectorAll("svg");
      for (var i = 0; i < svg.length; i++) {
        svg[i].setAttribute("width", px(11));
        svg[i].setAttribute("height", px(11));
      }
    }

    function step(delta) {
      invoke("zoom_step", { delta: delta })
        .then(paint)
        .catch(function () {});
    }

    zoomOut.addEventListener("click", function () {
      step(-STEP);
    });
    zoomIn.addEventListener("click", function () {
      step(STEP);
    });

    zoomCluster.appendChild(zoomOut);
    zoomCluster.appendChild(zoomLabel);
    zoomCluster.appendChild(zoomIn);
    bar.appendChild(zoomCluster);

    var winCluster = cluster("dss-cluster dss-win", WIN_W * 3);
    winCluster.style.transformOrigin = "right top";

    var minimize = control("dss-btn", "Minimize", glyph("min"));
    var maximize = control("dss-btn", "Maximize", glyph("max"));
    var close = control("dss-btn", "Close", glyph("close"));
    close.setAttribute("data-dss-close", "");
    minimize.style.width = px(WIN_W);
    maximize.style.width = px(WIN_W);
    close.style.width = px(WIN_W);

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

    window.__DSH_SHELL_CHROME__ = {
      setZoom: paint,
      setMaximized: function (isMaximized) {
        maximize.title = isMaximized ? "Restore" : "Maximize";
        maximize.setAttribute("aria-label", maximize.title);
        var old = winCluster.querySelector("svg");
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
       window with no close button. Re-checked after a tick, because a SPA that
       rewrites <body> would otherwise drop the bar silently. */
    function reportPayload(stillPresent) {
      var node = document.getElementById("dsh-shell-chrome");
      function box(el) {
        if (!el) return "none";
        var r = el.getBoundingClientRect();
        return r.width.toFixed(0) + "x" + r.height.toFixed(0) + "@" + r.left.toFixed(0) + "," + r.top.toFixed(0);
      }
      return {
        installed: true,
        still_present: !!node && stillPresent,
        height_css_px: node && stillPresent ? node.getBoundingClientRect().height : 0.0,
        zoom: z,
        computed_zoom: "",
        placeholder: document.documentElement.hasAttribute("data-dsh-shell-placeholder"),
        ready_state: document.readyState,
        origin: location.origin,
        dsh_root_children: (document.getElementById("root") || { childNodes: [] }).childNodes.length,
        boxes:
          "bar=" + box(node) +
          " drag=" + box(drag) +
          " zoomc=" + box(zoomCluster) +
          " label=" + box(zoomLabel) +
          " minus=" + box(zoomOut) +
          " plus=" + box(zoomIn) +
          " winc=" + box(winCluster) +
          " close=" + box(close) +
          " svg=" + box(close.firstChild) +
          " color=" + getComputedStyle(bar).color
      };
    }

    function report(stillPresent) {
      invoke("chrome_report", { report: reportPayload(stillPresent) }).catch(function () {});
    }
    report(true);
    setTimeout(function () {
      report(!!document.getElementById("dsh-shell-chrome"));
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
