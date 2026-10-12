import XCTest
@testable import DSHShellCore

/// The whale is dsh's brand, so these are not "does it compile" tests: a wrong
/// y-flip renders a recognisable but upside-down fish, and a parser that skips
/// one curve renders a fish with a bite taken out of it. Both look like a bug in
/// someone else's artwork rather than in this code.
final class SVGPathGeometryTests: XCTestCase {

    // MARK: - The real geometry

    func testTheWhaleParses() {
        let commands = SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)
        XCTAssertNotNil(commands, "the generated whale path must parse")
    }

    func testTheWhaleUsesOnlyTheFourCommandsSupported() {
        // If dsh ever adds an arc or a relative command, this fails loudly
        // instead of the parser quietly returning a truncated mark.
        let commands = SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!
        var seen = Set<String>()
        for command in commands {
            switch command {
            case .move: seen.insert("M")
            case .line: seen.insert("L")
            case .curve: seen.insert("C")
            case .close: seen.insert("Z")
            }
        }
        XCTAssertEqual(seen, ["M", "L", "C", "Z"])
    }

    func testTheWhaleHasFourSubpaths() {
        // 4 moves and 4 closes: the body plus three fins. A parser that drops a
        // close would blend one fin into the next.
        let commands = SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!
        XCTAssertEqual(commands.filter { if case .move = $0 { return true } else { return false } }.count, 4)
        XCTAssertEqual(commands.filter { $0 == .close }.count, 4)
    }

    func testTheWhaleStartsAtTheTopAndEndsAtTheBottom() {
        // Guards the orientation. SVG y grows downwards, so the tail (drawn last,
        // largest y) must be below the head. If this inverts, the renderer is
        // flipping the wrong way and the fish is upside down.
        let commands = SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!
        var minY = Double.infinity, maxY = -Double.infinity
        for command in commands {
            if case .move(_, let y) = command { minY = min(minY, y); maxY = max(maxY, y) }
        }
        XCTAssertLessThan(minY, maxY)
        // The head sits near the top of the box, so its start y is small.
        XCTAssertLessThan(minY, DSHFishLogoGeometry.height / 2)
    }

    func testTheViewBoxIsDshsCanvasAndNotThePathBounds() {
        // dsh's FISH_LOGO_VIEWBOX is the canvas its component declares, and the
        // path overshoots it slightly (its minimum x is negative). Fitting the
        // bounds instead of the viewBox would draw the whale slightly larger
        // than the web UI and off centre, so the two must not be conflated.
        let box = SVGPathGeometry.boundingBox(SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!)!
        XCTAssertLessThan(box.minX, 0, "the whale's bounds start left of the viewBox origin")

        // The official canvas, as extracted from dsh.
        XCTAssertEqual(DSHFishLogoGeometry.width, 23.16, accuracy: 0.001)
        XCTAssertEqual(DSHFishLogoGeometry.height, 17.04, accuracy: 0.001)
    }

    func testTheWhaleOnlyOverflowsItsViewBoxSlightly() {
        // The path pokes a little outside dsh's canvas on the right and bottom
        // (and starts left of the origin). That is dsh's own geometry — the web
        // UI maps the same overflowing path onto the same viewBox — so the shell
        // must do the same, not "fix" it by rescaling to the bounds.
        //
        // What matters is that the overflow stays a rounding-level amount. If a
        // future dsh release changed the viewBox meaningfully instead, this
        // fails and the renderer needs a look, because that is the one case
        // where scaling by the viewBox would visibly crop or pad the mark.
        let box = SVGPathGeometry.boundingBox(SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!)!
        XCTAssertLessThan(box.minX, 0, "the whale starts left of the viewBox origin")
        let overflowRight = box.maxX - DSHFishLogoGeometry.width
        let overflowBottom = box.maxY - DSHFishLogoGeometry.height
        XCTAssertLessThan(overflowRight, 0.05, "right edge should barely exceed the viewBox")
        XCTAssertLessThan(overflowBottom, 0.2, "bottom edge should barely exceed the viewBox")
    }

    func testTheWhaleIsWiderThanItIsTall() {
        // A sanity check on orientation: if this ever comes out portrait, the
        // aspect ratio is being applied on the wrong axis.
        let box = SVGPathGeometry.boundingBox(SVGPathGeometry.parse(DSHFishLogoGeometry.pathData)!)!
        XCTAssertGreaterThan(box.maxX - box.minX, box.maxY - box.minY)
    }

    // MARK: - The grammar

    func testParsesEachCommand() {
        let commands = SVGPathGeometry.parse("M1 2L3 4C5 6 7 8 9 10Z")!
        XCTAssertEqual(commands, [
            .move(x: 1, y: 2),
            .line(x: 3, y: 4),
            .curve(x1: 5, y1: 6, x2: 7, y2: 8, x: 9, y: 10),
            .close,
        ])
    }

    func testHandlesNegativeValuesAndLeadingDecimalPoints() {
        // dsh's path contains both, which is why this exists.
        let commands = SVGPathGeometry.parse("M-0.22-.03L.5-.5C1.5-2.5 3-4 5-6Z")!
        XCTAssertEqual(commands, [
            .move(x: -0.22, y: -0.03),
            .line(x: 0.5, y: -0.5),
            .curve(x1: 1.5, y1: -2.5, x2: 3, y2: -4, x: 5, y: -6),
            .close,
        ])
    }

    func testToleratesCommasAndNewlinesBetweenArguments() {
        XCTAssertEqual(SVGPathGeometry.parse("M 1,2\nL3 , 4 Z"), [
            .move(x: 1, y: 2), .line(x: 3, y: 4), .close,
        ])
    }

    func testRejectsUnsupportedCommands() {
        // Arcs and quadratics would need real support, not a shrug. Returning
        // nil means the caller keeps the committed artwork.
        XCTAssertNil(SVGPathGeometry.parse("M0 0A5 5 0 0 1 10 10"))
        XCTAssertNil(SVGPathGeometry.parse("M0 0Q1 2 3 4"))
        XCTAssertNil(SVGPathGeometry.parse("m0 0l1 1"))  // relative forms
        XCTAssertNil(SVGPathGeometry.parse("M0 0H10V10"))
    }

    func testRejectsTruncatedAndEmptyInput() {
        XCTAssertNil(SVGPathGeometry.parse(""))
        XCTAssertNil(SVGPathGeometry.parse("   "))
        XCTAssertNil(SVGPathGeometry.parse("M0 0C1 2 3"))       // curve missing args
        XCTAssertNil(SVGPathGeometry.parse("M0"))              // move missing args
        XCTAssertNil(SVGPathGeometry.parse("Z"))               // no move at all
        XCTAssertNil(SVGPathGeometry.parse("M0 0L"))           // trailing operator
    }

    // MARK: - Bounds

    func testBoundingBoxIncludesControlPoints() {
        // A Bézier's curve never reaches its control points, but the artwork's
        // canvas does contain them, so the box must too.
        let box = SVGPathGeometry.boundingBox([
            .move(x: 0, y: 0),
            .curve(x1: -10, y1: 20, x2: 30, y2: -40, x: 0, y: 0),
        ])!
        XCTAssertEqual(box.minX, -10)
        XCTAssertEqual(box.maxX, 30)
        XCTAssertEqual(box.minY, -40)
        XCTAssertEqual(box.maxY, 20)
    }

    func testBoundingBoxIsNilWithoutPoints() {
        XCTAssertNil(SVGPathGeometry.boundingBox([]))
    }
}