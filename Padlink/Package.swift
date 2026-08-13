// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PadlinkCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PadlinkCore", targets: ["PadlinkCore"]),
        .executable(name: "padlink-testclient", targets: ["PadlinkTestClient"])
    ],
    targets: [
        .target(name: "PadlinkCore"),
        .executableTarget(name: "PadlinkTestClient", dependencies: ["PadlinkCore"]),
        .testTarget(name: "PadlinkCoreTests", dependencies: ["PadlinkCore"])
    ]
)
