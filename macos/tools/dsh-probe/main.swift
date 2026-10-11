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

// MARK: - Injection

enum Mode: String, CaseIterable {
    case baseline, darwin, windows, darwinProxy

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
  const out = { mode: window.__PROBE_MODE__ ?? null,
                vw, vh, readyState: document.readyState, vars,
                htmlAttrs: {}, dragRegionCount: 0,
                appRegion: { supports: false, computed: null, webkitSupported: false },
                columns: [], topStrip: [], leadingSeat: null };

  for (const a of html.attributes) out.htmlAttrs[a.name] = a.value;

  // Is dsh still on its boot screen? `[data-dsh-boot]` is a stable, unhashed
  // attribute the boot card sets on itself.
  const boot = document.querySelector('[data-dsh-boot]');
  out.bootScreenPresent = !!boot;
  if (boot) out.bootCardText = (boot.innerText||'').replace(/\\s+/g,' ').slice(0, 400);
  else out.bootCardText = null;
  out.pageErrors = (window.__PROBE_ERRORS__ || []).slice(0, 20);

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
        ucc.addUserScript(us)
        // Capture page errors at documentStart, before dsh's own scripts run.
        ucc.addUserScript(WKUserScript(source: Self.errorTrap, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
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

for mode in Mode.allCases {
    logLine("--- mode \(mode.rawValue) ---")
    let probe = Probe(mode: mode)
    liveProbes.append(probe)   // kept alive on purpose; see finish()
    probe.load(url)
    // let navigation commit before measuring
    let settle = Date().addingTimeInterval(3)
    while Date() < settle {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // A cold profile loads its plugin graph on the first boot. Give every mode
    // the same budget so the comparison is not measuring warm-up.
    probe.measure(timeout: 90)

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

    var m = probe.result
    m["fullscreen"] = fullscreen
    m["bootWaitAttempts"] = probe.bootWaitAttempts
    m["bootWaitTimedOut"] = probe.bootWaitTimedOut
    m["pageErrors"] = probe.drainPageErrors()
    m["bridgeLog"] = probe.drainBridgeLog()
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