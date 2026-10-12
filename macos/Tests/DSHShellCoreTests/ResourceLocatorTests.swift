import XCTest
@testable import DSHShellCore

/// `ResourceLocator` exists because the app is built by two build systems from
/// one set of sources, and they disagree about how a bundled resource is found.
/// These tests cover the SwiftPM layout directly, since the `.app` layout is
/// exercised by the app itself.
final class ResourceLocatorTests: XCTestCase {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resources-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testItFindsAResourceInsideASwiftPMResourceBundle() {
        // What SwiftPM produces for an executable target: the binary and
        // `DSHShell_DSHShell.bundle` side by side, with the scripts inside the
        // bundle rather than in any Bundle the app can see.
        let container = tempDirectory()
        let bundle = container.appendingPathComponent("DSHShell_DSHShell.bundle")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? Data("window.__dshShellDesktop = {};".utf8)
            .write(to: bundle.appendingPathComponent("dsh_desktop_bridge.js"))

        let found = ResourceLocator.url(forResource: "dsh_desktop_bridge",
                                       withExtension: "js",
                                       inBundleDirectory: container)
        XCTAssertEqual(found, bundle.appendingPathComponent("dsh_desktop_bridge.js"))
    }

    func testItReturnsNilWhenNoBundleHasTheResource() {
        // The caller treats this as "do not declare the desktop runtime at all",
        // so a wrong positive would half-apply the contract.
        let container = tempDirectory()
        let bundle = container.appendingPathComponent("DSHShell_DSHShell.bundle")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: bundle.appendingPathComponent("something-else.js"))

        XCTAssertNil(ResourceLocator.url(forResource: "dsh_desktop_bridge",
                                        withExtension: "js",
                                        inBundleDirectory: container))
    }

    func testItIgnoresDirectoriesThatAreNotBundles() {
        let container = tempDirectory()
        let decoy = container.appendingPathComponent("dsh_desktop_bridge.js.d")
        try? FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try? Data("decoy".utf8).write(to: decoy.appendingPathComponent("dsh_desktop_bridge.js"))

        XCTAssertNil(ResourceLocator.url(forResource: "dsh_desktop_bridge",
                                        withExtension: "js",
                                        inBundleDirectory: container))
    }

    func testItReturnsNilForAMissingDirectoryRatherThanThrowing() {
        XCTAssertNil(ResourceLocator.url(forResource: "any", withExtension: "js",
                                        inBundleDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID())")))
    }

    func testTheBridgeScriptIsPresentInTheBuiltProduct() throws {
        // The one lookup whose failure is silent and fatal: without this script
        // dsh never declares the desktop runtime, and nothing says so.
        let bundle = Bundle.main
        let url = ResourceLocator.url(forResource: "dsh_desktop_bridge",
                                      withExtension: "js",
                                      in: bundle,
                                      container: ResourceLocator.defaultContainer(for: bundle))
        try XCTSkipIf(url == nil,
                     "run under `swift test` or the built app, where the script is a resource")
        let source = try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
        XCTAssertTrue(source.contains("dshDesktopBoot"))
        XCTAssertTrue(source.contains("dataset.platform"))
        // The drag forwarder must register itself at documentStart; a host-side
        // `evaluateJavaScript` call lands on about:blank and is gone by the time
        // the real document exists.
        XCTAssertTrue(source.contains("installDragForwarding()"))
    }
}