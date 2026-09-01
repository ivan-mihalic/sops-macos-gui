import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects
import SopsHealth

/// A syntactically valid but obviously-fake age key body, distinctive enough
/// that its presence in any string is unambiguous — used by the
/// no-leak test below to prove no error message echoes back what was typed.
/// Shaped like a real identity: `age-keygen` emits exactly 74 characters, and
/// the body is Bech32 (`b`, `i`, `o` and `1` are not in that alphabet). The
/// previous fixture was 56 characters and contained a `B`, so it was not a
/// key shape at all — which is why it kept passing while `importKey` checked
/// nothing but the 16-character prefix. It decrypts nothing, and is not meant
/// to; these tests are about acceptance, never about decryption.
private let validKey = "AGE-SECRET-KEY-1Q8W4UR23CLXD5MZFSH79VN6PG0KAYTJEQ8W4UR23CLXD5MZFSH79VN6PG0"
private let distinctiveGarbage = "NOT-AN-AGE-KEY-XYZZY-PLUGH-QUUX-42"

/// The three line endings a real `keys.txt` might use: bare LF (the common
/// case), CRLF (Windows, or `git core.autocrlf=true`), and a lone CR. A
/// file-scope constant, not a member of the `@MainActor`-isolated test
/// suite below — `@Test(arguments:)` needs to evaluate this outside actor
/// isolation, at macro-expansion time.
private let lineEndings = ["\n", "\r\n", "\r"]

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

    // MARK: - Session public key (SOPS-38 phase F3)

    @Test("sessionPublicKey is nil before any key is imported")
    func sessionPublicKeyStartsNil() {
        let store = SessionKeyStore()
        #expect(store.sessionPublicKey == nil)
    }

    /// The whole point: a caller that only ever sees the private identity a
    /// user pasted in (`withKey`'s lend-for-one-call surface) can still learn
    /// the *public* key it corresponds to, so a file's own recipient metadata
    /// can be compared against it without ever decrypting anything.
    @Test("importing a real age identity exposes the public key it corresponds to")
    func importingARealKeyExposesItsPublicKey() throws {
        let pair = try AgeKeyPair.generate()
        let store = SessionKeyStore()

        try store.importKey(pair.private)

        #expect(store.sessionPublicKey == pair.public)
    }

    @Test("forget() clears the derived public key alongside the private one")
    func forgetClearsThePublicKeyToo() throws {
        let pair = try AgeKeyPair.generate()
        let store = SessionKeyStore()
        try store.importKey(pair.private)
        #expect(store.sessionPublicKey != nil)

        store.forget()

        #expect(store.sessionPublicKey == nil)
    }

    /// `validKey` above has the *shape* `looksLikeACompleteAgeKey` checks —
    /// length and Bech32 alphabet — but is not a real, checksummed age
    /// identity, so real derivation (`SopsBridge.agePublicKey`) fails on it.
    /// That must not make `importKey` itself fail: it never promised the key
    /// was genuine, only that it looked like one (see that function's own
    /// doc comment), and `validKeyIsAccepted` above already pins that this
    /// exact string is accepted. `sessionPublicKey` reporting `nil` here is
    /// the honest "not known" a caller must already handle — never mistaken
    /// for "this session has no key at all" (`state` still reports
    /// `.configured`) or for "every file is read-only" (list/editor callers
    /// treat a `nil` public key as unknown, not as a positive read-only
    /// verdict — see `FileListModelTests`/`SecretDocumentViewModelTests`).
    @Test("a shape-valid but non-genuine key imports normally with no derivable public key")
    func shapeValidNonGenuineKeyHasNoPublicKey() throws {
        let store = SessionKeyStore()
        try store.importKey(validKey)

        #expect(store.state == .configured)
        #expect(store.sessionPublicKey == nil)
    }

    // MARK: - TTL (ticket #4)

    /// A controllable clock, so expiry is provable without a test ever
    /// sleeping for real. `now` starts at an arbitrary fixed instant — not
    /// `Date()` at test-run time — so the test's own wall-clock speed can
    /// never make it flaky.
    private final class FakeClock {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { current }
        func advance(minutes: Int) { current = current.addingTimeInterval(Double(minutes) * 60) }
    }

    @Test("a key stays usable before its TTL elapses")
    func keyUsableBeforeTTLElapses() throws {
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(validKey)

        clock.advance(minutes: 14)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == validKey)
    }

    /// The defect this ticket exists to close: before this, nothing ever set
    /// `state` back to `.empty` on its own — only an explicit `forget()`
    /// call did. The deadline is compared against `now()` on every access
    /// rather than driven by a sleeping timer, precisely so this is correct
    /// even if the process was asleep for the entire interval — see the
    /// class doc comment.
    @Test("a key becomes unusable once its TTL has elapsed")
    func keyUnusableAfterTTLElapses() throws {
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(validKey)

        clock.advance(minutes: 15)

        #expect(store.state == .empty)
        #expect(store.withKey { $0 } == nil)
    }

    @Test("the derived public key expires alongside the private key")
    func sessionPublicKeyExpiresWithTTL() throws {
        let pair = try AgeKeyPair.generate()
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(pair.private)
        #expect(store.sessionPublicKey == pair.public)

        clock.advance(minutes: 15)

        #expect(store.sessionPublicKey == nil)
    }

    @Test("the async withKey overload also honours the TTL")
    func asyncWithKeyHonoursTTL() async throws {
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(validKey)

        clock.advance(minutes: 15)

        let result: String? = await store.withKey { $0 }
        #expect(result == nil)
    }

    /// The TTL is read once per import, not once per process — a value the
    /// user changes in Settings between one import and the next must take
    /// effect on the next import without a relaunch, the same "read live"
    /// discipline `UpdateCheckConsent` and the key store itself already
    /// follow elsewhere in this app.
    @Test("each import reads the TTL provider afresh")
    func ttlIsReadFreshOnEachImport() throws {
        let clock = FakeClock()
        var minutes = 5
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { minutes })

        try store.importKey(validKey)
        clock.advance(minutes: 5)
        #expect(store.state == .empty, "the first import's 5-minute TTL should have expired it")

        minutes = 60
        try store.importKey(validKey)
        clock.advance(minutes: 5)
        #expect(store.state == .configured, "the second import's 60-minute TTL should still be live")
    }

    /// Expiry is only ever *checked*, never driven by anything that runs on a
    /// timer — so it does not matter, for correctness, whether the clock's
    /// value jumped because of a real elapsed 20 minutes or because the
    /// machine spent those 20 minutes asleep and `now()` simply reports a
    /// later wall-clock time on the next call after waking. This test stands
    /// in for that: it advances the fake clock by more than the TTL in one
    /// jump, the way a wake-from-sleep would, with no intervening access.
    @Test("expiry is correct across a simulated system sleep, because it is never driven by a running timer")
    func expiryIsCorrectAcrossASimulatedSleep() throws {
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(validKey)

        // One jump, not a sequence of small advances — this is what
        // `Date()` does across real sleep: no calls happen while asleep, and
        // the next call simply reports a later time.
        clock.advance(minutes: 400)

        #expect(store.state == .empty)
        #expect(store.withKey { $0 } == nil)
    }

    @Test("forget() clears a not-yet-expired TTL along with the key")
    func forgetClearsTheDeadlineToo() throws {
        let clock = FakeClock()
        let store = SessionKeyStore(now: clock.now, ttlMinutes: { 15 })
        try store.importKey(validKey)

        store.forget()
        // A very large advance would expire the old deadline regardless —
        // this proves forget() actually cleared it rather than merely
        // leaving an already-expired-eventually deadline in place, by using
        // an advance smaller than the TTL and importing again.
        clock.advance(minutes: 1)
        try store.importKey(validKey)

        #expect(store.state == .configured)
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

    // MARK: - Line endings (CRLF regression)

    // Review finding: `Character` is an extended grapheme cluster, and CRLF
    // ("\r\n") is *one* such cluster, not two — splitting on the `Character`
    // "\n" alone never breaks a CRLF-encoded keys.txt into lines at all.
    // Reproduced by the reviewer two ways: an all-comment CRLF file with a
    // good key present was refused as `.empty` (the key was never separated
    // out of the single unsplit "line"), and a key-first CRLF file had its
    // key plus every following "\r\n#comment" line accepted as a single
    // AGE-SECRET-KEY-1…-prefixed blob and stored as "the key" — silently
    // defeating the multi-key refusal above, since nothing was ever split
    // into candidates to count. Same gotcha as Task 1b's
    // `String.contains("\nsops:")` blind spot against `"\r\nsops:"`.
    //
    // Each of the four shapes above (single key with comments, several
    // keys, comments only, blank lines only) is re-run under all three line
    // endings a real file might use — bare LF, CRLF, and a lone CR (see the
    // file-scope `lineEndings` constant above).

    @Test("a keys.txt with comments then one key imports correctly under any line ending",
          arguments: lineEndings)
    func singleKeyWithCommentsFirstImportsAcrossLineEndings(lineEnding: String) throws {
        let store = SessionKeyStore()
        let contents = [
            "# created: 2026-08-06T12:00:00Z",
            "# public key: age1exampleexampleexampleexampleexampleexampleexamplex",
            validKey,
        ].joined(separator: lineEnding)

        try store.importFromKeysFileContents(contents)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == validKey)
    }

    // The specific shape that broke under CRLF: the key comes *first*, with
    // a comment line trailing it. Before the fix, this stored the key with
    // the trailing "\r\n# comment..." text still glued onto it, because the
    // unsplit blob still satisfied `hasPrefix("AGE-SECRET-KEY-1")`.
    @Test("a keys.txt with one key then a comment imports just the key under any line ending",
          arguments: lineEndings)
    func singleKeyThenCommentImportsAcrossLineEndings(lineEnding: String) throws {
        let store = SessionKeyStore()
        let contents = [
            validKey,
            "# public key: age1exampleexampleexampleexampleexampleexampleexamplex",
        ].joined(separator: lineEnding)

        try store.importFromKeysFileContents(contents)

        #expect(store.state == .configured)
        // Must be exactly the key, with no trailing newline/comment text
        // riding along — the failure mode this test guards against stored
        // the whole multi-line blob as "the key".
        #expect(store.withKey { $0 } == validKey)
    }

    @Test("a keys.txt with several keys is refused under any line ending", arguments: lineEndings)
    func multipleKeysRefusedAcrossLineEndings(lineEnding: String) {
        let store = SessionKeyStore()
        let secondKey = "AGE-SECRET-KEY-1L5R8T2N6Q9V3X7Z1B4D8F0H2J6M9P3R5T8W0Y2A4C6E8"
        let contents = [
            "# personal", validKey, "# work", secondKey,
        ].joined(separator: lineEnding)

        #expect(throws: SessionKeyStore.Error.multipleKeysInFile(count: 2)) {
            try store.importFromKeysFileContents(contents)
        }
        #expect(store.state == .empty)
    }

    @Test("a comments-only keys.txt is refused as empty under any line ending", arguments: lineEndings)
    func commentsOnlyRefusedAcrossLineEndings(lineEnding: String) {
        let store = SessionKeyStore()
        let contents = [
            "# created: 2026-08-06T12:00:00Z",
            "# public key: age1exampleexampleexampleexampleexampleexampleexamplex",
        ].joined(separator: lineEnding)

        #expect(throws: SessionKeyStore.Error.empty) {
            try store.importFromKeysFileContents(contents)
        }
        #expect(store.state == .empty)
    }

    @Test("a keys.txt with only blank lines is refused as empty under any line ending", arguments: lineEndings)
    func blankLinesOnlyRefusedAcrossLineEndings(lineEnding: String) {
        let store = SessionKeyStore()
        let contents = ["", "", ""].joined(separator: lineEnding)

        #expect(throws: SessionKeyStore.Error.empty) {
            try store.importFromKeysFileContents(contents)
        }
        #expect(store.state == .empty)
    }

    @Test("importing from an actual keys.txt file on disk reads it and imports the one key")
    func importFromLegacyKeyFileReadsTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-key-store-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
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
    // uses) before and after a successful import. Safe to point at the real
    // location precisely because passing this test is what proves
    // `SessionKeyStore` never touches it; if it ever regressed to writing
    // there, this test would be the one polluting a real user's Application
    // Support directory, which is the point.
    //
    // **Contents, not the listing**, and the comment this replaces claimed
    // otherwise in as many words: "not just 'no obviously key-named file
    // appeared', but that this store wrote *nothing* there at all". It
    // compared `contentsOfDirectory` — file *names*. A regression that
    // appended the identity to the `projects.json` already sitting in that
    // directory changed no name, and the test stayed green while real age
    // private keys landed in a real user's Application Support. Demonstrated
    // by mutation, and it is the most valuable single guarantee in this type:
    // a persisted identity survives a restart, rides into iCloud and Time
    // Machine backups, and is the one thing ADR 0001 promises never happens.
    @Test("the key is never written to disk")
    func keyIsNeverWrittenToDisk() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = support.appendingPathComponent("cz.mihalic.SopsGUI", isDirectory: true)

        let before = Self.fingerprint(of: appDir)

        let store = SessionKeyStore()
        try store.importKey(validKey)
        #expect(store.state == .configured)
        store.forget()

        let after = Self.fingerprint(of: appDir)

        // Names only, never contents: a difference report must not print what
        // a leaked file now holds.
        #expect(before == after,
                Comment(rawValue: "SessionKeyStore must never write to the app's Application Support directory. "
                    + "Entries that differ: \(Self.differingNames(before, after).joined(separator: ", "))"))
    }

    /// Every file under `directory`, recursively, mapped to a hash of its
    /// contents. Absent directory is an empty map, which is the same answer
    /// before and after and so cannot mask a write.
    private static func fingerprint(of directory: URL) -> [String: Int] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Int] = [:]
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            result[url.path] = data.hashValue
        }
        return result
    }

    private static func differingNames(_ before: [String: Int], _ after: [String: Int]) -> [String] {
        let names = Set(before.keys).union(after.keys)
        return names.filter { before[$0] != after[$0] }.map { ($0 as NSString).lastPathComponent }.sorted()
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

/// A key the store accepts must at least have the shape of a key.
///
/// `importKey` checked the 16-character prefix and nothing else, so
/// `AGE-SECRET-KEY-1` plus anything — a truncated paste, a typo — was accepted,
/// `state` became `.configured`, and `SecurityPostureCheck` reported `.ok`:
/// "An age key is imported for this session." The user read an all-clear and
/// then failed to decrypt every file, because the real refusal came from the
/// Go bridge on each open.
@MainActor
@Suite("A key is accepted only if it has the shape of one")
struct SessionKeyStoreShapeTests {

    private let wellShaped = "AGE-SECRET-KEY-1Q8W4UR23CLXD5MZFSH79VN6PG0KAYTJEQ8W4UR23CLXD5MZFSH79VN6PG0"

    @Test("a truncated paste is refused rather than reported as configured")
    func truncatedKeyIsRefused() {
        let store = SessionKeyStore()
        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey("AGE-SECRET-KEY-1Q8W4UR23CLXD5MZ")
        }
        #expect(store.state == .empty)
    }

    @Test("the prefix alone is refused")
    func prefixAloneIsRefused() {
        let store = SessionKeyStore()
        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey("AGE-SECRET-KEY-1")
        }
    }

    /// `b`, `i`, `o` and `1` are deliberately absent from Bech32 because they
    /// are the characters people mistype. A key containing one is not a key.
    @Test("a body character outside the Bech32 alphabet is refused")
    func nonBech32BodyIsRefused() {
        let store = SessionKeyStore()
        var typo = Array(wellShaped)
        typo[20] = "B"
        #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try store.importKey(String(typo))
        }
    }

    /// The paste field's doc comment claimed it "always accepts exactly one
    /// key, by construction". It did not: trimming only touches the ends, so
    /// two keys separated by a newline both went to the bridge, routing around
    /// the refusal `importFromKeysFileContents` enforces.
    ///
    /// `.multipleLinesPasted`, not `.multipleKeysInFile`: the latter's message
    /// names a file and a count of keys, and on the paste path there is no file
    /// — see the case's own doc comment.
    @Test("two keys pasted together are refused, not silently both imported")
    func pastedKeysFileIsRefused() {
        let store = SessionKeyStore()
        #expect(throws: SessionKeyStore.Error.multipleLinesPasted) {
            try store.importKey(wellShaped + "\n" + wellShaped)
        }
        #expect(store.state == .empty)
    }

    /// The common shape by a mile: `age-keygen` prints the public key as a
    /// comment right beneath the private one, so selecting both is one careless
    /// drag. It used to be reported as "That file has 2 keys in it … trim the
    /// file to the one you want" — a file the user never touched, a comment
    /// counted as a key, and advice that fixes nothing.
    @Test("a key pasted with age-keygen's public-key comment is refused without inventing a second key")
    func pastedKeyWithCommentIsRefusedHonestly() {
        let store = SessionKeyStore()
        #expect(throws: SessionKeyStore.Error.multipleLinesPasted) {
            try store.importKey(wellShaped + "\n# public key: age1qqqq")
        }
    }

    /// The file path keeps its own case, and its count must be a count of
    /// *keys*. A stray non-comment word used to be reported as a second key.
    @Test("a keys.txt with one key and one line of noise does not claim two keys")
    func keysFileNoiseIsNotCountedAsAKey() {
        let store = SessionKeyStore()
        do {
            try store.importFromKeysFileContents("# created by age-keygen\n" + wellShaped + "\nnotes\n")
            Issue.record("expected a refusal")
        } catch SessionKeyStore.Error.unreadableKeysFile {
            // Correct: one key, plus content that is not a key. Reporting this
            // as "that file has 1 keys in it … trim it to the one you want"
            // named the right number and still described nothing.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// The count is only reported when it is a count of keys, and then it must
    /// be right.
    @Test("a keys.txt holding two real keys says so, with the right number")
    func twoKeysAreCountedAsTwo() {
        let store = SessionKeyStore()
        #expect(throws: SessionKeyStore.Error.multipleKeysInFile(count: 2)) {
            try store.importFromKeysFileContents("# two identities\n" + wellShaped + "\n" + wellShaped + "\n")
        }
    }

    @Test("a well-shaped key is still accepted")
    func wellShapedKeyIsAccepted() throws {
        let store = SessionKeyStore()
        try store.importKey(wellShaped)
        #expect(store.state == .configured)
    }
}
