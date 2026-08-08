import Testing
import SopsEngine
@testable import SopsUI

@Suite("SecretRowViewLogic")
struct SecretRowViewLogicTests {

    private func row(path: [String], kind: SecretRow.Kind = .string) -> SecretRow {
        SecretRow(path: path, value: "x", kind: kind, isEncrypted: true)
    }

    @Test("a row whose path contains the merge-key segment is detected")
    func detectsMergeKeyRow() {
        #expect(SecretRowViewLogic.isMergeKeyRow(row(path: ["db", "<<", "host"])))
    }

    @Test("an ordinary row is not flagged as a merge key")
    func ordinaryRowIsNotFlagged() {
        #expect(!SecretRowViewLogic.isMergeKeyRow(row(path: ["db", "host"])))
    }

    // A key that merely *contains* the two characters, rather than being
    // exactly that path segment, must not trip the same UI — a user's own
    // key named "<<foo" is a plausible (if unusual) YAML map key and is not
    // a merge key at the tree level.
    @Test("a path segment that only resembles the merge-key marker is not flagged")
    func lookalikeSegmentIsNotFlagged() {
        #expect(!SecretRowViewLogic.isMergeKeyRow(row(path: ["<<foo"])))
    }

    @Test("displayPath joins the path with dots")
    func displayPathJoinsWithDots() {
        #expect(SecretRowViewLogic.displayPath(["db", "host"]) == "db.host")
    }

    @Test("every SecretRow.Kind has a distinct localized label")
    func everyKindHasADistinctLabel() {
        // `SecretRow.Kind` (Task 7, `SopsEngine`) is not `CaseIterable` —
        // adding that conformance for one UI-layer test isn't worth reaching
        // into a different task's type, so the eight cases are spelled out
        // here instead. If a ninth case is ever added there, this test stays
        // green by accident rather than catching the gap — a known, narrow
        // tradeoff for not touching `SopsEngine` from `SopsUI`'s test target.
        let allKinds: [SecretRow.Kind] = [.string, .int, .float, .bool, .null, .timestamp, .emptyMap, .emptyList]
        let labels = allKinds.map { SecretRowViewLogic.kindLabel($0) }
        #expect(Set(labels).count == allKinds.count)
    }
}
