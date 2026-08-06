// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopsGUIKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SopsUI", targets: ["SopsUI"])
    ],
    targets: [
        .target(name: "SopsUI", resources: [.process("Resources")]),
        .testTarget(name: "SopsUITests", dependencies: ["SopsUI"]),
    ]
)
