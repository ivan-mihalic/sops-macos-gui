import Foundation
import Testing

@testable import SopsEngine

/// Task 4 (SOPS-38): `format` stopped being an implicit "always YAML" and
/// became a real argument every `SopsBridge` call states — this suite is the
/// Swift-side proof that `.dotenv` genuinely reaches the bridge and comes
/// back out the other side, not just that the package compiles with the new
/// parameter. The cshim-level version of the same claim is
/// `Engine/cshim/exports_test.go`'s
/// `TestDotenvFormatReachesGobridgeThroughDecryptToRowsAndUpdateRecipients`;
/// this suite is its Swift-side counterpart, entirely in-process — no `sops`
/// CLI, no files on disk, no `age-keygen` subprocess needed for the fixture
/// itself (only `AgeKeyPair.generate()`, which still shells out to
/// `age-keygen` — there is no in-process keygen in this codebase).
///
/// A `.env` document is flat by construction: every row's `path` has exactly
/// one component, `isInList` is always false (there are no lists), and every
/// value decodes as `.string` — dotenv has no notion of an int, a bool or a
/// null distinct from its string spelling.
private let dotenvPlain = "DB_URL=postgres://x\nAPI_KEY=secret\n"

@Suite("SopsBridge, format: .dotenv")
struct SopsBridgeDotenvTests {

    @Test("decryptToRows returns the flat, one-segment-path rows a dotenv document has")
    func decryptToRowsReturnsFlatRows() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(dotenvPlain, format: .dotenv, recipients: [owner.public])

        let rows = try SopsBridge.decryptToRows(encrypted, format: .dotenv, agePrivateKey: owner.private)

        #expect(rows.count == 2)
        for row in rows {
            #expect(row.path.count == 1, "dotenv has no nesting; got path \(row.path)")
            #expect(!row.isInList, "dotenv has no lists")
            #expect(row.kind == .string, "every dotenv value is a string")
        }
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.path[0], $0.value) })
        #expect(byKey["DB_URL"] == "postgres://x")
        #expect(byKey["API_KEY"] == "secret")
    }

    /// The discriminating half of the claim: if `format` were silently
    /// dropped or hardcoded to `.yaml` somewhere between here and the Go
    /// side, this would either succeed with garbage or crash rather than
    /// throw a clean `SopsBridgeError` — a dotenv document's on-disk shape is
    /// not valid YAML, so asking the YAML store to parse it must fail.
    @Test("the same ciphertext read back with format: .yaml fails, proving the parameter is not ignored")
    func wrongFormatFailsCleanly() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(dotenvPlain, format: .dotenv, recipients: [owner.public])

        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        }
    }

    @Test("applyChanges adds, edits and removes a key in one save")
    func applyChangesAddEditRemove() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(dotenvPlain, format: .dotenv, recipients: [owner.public])

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .dotenv,
            changes: SecretChangeSet(
                sets: [SecretEdit(path: ["DB_URL"], value: "postgres://y", kind: .string)],
                adds: [SecretAddition(parent: [], key: "NEW_KEY", value: "new-value", kind: .string)],
                removes: [SecretRemoval(path: ["API_KEY"])]),
            agePrivateKey: owner.private)

        let rows = try SopsBridge.decryptToRows(saved, format: .dotenv, agePrivateKey: owner.private)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.path[0], $0.value) })

        #expect(byKey["DB_URL"] == "postgres://y")
        #expect(byKey["NEW_KEY"] == "new-value")
        #expect(byKey["API_KEY"] == nil, "API_KEY should have been removed")
        #expect(rows.count == 2)
    }

    @Test("recipients(in:) and updateRecipients round-trip a dotenv document")
    func recipientsAndUpdateRecipientsRoundTrip() throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(dotenvPlain, format: .dotenv, recipients: [owner.public])

        #expect(try SopsBridge.recipients(in: encrypted, format: .dotenv) == [owner.public])

        let rewrapped = try SopsBridge.updateRecipients(
            encrypted, format: .dotenv, to: [added.public], agePrivateKey: owner.private)

        #expect(try SopsBridge.recipients(in: rewrapped, format: .dotenv) == [added.public])

        // The new recipient can read it...
        let rows = try SopsBridge.decryptToRows(rewrapped, format: .dotenv, agePrivateKey: added.private)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.path[0], $0.value) })
        #expect(byKey["DB_URL"] == "postgres://x")
        #expect(byKey["API_KEY"] == "secret")

        // ...and the original owner, having been dropped, can no longer.
        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(rewrapped, format: .dotenv, agePrivateKey: owner.private)
        }
    }
}
