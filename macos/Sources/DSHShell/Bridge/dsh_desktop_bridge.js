/* dsh-desktop-bridge — declares this webview as a macOS desktop host.
 *
 * Injected as ONE WKUserScript at documentStart, ahead of bridge.js. That
 * ordering is load-bearing: dsh reads `dataset.platform` while its modules
 * initialise, so the attribute has to exist before any page script runs.
 *
 * ## Why this file exists at all
 *
 * dsh 0.2.0-rc.2 ships a desktop-host contract for macOS. Declaring the runtime
 * makes dsh reserve the 48px top band itself, apply its own vibrancy styling to
 * the sidebar, and hand keyboard input to a trusted preload instead of leaving it
 * to DOM key handling. Measured: docs/dsh-desktop-contract.md.
 *
 * ## The attribute and this bridge must load together, or not at all
 *
 * `dataset.platform` is not a CSS hook — it is a *runtime switch*. Its presence
 * puts dsh into the desktop runtime, which then requires `dshDesktopBoot.ready()`
 * to resolve before it will mount anything:
 *
 *     runtime: dataset.platform === undefined ? "web" : "desktop"
 *     ... ShortcutsService: if (runtime === "desktop" && !keyboard) throw
 *
 * Setting the attribute without this bridge does not degrade, it *breaks*: the
 * shortcuts service throws, `ui-shortcuts` and `ui-layout` stay pending forever,
 * and the boot card reports "24 entries did not activate" — an app that never
 * loads, with no explanation.
 *
 * So the attribute and the bridge live in this one file, injected as one script.
 * If the resource is missing, Swift never injects anything, neither happens, and
 * dsh runs as an ordinary browser document. There is no state in which half of
 * this contract is applied.
 *
 * ## What the host does NOT have to do
 *
 * `dshDesktopBoot.ready()` returns a `streamBaseUrl`, and the frontend then sets
 * `window.__DSH_TRANSPORT__ = { ownsHost: true, streamBaseUrl }`. That reads like
 * an obligation to proxy the event stream. It is not: in the shipped client
 * bundle `__DSH_TRANSPORT__` is consumed exactly once and only its `loadBundle`
 * field is read, and `ownsHost` is written and never read. The page keeps
 * talking to `location.origin` and keeps loading modules the way it does without
 * us.
 *
 * But do NOT read that as "the value does not matter". Returning
 * `streamBaseUrl: ""` — the natural conclusion, since nothing in that bundle
 * reads it — makes the dsh UI fail to boot: 57 entries never activate,
 * `@deepseek-ai/dsh-api-gateway: failed`, and the boot card sits on
 * "Loading plugins…" forever. Something outside the bundle consumes the value;
 * the bundle only proves that it is not the bundle.
 *
 * So: hand it the real origin. That is one property, and it is correct whether
 * or not anyone reads it.
 *
 * Measured by the probe in tools/dsh-probe: docs/dsh-desktop-contract.md.
 *
 * ## The revision is a hard requirement, not bookkeeping
 *
 * `installNativeKeyboard` begins:
 *
 *     keyboard.subscribe((input) => {
 *       if (input.revision !== snapshot().revision) return;
 *
 * A stale revision is dropped *silently*. The native side therefore dispatches
 * with the revision from the most recent `shortcuts.get()`, refreshed after
 * every successful `edit`. See DshDesktopBridge.swift.
 *
 * ## Messages to the host
 *
 * Page → host over `window.webkit.messageHandlers.dshDesktop` (fire and forget).
 * Host → page over `window.__dshShellDesktop.*` invoked via `evaluateJavaScript`.
 *
 * `postMessage` cannot carry a value back to JavaScript, which is why every
 * request here is a Promise the host resolves later by calling one of the
 * `__dshShellDesktop.*` entry points. That is also the direction a dispatched
 * shortcut has to travel, so there is only one mechanism rather than two.
 */
