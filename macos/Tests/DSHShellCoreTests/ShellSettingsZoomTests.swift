import XCTest
@testable import DSHShellCore

/// Page zoom, and the settings field that carries it between launches.
///
/// The ladder lives in exactly one place per implementation — `config.rs` on the
/// Windows side, `AppCoordinator.snapZoom` here — and a ladder written down
/// twice is a ladder that disagrees with itself.
final class ShellSettingsZoomTests: XCTestCase {
    func testZoomDefaultsToOneHundred() {
        XCTAssertEqual(ShellSettings.default.zoomPercent, 100)
    }

    func testZoomSurvivesARoundTrip() throws {
        var settings = ShellSettings.default
        settings.zoomPercent = 70
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ShellSettings.self, from: data).zoomPercent, 70)
    }

    /// A file written before zoom existed must still load — and must not have its
    /// other settings discarded on the way, which is the whole reason every
    /// field decodes through a default.
    func testAFileWrittenBeforeZoomStillLoads() throws {
        let legacy = """
        { "dshBinaryPath": "/x/dsh", "preferredPort": 34567 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ShellSettings.self, from: legacy)
        XCTAssertEqual(decoded.zoomPercent, 100)
        XCTAssertEqual(decoded.preferredPort, 34567)
        XCTAssertEqual(decoded.dshBinaryPath, "/x/dsh")
    }
}
