import Foundation
import Testing

@testable import SopsEngine

// The gate ADR 0001 names in one sentence: *every file the app writes must
// round-trip with the standard `sops` CLI, including MAC and
// `encrypted_regex`.* M2 is the milestone where this app first writes to files
// a user cares about, so this suite is deliberately an end-to-end matrix
// driven by the real binaries rather than a unit test of any one layer.
//
// For each fixture the shape is always the same four steps:
//
//   1. encrypt with the real `sops` CLI
//   2. edit through the bridge
//   3. `sops --decrypt` the result — the edit landed, nothing else moved
//   4. re-encrypt with the CLI, and the bridge still reads it
//
// `Engine/gobridge/document_test.go` proves the same properties against the Go
// functions directly. What is new here is the whole stack at once: the C
// boundary, the Swift wrapper, and a `sops` binary that was never compiled
// into this process.
//
// Nothing in this file ever prints a decrypted value. Failure messages carry
// key names, line indices and counts — never the text of a value — because a
// test log is exactly the kind of artefact that ends up in a CI transcript.

// MARK: - The real binaries

private let sopsBinary = "/opt/homebrew/bin/sops"
private let ageKeygenBinary = "/opt/homebrew/bin/age-keygen"

/// Resolved once. A compatibility test that quietly passes on a machine with
/// no `sops` asserts nothing at all, so the suite skips with a stated reason
/// instead of degrading into a no-op.
private let realBinariesPresent: Bool = {
    let manager = FileManager.default
    return manager.isExecutableFile(atPath: sopsBinary)
        && manager.isExecutableFile(atPath: ageKeygenBinary)
}()

private let needsRealBinaries = Comment(
    rawValue: "requires the real sops and age-keygen binaries in /opt/homebrew/bin")

/// Drives the real `sops` binary.
///
/// Every invocation carries `--disable-version-check`: sops otherwise reaches
/// out to GitHub to compare its own version, and a test suite must not depend
/// on the network — nor generate traffic the sandbox work in M5 will have to
/// explain away.
private enum CLI {

    static func run(_ arguments: [String], identities: [AgeKeyPair]) throws -> String {
        // SOPS_AGE_KEY_FILE keeps the developer's own ~/.config/sops keys out
        // of the test. This is the *oracle* process, not app code — the app
        // itself never sets SOPS_AGE_KEY* (ADR 0001).
        let keyFile = try TempFile(
            named: "keys.txt",
            contents: identities.map(\.private).joined(separator: "\n") + "\n")
        return try Process.capture(
            sopsBinary, ["--disable-version-check"] + arguments,
            environment: ["SOPS_AGE_KEY_FILE": keyFile.path])
    }

    static func encrypt(
        _ plain: String, recipients: [AgeKeyPair], encryptedRegex: String?
    ) throws -> String {
        let file = try TempFile(named: "plain.yaml", contents: plain)
        var arguments = ["--encrypt", "--age", recipients.map(\.public).joined(separator: ",")]
        if let encryptedRegex { arguments += ["--encrypted-regex", encryptedRegex] }
        return try run(arguments + [file.path], identities: recipients)
    }

    /// `sops --decrypt` verifies the MAC and refuses the file when it does not
    /// match, so every successful return here *is* a MAC assertion. That the
    /// gate is live rather than assumed is proved by `theMACGateIsLive` below,
    /// which tampers with a file and watches this call fail.
    static func decrypt(
        _ encrypted: String, identities: [AgeKeyPair], ignoreMAC: Bool = false
    ) throws -> String {
        let file = try TempFile(named: "enc.yaml", contents: encrypted)
        return try run(
            ["--decrypt"] + (ignoreMAC ? ["--ignore-mac"] : []) + [file.path],
            identities: identities)
    }
}

// MARK: - Reading a document's shape without reading its values

