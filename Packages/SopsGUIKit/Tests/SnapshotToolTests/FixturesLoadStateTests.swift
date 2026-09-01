import SopsUI
import Testing
@testable import snapshots

/// SOPS-38 phase F3 review fix: pins the exact drift that shipped once
/// already.
///
/// Task 1 changed `SecretDocumentViewModel.load()` so a wrong-key document
/// reaches `LoadState.readOnlyCiphertext` instead of `.failed`. `Fixtures
/// .editorLoadFailedViewModel()` — which backs `Catalog.swift`'s
/// `editor-load-failed` snapshot — used exactly that wrong-key shape, so it
/// silently stopped producing `.failed` at all: no test caught it, because
/// `SopsUITests` (`Package.swift`'s own test target list) has no dependency
/// on `snapshots` at all, and nothing else in the suite ever constructs a
/// `SnapshotTool` fixture. Task 2 rewrote the fixture to use a genuine
/// corruption instead, and added a separate `editorReadOnlyCiphertextViewModel()`
/// for the wrong-key shape — but a fix with no test pinning it is exactly the
/// kind of silent-drift risk this suite exists to close: the *next* change to
/// `LoadState`'s classification could just as easily reintroduce it, and
/// nothing would say so until someone happened to look at a PNG.
///
/// `SnapshotToolTests` exists as its own tiny target (rather than adding
/// `snapshots` to `SopsUITests`) because `snapshots` is an executable target,
/// not a library — `SopsUITests` depending on it would make every ordinary
/// UI test build (and, transitively, run) the whole snapshot catalog's own
/// dependency graph for a property only these two fixtures need. `snapshots`
/// is importable as `@testable` at all because `SnapshotMain.swift` uses
/// `@main` rather than a bare top-level `main.swift` — SwiftPM's "testable
/// executable" feature requires that shape.
@Suite("SnapshotTool.Fixtures — editor load-state fixtures reach the state their name claims")
@MainActor
struct FixturesLoadStateTests {

    /// The regression itself: a genuinely damaged file must reach `.failed`,
    /// never `.readOnlyCiphertext` — see `Fixtures.editorLoadFailedViewModel`'s
    /// own doc comment for the corruption technique and why it is not a
    /// wrong-key shape.
    @Test("editorLoadFailedViewModel() reaches .failed")
    func loadFailedFixtureReachesFailed() async throws {
        let model = try await Fixtures.editorLoadFailedViewModel()
        guard case .failed = model.loadState else {
            Issue.record("""
                editorLoadFailedViewModel() must reach .failed, got \(model.loadState) — the \
                editor-load-failed snapshot would silently start showing something else
                """)
            return
        }
    }

    /// The sibling fixture: the real wrong-key shape must reach
    /// `.readOnlyCiphertext`, which is the one property `CiphertextReadOnlyView`
    /// (Task 2) depends on to have anything real to render for the
    /// `editor-readonly-ciphertext` snapshot.
    @Test("editorReadOnlyCiphertextViewModel() reaches .readOnlyCiphertext")
    func readOnlyCiphertextFixtureReachesReadOnlyCiphertext() async throws {
        let model = try await Fixtures.editorReadOnlyCiphertextViewModel()
        guard case .readOnlyCiphertext = model.loadState else {
            Issue.record("""
                editorReadOnlyCiphertextViewModel() must reach .readOnlyCiphertext, got \
                \(model.loadState) — the editor-readonly-ciphertext snapshot would silently \
                start showing something else
                """)
            return
        }
    }
}
