// stub-dsh — a test double for `dsh web`. Never bundled, never launched
// outside the test suite.
//
// It exists so the tests can never boot a real harness: no API keys, no
// sessions, no LLM calls, safe to run at any time. See the equivalent
// `windows/src-tauri/src/bin/stub-dsh.rs`; the behaviours below are the shared
// contract, specified in `docs/dsh-shell-contract.md` §3.
//
// It reproduces five things the shell has to survive, and deliberately nothing
// more:
//
//   1. the `dsh web: http://host:port/?token=…` line, on **stdout**;
//   2. the 401 auth fence — any request without the token is refused, which is
//      what `dsh-client-connection`'s `authorizeIndex` does;
//   3. the `bili: … http://127.0.0.1:18787` decoy, on **stderr**;
//   4. a slow Loader, where the socket binds seconds before the URL is printed;
//   5. an early exit, before the URL is ever announced.
//
// Modes: `ok` (default), `no-url-line`, `tokenless`, `die-early`,
// `crash-after-ready`. The last one announces a working endpoint and then dies,
// which is the shape the crash-restart ladder exists for.

import Foundation

// MARK: - Arguments

/// Knobs come from argv for manual runs, and from the environment when the
/// shell is driving us: `DSHProcessManager.buildArgv` owns the argv, so a test
/// cannot pass `--mode` through it.
func knob(_ name: String, _ envKey: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        return args[i + 1]
    }
    if let value = ProcessInfo.processInfo.environment[envKey], !value.isEmpty {
        return value
    }
    return fallback
}

let mode = knob("--mode", "STUB_DSH_MODE", "ok")
let port = Int(knob("--port", "STUB_DSH_PORT", "0")) ?? 0
let host = knob("--host", "STUB_DSH_HOST", "127.0.0.1")
/// How long the URL line is delayed, to reproduce a slow plugin Loader.
let urlDelayMS = Int(knob("--url-delay-ms", "STUB_DSH_URL_DELAY_MS", "0")) ?? 0
let token = knob("--token", "STUB_DSH_TOKEN", "stub-token")
/// A ceiling on our own lifetime, so a leaked test child cannot outlive the run.
let lifetimeMS = Int(knob("--lifetime-ms", "STUB_DSH_LIFETIME_MS", "120000")) ?? 120000
/// Bytes of chatter printed before the URL line, to reproduce a dsh whose plugin
/// loader is loud. Real dsh prints hundreds of lines while plugins activate.
let chatterBytes = Int(knob("--chatter-bytes", "STUB_DSH_CHATTER_BYTES", "0")) ?? 0
/// How long `crash-after-ready` keeps serving before it dies, so the shell has
/// time to parse the URL line and reach `.ready` first.
let crashDelayMS = Int(knob("--crash-delay-ms", "STUB_DSH_CRASH_DELAY_MS", "500")) ?? 500

// MARK: - Output

func out(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}
func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// The decoy goes out first, unconditionally, exactly as dsh does. A resolver
// that scans stderr for any loopback URL points the webview at dsh's internal
// HTTP proxy and shows a white window — which is precisely the bug this line
// exists to keep reproducible.
err("bili: attaching to running proxy at http://127.0.0.1:18787 (pid \(getpid()))")

switch mode {
case "die-early":
    err("boom: refusing to start because the profile could not be composed")
    exit(3)
default:
    break
}

// MARK: - Listen

let fd = socket(AF_INET, SOCK_STREAM, 0)
guard fd >= 0 else {
    err("stub: cannot create socket")
    exit(4)
}
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
addr.sin_addr.s_addr = INADDR_ANY.bigEndian
let bound = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
if bound != 0 {
    err("stub: could not bind port \(port)")
    exit(5)
}
guard listen(fd, 16) == 0 else {
    err("stub: could not listen on port \(port)")
    exit(6)
}
// Report the port we actually got, so a caller that asked for 0 can find us.
var actual = sockaddr_in()
var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &actual) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &actualLen)
    }
}
let boundPort = Int(UInt16(bigEndian: actual.sin_port))

// MARK: - Answer

/// Mirror `authorizeIndex`: only a request carrying the valid token query, or
/// a `dsh-auth-` cookie, gets the index.
///
/// Note `accept()`, not `recv()`: on a listening socket BSD has no
/// `recv`/`send` — the kernel refuses them. `accept` is what actually takes a
/// connection off the queue.
func serve() -> Bool {
    let client = accept(fd, nil, nil)
    guard client >= 0 else { return false }

    var buf = [UInt8](repeating: 0, count: 8192)
    let n = recv(client, &buf, buf.count, 0)
    guard n > 0 else {
        close(client)
        return true
    }
    let request = String(decoding: buf[0..<n], as: UTF8.self)

    let hasToken = request.contains("token=\(token)")
    let hasCookie = request.contains("dsh-auth-")

    // `303` is the success case for a tokenized request: it trades the query
    // for a cookie and redirects to `./`. Anything else and a test that keeps
    // `?token=` in the URL will loop on 303s and think the stub is broken.
    let response: String
    if hasToken {
        response = "HTTP/1.1 303 See Other\r\nLocation: ./\r\n"
            + "Set-Cookie: dsh-auth-stub=1; Path=/\r\nContent-Length: 0\r\n\r\n"
    } else if hasCookie {
        let body = "<!doctype html><title>dsh stub</title>"
            + "<script>window.__DSH_BOOT__={}</script>"
        response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    } else {
        // The fence. A tokenless URL can never load the SPA, which is why the
        // shell's port probe is a log line and not a fallback.
        response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
    }

    _ = response.withCString { cstr in
        send(client, cstr, strlen(cstr), 0)
    }
    close(client)
    return true
}

// MARK: - Announce

if chatterBytes > 0 {
    // One long run of realistic plugin-loader chatter, then the URL line —
// i.e. exactly the shape that makes a byte-at-a-time reader fall behind.
    let line = "plugin-loader: activating entry \(String(repeating: "x", count: 60))"
    var written = 0
    while written < chatterBytes {
        out(line)
        written += line.utf8.count + 1
    }
    fflush(stdout)
}

if urlDelayMS > 0 { Thread.sleep(forTimeInterval: Double(urlDelayMS) / 1000.0) }

switch mode {
case "no-url-line":
    // Never announce. The caller must time out with a useful message rather
    // than adopt the port.
    err("web-app: this build was started with printUrl disabled")
case "tokenless":
    out("dsh web: http://\(host):\(boundPort)/")
default:
    let lan = port == 0 ? "" : " (LAN: http://192.168.1.9:\(boundPort)/?token=\(token))"
    out("dsh web: http://\(host):\(boundPort)/?token=\(token)\(lan)")
}
fflush(stdout)

// A working endpoint that then dies. The delay matters: the shell has to parse
// the URL line and reach `.ready` before the exit, or this degenerates into
// `die-early` and stops testing the crash ladder.
if mode == "crash-after-ready" {
    Thread.sleep(forTimeInterval: Double(crashDelayMS) / 1000.0)
    err("boom: crashing after announcing the endpoint")
    exit(1)
}

// MARK: - Serve until told to stop

// There is no stdin handshake on purpose: the shell spawns us with a null
// stdin, which is immediately at EOF, so reading it would end the loop at once.
let deadline = Date().addingTimeInterval(Double(lifetimeMS) / 1000.0)
while Date() < deadline {
    // `pollfd` is also the name of the struct, so the function needs the
    // module prefix.
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = Darwin.poll(&descriptor, 1, 200)
    if ready > 0, (descriptor.revents & Int16(POLLIN)) != 0 {
        if !serve() { break }
    }
}
close(fd)
exit(0)