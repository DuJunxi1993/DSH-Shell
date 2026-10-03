import XCTest
@testable import DSHShellCore

final class EndpointResolverTests: XCTestCase {
    func testParsesCanonicalURLLine() {
        let r = EndpointResolver()
        let url = r.resolveURL(in: "dsh web: http://127.0.0.1:54321/")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:54321/")
    }

    func testToleratesWhitespaceAndPrefix() {
        let r = EndpointResolver()
        let url = r.resolveURL(in: "  dsh web:    http://localhost:60000/some/path")
        XCTAssertEqual(url?.absoluteString, "http://localhost:60000/some/path")
    }

    func testIgnoresLinesWithoutTheMarker() {
        let r = EndpointResolver()
        XCTAssertNil(r.resolveURL(in: "hello world"))
        XCTAssertNil(r.resolveURL(in: "dsh web http://no-colon"))
    }

    func testStripsANSI() {
        let r = EndpointResolver()
        let url = r.resolveURL(in: "\u{001B}[2Kdsh web: \u{001B}[0mhttp://127.0.0.1:54321/")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:54321/")
    }
}
