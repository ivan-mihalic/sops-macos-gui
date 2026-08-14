import Foundation
import Testing
@testable import SopsUI

/// Ticket #7: `AgeKeyFileLocations.protectCommand(for:)` returns nil for a
/// path `ShellQuoting` cannot represent as one safe shell word, and before
/// this existed `KeyImportView`'s post-import callout simply omitted the
/// whole `HStack` in that case — the success message stood alone with no
/// hint there was still something to do. `SecurityPostureCheckTests`'
/// `unquotablePathStillExplainsWhatToDo` proves the equivalent health finding
/// carries a usable explanation on this path; this proves the view does too.
///
/// A source-text guard, for the reason `ClipboardRoutingTests` (same target)
/// states at length: a SwiftUI `if/else` branch that is never exercised by
/// any snapshot or behavioral test is invisible to a runtime probe, and
/// `KeyImportView` has no snapshot that forces `protectCommand` to return nil
/// (that would need a real file on disk with a newline in its name, which
/// `SnapshotTool`'s fixtures deliberately avoid — see its own doc comment on
/// staying in-memory/throwaway).
@Suite("KeyImportView explains, not silently omits, when no chmod command can be built")
struct KeyImportChmodFallbackTests {

    private static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SopsUI/Editor/KeyImportView.swift")

    private func text() throws -> String {
        OuterSidebarWiringTests.strippingComments(
            try String(contentsOf: Self.source, encoding: .utf8))
    }

    @Test("the post-import callout has an else branch for a command that could not be built")
    func calloutHasAFallbackBranch() throws {
        let text = try text()
        guard let ifRange = text.range(of: "if let command = AgeKeyFileLocations.protectCommand(for: [path]) {") else {
            Issue.record("the guarded chmod command block has moved or been rewritten")
            return
        }
        let tail = text[ifRange.upperBound...]
        guard let elseRange = tail.range(of: "} else {") else {
            Issue.record("no else branch follows the chmod command block — a path protectCommand refuses gets no explanation at all")
            return
        }
        #expect(tail[elseRange.upperBound...].contains("LocalizedKey.keyImportLegacyChmodUnavailable")
                    || tail[elseRange.upperBound...].contains(".keyImportLegacyChmodUnavailable"),
                "the fallback branch no longer shows the chmod-unavailable explanation")
    }
}
