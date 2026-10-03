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
        .testTarget(
            name: "DSHShellCoreTests",
            dependencies: ["DSHShellCore"],
            path: "Tests/DSHShellCoreTests"
        )
    ]
)
