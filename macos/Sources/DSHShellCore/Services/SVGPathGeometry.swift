import Foundation

/// The subset of SVG path geometry dsh's whale is drawn with, as numbers.
///
/// Parsing lives here rather than next to the `NSBezierPath` it feeds, for two
/// reasons: `DSHShellCore` does not link AppKit, and this is the half worth
/// testing. The grammar is fixed — the whale uses only `M`, `L`, `C` and `Z`
/// (4 moves, 71 cubics, 1 line, 4 closes) — so a full SVG path parser would be
/// several hundred lines of code covering curves and arcs the brand mark never
/// uses.
///
/// Everything stays in **SVG user units**, y growing **downwards**. Flipping
/// into CoreGraphics' y-up space is the renderer's job, and it happens in one
/// place: getting it subtly wrong would show the whale upside down rather than
/// failing.
public enum SVGPathGeometry {
    /// A command from the path's `d` attribute.
    public indirect enum Command: Equatable, Sendable {
        /// Move to the start of a new subpath.
        case move(x: Double, y: Double)
        /// Straight line to a point.
        case line(x: Double, y: Double)
        /// Cubic Bézier: two control points then an endpoint.
        case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
        /// Close the current subpath.
        case close
    }

    /// Parse `d` into commands.
    ///
    /// Returns `nil` rather than a partial result: a logo that is missing half
    /// its curves would look almost right, and an almost-right brand mark is
    /// harder to notice than a missing one.
    public static func parse(_ d: String) -> [Command]? {
        var commands: [Command] = []
        var index = d.startIndex

        // Each pass consumes one command letter plus its coordinate arguments.
        // SVG allows repeated argument sets after a single letter ("C x1 y1 …
        // x y x1 y1 … x y"); dsh does not use that form, so each letter is
        // treated as exactly one command and anything unexpected is a failure.
        // Separators between a number and the next command may be whitespace,
        // commas, or both, and the next command may arrive with any of them in
        // front — so the separators are consumed *before* the letter is read.
        // Reading the letter first rejects a perfectly ordinary path that
        // happens to wrap across lines, which is also how the whale's own data
        // is laid out in the declaration file.
        while true {
            let beforeSeparators = skipWhitespace(from: index, in: d)
            index = beforeSeparators
            guard index < d.endIndex else { break }

            let letter = d[index]
            guard "MLCZ".contains(letter) else { return nil }
            index = d.index(after: index)

            // A closure that wrote `index` would be capturing it mutably while
            // it is also being read here, which Swift forbids; threading the
            // position through returns is the tidier way to say "advance me".
            func takeNumbers(_ count: Int, from start: String.Index,
                             in s: String) -> ([Double], String.Index)? {
                var values: [Double] = []
                var cursor = start
                for _ in 0..<count {
                    let next = skipWhitespace(from: cursor, in: s)
                    guard let (value, after) = parseNumber(from: next, in: s) else { return nil }
                    values.append(value)
                    cursor = after
                }
                return (values, cursor)
            }

            switch letter {
            case "M", "L":
                guard let (n, after) = takeNumbers(2, from: index, in: d) else { return nil }
                index = after
                commands.append(letter == "M" ? .move(x: n[0], y: n[1]) : .line(x: n[0], y: n[1]))
            case "C":
                guard let (n, after) = takeNumbers(6, from: index, in: d) else { return nil }
                index = after
                commands.append(.curve(x1: n[0], y1: n[1], x2: n[2], y2: n[3], x: n[4], y: n[5]))
            case "Z":
                commands.append(.close)
            default:
                return nil
            }
        }

        // A path with no move cannot describe a mark; an empty string is not a
        // logo either.
        guard !commands.isEmpty,
              commands.contains(where: { if case .move = $0 { return true } else { return false } })
        else { return nil }
        return commands
    }

    /// The bounding box of the path's *points*, in SVG coordinates.
    ///
    /// Control points are included deliberately: a Bézier never reaches its own
    /// control points, so excluding them would clip the mark to the wrong size.
    ///
    /// Returned as min/max pairs rather than a `CGRect` because `DSHShellCore`
    /// does not link AppKit, and the renderer is the only thing that needs an
    /// actual rectangle.
    public static func boundingBox(_ commands: [Command]) -> (minX: Double, minY: Double,
                                                             maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var sawPoint = false

        // Spelled out rather than using `min`/`max`: this file also defines a
        // `Command` case and the implicit overloads are needlessly hard to read.
        func include(_ x: Double, _ y: Double) {
            sawPoint = true
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }

        for command in commands {
            switch command {
            case .move(let x, let y), .line(let x, let y):
                include(x, y)
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                include(x1, y1)
                include(x2, y2)
                include(x, y)
            case .close:
                break
            }
        }
        guard sawPoint else { return nil }
        return (minX, minY, maxX, maxY)
    }

    // MARK: - Lexing

    // Whitespace and commas only: the two things that can separate a number from
            // the next command. A letter is already a natural boundary, since
            // the number parser stops on it.
            private static func skipWhitespace(from i: String.Index, in s: String) -> String.Index {
        var i = i
        while i < s.endIndex, s[i].isWhitespace || s[i] == "," { i = s.index(after: i) }
        return i
    }

    private static func parseNumber(from i: String.Index, in s: String) -> (Double, String.Index)? {
        var i = i
        var literal = ""

        if i < s.endIndex, s[i] == "-" || s[i] == "+" {
            literal.append(s[i])
            i = s.index(after: i)
        }

        var sawDigit = false
        while i < s.endIndex, s[i].isNumber {
            literal.append(s[i]); sawDigit = true
            i = s.index(after: i)
        }
        if i < s.endIndex, s[i] == "." {
            literal.append(s[i])
            i = s.index(after: i)
            while i < s.endIndex, s[i].isNumber {
                literal.append(s[i]); sawDigit = true
                i = s.index(after: i)
            }
        }
        guard sawDigit, let value = Double(literal) else { return nil }

        // Exponent, for completeness; dsh writes none.
        if i < s.endIndex, s[i] == "e" || s[i] == "E" {
            var exp = String(s[i])
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "-" || s[j] == "+" {
                exp.append(s[j]); j = s.index(after: j)
            }
            var sawExpDigit = false
            while j < s.endIndex, s[j].isNumber {
                exp.append(s[j]); sawExpDigit = true
                j = s.index(after: j)
            }
            if sawExpDigit, let value = Double(literal + exp) {
                return (value, j)
            }
        }
        return (value, i)
    }
}