import Foundation
import Testing

@testable import SopsEngine

/// One of everything the editor has to render without damaging it: a leading
/// comment, every scalar type, a string that is only a string because it is
/// quoted, a block scalar, a nested map, a list of maps, empty containers.
let richDocumentYAML = """
    # who this file belongs to
    db:
        # the host is not a secret
        host: localhost
        port: 5432
        password: hunter2
        enabled: true
        ratio: 0.75
        nothing: null
        created: 2024-01-02T03:04:05Z
        quoted_number: "5432"
        multiline: |
            line one
            line two
        special: 'value: with colon'
    api_key: sk-live-abc123
    servers:
        - name: alpha
          ip: 10.0.0.1
        - name: beta
          ip: 10.0.0.2
    empty_map: {}
    empty_list: []

    """

/// Fixtures come from the real binaries, never from a hand-written string the
/// implementer believed the tool would emit.
private func encryptWithCLI(
    _ plain: String, key: AgeKeyPair, extraArgs: [String] = []
) throws -> String {
    let file = try TempFile(named: "plain.yaml", contents: plain)
    return try SopsCLI.run(
        ["--encrypt", "--age", key.public] + extraArgs + [file.path], identity: key)
}

private func cliDecrypt(_ encrypted: String, key: AgeKeyPair) throws -> String {
    let file = try TempFile(named: "enc.yaml", contents: encrypted)
    return try SopsCLI.run(["--decrypt", file.path], identity: key)
}

private func row(_ rows: [SecretRow], _ path: String...) throws -> SecretRow {
    guard let found = rows.first(where: { $0.path == path }) else {
        throw TestError("no row at \(path); present: \(rows.map { $0.path.joined(separator: ".") })")
    }
    return found
}

@Suite("The document API, across the C boundary")
struct SopsDocumentTests {

    // MARK: Reading

