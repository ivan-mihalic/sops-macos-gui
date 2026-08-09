import Foundation
import Testing
@testable import SopsEngine

/// Two keys the rest of the stack considers different must not share one `id`.
///
/// `SecretRow.id` was `"\(component.count):\(component)"`. A length prefix is
/// injective over *bytes*; this is a Swift `String`, and Swift string equality
/// is canonical equivalence. `café` in NFC and in NFD are one value here, and
/// `.count` is 4 for both — while go-yaml, sops and the C boundary see five
/// bytes and six.
///
/// The consequence was not a cosmetic clash. `pendingChangeSet()` looks each
/// baseline row up by `id`, so both rows matched one edit: one keystroke
/// produced two `SecretEdit`s, and the key the user never touched was
/// overwritten with the other's value and lost. The Go side cannot refuse it —
/// `planChanges` keys by bytes, so they are legitimately distinct paths.
@Suite("A row id distinguishes everything the file format distinguishes")
struct SecretRowIdentityTests {

    /// `café` — the accent as one code point (NFC) and as base + combining
    /// mark (NFD). Written as escapes so the file's own encoding cannot
    /// normalise the fixture and quietly make the test vacuous.
    private static let nfc = "caf\u{00E9}"
    private static let nfd = "cafe\u{0301}"

    private func row(_ key: String) -> SecretRow {
        SecretRow(path: [key], value: "v", kind: .string, isEncrypted: true)
    }

    @Test("the fixture really is two different byte sequences that Swift calls equal")
    func fixtureIsTheRealHazard() {
        #expect(Array(Self.nfc.utf8) != Array(Self.nfd.utf8), "the fixture is not two encodings")
        #expect(Self.nfc == Self.nfd, "Swift no longer treats these as equal; the hazard is gone")
        #expect(Self.nfc.count == Self.nfd.count, "the length prefix would have distinguished them")
    }

    @Test("two keys differing only in Unicode normalisation get different ids")
    func normalisationVariantsDoNotCollide() {
        #expect(
            row(Self.nfc).id != row(Self.nfd).id,
            "one id for two keys — an edit to either writes to both, and the untouched secret is lost")
    }

    @Test("an id still survives a value change, which is the point of having one")
    func idIsStableAcrossValueChanges() {
        let before = SecretRow(path: ["db", "password"], value: "old", kind: .string, isEncrypted: true)
        let after = SecretRow(path: ["db", "password"], value: "new", kind: .string, isEncrypted: true)
        #expect(before.id == after.id)
    }

    @Test("paths that differ only in where the separator falls stay distinct")
    func separatorAmbiguityIsStillClosed() {
        #expect(row("a:b").id != SecretRow(
            path: ["a", "b"], value: "v", kind: .string, isEncrypted: true).id)
        #expect(
            SecretRow(path: ["x"], value: "v", kind: .string, isEncrypted: true).id
                != SecretRow(path: ["", "x"], value: "v", kind: .string, isEncrypted: true).id)
    }

    @Test("documents are distinguished, so multi-document files do not alias")
    func documentIndexIsPartOfTheIdentity() {
        let first = SecretRow(document: 0, path: ["k"], value: "v", kind: .string, isEncrypted: true)
        let second = SecretRow(document: 1, path: ["k"], value: "v", kind: .string, isEncrypted: true)
        #expect(first.id != second.id)
    }
}
