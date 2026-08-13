// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PadlinkCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PadlinkCore", targets: ["PadlinkCore"])
    ],
    targets: [
        .target(name: "PadlinkCore"),
        .testTarget(name: "PadlinkCoreTests", dependencies: ["PadlinkCore"])
    ]
)
