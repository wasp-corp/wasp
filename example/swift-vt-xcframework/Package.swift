// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-vt-xcframework",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "swift-vt-xcframework",
            dependencies: ["WaspVt"],
            path: "Sources"
        ),
        .binaryTarget(
            name: "WaspVt",
            path: "../../zig-out/lib/wasp-vt.xcframework"
        ),
    ]
)