(function () {
  "use strict";

  /* Idempotent: the host may inject this more than once across a navigation.
     Re-running it would reset the subscription slots mid-session. */
  if (window.__dshShellDesktop) { return; }

  /* ------------------------------------------------------------------ *
   * 1. The runtime switch. First statement that touches the document,
   *    because everything below depends on the attribute being set.
   * ------------------------------------------------------------------ */
  document.documentElement.dataset.platform = "darwin";

  var host = window.webkit && window.webkit.messageHandlers
    ? window.webkit.messageHandlers.dshDesktop
    : null;

  var keyboardListener = null;
  var shortcutListener = null;
  var nextRequestId = 0;
  var pending = Object.create(null);

  function send(type, payload) {
    if (!host) { return false; }
    try {
      host.postMessage(JSON.stringify({ type: type, payload: payload || null }));
      return true;
    } catch (error) {
      /* A dead handler means the host is gone. Fall back to the in-memory
         defaults below rather than rejecting every shortcut lookup. */
      return false;
    }
  }

  function settle(id, ok, value) {
    var entry = pending[id];
    if (!entry) { return; }
    delete pending[id];
    if (ok) { entry.resolve(value); } else { entry.reject(value); }
  }

  /* A snapshot that is valid without the host. Shape comes from
     `ShortcutPersistence.initialShortcutConfig()`: `revision` is a UUID
     *string*, which is not a detail — the service compares it by value and a
     number here fails every comparison. */
  function fallbackSnapshot() {
    return {
      revision: "00000000-0000-4000-8000-000000000000",
      sequence: 0,
      document: { schemaVersion: 1, profiles: {} },
      status: "ready",
      error: null,
      usingDefaults: true
    };
  }

  /* -------------------------------------------------------------- *
   * 2. The boot bridge.
   *
   *    dsh awaits this before resolving `__DSH_BOOT_READY__`, so a rejection
   *    means the page never mounts. It must resolve, always, quickly.
   * -------------------------------------------------------------- */
  var boot = {
    ready: function () {
      /* `location.origin`, not "". Reading the shipped bundle says the value is
         never consumed there, which is true and is exactly how the empty string
         got shipped into the first version — and it does not boot. Hand it the
         real origin; it is correct either way and costs one property. */
      return Promise.resolve({ injections: [], streamBaseUrl: location.origin });
    },
    failed: function (reason) {
      send("bootFailed", { reason: String(reason) });
      return Promise.resolve();
    }
  };

  /* -------------------------------------------------------------- *
   * 3. The desktop capability surface. Five entry points, measured.
   * -------------------------------------------------------------- */
  var desktop = {
    protocolVersion: 1,

    keyboard: {
      /* Registers dsh's dispatcher. The returned function is how it
         unsubscribes; we do not need to do anything with it, but returning
         one is part of the contract. */
      subscribe: function (listener) {
        keyboardListener = listener;
        send("keyboardSubscribed", {});
        return function () {
          if (keyboardListener === listener) { keyboardListener = null; }
        };
      },
      closeWindow: function (revision) {
        send("closeWindow", { revision: revision });
        return Promise.resolve();
      }
    },

    shortcuts: {
      get: function (definitions) {
        if (!host) { return Promise.resolve(fallbackSnapshot()); }
        var id = String(++nextRequestId);
        var p = new Promise(function (resolve, reject) {
          pending[id] = { resolve: resolve, reject: reject };
        });
        send("shortcutsGet", { id: id, definitions: definitions || [] });
        return p;
      },
      edit: function (edit, revision) {
        if (!host) { return Promise.resolve({ status: "not-ready", snapshot: fallbackSnapshot() }); }
        var id = String(++nextRequestId);
        var p = new Promise(function (resolve, reject) {
          pending[id] = { resolve: resolve, reject: reject };
        });
        send("shortcutsEdit", { id: id, edit: edit, revision: revision });
        return p;
      },
      subscribe: function (listener) {
        shortcutListener = listener;
        return function () {
          if (shortcutListener === listener) { shortcutListener = null; }
        };
      },
      recording: function () {
        return Promise.resolve({});
      },
      dispose: function () {}
    },

    deviceInfo: {
      platform: "macos",
      runtime: "desktop",
      /* Reported, not required. Useful when a dsh build starts branching on it. */
      hostBridgeVersion: 1
    }
  };

  window.dshDesktopBoot = boot;
  window.dshDesktop = desktop;

  /* -------------------------------------------------------------- *
   * 4. The surface the host drives. Everything here is called from Swift via
   *    `evaluateJavaScript`, which is the only way a value gets back into the
   *    page — `postMessage` is one-way.
   * -------------------------------------------------------------- */
  window.__dshShellDesktop = {
    version: 1,
    mode: "darwinReal",

    /* Resolve a pending `shortcuts.get` / `shortcuts.edit`. */
    resolveShortcuts: function (id, ok, value) {
      settle(String(id), !!ok, value);
      return true;
    },

    /* Push one DesktopShortcutInput into the listener dsh registered.
       Returns false when nothing is listening, so the host can log that rather
       than believe a shortcut fired. */
    dispatchShortcut: function (input) {
      if (!keyboardListener) { return false; }
      keyboardListener(input);
      return true;
    },

    /* Publish a changed shortcut configuration to dsh's subscribers. */
    publishShortcuts: function (snapshot) {
      if (!shortcutListener) { return false; }
      shortcutListener(snapshot);
      return true;
    },

    hasKeyboardListener: function () { return !!keyboardListener; },
    hasShortcutListener: function () { return !!shortcutListener; }
  };

  /* -------------------------------------------------------------- *
   * 5. Native window drag.
   *
   *    dsh marks its chrome rows `data-window-drag` and ui-web's base.css
   *    turns that into `-webkit-app-region: drag` — a Blink property. WebKit
   *    does not implement it (measured: `CSS.supports('-webkit-app-region',
   *    'drag')` is false), so on macOS those rows would not drag the window at
   *    all. We forward the gesture to the host, which hands a mouseDown to
   *    `performWindowDragWithEvent:`.
   *
   *    Installed here, inside the injected script, rather than by the host
   *    calling in afterwards. The host cannot: it runs before the document
   *    exists, so a listener it evaluates is attached to `about:blank` and is
   *    gone by the first navigation — which is the only document that matters.
   *    Registering at documentStart is also what makes it survive a reload.
   * -------------------------------------------------------------- */
  function installDragForwarding() {
    if (document.__dshShellDragInstalled) { return false; }
    document.__dshShellDragInstalled = true;
    document.addEventListener(
      "mousedown",
      function (event) {
        if (event.button !== 0) { return; }
        var row = event.target && event.target.closest
          ? event.target.closest("[data-window-drag]")
          : null;
        if (!row) { return; }
        /* Without this the browser begins a text selection under the cursor
           and the page scrolls instead of the window moving. */
        event.preventDefault();
        /* Reported for diagnosis only. The host ignores the coordinates and
           drives the drag from `NSEvent.mouseLocation`, because that is the real
           cursor and is what the Window Server expects; synthesising a drag from
           reported values would make the window follow our numbers rather than
           the user's pointer. */
        send("beginWindowDrag", { screenX: event.screenX, screenY: event.screenY });
      },
      true
    );
    return true;
  }
  installDragForwarding();

  send("bridgeInstalled", {
    hasHost: !!host,
    appRegion: !!(window.CSS && CSS.supports && CSS.supports("-webkit-app-region", "drag"))
  });
})();