    @Test("rows come back in the file's own order, with the file's own types")
    func rowsPreserveOrderAndTypes() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: key.private)

        #expect(
            rows.map { $0.path.joined(separator: ".") } == [
                "db.host", "db.port", "db.password", "db.enabled", "db.ratio",
                "db.nothing", "db.created", "db.quoted_number", "db.multiline", "db.special",
                "api_key",
                "servers.0.name", "servers.0.ip", "servers.1.name", "servers.1.ip",
                "empty_map", "empty_list",
            ])

        #expect(try row(rows, "db", "port").kind == .int)
        #expect(try row(rows, "db", "port").value == "5432")
        #expect(try row(rows, "db", "quoted_number").kind == .string)
        #expect(try row(rows, "db", "enabled").kind == .bool)
        #expect(try row(rows, "db", "ratio").kind == .float)
        #expect(try row(rows, "db", "nothing").kind == .null)
        #expect(try row(rows, "db", "created").kind == .timestamp)
        #expect(try row(rows, "db", "multiline").value == "line one\nline two\n")
        #expect(try row(rows, "empty_map").kind == .emptyMap)
        #expect(try row(rows, "empty_list").kind == .emptyList)
    }

    @Test("rows say which values are ciphertext on disk, so masking is not guesswork")
    func rowsReportEncryptedness() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            richDocumentYAML, key: key, extraArgs: ["--encrypted-regex", "^(password|api_key)$"])

        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: key.private)

        #expect(try row(rows, "db", "password").isEncrypted)
        #expect(try row(rows, "api_key").isEncrypted)
        #expect(try !row(rows, "db", "host").isEncrypted)
    }

    @Test("a document whose only content is the sops block has no rows and is not an error")
    func sopsBlockOnlyDocument() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI("{}\n", key: key)

        #expect(try SopsBridge.decryptToRows(encrypted, agePrivateKey: key.private).isEmpty)
    }

    @Test("rows are identifiable and stable across a reload")
    func rowIdentityIsStable() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let first = try SopsBridge.decryptToRows(encrypted, agePrivateKey: key.private)
        let second = try SopsBridge.decryptToRows(encrypted, agePrivateKey: key.private)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count, "row ids must be unique")
        #expect(first == second)
    }

    // MARK: The identity guard

    @Test("reading without a supplied identity is refused, not filled in from the environment")
    func readingRefusesAnEmptyKey() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        for keyArgument in ["", "   ", "# exported\n", key.public] {
            #expect(throws: SopsBridgeError.self) {
                try SopsBridge.decryptToRows(encrypted, agePrivateKey: keyArgument)
            }
        }
    }

    @Test("saving without a supplied identity is refused")
    func savingRefusesAnEmptyKey() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)
        let edit = SecretEdit(path: ["db", "host"], value: "elsewhere", kind: .string)

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.applyEdits(encrypted, edits: [edit], agePrivateKey: "")
        }
    }

    @Test("an unrelated identity fails rather than returning an empty form")
    func unrelatedIdentityFails() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: owner)

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decryptToRows(encrypted, agePrivateKey: stranger.private)
        }
    }

    // MARK: Writing — the round trip that matters

    @Test("an edit lands and nothing else in the file changes")
    func editChangesOnlyWhatWasEdited() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let before = try cliDecrypt(encrypted, key: key)
        let edited = try SopsBridge.applyEdits(
            encrypted,
            edits: [SecretEdit(path: ["db", "password"], value: "correct horse", kind: .string)],
            agePrivateKey: key.private)
        let after = try cliDecrypt(edited, key: key)

        let beforeLines = before.components(separatedBy: "\n")
        let afterLines = after.components(separatedBy: "\n")
        #expect(beforeLines.count == afterLines.count)

        let changed = zip(beforeLines, afterLines).enumerated()
            .filter { $0.element.0 != $0.element.1 }
        #expect(changed.count == 1, "expected one changed line, got \(changed.map(\.element))")
        #expect(changed.first?.element.1.trimmingCharacters(in: .whitespaces)
            == "password: correct horse")

        // The comments are the canary: a YAML re-emitter would have eaten them.
        #expect(after.contains("# who this file belongs to"))
        #expect(after.contains("# the host is not a secret"))
    }

    @Test("the sops CLI decrypts what the editor wrote, and the new value is not in plaintext")
    func cliReadsWhatWeWrote() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let edited = try SopsBridge.applyEdits(
            encrypted,
            edits: [SecretEdit(path: ["api_key"], value: "sk-live-rotated", kind: .string)],
            agePrivateKey: key.private)

        #expect(try cliDecrypt(edited, key: key).contains("api_key: sk-live-rotated"))
        #expect(!edited.contains("sk-live-rotated"))
    }

    @Test("a save keeps the file's own recipients rather than any config's")
    func saveKeepsTheFilesOwnRecipients() throws {
        let owner = try AgeKeyPair.generate()
        let colleague = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            richDocumentYAML, key: owner,
            extraArgs: [
                "--age", "\(owner.public),\(colleague.public)",
                "--encrypted-regex", "^(password|api_key)$",
            ])

        let edited = try SopsBridge.applyEdits(
            encrypted,
            edits: [SecretEdit(path: ["db", "password"], value: "rotated", kind: .string)],
            agePrivateKey: owner.private)

        #expect(edited.contains(owner.public))
        #expect(edited.contains(colleague.public))
        #expect(edited.contains("encrypted_regex: ^(password|api_key)$"))
        // The colleague must still be able to read it.
        #expect(try cliDecrypt(edited, key: colleague).contains("password: rotated"))
    }

    @Test("editing a non-string scalar keeps its type through the CLI")
    func nonStringScalarsKeepTheirType() throws {
        let cases: [(String, SecretRow.Kind, String, String)] = [
            ("port", .int, "6543", "port: 6543"),
            ("ratio", .float, "0.5", "ratio: 0.5"),
            ("enabled", .bool, "false", "enabled: false"),
            ("created", .timestamp, "2030-12-25T10:00:00Z", "created: 2030-12-25T10:00:00Z"),
            ("quoted_number", .string, "9999", "quoted_number: \"9999\""),
        ]
        for (leaf, kind, value, wantLine) in cases {
            let key = try AgeKeyPair.generate()
            let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

            let edited = try SopsBridge.applyEdits(
                encrypted,
                edits: [SecretEdit(path: ["db", leaf], value: value, kind: kind)],
                agePrivateKey: key.private)

            #expect(try cliDecrypt(edited, key: key).contains(wantLine), "for \(leaf)")

            let rows = try SopsBridge.decryptToRows(edited, agePrivateKey: key.private)
            #expect(try row(rows, "db", leaf).kind == kind, "for \(leaf)")
            #expect(try row(rows, "db", leaf).value == value, "for \(leaf)")
        }
    }

    @Test("editing through nested maps and list indices reaches the right value")
    func nestedPathsResolve() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let edited = try SopsBridge.applyEdits(
            encrypted,
            edits: [SecretEdit(path: ["servers", "1", "ip"], value: "10.0.0.99", kind: .string)],
            agePrivateKey: key.private)

        let out = try cliDecrypt(edited, key: key)
        #expect(out.contains("ip: 10.0.0.99"))
        #expect(out.contains("ip: 10.0.0.1"), "the sibling list element was disturbed")
        #expect(out.contains("name: beta"))
    }

    @Test("both sides of an encrypted_regex stay on their own side after an edit")
    func encryptedRegexSidesAreKept() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            richDocumentYAML, key: key, extraArgs: ["--encrypted-regex", "^(password|api_key)$"])

        let edited = try SopsBridge.applyEdits(
            encrypted,
            edits: [
                SecretEdit(path: ["db", "password"], value: "new-secret-value", kind: .string),
                SecretEdit(path: ["db", "host"], value: "new-public-host", kind: .string),
            ],
            agePrivateKey: key.private)

        #expect(!edited.contains("new-secret-value"), "a secret was written in plaintext")
        #expect(edited.contains("host: new-public-host"), "a plaintext value was encrypted")
    }

    @Test("values YAML would want to quote survive a round trip exactly")
    func quotingHostileValuesSurvive() throws {
        for value in [
            "line one\nline two\n", "#not a comment", "true", "null", "0755",
            "padded ", "key: value", "příliš žluťoučký kůň 🐴", "a\tb", "",
        ] {
            let key = try AgeKeyPair.generate()
            let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

            let edited = try SopsBridge.applyEdits(
                encrypted,
                edits: [SecretEdit(path: ["db", "password"], value: value, kind: .string)],
                agePrivateKey: key.private)

            // The CLI must accept the result, and it must read back identically.
            _ = try cliDecrypt(edited, key: key)
            let rows = try SopsBridge.decryptToRows(edited, agePrivateKey: key.private)
            #expect(try row(rows, "db", "password").value == value)
        }
    }

    @Test("saving with no edits rewrites only the timestamp and the MAC")
    func noEditsRewritesAlmostNothing() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            richDocumentYAML, key: key, extraArgs: ["--encrypted-regex", "^(password|api_key)$"])

        let saved = try SopsBridge.applyEdits(encrypted, edits: [], agePrivateKey: key.private)

        let beforeLines = encrypted.components(separatedBy: "\n")
        let afterLines = saved.components(separatedBy: "\n")
        #expect(beforeLines.count == afterLines.count)
        for (before, after) in zip(beforeLines, afterLines) where before != after {
            let field = before.trimmingCharacters(in: .whitespaces)
            #expect(
                field.hasPrefix("lastmodified:") || field.hasPrefix("mac:"),
                "a line other than lastmodified/mac changed:\n  \(before)\n  \(after)")
        }
    }

    // MARK: Refusals

    @Test("an edit the document cannot accept is refused, never guessed at")
    func impossibleEditsAreRefused() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)

        let refusals: [SecretEdit] = [
            SecretEdit(path: ["db", "nonexistent"], value: "x", kind: .string),
            SecretEdit(path: ["db", "host", "deeper"], value: "x", kind: .string),
            SecretEdit(path: ["servers", "9", "ip"], value: "x", kind: .string),
            SecretEdit(path: [], value: "x", kind: .string),
            SecretEdit(path: ["db"], value: "x", kind: .string),
            SecretEdit(path: ["empty_map"], value: "x", kind: .string),
            SecretEdit(path: ["db", "port"], value: "not a number", kind: .int),
            SecretEdit(path: ["db", "enabled"], value: "perhaps", kind: .bool),
            SecretEdit(path: ["db", "created"], value: "yesterday", kind: .timestamp),
        ]
        for edit in refusals {
            #expect(throws: SopsBridgeError.self, "for \(edit.path)") {
                try SopsBridge.applyEdits(encrypted, edits: [edit], agePrivateKey: key.private)
            }
        }
    }

    @Test("no error string ever contains the value the user typed")
    func errorsNeverCarryAValue() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)
        let secretish = "hunter2-correct-horse-battery-staple"

        let failing: [SecretEdit] = [
            SecretEdit(path: ["db", "port"], value: secretish, kind: .int),
            SecretEdit(path: ["db", "nonexistent"], value: secretish, kind: .string),
            SecretEdit(path: ["db"], value: secretish, kind: .string),
        ]
        for edit in failing {
            do {
                _ = try SopsBridge.applyEdits(
                    encrypted, edits: [edit], agePrivateKey: key.private)
                Issue.record("expected a refusal for \(edit.path)")
            } catch let error as SopsBridgeError {
                #expect(!error.description.contains(secretish), "\(error.description)")
                if let last = edit.path.last {
                    #expect(error.description.contains(last), "\(error.description)")
                }
            }
        }
    }

    @Test("a tampered document is rejected rather than partly read")
    func tamperedDocumentIsRejected() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(richDocumentYAML, key: key)
        let tampered = encrypted.replacingOccurrences(of: "port: ENC[", with: "porx: ENC[")

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decryptToRows(tampered, agePrivateKey: key.private)
        }
    }

    // MARK: Repeated use

    @Test("repeated edit round trips are stable and never leak plaintext into the file")
    func repeatedRoundTripsAreStable() throws {
        let key = try AgeKeyPair.generate()
        var current = try encryptWithCLI(richDocumentYAML, key: key)

        for iteration in 0..<10 {
            let value = "rotated-\(iteration)"
            current = try SopsBridge.applyEdits(
                current,
                edits: [SecretEdit(path: ["db", "password"], value: value, kind: .string)],
                agePrivateKey: key.private)
            #expect(!current.contains(value))

            let rows = try SopsBridge.decryptToRows(current, agePrivateKey: key.private)
            #expect(try row(rows, "db", "password").value == value)
            #expect(try row(rows, "db", "port").kind == .int)
        }
        #expect(try cliDecrypt(current, key: key).contains("# who this file belongs to"))
    }
}
