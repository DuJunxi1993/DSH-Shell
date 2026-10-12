// dsh-probe — measures what the dsh web UI does on its own when a desktop host
// declares itself, versus what it does for an ordinary browser document.
//
// The question this answers: how much of the chrome-avoidance code in both
// shells is redundant. dsh 0.2.0-rc.2 ships a documented desktop contract
// (`html[data-platform='darwin']`, `html[data-windows-titlebar]` +
// `--dsh-windows-titlebar-height`, the `--dsh-frame-*` custom properties). Both
// shells ignore it and compensate geometrically instead. This probe measures
// what dsh reserves for itself once the contract is honoured.
//
// Three modes, same URL, same measurements, one screenshot each:
//   A baseline  — nothing injected. Reproduces what the macOS shell sees today.
//   B darwin    — `documentElement.dataset.platform = 'darwin'`.
//   C windows   — `data-windows-titlebar` + `--dsh-windows-titlebar-height: 32px`.
//
// Build:  swiftc -O main.swift -o dsh-probe -framework AppKit -framework WebKit
// Run:    ./dsh-probe --port 3080 --out <dir>
//
// Safety: this spawns `dsh web` and kills only the PID it captured from its own
// Process. It never kills by name. See the "Hard safety rules" in
// windows/AGENTS.md — a previous agent killed its own host harness with a
// name-based kill.

import AppKit
import Foundation
import WebKit

// MARK: - Arguments

func argValue(_ name: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let outDir = argValue("--out", FileManager.default.currentDirectoryPath + "/probe-out")
let dshBin = argValue("--dsh", "/Users/djx/.npm-global/bin/dsh")
let dshHome = argValue("--dsh-home", NSTemporaryDirectory() + "dsh-probe-home-\(getpid())")
let port = Int(argValue("--port", "3080")) ?? 3080
let trustedHost = "127.0.0.1:\(port)"
/// Restrict the run to one mode. Not a convenience: loading the same page six
/// times in a row against one dsh mutates host state, and a failure that only
/// appears on the last load is indistinguishable from a bug in that mode's
/// script. Running a mode alone is what separates the two.
let onlyMode = argValue("--only", "")
/// Page zoom to measure at, as a percentage. The shell caps its own ladder at
/// 100; this measures what dsh actually does past that, so the cap is an
/// informed decision rather than an inherited one.
let zoomPercent = Double(argValue("--zoom", "100")) ?? 100

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: dshHome, withIntermediateDirectories: true)

// MARK: - Output helpers

func logLine(_ s: String) {
    FileHandle.standardError.write(("[dsh-probe] " + s + "\n").data(using: .utf8)!)
}

// MARK: - dsh lifecycle

final class Dsh {
    let process = Process()
    private(set) var url: URL?
    private(set) var resolvedReason = ""
    var stderrTail: [String] = []
    private var stdoutDone = false
    private var resolveWaiters: [(URL?) -> Void] = []
    /// Compiled once, not per line.
    static let urlLine = try? NSRegularExpression(
        pattern: #"^\s*dsh\s+web\s*:\s*(\S+)"#, options: [.caseInsensitive])

    init(port: Int, dshBin: String, dshHome: String, trustedHost: String) {
        process.executableURL = URL(fileURLWithPath: dshBin)
        // Never through a shell: user input cannot become argv injection.
        process.arguments = ["web", "--no-open", "--host", "127.0.0.1",
                             "--port", "\(port)", "--trusted-host", trustedHost]
        var env = ProcessInfo.processInfo.environment
        env["DSH_HOME"] = dshHome  // isolate from the user's ~/.dsh
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                self?.consumeLine(String(line))
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let self else { return }
                // stderr is logged, never parsed as a URL source: dsh prints its
                // internal `bili` proxy there (http://127.0.0.1:18787).
                self.stderrTail.append(String(line))
                if self.stderrTail.count > 40 { self.stderrTail.removeFirst() }
            }
        }
    }

    /// The four acceptance rules, each learned from a real failure.
    private func consumeLine(_ line: String) {
        let stripped = line.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
        // 1. must be the `dsh web:` line — stderr's bili proxy URL is a decoy.
        //    `\S+` stops at the space of the optional `(LAN: …)` suffix.
        guard let re = Self.urlLine,
              let m = re.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let g = Range(m.range(at: 1), in: stripped)
        else { return }
        let raw = String(stripped[g])

        func reject(_ why: String) {
            logLine("URL line rejected: \(why) — \(raw)")
        }
        guard let u = URL(string: raw) else { return reject("unparsable") }
        // 2. loopback only; dsh binds loopback
        let host = u.host?.lowercased() ?? ""
        guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
            return reject("non-loopback host \(host)")
        }
        // 3. the port we asked for — the internal proxy may answer on another
        guard u.port == port else { return reject("port \(u.port ?? -1) != \(port)") }
        // 4. a non-empty token is mandatory: `authorizeIndex` answers 401 without
        //    a valid token query or a `dsh-auth-` cookie, and a tokenless URL can
        //    never load the SPA.
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let token = comps?.queryItems?.first { $0.name == "token" }?.value ?? ""
        guard !token.isEmpty else { return reject("no ?token=") }

        url = u
        resolvedReason = "dsh web: line, loopback, port \(port), token present"
        let waiters = resolveWaiters
        resolveWaiters = []
        waiters.forEach { $0(u) }
    }

    func waitForURL(timeout: TimeInterval) -> URL? {
        if let url { return url }
        let deadline = Date().addingTimeInterval(timeout)
        var answered = false
        var result: URL?
        let done = DispatchSemaphore(value: 0)
        resolveWaiters.append { u in
            result = u
            answered = true
            done.signal()
        }
        while !answered && Date() < deadline {
            if process.isRunning {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            } else {
                break
            }
        }
        _ = done.wait(timeout: .now())
        if !answered { logLine("timed out after \(Int(timeout))s waiting for the URL line") }
        return result
    }

    var pid: Int32 { process.processIdentifier }

    /// SIGTERM, bounded grace, SIGKILL. Scoped to the PID we captured; nothing
    /// in this file signals a process we did not spawn.
    func shutdown() {
        guard process.isRunning else { return }
        logLine("terminating dsh pid \(pid)")
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}

