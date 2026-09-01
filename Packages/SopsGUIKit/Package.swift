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
        // `SopsEngine` is an explicit dependency, not a transitive one through
        // `SopsHealth` (which already depends on it), because SwiftPM module
        // visibility follows a target's own declared dependency list, not the
        // whole graph reachable through it — the same reason
        // `SopsProjectsTests` below states it explicitly. SOPS-38 phase F3:
        // `SessionKeyStore` derives the session's own age public key via
        // `SopsBridge.agePublicKey(forPrivateKey:)`, so this target needs
        // `SopsEngine` for its own production code now, not only its tests.
        .target(name: "SopsProjects", dependencies: ["SopsHealth", "SopsEngine"]),
        // `SopsEngine` is an explicit dependency, not a transitive one, because
        // `ProjectRecipientApplierTests` builds its fixtures with the real
        // in-process bridge (`SopsBridge.encryptYAML`/`decryptYAML`) rather
        // than hand-written ciphertext — the discipline Task 1 established for
        // every recipient-management test.
        .testTarget(name: "SopsProjectsTests", dependencies: ["SopsProjects", "SopsEngine", "ScratchCleanup"]),

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
        // SOPS-38 phase F3 review fix: pins that `Fixtures.editorLoadFailedViewModel()`
        // and `Fixtures.editorReadOnlyCiphertextViewModel()` each still reach the
        // `LoadState` their snapshot name claims. `SopsUITests` deliberately does
        // not depend on `snapshots` (Package.swift's own products list — the
        // catalog is a dev tool, never part of the shipped app), which is exactly
        // why the drift this pins went unnoticed the first time: Task 1 changed
        // `SecretDocumentViewModel.load()`'s classification, and the fixture that
        // used to reach `.failed` started reaching `.readOnlyCiphertext` instead,
        // with nothing anywhere in the test suite positioned to notice. `snapshots`
        // uses `@main` (`SnapshotMain.swift`), which is what makes it a testable
        // executable target at all — a target with a bare top-level `main.swift`
        // could not be imported this way.
        .testTarget(
            name: "SnapshotToolTests",
            dependencies: ["snapshots", "SopsUI", "SopsEngine"],
            path: "Tests/SnapshotToolTests"
        ),
    ]
)
