import Foundation
import SopsEngine
import Testing
@testable import SopsUI

/// A `null` row renders an editable text field, so a user can reveal it and
/// type a secret into it. The edit used to go to the bridge tagged `.null`,
/// where `KindNull` returned `nil` and dropped the text — no error, no alert,
/// "Unsaved changes" cleared, and the secret never on disk. Worse in a batch:
/// two edits in one save came back reported as saved with one discarded.
@Suite("Typing into a null row")
@MainActor
struct NullRowEditTests {

    private func row(kind: SecretRow.Kind) -> SecretRow {
        SecretRow(document: 0, path: ["db", "password"], value: "", kind: kind,
                  isInList: false, isPendingAdd: false, isEncrypted: false)
    }

    @Test("typing text into a null row writes it as a string")
    func typedNullBecomesAString() {
        #expect(SecretDocumentViewModel.editedKind(of: row(kind: .null), newValue: "hunter2-EXAMPLE") == .string,
                "the edit would have been sent as null, and a null cannot carry a value")
    }

    @Test("clearing a null row back to empty leaves it null")
    func clearedNullStaysNull() {
        #expect(SecretDocumentViewModel.editedKind(of: row(kind: .null), newValue: "") == .null)
    }

    /// Every other type keeps its own. A row's type is not the editor's to
    /// change on the user's behalf.
    @Test("no other type is rewritten", arguments: [
        SecretRow.Kind.string, .int, .float, .bool, .timestamp,
    ])
    func otherKindsAreUnchanged(_ kind: SecretRow.Kind) {
        #expect(SecretDocumentViewModel.editedKind(of: row(kind: kind), newValue: "anything") == kind)
    }
}