private func lines(of text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// Everything above the `sops:` block — the document's own content.
private func bodyLines(of encrypted: String) throws -> [String] {
    let all = lines(of: encrypted)
    guard let start = all.firstIndex(of: "sops:") else {
        throw TestError("the encrypted file has no sops block")
    }
    return Array(all[..<start])
}

/// The `sops:` block itself: wrapped data keys, recipients, rules, metadata.
private func metadataLines(of encrypted: String) throws -> [String] {
    let all = lines(of: encrypted)
    guard let start = all.firstIndex(of: "sops:") else {
        throw TestError("the encrypted file has no sops block")
    }
    return Array(all[start...])
}

/// The recipients the file is readable by, in file order.
private func recipientLines(of encrypted: String) throws -> [String] {
    try metadataLines(of: encrypted)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("recipient:") }
}

private func encryptedRegexLine(of encrypted: String) throws -> String? {
    try metadataLines(of: encrypted)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("encrypted_regex:") }
}

/// The whole `sops:` block minus the two fields that legitimately move on
/// every save. What is left is the wrapped data keys, the recipient list, the
/// rules and the version — none of which a value edit may touch. Comparing it
/// byte for byte is how "the save did not re-wrap the data key" gets asserted
/// rather than assumed.
private func durableMetadataLines(of encrypted: String) throws -> [String] {
    try metadataLines(of: encrypted).filter {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("lastmodified:") && !trimmed.hasPrefix("mac:")
    }
}

private func commentLines(of text: String) -> [String] {
    lines(of: text)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("#") }
}

/// The document's outline: one entry per non-empty, non-comment line, carrying
/// the indentation and the key — or `-` for a bare list element — and never
/// the value. Two outlines being equal means no key was renamed, reordered,
/// re-indented or dropped, and comparing them can never put a decrypted value
/// into test output.
private func keyOutline(of text: String) -> [String] {
    var outline: [String] = []
    for line in lines(of: text) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let indent = String(line.prefix { $0 == " " })
        var body = trimmed
        var dash = ""
        if body == "-" {
            dash = "-"
            body = ""
        } else if body.hasPrefix("- ") {
            dash = "- "
            body = String(body.dropFirst(2))
        }
        if let colon = body.firstIndex(of: ":") {
            outline.append(indent + dash + body[..<colon] + ":")
        } else {
            // A bare list scalar or a block-scalar continuation: it has no key,
            // so all that is recorded is that a value-only line sits here.
            outline.append(indent + dash + "•")
        }
    }
    return outline
}

/// Indices where two line arrays differ. Returns `nil` when the arrays are not
/// even the same length, which is a different failure and deserves saying so.
private func changedLineIndices(_ before: [String], _ after: [String]) -> [Int]? {
    guard before.count == after.count else { return nil }
    return before.indices.filter { before[$0] != after[$0] }
}

// MARK: - The matrix

private struct Fixture: Sendable, CustomTestStringConvertible {
    let name: String
    let plaintext: String
    /// How many age recipients the file is encrypted to.
    let recipients: Int
    let encryptedRegex: String?
    /// The one value the editor changes.
    let edit: SecretEdit
    /// What the changed line must read, trimmed, in the decrypted file.
    let editedLine: String

    var testDescription: String { name }
}

private let plainYAMLFixture = """
    service: api
    db:
        host: localhost
        password: hunter2
    api_key: sk-live-abc123

    """

private let regexYAMLFixture = """
    service: api
    db:
        host: localhost
        password: hunter2
    api_key: sk-live-abc123
    token: t-abc

    """

private let commentedYAMLFixture = """
    # who this file belongs to
    metadata:
        # the owner is not a secret
        owner: platform
        nested:
            deeper:
                # three levels down
                value: kept
    db:
        host: localhost
        # rotate quarterly
        password: hunter2
        quoted_number: "5432"
        port: 5432
    # trailing note

    """

private let listYAMLFixture = """
    ports:
        - 8080
        - 8443
        - 9090
    servers:
        - name: alpha
          ip: 10.0.0.1
        - name: beta
          ip: 10.0.0.2
    tags:
        - production

    """

