import Foundation
import Testing
@testable import SopsProjects
import SopsHealth

/// A syntactically valid but obviously-fake age key body, distinctive enough
/// that its presence in any string is unambiguous — used by the
/// no-leak test below to prove no error message echoes back what was typed.
private let validKey = "AGE-SECRET-KEY-1QZ7X9K3M8V2N5P0R4T6W1Y8B3D9F2H5J7L0Q4S6U8W1Z3"
private let distinctiveGarbage = "NOT-AN-AGE-KEY-XYZZY-PLUGH-QUUX-42"

@Suite("SessionKeyStore")
@MainActor
struct SessionKeyStoreTests {

    // MARK: - Acceptance

    @Test("a valid AGE-SECRET-KEY-1 key is accepted and the store reports configured")
    func validKeyIsAccepted() throws {
        let store = SessionKeyStore()
        #expect(store.state == .empty)

        try store.importKey(validKey)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == validKey)
    }

    @Test("a key with surrounding whitespace or a trailing newline is accepted")
    func whitespaceAndNewlineAreTrimmed() throws {
        let store = SessionKeyStore()

        try store.importKey("  \(validKey)  \n")

        #expect(store.state == .configured)
        // The stored key is the trimmed form, not the raw paste — a
        // decryption call downstream must not have to re-trim.
        #expect(store.withKey { $0 } == validKey)
    }

    // MARK: - Refusal: wrong shape

    @Test("anything without the AGE-SECRET-KEY-1 prefix is refused")
    func wrongPrefixIsRefused() {
        let store = SessionKeyStore()

        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey("hunter2")
        }
        #expect(store.state == .empty)
    }

    // ADR 0001 / Engine/gobridge/bridge.go: an AGE-PLUGIN-… identity routes
    // to plugin.NewIdentity in sops, which executes an `age-plugin-*` binary
    // found on PATH. A well-formed plugin identity must be refused exactly
    // like any other non-AGE-SECRET-KEY-1 string, not treated as "close
    // enough" because it has its own recognizable age-ish shape.
    @Test("a well-formed AGE-PLUGIN- identity is refused, not treated as a valid age key")
    func agePluginIdentityIsRefused() {
        let store = SessionKeyStore()

        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey("AGE-PLUGIN-YUBIKEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ")
        }
        #expect(store.state == .empty)
    }

    @Test("an empty string is refused")
    func emptyStringIsRefused() {
        let store = SessionKeyStore()

        #expect(throws: SessionKeyStore.Error.empty) {
            try store.importKey("")
        }
        #expect(store.state == .empty)
    }

    @Test("a whitespace-only string is refused")
    func whitespaceOnlyStringIsRefused() {
        let store = SessionKeyStore()

        #expect(throws: SessionKeyStore.Error.empty) {
            try store.importKey("   \n\t  ")
        }
        #expect(store.state == .empty)
    }

    // A comment-only paste is what you get if someone selects only the
    // "# public key: age1…" line of a keys.txt by mistake. It is non-empty
    // text, so it must fail the prefix check, not the emptiness check — but
    // either way it must not be accepted.
    @Test("a comment-only string is refused")
    func commentOnlyStringIsRefused() {
        let store = SessionKeyStore()

        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey("# created: 2026-08-06\n# public key: age1exampleexampleexample")
        }
        #expect(store.state == .empty)
    }

    // MARK: - forget()

    @Test("forget() returns the store to empty")
    func forgetReturnsToEmpty() throws {
        let store = SessionKeyStore()
        try store.importKey(validKey)
        #expect(store.state == .configured)

        store.forget()

        #expect(store.state == .empty)
        #expect(store.withKey { $0 } == nil)
    }

    // MARK: - keys.txt import

    @Test("a keys.txt containing comments and one key imports correctly")
    func keysFileWithCommentsAndOneKeyImports() throws {
        let store = SessionKeyStore()
        let contents = """
        # created: 2026-08-06T12:00:00Z
        # public key: age1exampleexampleexampleexampleexampleexampleexamplex
        \(validKey)
        """

        try store.importFromKeysFileContents(contents)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == validKey)
    }

    // Decision (documented on `importFromKeysFileContents(_:)`): a file with
    // more than one candidate key is refused outright rather than this store
    // guessing which one the user meant (first line, last line, ...) —
    // guessing would silently discard a key the user may still need, with no
    // indication a choice was made at all. `.multipleKeysInFile(count:)`
    // reports how many were found so the caller can say so.
    @Test("a keys.txt containing several keys is refused, not silently resolved to one")
    func keysFileWithMultipleKeysIsRefused() {
        let store = SessionKeyStore()
        let secondKey = "AGE-SECRET-KEY-1L5R8T2N6Q9V3X7Z1B4D8F0H2J6M9P3R5T8W0Y2A4C6E8"
        let contents = """
        # personal
        \(validKey)
        # work
        \(secondKey)
        """

        #expect(throws: SessionKeyStore.Error.multipleKeysInFile(count: 2)) {
            try store.importFromKeysFileContents(contents)
        }
        // Nothing was adopted — neither key, not even the first one seen.
        #expect(store.state == .empty)
    }

    @Test("a keys.txt with only comments is refused as empty")
    func keysFileWithOnlyCommentsIsRefused() {
        let store = SessionKeyStore()
        let contents = """
        # created: 2026-08-06T12:00:00Z
        # public key: age1exampleexampleexampleexampleexampleexampleexamplex
        """

        #expect(throws: SessionKeyStore.Error.empty) {
            try store.importFromKeysFileContents(contents)
        }
        #expect(store.state == .empty)
    }

    @Test("importing from an actual keys.txt file on disk reads it and imports the one key")
    func importFromLegacyKeyFileReadsTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-key-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keysFile = dir.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n\(validKey)\n".write(to: keysFile, atomically: true, encoding: .utf8)

        let store = SessionKeyStore()
        try store.importFromLegacyKeyFile(at: keysFile.path)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == validKey)
    }

    // MARK: - Never written to disk

    // The whole point of "in memory for the session only" is that nothing
    // about the key ends up on disk. This scans the app's real Application
    // Support directory (the same location `ProjectStore.defaultFileURL`
    // uses) before and after a successful import and asserts the listing is
    // byte-for-byte unchanged — not just "no obviously key-named file
    // appeared", but that this store wrote *nothing* there at all. Safe to
    // point at the real location precisely because passing this test is what
    // proves `SessionKeyStore` never touches it; if it ever regressed to
    // writing there, this test would be the one polluting a real user's
    // Application Support directory, which is the point.
    @Test("the key is never written to disk")
    func keyIsNeverWrittenToDisk() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = support.appendingPathComponent("cz.mihalic.SopsGUI", isDirectory: true)

        let before = try? FileManager.default.contentsOfDirectory(atPath: appDir.path)

        let store = SessionKeyStore()
        try store.importKey(validKey)
        #expect(store.state == .configured)
        store.forget()

        let after = try? FileManager.default.contentsOfDirectory(atPath: appDir.path)

        #expect(before == after,
                "SessionKeyStore must never write to the app's Application Support directory; before=\(before ?? []) after=\(after ?? [])")
    }

    // MARK: - No secret in any error

    // The single most tempting place in this app to echo a secret back is a
    // key-import error message. Every `SessionKeyStore.Error` case carries
    // no associated text derived from the input — `.notAnAgeKey` and
    // `.empty` carry nothing at all, and `.multipleKeysInFile` carries only
    // a count — so there is no representation of any of them that could
    // possibly contain a fragment of what was typed. This proves that with a
    // distinctive, unmistakable garbage body: if this ever failed, it would
    // mean a case gained an associated value carrying raw input text.
    @Test("no error message contains any part of the supplied key")
    func noErrorMessageLeaksTheSuppliedKey() {
        let store = SessionKeyStore()

        do {
            try store.importKey(distinctiveGarbage)
            Issue.record("expected importKey to throw for garbage input")
        } catch {
            let described = String(describing: error)
            let localized = (error as NSError).localizedDescription
            #expect(!described.contains("XYZZY"))
            #expect(!described.contains(distinctiveGarbage))
            #expect(!localized.contains("XYZZY"))
            #expect(!localized.contains(distinctiveGarbage))
        }

        // Same proof against a second, differently-shaped distinctive
        // string — the case most tempting to echo "so the user can see
        // what they pasted".
        let distinctiveNonKey = "QWERTY-MARKER-77 NOT A REAL AGE KEY BODY 000111"
        do {
            try store.importKey(distinctiveNonKey)
            Issue.record("expected importKey to throw for a distinctive non-key string")
        } catch {
            let described = String(describing: error)
            #expect(!described.contains("QWERTY-MARKER-77"))
        }
    }
}
