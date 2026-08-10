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
        // Test-only: deletes scratch directories when the test process exits.
        // A target rather than a helper per suite, because there are four test
        // targets and 75+ fixture label prefixes between them — see the type's
        // own comment for the audit that made that necessary.
        .target(name: "ScratchCleanup"),
        .testTarget(name: "SopsUITests", dependencies: ["SopsUI", "SopsEngine", "ScratchCleanup"]),
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
        .testTarget(name: "SopsEngineTests", dependencies: ["SopsEngine", "ScratchCleanup"]),
        .target(name: "SopsHealth", dependencies: ["SopsEngine"]),
        .testTarget(name: "SopsHealthTests", dependencies: ["SopsHealth", "SopsEngine", "ScratchCleanup"]),
        .target(name: "SopsProjects", dependencies: ["SopsHealth"]),
        .testTarget(name: "SopsProjectsTests", dependencies: ["SopsProjects", "ScratchCleanup"]),

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