private let matrix: [Fixture] = [
    Fixture(
        name: "plain",
        plaintext: plainYAMLFixture,
        recipients: 1,
        encryptedRegex: nil,
        edit: SecretEdit(path: ["db", "password"], value: "rotated-plain", kind: .string),
        editedLine: "password: rotated-plain"),

    // The edited key here is one the regex does *not* match, so the save has to
    // leave it in cleartext — writing it back as ciphertext would be just as
    // wrong as the reverse, and only the file's own rule can decide.
    Fixture(
        name: "encrypted_regex",
        plaintext: regexYAMLFixture,
        recipients: 1,
        encryptedRegex: "^(password|api_key|token)$",
        edit: SecretEdit(path: ["db", "host"], value: "db.internal", kind: .string),
        editedLine: "host: db.internal"),

    Fixture(
        name: "three recipients",
        plaintext: plainYAMLFixture,
        recipients: 3,
        encryptedRegex: nil,
        edit: SecretEdit(path: ["api_key"], value: "sk-live-rotated", kind: .string),
        editedLine: "api_key: sk-live-rotated"),

    Fixture(
        name: "comments and nested maps",
        plaintext: commentedYAMLFixture,
        recipients: 1,
        encryptedRegex: nil,
        edit: SecretEdit(path: ["db", "password"], value: "rotated-commented", kind: .string),
        editedLine: "password: rotated-commented"),

    Fixture(
        name: "list values",
        plaintext: listYAMLFixture,
        recipients: 1,
        encryptedRegex: nil,
        edit: SecretEdit(path: ["servers", "1", "ip"], value: "10.0.0.9", kind: .string),
        editedLine: "ip: 10.0.0.9"),
]

@Suite("Everything the editor writes stays readable by the sops CLI")
struct EditorCompatibilityTests {

    @Test(
        "one edit round-trips through the real CLI with nothing else changed",
        .enabled(if: realBinariesPresent, needsRealBinaries),
        arguments: matrix)
    fileprivate func oneEditRoundTrips(fixture: Fixture) throws {
        let keys = try (0..<fixture.recipients).map { _ in try AgeKeyPair.generate() }

        // ---- 1. Encrypt with the real CLI. ------------------------------
        let encrypted = try CLI.encrypt(
            fixture.plaintext, recipients: keys, encryptedRegex: fixture.encryptedRegex)
        // A successful --decrypt is the MAC assertion; see CLI.decrypt.
        let before = try CLI.decrypt(encrypted, identities: keys)
        #expect(before == fixture.plaintext, "the CLI did not round-trip its own fixture")
        // And the bridge agrees about the starting document.
        let rowsBefore = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: keys[0].private)
        #expect(!rowsBefore.isEmpty)

        // ---- 2. Edit one value through the bridge. ----------------------
        let saved = try SopsBridge.applyEdits(
            encrypted, format: .yaml, edits: [fixture.edit], agePrivateKey: keys[0].private)

