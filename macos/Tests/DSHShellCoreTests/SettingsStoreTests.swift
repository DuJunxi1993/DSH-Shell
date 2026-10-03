import XCTest
@testable import DSHShellCore

final class SettingsStoreTests: XCTestCase {
    func testLoadReturnsDefaultWhenFileMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-swiftUI-test-settings-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: url)
        let s = store.load()
        XCTAssertEqual(s, ShellSettings.default)
    }

    func testSaveAndReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-swiftUI-test-settings-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: url)
        var custom = ShellSettings.default
        custom.preferredPort = 12345
        custom.trustedHosts = ["10.0.0.1"]
        store.save(custom)
        let reloaded = SettingsStore(fileURL: url).load()
        XCTAssertEqual(reloaded, custom)
    }
}
