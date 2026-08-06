// swift-tools-version: 6.0
import PackageDescription

// M0 spike: a Swift package that links the Go SOPS bridge as a static
// xcframework and proves CLI byte-compatibility from the Swift side.
// Run ./build-xcframework.sh before `swift test`.
let package = Package(
    name: "SopsBridgeSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "CSopsBridge",
            path: "build/SopsBridge.xcframework"
        ),
        .target(
            name: "SopsBridge",
            dependencies: ["CSopsBridge"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
            ]
        ),
        .executableTarget(
            name: "sops-spike-demo",
            dependencies: ["SopsBridge"]
        ),
        .testTarget(
            name: "SopsBridgeTests",
            dependencies: ["SopsBridge"]
        ),
    ]
)
