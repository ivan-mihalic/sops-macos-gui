import Foundation
import Testing

@testable import SopsEngine

/// SOPS-38 phase F2 task 2: `.ini` becomes a real `SopsFileFormat` case —
/// this suite is the Swift-side proof that `.ini` genuinely reaches the
/// bridge and comes back out the other side, mirroring
/// `SopsBridgeDotenvTests`. The cshim-level version of the same claim is
/// `Engine/cshim/exports_test.go`'s
/// `TestJSONAndINIFormatsReachGobridgeThroughDecryptToRowsAndUpdateRecipients`;
/// the Go-store-level version (row shapes, edge cases, refusal wording) is
/// `Engine/gobridge/ini_test.go` from F2 task 1. This suite adds nothing new
/// about the store's own behaviour — it only proves the Swift `format:
/// .ini` argument actually reaches it.
///
/// Two sections, each with string keys — the same shape as
/// `Engine/gobridge/ini_test.go`'s `iniPlain`, so a discrepancy between the
/// two languages' pictures of "the same document" would show up as a
/// difference from the pinned Go values, not get invented independently
/// here.
private let iniPlain = "[db]\nurl = postgres://x\npassword = secret\n\n[api]\nkey = secret2\n"

@Suite("SopsBridge, format: .ini")
struct SopsBridgeINITests {

    /// gopkg.in/ini.v1's `Sections()` always returns an implicit `DEFAULT`
    /// section, even when nothing in the source document precedes the first
    /// `[section]` header (`Engine/gobridge/ini_test.go`'s
    /// `TestINILoadAlwaysCarriesAnImplicitDefaultSection`, F2 task 1) — so
    /// every INI document's row list, this one included, starts with a
    /// `["DEFAULT"]` row of `Kind.emptyMap`, not just the two-segment
    /// `[section, key]` rows the plain keys produce.
    @Test("decryptToRows returns the implicit DEFAULT row plus two-segment [section, key] paths")
    func decryptToRowsReturnsSectionKeyPaths() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])

        let rows = try SopsBridge.decryptToRows(encrypted, format: .ini, agePrivateKey: owner.private)

        #expect(rows.count == 4)

        let defaultRow = try #require(rows.first { $0.path == ["DEFAULT"] })
        #expect(defaultRow.kind == .emptyMap)

        for row in rows where row.path != ["DEFAULT"] {
            #expect(row.path.count == 2, "every real INI entry is [section, key]; got \(row.path)")
            #expect(!row.isInList, "INI has no lists")
            #expect(row.kind == .string, "every INI value is a string")
        }

        let url = try #require(rows.first { $0.path == ["db", "url"] })
        #expect(url.value == "postgres://x")
        let password = try #require(rows.first { $0.path == ["db", "password"] })
        #expect(password.value == "secret")
        let key = try #require(rows.first { $0.path == ["api", "key"] })
        #expect(key.value == "secret2")
    }

    /// The discriminating half: an INI document's on-disk shape is not valid
    /// YAML — unlike JSON's (see `SopsBridgeJSONTests`'s own note on why
    /// `.yaml` is not a valid negative case for `.json`). Verified directly
    /// here, not assumed from that asymmetry.
    @Test("the same ciphertext read back with format: .yaml fails, proving the parameter is not ignored")
    func wrongFormatYAMLFailsCleanly() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])

        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        }
    }

    /// A second negative case, for completeness against the other new
    /// format rather than only the pre-existing ones: an INI document is
    /// not valid JSON either.
    @Test("the same ciphertext read back with format: .json also fails")
    func wrongFormatJSONFailsCleanly() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])

        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(encrypted, format: .json, agePrivateKey: owner.private)
        }
    }

    /// The addition and edit both target keys inside an existing section
    /// (`parent: ["db"]`), never the document root — `Engine/gobridge`'s F2
    /// task 1 pinned that a scalar `Add` at an INI document's root (`parent:
    /// []`) is refused with a clean error
    /// (`TestINIApplyChangesAddAtDocumentRootProducesCleanError`), because
    /// the INI store's root must stay a `TreeBranch` of sections. This test
    /// does not re-prove that refusal — it stays inside the shape every
    /// legitimate INI edit actually has.
    @Test("applyChanges adds, edits and removes a key within an existing section")
    func applyChangesAddEditRemove() throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .ini,
            changes: SecretChangeSet(
                sets: [SecretEdit(path: ["db", "url"], value: "postgres://y", kind: .string)],
                adds: [SecretAddition(parent: ["db"], key: "host", value: "localhost", kind: .string)],
                removes: [SecretRemoval(path: ["api", "key"])]),
            agePrivateKey: owner.private)

        let rows = try SopsBridge.decryptToRows(saved, format: .ini, agePrivateKey: owner.private)

        #expect(rows.first { $0.path == ["db", "url"] }?.value == "postgres://y")
        #expect(rows.first { $0.path == ["db", "host"] }?.value == "localhost")
        #expect(rows.first { $0.path == ["api", "key"] } == nil, "api.key should have been removed")
        // An untouched key in the edited section survives.
        #expect(rows.first { $0.path == ["db", "password"] }?.value == "secret")
    }

    @Test("recipients(in:) and updateRecipients round-trip an INI document")
    func recipientsAndUpdateRecipientsRoundTrip() throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])

        #expect(try SopsBridge.recipients(in: encrypted, format: .ini) == [owner.public])

        let rewrapped = try SopsBridge.updateRecipients(
            encrypted, format: .ini, to: [added.public], agePrivateKey: owner.private)

        #expect(try SopsBridge.recipients(in: rewrapped, format: .ini) == [added.public])

        // The new recipient can read it...
        let rows = try SopsBridge.decryptToRows(rewrapped, format: .ini, agePrivateKey: added.private)
        #expect(rows.first { $0.path == ["db", "url"] }?.value == "postgres://x")

        // ...and the original owner, having been dropped, can no longer.
        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(rewrapped, format: .ini, agePrivateKey: owner.private)
        }
    }
}
