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

    // MARK: - The mask

    // `AccessibilityTreeTests.maskDoesNotLeakTheLengthOfTheSecret` is what
    // proves the *view* stopped leaking length; these pin the rule itself, at
    // sizes a rendered fixture would be silly to cover.

    @Test("two secrets of very different lengths mask to exactly the same string")
    func maskIsIdenticalForVeryDifferentLengths() {
        let pin = SecretRowViewLogic.maskedValue(for: "1234")
        let token = SecretRowViewLogic.maskedValue(for: String(repeating: "T", count: 64))
        #expect(pin == token)
    }

    @Test("the mask's width never depends on the value's length",
          arguments: [1, 2, 5, 13, 64, 512, 4096])
    func maskWidthIsConstant(length: Int) {
        let mask = SecretRowViewLogic.maskedValue(for: String(repeating: "s", count: length))
        #expect(mask.count == SecretRowViewLogic.maskWidth)
    }

    @Test("the mask is bullets and nothing else")
    func maskIsBulletsOnly() {
        let mask = SecretRowViewLogic.maskedValue(for: "correct-horse-battery-staple-EXAMPLE")
        #expect(!mask.isEmpty)
        #expect(mask.allSatisfy { $0 == "•" })
    }

    // sops never encrypts an empty string, so there is no secret behind one
    // to hide — and a mask over nothing would claim a value the file does not
    // have. See `SecretRowViewLogic.maskedValue(for:)`.
    @Test("an empty value masks to nothing rather than to a row of bullets")
    func emptyValueIsNotMasked() {
        #expect(SecretRowViewLogic.maskedValue(for: "").isEmpty)
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
