/* Platform adaptation, injected as a Tauri initialization script.
 *
 * This runs before any page script on every navigation, so it must tolerate a
 * document that has not been parsed yet. The previous version was a .css file
 * containing a JavaScript IIFE, `eval`-ed immediately after the window was
 * built — which raced the page load and silently did nothing most of the time.
 */
(function () {
  "use strict";

  var MARKER = "dsh-shell-platform-adapt";
  var CSS = [
    ":root { --dsh-shell-scrollbar: 10px; }",
    "html, body { scrollbar-width: thin; }",
    "::-webkit-scrollbar { width: var(--dsh-shell-scrollbar); height: var(--dsh-shell-scrollbar); }",
    "::-webkit-scrollbar-thumb { background: rgba(128,128,128,0.32); border-radius: 6px; }",
    "::-webkit-scrollbar-thumb:hover { background: rgba(128,128,128,0.5); }",
    "::-webkit-scrollbar-track { background: transparent; }",
    "/* Native window drag region along the top edge, like a desktop app. */",
    "body { -webkit-user-select: none; }",
    "input, textarea, [contenteditable] { -webkit-user-select: text; }"
  ].join("\n");

  function install() {
    if (document.getElementById(MARKER)) {
      return;
    }
    var style = document.createElement("style");
    style.id = MARKER;
    style.textContent = CSS;
    var host = document.head || document.documentElement;
    if (host) {
      host.appendChild(style);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  } else {
    install();
  }
})();
