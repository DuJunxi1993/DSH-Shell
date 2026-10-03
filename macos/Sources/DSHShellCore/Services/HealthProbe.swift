import Foundation

/// Probes a localhost HTTP endpoint and decides whether it is serving the dsh SPA.
///
/// Used by `AttachProbe` to scan ports when the user has `launchMode == .attach` or
/// when `spawn` failed to deliver a URL line.
public struct HealthProbe: Sendable {
    public init() {}

    /// One probe attempt.
    public struct Result: Equatable, Sendable {
        public let url: URL
        public let reachable: Bool
        public let servedIndex: Bool
        public let latency: TimeInterval

        public var isAdoptable: Bool { reachable && servedIndex }
    }

    public func probe(url: URL, timeout: TimeInterval = 1.0) async -> Result {
        let start = Date()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else {
                return Result(url: url, reachable: false, servedIndex: false, latency: latency)
            }
            let reachable = (200..<400).contains(http.statusCode)
            let ct = http.value(forHTTPHeaderField: "content-type") ?? ""
            let servedIndex = reachable && ct.contains("text/html") && Self.containsDshSignature(data)
            return Result(url: url, reachable: reachable, servedIndex: servedIndex, latency: latency)
        } catch {
            return Result(url: url, reachable: false, servedIndex: false, latency: Date().timeIntervalSince(start))
        }
    }

    /// Cheap heuristic: the dsh SPA's `index.html` always includes a script that
    /// imports `window.__DSH_BOOT__` (per `apps/web` Vite entry). We accept any
    /// HTML whose body mentions `DSH` or `dsh` as a fallback signal.
    static func containsDshSignature(_ data: Data) -> Bool {
        let prefix = data.prefix(4096)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.range(of: #"__DSH_BOOT__"#, options: .regularExpression) != nil
            || text.localizedCaseInsensitiveContains("DeepSeek Harness")
    }
}

/// Scans a set of ports on `127.0.0.1` for an existing dsh SPA. Used as the
/// fallback when `dsh web` did not emit a URL line or when the user picked
/// `launchMode == .attach`.
public struct AttachProbe: Sendable {
    public let portsToScan: [Int]
    public let concurrency: Int

    public init(portsToScan: [Int] = (49152..<65536).map { $0 } + Array(54321...54325), concurrency: Int = 32) {
        self.portsToScan = portsToScan
        self.concurrency = concurrency
    }

    public func findExisting(probe: HealthProbe = HealthProbe()) async -> URL? {
        await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
            var iterator = portsToScan.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                inFlight += 1
                let url = URL(string: "http://127.0.0.1:\(next)/")!
                group.addTask {
                    let result = await probe.probe(url: url, timeout: 0.5)
                    return result.isAdoptable ? url : nil
                }
            }

            for _ in 0..<concurrency { enqueueNext() }

            while inFlight > 0 {
                guard let candidate = await group.next() else { break }
                inFlight -= 1
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
                enqueueNext()
            }
            return nil
        }
    }
}
