// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DSHShell",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DSHShell", targets: ["DSHShell"]),
        .library(name: "DSHShellCore", targets: ["DSHShellCore"]),
        .library(name: "DSHShellBridge", targets: ["DSHShellBridge"])
    ],
    targets: [
        .target(
            name: "DSHShellCore",
            path: "Sources/DSHShellCore"
        ),
        .target(
            name: "DSHShellBridge",
            path: "Sources/DSHShellBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DSHShell",
            dependencies: ["DSHShellCore", "DSHShellBridge"],
            path: "Sources/DSHShell"
        ),
        // Test double for `dsh web`. Deliberately not a product: it is never
        // bundled and never launched outside `swift test`. The test target
        // depends on it so `swift test` builds it, and finds it next to the
        // test bundle. See docs/dsh-shell-contract.md §3.
        .executableTarget(
            name: "stub-dsh",
            path: "Sources/stub-dsh"
        ),
        .testTarget(
            name: "DSHShellCoreTests",
            dependencies: ["DSHShellCore", "stub-dsh"],
            path: "Tests/DSHShellCoreTests"
        )
    ]
)