        // ---- 3. `sops --decrypt` the result. ----------------------------
        // Once per recipient, separately: a save that dropped a recipient
        // still decrypts for whoever performed it, and the owner finds out
        // months later. Each decrypt verifies the MAC again.
        var perRecipient: [String] = []
        for identity in keys {
            perRecipient.append(try CLI.decrypt(saved, identities: [identity]))
        }
        #expect(
            Set(perRecipient).count == 1,
            "the recipients no longer all see the same document")
        let after = try #require(perRecipient.first)

        // The edit landed, and it is the only line that moved.
        guard let changed = changedLineIndices(lines(of: before), lines(of: after)) else {
            Issue.record(
                "the decrypted line count changed: \(lines(of: before).count) -> \(lines(of: after).count)")
            return
        }
        #expect(changed.count == 1, "expected exactly one changed plaintext line, got \(changed.count)")
        if let index = changed.first {
            #expect(
                lines(of: after)[index].trimmingCharacters(in: .whitespaces) == fixture.editedLine,
                "the changed line is not the edit that was asked for")
        }

        // ---- Step 2 of the plan: what must not change. ------------------

        // Comments preserved.
        #expect(commentLines(of: after) == commentLines(of: before), "a comment changed or was dropped")

        // Key order preserved.
        #expect(keyOutline(of: after) == keyOutline(of: before), "the key outline changed")

        // Recipients unchanged, and the wrapped data keys with them — a save
        // must not re-wrap, which is `sops updatekeys`' job and nobody else's.
        #expect(try recipientLines(of: saved).count == fixture.recipients)
        #expect(try recipientLines(of: saved) == recipientLines(of: encrypted), "the recipients changed")
        #expect(
            try durableMetadataLines(of: saved) == durableMetadataLines(of: encrypted),
            "the sops block changed beyond lastmodified and mac")

        // encrypted_regex unchanged — present and identical where the fixture
        // has one, absent where it does not.
        #expect(try encryptedRegexLine(of: saved) == encryptedRegexLine(of: encrypted))
        if let regex = fixture.encryptedRegex {
            #expect(try encryptedRegexLine(of: saved) == "encrypted_regex: \(regex)")
        } else {
            #expect(try encryptedRegexLine(of: saved) == nil)
        }

        // Untouched values keep their **exact ciphertext**, not merely a
        // ciphertext that decrypts the same: exactly one line of the encrypted
        // body differs, so a one-value save is a two-line diff once
        // lastmodified and mac are counted.
        let bodyBefore = try bodyLines(of: encrypted)
        let bodyAfter = try bodyLines(of: saved)
        guard let ciphertextChanges = changedLineIndices(bodyBefore, bodyAfter) else {
            Issue.record(
                "the encrypted body's line count changed: \(bodyBefore.count) -> \(bodyAfter.count)")
            return
        }
        #expect(
            ciphertextChanges.count == 1,
            "expected exactly one changed line in the encrypted body, got \(ciphertextChanges.count)")
        if let index = ciphertextChanges.first {
            let key = String(fixture.edit.path.last ?? "")
            #expect(
                bodyAfter[index].trimmingCharacters(in: .whitespaces).hasPrefix(key + ":"),
                "the changed ciphertext line is not the edited key")
        }
        // The whole file therefore differs in the edited line plus sops's own
        // per-save metadata, and in nothing else. `lastmodified` is a
        // whole-second timestamp, so a save inside the same second leaves it
        // byte-identical — that is two changed lines rather than three, and
        // pinning the count at three would be a clock-dependent test.
        let wholeAfter = lines(of: saved)
        guard let wholeFile = changedLineIndices(lines(of: encrypted), wholeAfter) else {
            Issue.record("the encrypted file's line count changed")
            return
        }
        let editedKey = String(fixture.edit.path.last ?? "")
        for index in wholeFile {
            let trimmed = wholeAfter[index].trimmingCharacters(in: .whitespaces)
            #expect(
                ["\(editedKey):", "lastmodified:", "mac:"].contains(where: trimmed.hasPrefix),
                "a line nobody touched changed at index \(index)")
        }
        // The MAC is computed over the values, one of which changed, so it has
        // to move. A file whose MAC did *not* change after an edit is a file
        // the CLI will refuse.
        #expect(
            wholeFile.contains {
                wholeAfter[$0].trimmingCharacters(in: .whitespaces).hasPrefix("mac:")
            },
            "the MAC did not change across an edit")
        #expect(wholeFile.count <= 3, "expected at most a three-line file diff, got \(wholeFile.count)")

        // ---- 4. Re-encrypt with the CLI; the bridge still reads it. -----
        let reEncrypted = try CLI.encrypt(
            after, recipients: keys, encryptedRegex: fixture.encryptedRegex)
        #expect(try CLI.decrypt(reEncrypted, identities: keys) == after)

        let rowsFromOurSave = try SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: keys[0].private)
        let rowsFromTheCLI = try SopsBridge.decryptToRows(reEncrypted, format: .yaml, agePrivateKey: keys[0].private)
        #expect(
            rowsFromTheCLI == rowsFromOurSave,
            "the bridge reads its own save and the CLI's re-encryption differently")
        // The edit is visible through the bridge too, not only through the CLI.
        #expect(rowsFromOurSave.first { $0.path == fixture.edit.path }?.value == fixture.edit.value)
    }

    // MARK: The shape-changing path (Task 8b)

    @Test(
        "adding and removing map keys round-trips through the CLI",
        .enabled(if: realBinariesPresent, needsRealBinaries))
    func structuralSaveRoundTrips() throws {
        let keys = try (0..<2).map { _ in try AgeKeyPair.generate() }
        let encrypted = try CLI.encrypt(
            commentedYAMLFixture, recipients: keys, encryptedRegex: nil)
        let before = try CLI.decrypt(encrypted, identities: keys)

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(
                adds: [
                    SecretAddition(
                        parent: ["db"], key: "replica", value: "replica.internal", kind: .string)
                ],
                removes: [SecretRemoval(path: ["db", "quoted_number"])]),
            agePrivateKey: keys[0].private)

        // MAC verified, once per recipient.
        for identity in keys {
            #expect(try CLI.decrypt(saved, identities: [identity]) == CLI.decrypt(saved, identities: keys))
        }
        let after = try CLI.decrypt(saved, identities: keys)

        // The shape changed in exactly the two ways asked for.
        var expectedOutline = keyOutline(of: before).filter { $0 != "    quoted_number:" }
        expectedOutline.insert("    replica:", at: expectedOutline.firstIndex(of: "    port:")! + 1)
        #expect(keyOutline(of: after) == expectedOutline, "the outline changed beyond the add and the remove")

        // And nothing else did.
        #expect(commentLines(of: after) == commentLines(of: before), "a comment changed or was dropped")
        #expect(try recipientLines(of: saved) == recipientLines(of: encrypted), "the recipients changed")
        #expect(
            try durableMetadataLines(of: saved) == durableMetadataLines(of: encrypted),
            "the sops block changed beyond lastmodified and mac")

        // Untouched ciphertext is byte-identical across a structural save too:
        // the removed line disappears, the added line appears, and every
        // surviving line is the same bytes it was.
        let bodyBefore = try bodyLines(of: encrypted)
        let bodyAfter = try bodyLines(of: saved)
        let survivors = bodyBefore.filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("quoted_number:")
        }
        let stillThere = bodyAfter.filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("replica:")
        }
        #expect(survivors == stillThere, "a line nobody touched changed across a structural save")

        // The CLI can re-encrypt the result and the bridge still reads it.
        let reEncrypted = try CLI.encrypt(after, recipients: keys, encryptedRegex: nil)
        #expect(
            try SopsBridge.decryptToRows(reEncrypted, format: .yaml, agePrivateKey: keys[1].private)
                == SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: keys[1].private))
    }

    @Test(
        "removing a list element renumbers the rest and the CLI still reads the file",
        .enabled(if: realBinariesPresent, needsRealBinaries))
    func listRemovalRoundTrips() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try CLI.encrypt(listYAMLFixture, recipients: [key], encryptedRegex: nil)

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(removes: [SecretRemoval(path: ["ports", "0"])]),
            agePrivateKey: key.private)

        // MAC verified by the CLI, and the survivors kept their order.
        let after = try CLI.decrypt(saved, identities: [key])
        let rows = try SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: key.private)
        #expect(rows.filter { $0.path.first == "ports" }.map(\.value) == ["8443", "9090"])
        #expect(rows.filter { $0.path.first == "ports" }.map { $0.path[1] } == ["0", "1"])

        // The indices shifted, so the outline has one fewer list entry under
        // `ports` and is otherwise untouched.
        let before = try CLI.decrypt(encrypted, identities: [key])
        var expectedOutline = keyOutline(of: before)
        expectedOutline.remove(at: try #require(expectedOutline.firstIndex(of: "    - •")))
        #expect(keyOutline(of: after) == expectedOutline)

        // Byte-identical ciphertext for everything that survived.
        let bodyBefore = try bodyLines(of: encrypted)
        let bodyAfter = try bodyLines(of: saved)
        #expect(bodyBefore.count == bodyAfter.count + 1)
        #expect(bodyAfter.allSatisfy { bodyBefore.contains($0) }, "a surviving list line was re-encrypted")

        // Re-encrypted by the CLI, still ours to read.
        let reEncrypted = try CLI.encrypt(after, recipients: [key], encryptedRegex: nil)
        #expect(
            try SopsBridge.decryptToRows(reEncrypted, format: .yaml, agePrivateKey: key.private)
                == SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: key.private))
        #expect(try CLI.decrypt(reEncrypted, identities: [key]) == after)
    }

    @Test(
        "an added key's fate is decided by the file's own encrypted_regex, and the CLI agrees",
        .enabled(if: realBinariesPresent, needsRealBinaries))
    func additionFollowsTheFilesOwnRegex() throws {
        let key = try AgeKeyPair.generate()
        let regex = "^(password|api_key|token)$"
        let encrypted = try CLI.encrypt(
            regexYAMLFixture, recipients: [key], encryptedRegex: regex)

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(adds: [
                // Matches the rule: must land as ciphertext.
                SecretAddition(parent: ["db"], key: "token", value: "added-secret", kind: .string),
                // Does not match: must land in cleartext.
                SecretAddition(parent: ["db"], key: "region", value: "eu-central", kind: .string),
            ]),
            agePrivateKey: key.private)

        // The file itself, before anything decrypts it.
        #expect(!saved.contains("added-secret"), "a value the rule covers was written in cleartext")
        #expect(saved.contains("region: eu-central"), "a value the rule does not cover was encrypted")
        #expect(try encryptedRegexLine(of: saved) == "encrypted_regex: \(regex)")
        #expect(try recipientLines(of: saved) == recipientLines(of: encrypted))

        // The CLI reads it — MAC verified — and the bridge agrees about which
        // of the two new keys is actually protected.
        let after = try CLI.decrypt(saved, identities: [key])
        #expect(after.contains("token: added-secret"))
        #expect(after.contains("region: eu-central"))

        let rows = try SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: key.private)
        #expect(rows.first { $0.path == ["db", "token"] }?.isEncrypted == true)
        #expect(rows.first { $0.path == ["db", "region"] }?.isEncrypted == false)

        // Re-encrypted by the CLI under the same rule, still ours to read, and
        // the same rows come back.
        let reEncrypted = try CLI.encrypt(after, recipients: [key], encryptedRegex: regex)
        #expect(
            try SopsBridge.decryptToRows(reEncrypted, format: .yaml, agePrivateKey: key.private) == rows,
            "the bridge reads its own save and the CLI's re-encryption differently")
    }

    // MARK: The MAC gate

    @Test(
        "the MAC gate is live: a tampered file is refused by the CLI, not silently decrypted",
        .enabled(if: realBinariesPresent, needsRealBinaries))
    func theMACGateIsLive() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try CLI.encrypt(plainYAMLFixture, recipients: [key], encryptedRegex: nil)
        let saved = try SopsBridge.applyEdits(
            encrypted,
            format: .yaml, edits: [SecretEdit(path: ["db", "password"], value: "rotated-plain", kind: .string)],
            agePrivateKey: key.private)

        // Roll one value back to the ciphertext it had *before* the edit and
        // leave the new MAC in place. Every ciphertext still unwraps — sops
        // authenticates each value against its own key path, so a value put
        // back where it came from decrypts perfectly — but the file-level MAC
        // is computed over the values as a whole and no longer matches. That
        // is the shape a bad merge or a partial revert actually takes, and it
        // is precisely what the MAC exists to catch.
        var body = try bodyLines(of: saved)
        let original = try bodyLines(of: encrypted)
        try #require(body.count == original.count)
        let rolledBack = try #require(body.indices.first { body[$0] != original[$0] })
        body[rolledBack] = original[rolledBack]
        let tampered = (body + (try metadataLines(of: saved))).joined(separator: "\n")

        #expect(throws: (any Error).self) {
            try CLI.decrypt(tampered, identities: [key])
        }
        // And it is the MAC specifically doing the refusing: with the check
        // waived the very same bytes decrypt fine. Without this half, the
        // assertion above would also pass on a file that was merely unreadable.
        #expect(throws: Never.self) {
            try CLI.decrypt(tampered, identities: [key], ignoreMAC: true)
        }
        // Our own bridge refuses it too, rather than presenting a form the
        // user might save back over their file.
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decryptToRows(tampered, format: .yaml, agePrivateKey: key.private)
        }
    }
}
