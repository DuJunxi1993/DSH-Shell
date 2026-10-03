import Foundation

/// Parses the `dsh web:` URL line emitted by `dsh-web-app`'s `web-runtime` plugin on stdout.
///
/// The exact format is `dsh web: <url>` followed by a newline. The URL is the local
/// HTTP endpoint the SPA is served from. We consider the first such line we see
/// authoritative; subsequent lines (e.g. on a re-bind) are ignored.
public struct EndpointResolver: Sendable {
    public init() {}

    /// Try to extract a URL from one line of stdout.
    public func resolveURL(in line: String) -> URL? {
        // Be tolerant of trailing whitespace, ANSI codes, and the absence/presence of a colon.
        let pattern = #"dsh web:\s+(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 2,
              let urlRange = Range(match.range(at: 1), in: line)
        else { return nil }
        let raw = String(line[urlRange])
        // Strip ANSI escape sequences if any slipped through.
        let cleaned = raw.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
        return URL(string: cleaned)
    }
}
