// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopsGUIKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SopsUI", targets: ["SopsUI"]),
        .library(name: "SopsEngine", targets: ["SopsEngine"]),
        .library(name: "SopsHealth", targets: ["SopsHealth"]),
    ],
    targets: [
        .target(name: "SopsUI", dependencies: ["SopsHealth"], resources: [.process("Resources")]),
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
        .target(name: "SopsHealth", dependencies: ["SopsEngine"]),
        .testTarget(name: "SopsHealthTests", dependencies: ["SopsHealth", "SopsEngine"]),
    ]
)
