import XCTest
@testable import DSHShellCore

final class SettingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-shelU-test-settings-\(UUID().uuidString).json")
    }

    func testLoadReturnsDefaultWhenFileMissing() {
        let store = SettingsStore(fileURL: tempURL())
        XCTAssertEqual(store.load(), ShellSettings.default)
    }

    func testSaveAndReload() {
        let url = tempURL()
        let store = SettingsStore(fileURL: url)
        var custom = ShellSettings.default
        custom.preferredPort = 12345
        custom.trustedHosts = ["10.0.0.1"]
        store.save(custom)
        XCTAssertEqual(SettingsStore(fileURL: url).load(), custom)
    }

    /// The test that does not exist yet is the one that matters.
    ///
    /// Every field used to be required, and a decode failure was swallowed into
    /// defaults with no log line. So the first release that added a field would
    /// have made every existing settings file fail to decode, and the user
    /// would have silently lost their binary path, port and launch mode — with
    /// nothing on screen and nothing in the log to say why.
    ///
    /// A settings file written *before* any field exists must therefore still
    /// load, taking defaults for what it does not contain. This is the same
    /// guard as `#[serde(default)]` plus `a_settings_file_without_zoom_still_loads`
    /// in the Rust implementation.
    func testAFileMissingEveryNewFieldStillLoads() throws {
        let url = tempURL()
        // Exactly what v0.1.0 wrote: three fields, nothing else.
        let legacy = """
        {
          "dshBinaryPath": "/custom/path/dsh",
          "launchMode": "attach",
          "preferredPort": 34567
        }
        """.data(using: .utf8)!
        try legacy.write(to: url)

        let loaded = SettingsStore(fileURL: url).load()
        // What the user configured survives…
        XCTAssertEqual(loaded.dshBinaryPath, "/custom/path/dsh")
        XCTAssertEqual(loaded.launchMode, .attach)
        XCTAssertEqual(loaded.preferredPort, 34567)
        // …and what the file does not mention takes a default rather than
        // throwing the whole file away.
        XCTAssertEqual(loaded.listenHost, "127.0.0.1")
        XCTAssertEqual(loaded.trustedHosts, ["127.0.0.1", "localhost"])
        XCTAssertTrue(loaded.autoRestartOnCrash)
    }

    func testAnEmptyObjectDecodesToDefaults() throws {
        let url = tempURL()
        try Data("{}".utf8).write(to: url)
        let loaded = SettingsStore(fileURL: url).load()
        XCTAssertEqual(loaded.preferredPort, ShellSettings.default.preferredPort)
        XCTAssertEqual(loaded.launchMode, ShellSettings.default.launchMode)
    }

    func testAFieldWithTheWrongTypeDoesNotDiscardTheRest() throws {
        // A single bad value must not cost the user every other setting.
        let url = tempURL()
        let partial = """
        {
          "dshBinaryPath": "/x/dsh",
          "preferredPort": "not-a-number"
        }
        """.data(using: .utf8)!
        try partial.write(to: url)
        let loaded = SettingsStore(fileURL: url).load()
        XCTAssertEqual(loaded.dshBinaryPath, "/x/dsh")
        XCTAssertEqual(loaded.preferredPort, ShellSettings.default.preferredPort)
    }

    func testAUnknownKeyIsIgnoredRatherThanFatal() throws {
        // Forward compatibility: a file written by a *newer* build must still
        // open in an older one.
        let url = tempURL()
        let future = """
        { "preferredPort": 4000, "somethingFromTheFuture": true }
        """.data(using: .utf8)!
        try future.write(to: url)
        XCTAssertEqual(SettingsStore(fileURL: url).load().preferredPort, 4000)
    }

    func testAValidFileIsNotResurrectedAsDefaults() throws {
        // Guards against the failure mode of the *other* fix: silently
        // replacing a good configuration.
        let url = tempURL()
        let store = SettingsStore(fileURL: url)
        var custom = ShellSettings.default
        custom.preferredPort = 5555
        store.save(custom)
        XCTAssertEqual(SettingsStore(fileURL: url).load().preferredPort, 5555)
    }
}