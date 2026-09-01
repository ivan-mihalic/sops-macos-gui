import Foundation
import Testing

@testable import SopsEngine

/// SOPS-38 phase F2 task 2: `.json` becomes a real `SopsFileFormat` case —
/// this suite is the Swift-side proof that `.json` genuinely reaches the
/// bridge and comes back out the other side, mirroring
/// `SopsBridgeDotenvTests`. The cshim-level version of the same claim is
/// `Engine/cshim/exports_test.go`'s
/// `TestJSONAndINIFormatsReachGobridgeThroughDecryptToRowsAndUpdateRecipients`;
/// the Go-store-level version (row shapes, edge cases, refusal wording) is
/// `Engine/gobridge/json_test.go` from F2 task 1. This suite adds nothing new
/// about the store's own behaviour — it only proves the Swift `format:
/// .json` argument actually reaches it.
///
/// Nested, with a list and every `SecretRow.Kind` the JSON store can carry —
/// deliberately the same shape as `Engine/gobridge/json_test.go`'s
/// `jsonPlain`, so a discrepancy between the two languages' pictures of "the
/// same document" would show up as a difference from the pinned Go values,
/// not get invented independently here.
private let jsonPlain = """
{
  "db": {
    "url": "postgres://x",
    "port": 5432,
    "ssl": true,
    "ratio": 0.5,
    "note": null
  },
  "tags": ["a", "b"]
}
"""

@Suite("SopsBridge, format: .json")
struct SopsBridgeJSONTests {

    @Test("decryptToRows returns nested paths, list membership and every Kind a JSON document can carry")
    func decryptToRowsReturnsNestedPathsAndKinds() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])

        let rows = try SopsBridge.decryptToRows(encrypted, format: .json, agePrivateKey: owner.private)

        #expect(rows.count == 7)
        func row(_ path: String...) throws -> SecretRow {
            try #require(rows.first { $0.path == path })
        }

        let url = try row("db", "url")
        #expect(url.value == "postgres://x")
        #expect(url.kind == .string)
        #expect(!url.isInList)

        let port = try row("db", "port")
        #expect(port.value == "5432")
        #expect(port.kind == .int)

        let ssl = try row("db", "ssl")
        #expect(ssl.value == "true")
        #expect(ssl.kind == .bool)

        let ratio = try row("db", "ratio")
        #expect(ratio.value == "0.5")
        #expect(ratio.kind == .float)

        let note = try row("db", "note")
        #expect(note.kind == .null)

        let tag0 = try row("tags", "0")
        #expect(tag0.value == "a")
        #expect(tag0.isInList)
        let tag1 = try row("tags", "1")
        #expect(tag1.value == "b")
        #expect(tag1.isInList)
    }

    /// The discriminating half — but **not** against `format: .yaml`. See
    /// the file-scope note below on why JSON is the one format here where
    /// that combination is not a negative case.
    @Test("the same ciphertext read back with format: .ini fails, proving the parameter is not ignored")
    func wrongFormatINIFailsCleanly() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])

        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(encrypted, format: .ini, agePrivateKey: owner.private)
        }
    }

    /// **Not a bug this task introduced — a fact about sops's own stores,
    /// pinned here rather than left to be rediscovered by surprise.**
    ///
    /// A sops JSON document is, byte for byte, also valid YAML: JSON is a
    /// syntactic subset of YAML 1.2, and sops's JSON emitter writes exactly
    /// the double-quoted, comma-and-brace flow style that a YAML parser
    /// accepts unchanged. Measured directly against this build (a throwaway
    /// Go probe against `gobridge.DecryptToRows`, run before writing this
    /// test and not part of any commit): `format="yaml"` against a
    /// genuinely JSON-encrypted document does not fail — it **succeeds
    /// silently** and returns the same rows `format="json"` would. Verified
    /// here too, at the Swift/bridge boundary, not just in Go.
    ///
    /// This is not a JSON/YAML store confusion the app can trigger by
    /// accident today: nothing yet writes `format: .yaml` against a document
    /// it opened as `.json` (`SecretDocumentViewModel.format` is set once,
    /// at construction, from what the caller — ultimately the health
    /// scanner — decided the file's format is, and never re-derived). It is
    /// recorded so a future format-detection change does not "fix" a
    /// discriminating test that silently stopped discriminating, and so
    /// nobody re-derives this by surprise from a failing assertion later.
    @Test("format: .yaml against a JSON document does not fail — it silently reads the same content")
    func wrongFormatYAMLSucceedsSilently() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])

        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        let url = try #require(rows.first { $0.path == ["db", "url"] })
        #expect(url.value == "postgres://x", "a JSON document's own on-disk shape parses cleanly as YAML too")
    }

    @Test("applyChanges adds, edits and removes a key in one save, preserving nested structure")
    func applyChangesAddEditRemove() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .json,
            changes: SecretChangeSet(
                sets: [SecretEdit(path: ["db", "url"], value: "postgres://y", kind: .string)],
                adds: [SecretAddition(parent: ["db"], key: "region", value: "us-east", kind: .string)],
                removes: [SecretRemoval(path: ["db", "note"])]),
            agePrivateKey: owner.private)

        let rows = try SopsBridge.decryptToRows(saved, format: .json, agePrivateKey: owner.private)

        let url = try #require(rows.first { $0.path == ["db", "url"] })
        #expect(url.value == "postgres://y")
        let region = try #require(rows.first { $0.path == ["db", "region"] })
        #expect(region.value == "us-east")
        #expect(rows.first { $0.path == ["db", "note"] } == nil, "db.note should have been removed")
        // db.port/ssl/ratio and tags.0/tags.1 are untouched by this change set.
        #expect(rows.first { $0.path == ["db", "port"] }?.value == "5432")
        #expect(rows.first { $0.path == ["tags", "1"] }?.value == "b")
    }

    @Test("recipients(in:) and updateRecipients round-trip a JSON document")
    func recipientsAndUpdateRecipientsRoundTrip() throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])

        #expect(try SopsBridge.recipients(in: encrypted, format: .json) == [owner.public])

        let rewrapped = try SopsBridge.updateRecipients(
            encrypted, format: .json, to: [added.public], agePrivateKey: owner.private)

        #expect(try SopsBridge.recipients(in: rewrapped, format: .json) == [added.public])

        // The new recipient can read it...
        let rows = try SopsBridge.decryptToRows(rewrapped, format: .json, agePrivateKey: added.private)
        #expect(rows.first { $0.path == ["db", "url"] }?.value == "postgres://x")

        // ...and the original owner, having been dropped, can no longer.
        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(rewrapped, format: .json, agePrivateKey: owner.private)
        }
    }
}
