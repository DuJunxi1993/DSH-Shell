import Foundation

/// Splits a byte stream into lines across arbitrary read boundaries.
///
/// `FileHandle.readabilityHandler` may hand over a chunk that starts halfway
/// through a line and ends halfway through the next one, so the tail has to
/// survive between calls. That tail is mutable state shared across Foundation's
/// dispatch of the handler — which is not the same thread every time — hence the
/// lock rather than a plain `var`.
///
/// `@unchecked Sendable` because the lock is what makes it so; the invariant is
/// that `buffer` is only ever touched inside `lock`.
final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Appends `chunk` and returns every line it completed, in order.
    func takeCompletedLines(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(data: buffer[0..<newline], encoding: .utf8) ?? ""
            buffer.removeSubrange(0...newline)
            lines.append(line)
        }
        return lines
    }

    /// The unterminated tail, if any. Called once, at EOF.
    func takeRemainder() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(data: buffer, encoding: .utf8)
    }
}