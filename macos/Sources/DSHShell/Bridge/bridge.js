// dsh-shell bridge — injected at documentStart into the dsh SPA.
// Provides:
//   window.__dshShell.do(action, arg)   — native -> web commands
//   web -> native events via window.webkit.messageHandlers.dshBridge
//
// Everything here must be defensive: the SPA's DOM is not guaranteed to match
// any assumption, so every lookup is guarded and failures are silent. Probe
// events are posted so the native side can tune selectors from real pages.
(function () {
  'use strict';
  if (window.__dshShell) { return; }

  var bridge = {};

  function post(type, payload) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshBridge;
      if (h) { h.postMessage(JSON.stringify({ type: type, payload: payload || null })); }
    } catch (e) { /* never throw */ }
  }

  function cls(el) { return el && el.className ? String(el.className) : ''; }
  function attr(el, name) { return el ? el.getAttribute(name) : null; }

  // ---- composer detection: the main message input ----
  function findComposer() {
    var q = document.querySelector('textarea[data-testid], textarea, [contenteditable="true"]');
    return q || null;
  }

  function focusComposer() {
    var el = findComposer();
    if (el) { el.focus(); return { ok: true }; }
    return { ok: false };
  }

  // React-controlled textarea value setter trick: bypasses React's value
  // tracker while still firing a bubbled `input` event React listens to.
  function setNativeValue(el, text) {
    var proto = el.tagName === 'TEXTAREA'
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) { setter.set.call(el, text); }
    else { el.value = text; }
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }

  function sendMessage() {
    var el = findComposer();
    if (!el) { return { ok: false }; }
    el.focus();
    var e = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
    el.dispatchEvent(new KeyboardEvent('keydown', e));
    el.dispatchEvent(new KeyboardEvent('keyup', e));
    return { ok: true };
  }

  // ---- button lookup helpers ----
  function buttonByPattern(patterns) {
    var buttons = document.querySelectorAll('button, [role="button"]');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      var hay = ((attr(b, 'aria-label') || '') + ' ' + (attr(b, 'title') || '') + ' ' + cls(b)).toLowerCase();
      for (var j = 0; j < patterns.length; j++) {
        if (hay.indexOf(patterns[j]) !== -1) { return b; }
      }
    }
    return null;
  }

  function newSession() {
    var b = buttonByPattern(['new chat', 'new conversation', '新建', '新对话', 'new-session', 'create session']);
    if (b) { b.click(); return { ok: true, method: 'click' }; }
    return { ok: false };
  }

  function openWorkspace() {
    var b = buttonByPattern(['workspace', 'folder', 'directory', '工作区', '目录', '文件夹']);
    if (b) { b.click(); return { ok: true, method: 'click' }; }
    return { ok: false };
  }

  // ---- CSS shim: keep the SPA's top chrome clear of the traffic lights ----
  // The titlebar shim has been REMOVED, and the reason is worth keeping.
  //
  // It padded the sidebar column by 20px so the transparent titlebar's traffic
  // lights would not sit on top of it, targeting:
  //
  //     #root [data-dsh-frame] > [data-pane="sidebar"]
  //
  // Neither `data-dsh-frame` nor `data-pane` exists anywhere in
  // @deepseek-ai/dsh@0.2.0-rc.2 — grepped across the whole package tree. The
  // comment above the selector claimed they were "dsh's own semantic markers,
  // stable across builds unlike the hashed CSS-module classes"; they were a
  // guess that reads like a fact, and the shim has been a silent no-op ever
  // since. A no-op is the right failure mode and the wrong feature.
  //
  // dsh does have a real mechanism for this, and it is not a selector: under
  // `html[data-platform='darwin']` it publishes `--dsh-frame-top-clearance`
  // and reserves the space itself. Claiming the desktop runtime is a separate
  // decision — it requires the `window.dshDesktop` preload bridge — and is
  // written up in docs/dsh-shell-contract.md §7. Until then the shell keeps
  // the native titlebar and lets dsh lay out as a browser, which is what
  // actually happens.
  //
  // What replaced the heartbeat call: nothing. The scan no longer writes to the
  // page's style attributes on every tick, which was a forced style recalc up
  // to 2.5 times a second during a conversation.

  // ---- probe: report DOM candidates for native-side selector tuning ----
  function probeCandidates() {
    var out = { headings: [], buttons: [], inputs: [], running: false, layout: null };
    try {
      var hs = document.querySelectorAll('h1, h2, h3');
      for (var i = 0; i < Math.min(hs.length, 10); i++) {
        var t = hs[i].textContent ? hs[i].textContent.trim().slice(0, 120) : '';
        if (t) { out.headings.push({ tag: hs[i].tagName, cls: cls(hs[i]).slice(0, 100), text: t }); }
      }
      var bs = document.querySelectorAll('button');
      for (var j = 0; j < Math.min(bs.length, 40); j++) {
        out.buttons.push({
          aria: attr(bs[j], 'aria-label'),
          title: attr(bs[j], 'title'),
          cls: cls(bs[j]).slice(0, 100)
        });
      }
      var ins = document.querySelectorAll('textarea, [contenteditable="true"]');
      for (var k = 0; k < Math.min(ins.length, 5); k++) {
        out.inputs.push({
          tag: ins[k].tagName,
          placeholder: attr(ins[k], 'placeholder'),
          cls: cls(ins[k]).slice(0, 100)
        });
      }
      // layout: path from #root down to the grid frame, so the shim can pick
      // a stable selector for the sidebar column alone.
      var root = document.getElementById('root');
      if (root) {
        var walk = [];
        var el = root;
        for (var d = 0; d < 4 && el; d++) {
          var info = { tag: el.tagName, cls: cls(el).slice(0, 80), data: [] };
          if (el.attributes) {
            for (var a = 0; a < el.attributes.length; a++) {
              var n = el.attributes[a].name;
              if (n.indexOf('data-') === 0) { info.data.push(n + '=' + (el.attributes[a].value || '')); }
            }
          }
          var gtc = el.style && el.style.gridTemplateColumns;
          if (gtc) { info.grid = gtc; }
          var cs = window.getComputedStyle ? window.getComputedStyle(el) : null;
          if (cs && cs.paddingTop !== '0px') { info.pad = cs.paddingTop; }
          walk.push(info);
          el = el.firstElementChild;
        }
        out.layout = walk;
        // Replaced the old shim report. The question worth asking about the page
        // is now the one that decides the route: does dsh know it is on a
        // desktop, and what does it publish? Read from CSS rather than from
        // class names, so it survives a dsh build.
        var rootStyle = window.getComputedStyle(document.documentElement);
        out.desktop = {
          platform: document.documentElement.getAttribute('data-platform'),
          titlebar: document.documentElement.hasAttribute('data-windows-titlebar'),
          fullscreen: document.documentElement.hasAttribute('data-fullscreen'),
          topClearance: rootStyle.getPropertyValue('--dsh-frame-top-clearance').trim(),
          chromeTop: rootStyle.getPropertyValue('--dsh-frame-chrome-top').trim(),
          leadingClearance: rootStyle.getPropertyValue('--dsh-frame-leading-clearance').trim(),
          overlayTop: rootStyle.getPropertyValue('--dsh-frame-overlay-top').trim(),
          dragRegions: document.querySelectorAll('[data-window-drag]').length,
          appRegionSupported: !!(window.CSS && CSS.supports && CSS.supports('-webkit-app-region', 'drag'))
        };
      }
    } catch (e) { /* ignore */ }
    return out;
  }

  // ---- observation: agent running state + document title ----
  var runningState = null;
  var lastTitle = null;
  function scanRunning() {
    try {
      var buttons = document.querySelectorAll('button');
      var running = false;
      for (var i = 0; i < buttons.length; i++) {
        var b = buttons[i];
        var hay = ((attr(b, 'aria-label') || '') + ' ' + (attr(b, 'title') || '') + ' ' + cls(b)).toLowerCase();
        if (hay.indexOf('stop') !== -1 || hay.indexOf('interrupt') !== -1 || hay.indexOf('中断') !== -1 || hay.indexOf('停止') !== -1) {
          running = true; break;
        }
      }
      if (running !== runningState) {
        runningState = running;
        post('agentState', { running: running });
      }
      var t = (document.title || '').trim();
      if (t !== lastTitle) {
        lastTitle = t;
        post('title', { text: t });
      }
    } catch (e) { /* ignore */ }
  }

  function scheduleScan() {
    clearTimeout(scheduleScan._t);
    scheduleScan._t = setTimeout(function () { scanRunning(); }, 400);
  }

  try {
    var mo = window.MutationObserver ? new MutationObserver(scheduleScan) : null;
    if (mo) { mo.observe(document.documentElement, { childList: true, subtree: true }); }
  } catch (e) { /* ignore */ }

  // ---- public surface ----
  bridge.do = function (action, arg) {
    var result;
    switch (action) {
      case 'focusComposer': result = focusComposer(); break;
      case 'sendMessage': result = sendMessage(); break;
      case 'newSession': result = newSession(); break;
      case 'openWorkspace': result = openWorkspace(); break;
      case 'injectText': { var el = findComposer(); result = el ? (setNativeValue(el, String(arg || '')), { ok: true }) : { ok: false }; break; }
      default: result = { ok: false, reason: 'unknown action' };
    }
    var ack = { action: action, ok: !!result.ok };
    if (result && result.reason) { ack.reason = result.reason; }
    post('ack', ack);
    return result;
  };

  window.__dshShell = bridge;

  // initial probe once the app shell has a chance to mount
  setTimeout(function () {
    post('probe', probeCandidates());
    scanRunning();
  }, 2500);
  setTimeout(function () {
    post('probe', probeCandidates());
    scanRunning();
  }, 8000);
})();
