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
        .library(name: "SopsProjects", targets: ["SopsProjects"]),
    ],
    targets: [
        .target(name: "SopsUI", dependencies: ["SopsEngine", "SopsHealth", "SopsProjects"], resources: [.process("Resources")]),
        .testTarget(name: "SopsUITests", dependencies: ["SopsUI", "SopsEngine"]),
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
        .target(name: "SopsProjects", dependencies: ["SopsHealth"]),
        .testTarget(name: "SopsProjectsTests", dependencies: ["SopsProjects"]),

        // MARK: SnapshotTool — headless visual snapshots (`swift run snapshots`).
        // Dev tool only: nothing in `App/` or `SopsGUI.xcodeproj` depends on
        // this, so it never reaches the shipped app. Depends on `SopsUI` for
        // the views themselves, and directly on `SopsHealth`/`SopsProjects`
        // for the fixture types (`HealthFinding`, `StoredProject`,
        // `ProjectStore`, ...) the catalog builds fixtures out of. Task 9
        // added `SecretEditorView`/`SecretDocumentViewModel` to the catalog,
        // which needs `SecretRow`/`SopsBridge` (`SopsEngine`) to build real
        // decrypted fixtures — this target now links `CSopsBridge`'s
        // xcframework too, so `Engine/build/SopsBridge.xcframework` must
        // exist before `swift run snapshots` (as it already must for
        // `swift test`; `Scripts/bootstrap.sh` builds it).
        .executableTarget(
            name: "snapshots",
            dependencies: ["SopsUI", "SopsEngine", "SopsHealth", "SopsProjects"],
            path: "Sources/SnapshotTool"
        ),
    ]
)