/// The load-bearing invariant of this whole repository: the app exits → dsh dies
/// → the port is freed. Asserted directly rather than assumed.
func portIsFree(_ port: Int) -> Bool {
    let l = socket(AF_INET, SOCK_STREAM, 0)
    guard l >= 0 else { return false }
    defer { close(l) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    // SO_REUSEADDR because that is what a real server (node) sets, and because
    // TIME_WAIT sockets from accepted connections otherwise make a strict bind
    // report "in use" long after the listener is gone.
    var on: Int32 = 1
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(l, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return r == 0
}

/// The host-side stand-in the probe appends around the app's real bridge.
///
/// Two things a browser cannot provide, which is exactly the two the app provides
/// natively: answering `shortcuts.get`, and the key monitor. Everything else —
/// the attribute, the five entry points, the drag forwarding — is the file under
/// test, unmodified.
///
/// Split in two, and the split is the whole point. The handler has to exist
/// *before* the bridge runs, because the bridge captures
/// `window.webkit.messageHandlers.dshDesktop` once at load and would otherwise
/// hold `null` for the rest of the page's life. In the app that ordering is free:
/// Swift registers the handler on the user content controller before injecting.
/// A probe that appended its handler afterwards was therefore testing a
/// situation the app never produces, and it failed for a reason that had nothing
/// to do with the bridge.
private let probeHostPre = """
; /* ---- host stand-in, installed before the bridge under test ---- */
(function () {
  var SNAPSHOT = {
    revision: "00000000-0000-4000-8000-000000000000",
    sequence: 1,
    document: { schemaVersion: 1, profiles: {} },
    status: "ready", error: null, usingDefaults: true
  };
  window.__dshProbeLog = [];
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.dshDesktop = {
    postMessage: function (raw) {
      var msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      // Record the payload too. `type` alone cannot distinguish "dsh reported a
      // boot failure" from what it failed on, and the failure text is the only
      // place the reason exists.
      window.__dshProbeLog.push(
        msg.type + (msg.payload === null || msg.payload === undefined
          ? '' : ' ' + JSON.stringify(msg.payload)));
      var reply = function (id, ok, value) {
        if (window.__dshShellDesktop && window.__dshShellDesktop.resolveShortcuts) {
          window.__dshShellDesktop.resolveShortcuts(id, ok, value);
        }
      };
      if (msg.type === "shortcutsGet") reply(msg.payload.id, true, SNAPSHOT);
      else if (msg.type === "shortcutsEdit") reply(msg.payload.id, true, { status: "saved", snapshot: SNAPSHOT });
      else if (msg.type === "beginWindowDrag") window.__dshProbeDrag = msg.payload;
    }
  };
})();
"""

private let probeHostPost = """
// ---- probe instrumentation, after the bridge ----
// Wrap `ready()` so we can see whether dsh ever called it and what it did.
// A boot card sitting on "Loading plugins..." for 90s means __DSH_BOOT_READY__
// never resolved, and the only way to tell "never called" from "called and
// rejected" from "resolved but something else hung" is to watch the call.
(function () {
  var b = window.dshDesktopBoot;
  if (!b || b.__probeWrapped) { return; }
  b.__probeWrapped = true;
  var real = b.ready;
  b.ready = function () {
    window.__dshProbeLog.push('ready:called');
    var r;
    try { r = real.apply(this, arguments); }
    catch (e) { window.__dshProbeLog.push('ready:threw ' + e); throw e; }
    return Promise.resolve(r).then(
      function (v) { window.__dshProbeLog.push('ready:resolved'); return v; },
      function (e) { window.__dshProbeLog.push('ready:rejected ' + e); throw e; });
  };
})();
window.__dshProbeInstalled = true;
"""

extension Mode {
    /// Read the bridge the app actually ships.
    ///
    /// `STUB_BRIDGE_PATH` overrides it so a candidate implementation can be tried
    /// without rebuilding the app. A missing file is a hard failure in the probe:
    /// the point is to test the real thing, and silently falling back to a copy
    /// would turn the gate into decoration.
    static func appBridgeSource() -> String {
        if let override = ProcessInfo.processInfo.environment["STUB_BRIDGE_PATH"],
           FileManager.default.isReadableFile(atPath: override) {
            return probeHostPre
                + ((try? String(contentsOfFile: override, encoding: .utf8)) ?? "")
                + probeHostPost
        }
        // Search upward from this file rather than counting directories: the probe may
        // be compiled from anywhere, and a wrong count fails with "cannot read the
        // bridge", which reads like a missing file rather than like a path bug.
        //
        // `#filePath` is whatever path the compiler was given, so it can be
        // relative. Resolve it against the working directory first — otherwise
        // `deletingLastPathComponent` walks off the front of a relative path and
        // the search starts in the wrong place entirely.
        var dir = URL(fileURLWithPath: #filePath)
        if !dir.path.hasPrefix("/") {
            dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(dir.path)
        }
        dir = dir.standardizedFileURL.deletingLastPathComponent()
        let relative = "Sources/DSHShell/Bridge/dsh_desktop_bridge.js"
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative)
            if let source = try? String(contentsOfFile: candidate.path, encoding: .utf8) {
                logLine("app bridge loaded from \(candidate.path)")
                return probeHostPre + source + probeHostPost
            }
            dir = dir.deletingLastPathComponent()
        }
        FileHandle.standardError.write(
            "[dsh-probe] FATAL: cannot find \(relative) above \(#filePath)\n"
                .data(using: .utf8)!)
        exit(5)
    }
}

// MARK: - Process leak protection

/// The PID of the dsh this probe spawned, if any.
///
/// Registered with `atexit` so that *every* exit path reaps it, including the
/// ones nobody planned: a fatal read of the bridge, a crash in a measurement
/// closure, a Ctrl-C. Without this the probe leaks a dsh holding the port, which
/// is the exact failure every test in this repository exists to prevent — and the
/// first version of this tool produced it.
///
/// Not a `deinit`: a leaked object never runs one.
nonisolated(unsafe) var probeSpawnedPID: Int32 = -1

nonisolated func reapSpawnedDsh() {
    let pid = probeSpawnedPID
    guard pid > 0 else { return }
    probeSpawnedPID = -1
    if kill(pid, 0) != 0 { return }
    kill(pid, SIGTERM)
    // No run loop is guaranteed here, so poll with waitpid rather than sleeping
    // on a Task: this runs during teardown, where nothing else is scheduled.
    var status: Int32 = 0
    for _ in 0..<50 {
        if waitpid(pid, &status, WNOHANG) != 0 { return }
        usleep(100_000)
    }
    kill(pid, SIGKILL)
}

// MARK: - Injection

enum Mode: String, CaseIterable {
    case baseline, darwin, windows, darwinProxy, darwinReal, darwinAppBridge

    var script: String {
        switch self {
        case .baseline:
            // No DOM contract declared. Reproduces today's macOS shell.
            return "window.__PROBE_MODE__='baseline';"
        case .darwin:
            // dsh reads this during module init, so it must land at
            // documentStart, before any page script.
            //
            // NOTE: this is also the runtime switch, not just a CSS hook.
            // `detectEnvironment` returns runtime:"desktop" whenever the
            // attribute is present, and ShortcutsService then throws
            // "Desktop keyboard bridge unavailable" without window.dshDesktop.
            return "window.__PROBE_MODE__='darwin';"
                + "document.documentElement.dataset.platform='darwin';"
        case .windows:
            // `--dsh-windows-titlebar-height` is read, never set, by dsh: the
            // host owns it. Setting it on <html> inherits into the frame.
            return "window.__PROBE_MODE__='windows';"
                + "document.documentElement.setAttribute('data-windows-titlebar','');"
                + "document.documentElement.style.setProperty('--dsh-windows-titlebar-height','32px');"
        case .darwinAppBridge:
            // The gate. Every earlier mode embedded a *copy* of the bridge, which
            // proved the contract was implementable and said nothing about
            // whether this implementation works. This one loads the file the app
            // actually ships, so a regression in it fails here rather than as a
            // white window on someone's machine.
            return Mode.appBridgeSource()
        case .darwinProxy:
            // Enumerates the preload surface instead of guessing it: a Proxy
            // records every property read and every call dsh makes against
            // window.dshDesktop, which is the actual answer to "what must a
            // macOS desktop host implement".
            return """
            window.__PROBE_MODE__='darwinProxy';
            window.__PROBE_BRIDGE_LOG__=[];
            const L = window.__PROBE_BRIDGE_LOG__;
            const rec = (s) => { if (L.length < 200) L.push(s); };
            const stub = (name) => new Proxy(function(){}, {
              get(t,p){
                if (p === 'then' || p === Symbol.toPrimitive || typeof p === 'symbol') return undefined;
                rec('get ' + name + '.' + String(p));
                if (p === 'get' || p === 'edit' || p === 'load' || p === 'recording' || p === 'closeWindow' || p === 'subscribe')
                  return function(...a){ rec('call ' + name + '.' + String(p) + '/' + a.length); return Promise.resolve({commands:{},revision:0}); };
                return stub(name + '.' + String(p));
              },
              apply(t,th,a){ rec('call ' + name + '()'); return Promise.resolve({commands:{},revision:0}); }
            });
            document.documentElement.dataset.platform='darwin';
            window.dshDesktop = stub('dshDesktop');
            window.dshDesktopBoot = stub('dshDesktopBoot');
            """
        case .darwinReal:
            // A hand-written bridge, as opposed to the Proxy above. The Proxy
            // answers every property with another Proxy, which is how it proved
            // the surface is only five entries wide; it cannot say whether a real
            // implementation boots, because it never returns a well-typed value
            // for any of them.
            //
            // Shapes taken from the shipped type declarations rather than guessed:
            //   shortcuts.get  -> ShortcutPersistence's snapshot
            //                       { revision: uuid, sequence, document, status, error, usingDefaults }
            //   keyboard       -> DesktopKeyboardApi { subscribe(listener), closeWindow(revision) }
            //   DesktopShortcutInput = { revision } & ({ kind:'menu', commandId }
            //                       | { kind:'keyboard', frameName, code, secondCode?, control,
            //                           alt, shift, meta, repeat })
            //
            // Note what the earlier hand-written attempt got wrong, because it is
            // the kind of mistake that costs an afternoon: it defined `dshDesktop`
            // and stopped. `dshDesktopBoot` is the one that actually throws —
            // dsh awaits its `ready()` before mounting anything, so a document
            // with no preload bridge never finishes booting at all.
            return """
            window.__PROBE_MODE__='darwinReal';
            window.__PROBE_BRIDGE_LOG__=[];
            document.documentElement.dataset.platform='darwin';
            (function () {
              const log = (m) => { (window.__PROBE_BRIDGE_LOG__ = window.__PROBE_BRIDGE_LOG__ || []).push(m); };

              // 1. The boot bridge. dsh awaits this before mounting, so an
              //    absent or rejecting `ready()` is a hard boot failure.
              //    `injections` is a list of rows (kind: global|script|script-src|
              //    style|html); none are needed when the host owns no assets.
              window.dshDesktopBoot = {
                ready: () => {
                  log('dshDesktopBoot.ready() -> injections:[] streamBaseUrl:' + location.origin);
                  return Promise.resolve({ injections: [], streamBaseUrl: location.origin });
                },
                failed: (err) => log('dshDesktopBoot.failed: ' + err)
              };

              let keyboardListener = null;
              let shortcutListener = null;

              window.dshDesktop = {
                protocolVersion: 1,

                // 2. Native keyboard. The host intercepts complete chords and
                //    forwards them; DOM input keeps driving dsh's fixed actions.
                keyboard: {
                  subscribe: (listener) => {
                    keyboardListener = listener;
                    log('keyboard.subscribe registered');
                    return () => { keyboardListener = null; };
                  },
                  closeWindow: (revision) => {
                    log('keyboard.closeWindow rev=' + revision);
                    return Promise.resolve();
                  }
                },

                // 3./4. Shortcut preferences, persisted by the host rather than
                //    in origin-local storage — "Desktop never falls back to
                //    browser storage".
                shortcuts: {
                  get: (definitions) => {
                    log('shortcuts.get definitions=' + (definitions ? definitions.length : 'null'));
                    if (definitions && definitions.length) {
                      /* The catalog shape is the whole basis of the host's keyboard
                       filter — `defaults` per profile and `fixed` are what
                       effectiveShortcuts consumes — so print it rather than only
                       its length. See docs/dsh-desktop-contract.md §4.5. */
                    log('shortcuts.get SAMPLE=' + JSON.stringify(definitions.slice(0, 4)));
                    }
                    return Promise.resolve({
                      revision: '00000000-0000-4000-8000-000000000000',
                      sequence: 0,
                      document: { schemaVersion: 1, profiles: {} },
                      status: 'ready',
                      error: null,
                      usingDefaults: true
                    });
                  },
                  edit: (edit, revision) => {
                    log('shortcuts.edit type=' + (edit && edit.type) + ' rev=' + revision);
                    return Promise.resolve({ status: 'saved', snapshot: null });
                  },
                  subscribe: (listener) => {
                    shortcutListener = listener;
                    log('shortcuts.subscribe registered');
                    return () => { shortcutListener = null; };
                  },
                  recording: () => Promise.resolve({}),
                  dispose: () => {}
                },

                deviceInfo: { platform: 'macos', runtime: 'desktop' }
              };

              // Lets the probe exercise the input path without a native bridge:
              // shapes one DesktopShortcutInput exactly as the type declares it
              // and pushes it through the registered listener.
              window.__probeDispatchShortcut__ = (code, mods) => {
                if (!keyboardListener) { log('shortcut dispatch with no listener'); return false; }
                const m = mods || {};
                keyboardListener({
                  revision: '00000000-0000-4000-8000-000000000000',
                  kind: 'keyboard',
                  frameName: '__dsh_shell_top__',
                  code: code,
                  control: !!m.control,
                  alt: !!m.alt,
                  shift: !!m.shift,
                  meta: !!m.meta,
                  repeat: false
                });
                log('shortcut dispatched code=' + code);
                return true;
              };
            })();
            """
        }
    }
}

// MARK: - Measurement

/// Runs in the page. Everything is read geometrically or through custom
/// properties — never through a class name, because dsh's are CSS-Modules
/// hashes that change every build (`pI_x6G_centerCol` in one release,
/// something else in the next).
let measureJS = """
(() => {
  const html = document.documentElement;
  const cs = getComputedStyle(html);
  const vars = {};
  for (const v of ['--dsh-frame-top-clearance','--dsh-frame-leading-clearance',
                    '--dsh-frame-overlay-top','--dsh-frame-chrome-top',
                    '--dsh-windows-titlebar-height','--dsh-windows-content-radius',
                    '--dsh-windows-sidebar-width']) {
    vars[v] = cs.getPropertyValue(v).trim();
  }

  const vw = innerWidth, vh = innerHeight;
  /* Zoom above 100% shrinks the CSS viewport, which can cross a responsive
     breakpoint. Everything below measures whether it actually did, because
     "the shell caps zoom at 100" is only a defensible rule if going past it
     breaks the page. */
  const out_zoom = { pageZoom: null, cssWidth: 0, layoutWidth: 0,
                     columnsCollapsed: 0, sidebarVisible: false,
                     matches: {}, horizontalOverflow: false };
  const out = { mode: window.__PROBE_MODE__ ?? null,
                vw, vh, readyState: document.readyState, vars,
                htmlAttrs: {}, dragRegionCount: 0,
                appRegion: { supports: false, computed: null, webkitSupported: false },
                columns: [], topStrip: [], leadingSeat: null, zoom: out_zoom };
  out_zoom.pageZoom = Math.round(visualViewport ? visualViewport.scale * 100 : 0) / 100;
  out_zoom.cssWidth = Math.round(document.documentElement.clientWidth);
  out_zoom.layoutWidth = document.documentElement.scrollWidth;
  out_zoom.horizontalOverflow = out_zoom.layoutWidth > out_zoom.cssWidth + 1;
  for (const q of ['(max-width: 900px)', '(max-width: 700px)', '(max-width: 480px)']) {
    out_zoom.matches[q] = matchMedia(q).matches;
  }
  const sidebar = document.querySelector('[data-pane="sidebar"]');
  if (sidebar) {
    const r = sidebar.getBoundingClientRect();
    out_zoom.sidebarVisible = r.width > 1 && r.height > 1;
    out_zoom.columnsCollapsed = sidebar.closest('[style*="--dsh-frame-leading-clearance"]') ? 1 : 0;
  }

  for (const a of html.attributes) out.htmlAttrs[a.name] = a.value;

  // Is dsh still on its boot screen? `[data-dsh-boot]` is a stable, unhashed
  // attribute the boot card sets on itself.
  const boot = document.querySelector('[data-dsh-boot]');
  out.bootScreenPresent = !!boot;
  if (boot) out.bootCardText = (boot.innerText||'').replace(/\\s+/g,' ').slice(0, 400);
  else out.bootCardText = null;
  out.pageErrors = (window.__PROBE_ERRORS__ || []).slice(0, 20);

  // How far the injected bridge actually got. Without this, a desktop-runtime
  // failure is indistinguishable from a bad attribute: the page shows a boot card
  // that never advances, and the only record is "24 entries did not activate",
  // which does not say whether the script ran at all.
  out.desktopSurface = {
    platform: document.documentElement.getAttribute('data-platform'),
    boot: typeof window.dshDesktopBoot,
    bootReady: !!(window.dshDesktopBoot && window.dshDesktopBoot.ready),
    desktop: typeof window.dshDesktop,
    desktopKeys: window.dshDesktop ? Object.keys(window.dshDesktop) : [],
    keyboardKeys: window.dshDesktop && window.dshDesktop.keyboard
      ? Object.keys(window.dshDesktop.keyboard) : [],
    shortcutsKeys: window.dshDesktop && window.dshDesktop.shortcuts
      ? Object.keys(window.dshDesktop.shortcuts) : [],
    shell: typeof window.__dshShellDesktop,
    hasMessageHandler: !!(window.webkit && window.webkit.messageHandlers
      && window.webkit.messageHandlers.dshDesktop),
    probeMessages: (window.__dshProbeLog || []).slice(0, 12),
    transport: !!window.__DSH_TRANSPORT__,
    transportKeys: window.__DSH_TRANSPORT__ ? Object.keys(window.__DSH_TRANSPORT__) : [],
    bootReadySettled: !!(window.__DSH_BOOT_READY__ && window.__DSH_BOOT_READY__.settled)
  };

  // THE decisive measurement: did dsh reserve the strip for itself? The frame
  // is the box whose computed padding-top equals the published clearance.
  const target = parseFloat(vars['--dsh-frame-top-clearance']);
  if (target > 0) {
    let hit = null;
    for (const el of html.querySelectorAll('*')) {
      const r = el.getBoundingClientRect();
      if (r.height < vh * 0.9 || r.width < vw * 0.9) continue;
      const pt = parseFloat(getComputedStyle(el).paddingTop);
      if (Math.abs(pt - target) < 0.5) {
        hit = { paddingTop: getComputedStyle(el).paddingTop,
                left: Math.round(r.left), top: Math.round(r.top),
                width: Math.round(r.width), height: Math.round(r.height) };
        break;
      }
    }
    out.frameReservingTop = hit;
    // how much of the window the first row of real content starts below
    const rows = [];
    for (const y of [4, 16, 32, 40, 48, 64]) {
      const e = document.elementFromPoint(Math.round(vw*0.6), y);
      if (!e) { rows.push({y, tag:null}); continue; }
      const r = e.getBoundingClientRect();
      rows.push({ y, tag: e.tagName.toLowerCase(), w: Math.round(r.width),
                  h: Math.round(r.height), text: (e.innerText||'').slice(0,24) });
    }
    out.contentBelowStrip = rows;
  } else {
    out.frameReservingTop = null;
    out.contentBelowStrip = null;
  }

  // The drag contract. `-webkit-app-region` is a Blink property; whether
  // WKWebView honours it decides if dsh's `data-window-drag` rows self-drag.
  out.appRegion.supports = !!(window.CSS && CSS.supports && CSS.supports('-webkit-app-region','drag'));
  const drags = document.querySelectorAll('[data-window-drag]');
  out.dragRegionCount = drags.length;
  if (drags.length) {
    out.appRegion.computed = getComputedStyle(drags[0]).webkitAppRegion
                           || getComputedStyle(drags[0]).getPropertyValue('-webkit-app-region')
                           || null;
    out.dragRegionSample = (() => {
      const r = drags[0].getBoundingClientRect();
      return {x:Math.round(r.x), y:Math.round(r.y), w:Math.round(r.width), h:Math.round(r.height),
              text: (drags[0].innerText||'').slice(0,40)};
    })();
  }

  // Column map, geometric only. 'Tall enough to be a column' is the same test
  // the Windows chrome uses; here it is only for reporting.
  const seen = [];
  for (const el of html.querySelectorAll('*')) {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height < vh * 0.4) continue;
    if (r.left < -1 || r.right > vw + 1) continue;
    const s = getComputedStyle(el);
    seen.push({ el, r, s });
  }
  // Widest left-anchored column is the shell; its right-hand siblings are content/dock.
  const left = seen.filter(c => c.r.left <= 2 && c.r.width < vw * 0.9)
                    .sort((a,b) => b.r.width - a.r.width)[0];
  const divider = left ? left.r.right : 0;
  const right = seen.filter(c => c !== left && !left?.el.contains(c.el)
                                 && c.r.left >= divider - 4)
                     .sort((a,b) => a.r.left - b.r.left);
  const picks = (left ? [left] : []).concat(right.slice(0, 3));
  out.columns = picks.map(c => ({
    left: Math.round(c.r.left), right: Math.round(c.r.right), width: Math.round(c.r.width),
    paddingTop: c.s.paddingTop, paddingRight: c.s.paddingRight,
    borderTopLeftRadius: c.s.borderTopLeftRadius,
    position: c.s.position,
    // a hashed class tells us nothing, but the *count* distinguishes the
    // frame from a leaf, and the custom props it reads are worth knowing
    cls: (c.el.className && typeof c.el.className === 'string')
           ? c.el.className.split(/\\s+/).filter(Boolean).length : 0,
    readsTopClearance: c.s.getPropertyValue('padding-top')
                        === 'var(--dsh-frame-top-clearance)' ? 'var'
                      : (c.s.paddingTop === vars['--dsh-frame-top-clearance'] ? 'match' : null)
  }));

  // What actually occupies the top 6px across the width? This is the strip a
  // desktop chrome would have to share with the traffic lights.
  for (const x of [5, 30, 60, 90, 120, 200, Math.round(vw/2), vw - 120, vw - 10]) {
    const e = document.elementFromPoint(x, 6);
    const r = e ? e.getBoundingClientRect() : null;
    out.topStrip.push({ x, tag: e ? e.tagName.toLowerCase() : null,
                        w: r ? Math.round(r.width) : 0,
                        h: r ? Math.round(r.height) : 0,
                        text: e ? (e.innerText||'').slice(0,24) : null });
  }

  // The `shell.leading` window-chrome seat: CSS puts it at top:11px left:88px.
  for (const e of html.querySelectorAll('*')) {
    const s = getComputedStyle(e);
    if (s.position !== 'absolute') continue;
    if (s.top !== '11px') continue;
    const r = e.getBoundingClientRect();
    if (r.width === 0) continue;
    out.leadingSeat = { left: Math.round(r.left), top: Math.round(r.top),
                        w: Math.round(r.width), h: Math.round(r.height),
                        text: (e.innerText||'').slice(0,40) };
    break;
  }
  return JSON.stringify(out);
})()
"""

/// Re-reads the frame-level variables after a state change (fullscreen).
let reMeasureJS = """
(() => {
  const cs = getComputedStyle(document.documentElement);
  return JSON.stringify({
    top: cs.getPropertyValue('--dsh-frame-top-clearance').trim(),
    leading: cs.getPropertyValue('--dsh-frame-leading-clearance').trim(),
    overlay: cs.getPropertyValue('--dsh-frame-overlay-top').trim(),
    chromeTop: cs.getPropertyValue('--dsh-frame-chrome-top').trim(),
    paddingTop: getComputedStyle(document.querySelector('#root > *') || document.body).paddingTop
  });
})()
"""

// MARK: - Web view driver

final class Probe {
    var webView: WKWebView!
    var window: NSWindow!
    var zoomPercent: Double = 100
    let mode: Mode
    var result: [String: Any] = [:]
    var done = false
    var failed: String?
    var bootWaitAttempts = 0
    var bootWaitTimedOut = false
    /// console.error / window.onerror from the page. A boot failure is
    /// otherwise invisible: the card just says "Failed to load plugins".
    var pageErrors: [String] = []

    init(mode: Mode) {
        self.mode = mode
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        let us = WKUserScript(source: mode.script,
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: true)
        // The error trap has to be installed BEFORE the script under test, not
        // after. A throw inside that script happens before any later script runs,
        // so a trap installed second captures only what dsh reports afterwards
        // and misses the actual cause — which is precisely the failure this mode
        // exists to find. Getting this order wrong cost one confusing run.
        ucc.addUserScript(WKUserScript(source: Self.errorTrap, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        ucc.addUserScript(us)
        cfg.userContentController = ucc
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                            configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "dsh-probe — \(mode.rawValue)"
        window.contentView = webView
        window.orderFront(nil)
    }

    static let errorTrap = """
    (() => {
      window.__PROBE_ERRORS__ = [];
      const push = (s) => { if (window.__PROBE_ERRORS__.length < 40) window.__PROBE_ERRORS__.push(s); };
      const ce = console.error.bind(console);
      console.error = function (...a) { push('console.error: ' + a.map(x => {
        try { return typeof x === 'string' ? x : (x && x.stack) || JSON.stringify(x); }
        catch { return String(x); } }).join(' ')); ce(...a); };
      window.addEventListener('error', (e) => push('window.error: ' + (e.message || e.type)));
      window.addEventListener('unhandledrejection', (e) => push('unhandledrejection: ' +
        ((e.reason && (e.reason.stack || e.reason.message)) || e.reason)));
    })();
    """

    func drainPageErrors() -> [String] {
        var out: [String] = []
        webView.evaluateJavaScript("JSON.stringify(window.__PROBE_ERRORS__ || [])") { res, _ in
            if let s = res as? String, let d = s.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [String] {
                out = arr
            }
        }
        let inner = Date().addingTimeInterval(1.5)
        while Date() < inner {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return out
    }

    /// What dsh actually asked the preload for.
    func drainBridgeLog() -> [String] {
        var out: [String] = []
        webView.evaluateJavaScript("JSON.stringify(window.__PROBE_BRIDGE_LOG__ || [])") { res, _ in
            if let s = res as? String, let d = s.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [String] {
                out = arr
            }
        }
        let inner = Date().addingTimeInterval(1.5)
        while Date() < inner {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return out
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Set the page zoom the way the shell does, without letting WebKit's own
    /// menu clamp it. `--zoom <percent>` on the command line.
    func setZoom(_ percent: Double) {
        zoomPercent = percent
        webView.pageZoom = CGFloat(percent) / 100.0
    }

    /// Poll until dsh's boot card is gone, then measure. The boot card sets a
    /// stable unhashed `data-dsh-boot` attribute on itself.
    func measure(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))

        while Date() < deadline && !done {
            attempts += 1
            var settled = false
            webView.evaluateJavaScript(
                "!!document.querySelector('[data-dsh-boot]')"
            ) { res, _ in
                settled = (res as? Bool) == false
            }
            // let the evaluateJavaScript callback land
            let inner = Date().addingTimeInterval(0.6)
            while Date() < inner && !settled {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if settled { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))
        }
        bootWaitAttempts = attempts
        bootWaitTimedOut = Date() >= deadline

        webView.evaluateJavaScript(measureJS) { [weak self] res, err in
            guard let self else { return }
            if let err { self.failed = "measureJS: \(err)"; self.done = true; return }
            guard let s = res as? String,
                  let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { self.failed = "measureJS: unparsable result"; self.done = true; return }
            self.result = obj
            self.done = true
        }
        let inner = Date().addingTimeInterval(5)
        while Date() < inner && !done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func screenshot(to path: String) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        webView.takeSnapshot(with: cfg) { image, err in
            guard let image else {
                logLine("snapshot failed for \(self.mode.rawValue): \(String(describing: err))")
                return
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
        let inner = Date().addingTimeInterval(3)
        while Date() < inner {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Do NOT tear the web view down between modes. WKWebView has a long history
    /// of crashes when deallocated while a load is still in flight, and the
    /// probes are kept alive by `liveProbes` until the process exits instead.
    func finish() {
        webView.stopLoading()
        window.orderOut(nil)
    }
}

// MARK: - Main

func waitForPortRelease(_ port: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if portIsFree(port) { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock tile, no focus steal

logLine("DSH_HOME=\(dshHome)  port=\(port)")

let dsh = Dsh(port: port, dshBin: dshBin, dshHome: dshHome, trustedHost: trustedHost)
do {
    try dsh.process.run()
} catch {
    logLine("failed to spawn \(dshBin): \(error)")
    exit(2)
}
probeSpawnedPID = dsh.pid
atexit(reapSpawnedDsh)
logLine("spawned dsh pid \(dsh.pid)")

guard let url = dsh.waitForURL(timeout: 120) else {
    logLine("no usable URL. stderr tail:")
    dsh.stderrTail.forEach { logLine("  [stderr] \($0)") }
    dsh.shutdown()
    exit(3)
}
logLine("resolved: \(url.absoluteString)")
logLine("  via: \(dsh.resolvedReason)")

var report: [String: Any] = [
    "dshVersion": "0.2.0-rc.2",
    "dshPid": Int(dsh.pid),
    "port": port,
    "url": url.absoluteString,
    "urlAcceptedBecause": dsh.resolvedReason,
    "modes": [:] as [String: Any],
]
/// Held so no WKWebView is deallocated mid-run.
var liveProbes: [Probe] = []
var m2Dispatch = ""
var m2DispatchExtra = ""

let modesToRun: [Mode] = onlyMode.isEmpty
    ? Mode.allCases
    : (Mode.allCases.filter { $0.rawValue == onlyMode })
if modesToRun.isEmpty {
    logLine("no mode matches --only \(onlyMode); known: "
        + Mode.allCases.map(\.rawValue).joined(separator: ", "))
    exit(6)
}
logLine("modes: " + modesToRun.map(\.rawValue).joined(separator: ", "))

for mode in modesToRun {
    logLine("--- mode \(mode.rawValue) ---")
    let probe = Probe(mode: mode)
    liveProbes.append(probe)   // kept alive on purpose; see finish()
    probe.setZoom(zoomPercent)
    logLine("zoom: \(Int(zoomPercent))%")
    probe.load(url)
    // let navigation commit before measuring
    let settle = Date().addingTimeInterval(3)
    while Date() < settle {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // A cold profile loads its plugin graph on the first boot. Give every mode
    // the same budget so the comparison is not measuring warm-up.
    probe.measure(timeout: 90)

if mode == .darwinReal {
        // Declaring the bridge is not the same as implementing it: an
        // unsubscribed listener that throws when fed a real input would be a
        // bridge that looks fine until a user presses a shortcut. Push one
        // DesktopShortcutInput through the listener dsh actually registered.
        var dispatched = "not-run"
        probe.webView.evaluateJavaScript(
            "JSON.stringify({ ok: !!window.__probeDispatchShortcut__('KeyN', { meta: true }),"
                + " listener: !!(window.__PROBE_BRIDGE_LOG__||[]).length })"
        ) { res, err in
            if let s = res as? String { dispatched = s } else { dispatched = "error: \(String(describing: err))" }
        }
        let wait = Date().addingTimeInterval(3)
        while Date() < wait {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        logLine("darwinReal shortcut dispatch: \(dispatched)")
        m2Dispatch = dispatched
    }

    if let f = probe.failed { logLine("mode \(mode.rawValue) FAILED: \(f)") }

    // fullscreen is itself a contract: clearances must converge
    probe.webView.evaluateJavaScript(
        "document.documentElement.setAttribute('data-fullscreen',''); 'ok'"
    ) { _, _ in }
    let fs = Date().addingTimeInterval(1.2)
    while Date() < fs {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    var fullscreen: [String: Any] = [:]
    probe.webView.evaluateJavaScript(reMeasureJS) { res, _ in
        if let s = res as? String, let d = s.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            fullscreen = o
        }
    }
    let inner = Date().addingTimeInterval(3)
    while Date() < inner {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    probe.screenshot(to: "\(outDir)/\(mode.rawValue).png")
    probe.finish()

    if mode == .darwinReal { m2DispatchExtra = m2Dispatch }
    var m = probe.result
    m["fullscreen"] = fullscreen
    m["bootWaitAttempts"] = probe.bootWaitAttempts
    m["bootWaitTimedOut"] = probe.bootWaitTimedOut
    m["pageErrors"] = probe.drainPageErrors()
    m["bridgeLog"] = probe.drainBridgeLog()
    if mode == .darwinReal { m["shortcutDispatch"] = m2DispatchExtra }
    if let f = probe.failed { m["probeFailure"] = f }
    if var modes = report["modes"] as? [String: Any] {
        modes[mode.rawValue] = m
        report["modes"] = modes
    }
    logLine("mode \(mode.rawValue) collected \(m.count) fields")
}

// MARK: - Shutdown + the invariant

logLine("shutting down dsh pid \(dsh.pid)")
dsh.shutdown()
probeSpawnedPID = -1   // reaped through the actor; atexit must not signal it twice
let freed = waitForPortRelease(port, timeout: 30)
report["portFreedAfterShutdown"] = freed
report["pidStillAliveAfterShutdown"] = kill(dsh.pid, 0) == 0

let out = "\(outDir)/report.json"
if let d = try? JSONSerialization.data(withJSONObject: report,
                                       options: [.prettyPrinted, .sortedKeys]) {
    try? d.write(to: URL(fileURLWithPath: out))
    logLine("wrote \(out)")
}
logLine("port \(port) free after shutdown: \(freed ? "YES" : "NO")")
logLine("artifacts in \(outDir)")
exit(freed ? 0 : 4)