import Foundation

/// Probes a localhost HTTP endpoint and reports what answered.
///
/// Used for two things only, neither of which is producing a URL:
///
///   - **Port liveness logging** during `spawn`. The socket binds seconds
///     before dsh's plugin Loader settles and prints its authenticated URL, so
///     "the port is listening, still waiting for the token line" is the
///     difference between "dsh is slow" and "dsh is broken" in the log.
///   - **`attach`**, to tell a user that nothing is listening where the
///     settings say it should be.
///
/// It is deliberately *not* used to adopt an endpoint. `isAdoptable` therefore
/// requires a `401`, which is dsh's answer to a request carrying neither a
/// token query nor a `dsh-auth-` cookie — proof that a token-fenced dsh is
/// there, without pretending we have a way in.
public struct HealthProbe: Sendable {
    public init() {}

    /// One probe attempt.
    public struct Result: Equatable, Sendable {
        public let url: URL
        /// Anything answered at all: status 2xx–3xx **or** 401.
        public let reachable: Bool
        /// A 401, i.e. dsh's auth fence is up. This is the token-fenced dsh
        /// signature, and the only positive signal a tokenless probe can get.
        public let authFenced: Bool
        public let statusCode: Int
        public let latency: TimeInterval
    }

    public func probe(url: URL, timeout: TimeInterval = 1.0) async -> Result {
        let start = Date()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else {
                return Result(url: url, reachable: false, authFenced: false,
                              statusCode: 0, latency: latency)
            }
            let code = http.statusCode
            // A 401 counts as reachable: it is the dsh index refusing us, which
            // is more informative than a refused connection.
            let reachable = (200..<400).contains(code) || code == 401
            return Result(url: url, reachable: reachable, authFenced: code == 401,
                          statusCode: code, latency: latency)
        } catch {
            return Result(url: url, reachable: false, authFenced: false,
                          statusCode: 0, latency: Date().timeIntervalSince(start))
        }
    }
}

/// Asks one specific loopback port whether a dsh is there.
///
/// The previous implementation swept all 16384 macOS ephemeral ports with
/// 32-way concurrency, ignored `preferredPort` entirely, identified a hit by
/// scraping the SPA's HTML for a marker, and returned a tokenless URL. Three
/// separate problems: the sweep ignores the only port the user configured, 16k
/// outbound loopback connections is visible to anything watching `lsof` and
/// trips local network tooling, and a tokenless URL answers `401` anyway.
public struct AttachProbe: Sendable {
    public let host: String
    public let port: Int
    public let timeout: TimeInterval

    public init(host: String = "127.0.0.1", port: Int, timeout: TimeInterval = 1.0) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    /// The origin we would hand to the webview.
    ///
    /// Read the caveat on `DSHProcessManager.startAttach`: this URL carries no
    /// token, so against a token-fenced dsh it renders a 401. Adopt mode is
    /// therefore only useful when something else has already satisfied the
    /// fence. Surfacing the 401 is more useful than hiding it.
    public var origin: URL? {
        URL(string: "http://\(host):\(port)/")
    }

    public func findExisting(probe: HealthProbe = HealthProbe()) async -> URL? {
        guard let origin else { return nil }
        let result = await probe.probe(url: origin, timeout: timeout)
        return result.reachable ? origin : nil
    }
}