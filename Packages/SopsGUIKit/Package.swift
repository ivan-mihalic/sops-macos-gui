// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopsGUIKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SopsUI", targets: ["SopsUI"]),
        .library(name: "SopsEngine", targets: ["SopsEngine"]),
    ],
    targets: [
        .target(name: "SopsUI", resources: [.process("Resources")]),
        .testTarget(name: "SopsUITests", dependencies: ["SopsUI"]),
        .binaryTarget(
            name: "CSopsBridge",
            path: "../../Engine/build/SopsBridge.xcframework"
        ),
        .target(
            name: "SopsEngine",
            dependencies: ["CSopsBridge"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(name: "SopsEngineTests", dependencies: ["SopsEngine"]),
    ]
)
