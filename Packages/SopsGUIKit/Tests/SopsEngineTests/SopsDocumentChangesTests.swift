import Foundation
import ScratchCleanup
import Testing

@testable import SopsEngine

// The structural half of the document API, through the C boundary and the
// Swift wrapper — `sops_apply_changes`, not the Go function behind it.
// `Engine/gobridge/documentchanges_test.go` covers the semantics; what these
// tests are for is the boundary: that the change set encodes, that a refusal
// arrives as a `SopsBridgeError` the UI can render, and that no value ever
// rides along with one.

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

private let structuralYAML = """
    service: api
    ports:
        - 8080
        - 8443
        - 9090
    db:
        host: localhost
        password: hunter2
    empty_map: {}

    """

@Suite("Adding and removing keys, across the C boundary")
struct SopsDocumentChangesTests {

    @Test("one save adds a key, removes another and edits a third")
    func addRemoveAndEditInOneSave() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(
                sets: [SecretEdit(path: ["service"], value: "api-v2", kind: .string)],
                adds: [
                    SecretAddition(parent: ["db"], key: "replica", value: "replica.internal", kind: .string)
                ],
                removes: [SecretRemoval(path: ["db", "password"])]),
            agePrivateKey: key.private)

        let plain = try cliDecrypt(saved, key: key)
        #expect(plain.contains("service: api-v2"))
        #expect(plain.contains("replica: replica.internal"))
        #expect(!plain.contains("password"))
        #expect(plain.contains("host: localhost"))
        #expect(plain.contains("- 8443"))
        #expect(plain.contains("empty_map: {}"))
    }

    @Test("a list entry is appended, and the rows come back renumbered after a removal")
    func listEntriesAppendAndRenumber() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        let appended = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(adds: [SecretAddition(parent: ["ports"], value: "9443", kind: .int)]),
            agePrivateKey: key.private)
        var rows = try SopsBridge.decryptToRows(appended, format: .yaml, agePrivateKey: key.private)
        #expect(try row(rows, "ports", "3").value == "9443")
        #expect(try row(rows, "ports", "3").kind == .int)

        let removed = try SopsBridge.applyChanges(
            appended,
            format: .yaml, changes: SecretChangeSet(removes: [SecretRemoval(path: ["ports", "0"])]),
            agePrivateKey: key.private)
        rows = try SopsBridge.decryptToRows(removed, format: .yaml, agePrivateKey: key.private)
        #expect(rows.filter { $0.path.first == "ports" }.map(\.value) == ["8443", "9090", "9443"])
    }

    @Test("a row says whether its container is a list, which no path can tell you")
    func rowsReportTheirContainer() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            "lookalike:\n    \"0\": zero\nreal:\n    - first\n", key: key)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: key.private)

        #expect(try !row(rows, "lookalike", "0").isInList)
        #expect(try row(rows, "real", "0").isInList)
    }

    @Test("a batch whose list indices could be read two ways is refused, naming both paths")
    func anAmbiguousBatchIsRefused() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.applyChanges(
                encrypted,
                format: .yaml, changes: SecretChangeSet(
                    sets: [SecretEdit(path: ["ports", "2"], value: "9091", kind: .int)],
                    removes: [SecretRemoval(path: ["ports", "1"])]),
                agePrivateKey: key.private)
        }

        do {
            _ = try SopsBridge.applyChanges(
                encrypted,
                format: .yaml, changes: SecretChangeSet(
                    sets: [SecretEdit(path: ["ports", "2"], value: "9091", kind: .int)],
                    removes: [SecretRemoval(path: ["ports", "1"])]),
                agePrivateKey: key.private)
            Issue.record("the ambiguous batch was accepted")
        } catch let error as SopsBridgeError {
            #expect(error.description.contains("ports.1"), Comment(rawValue: error.description))
            #expect(error.description.contains("ports.2"), Comment(rawValue: error.description))
        }
    }

    @Test("a removal that finds nothing fails the save rather than reporting success")
    func aMissingRemovalIsAnError() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        do {
            _ = try SopsBridge.applyChanges(
                encrypted,
                format: .yaml, changes: SecretChangeSet(removes: [SecretRemoval(path: ["db", "nope"])]),
                agePrivateKey: key.private)
            Issue.record("removing a key that is not there was reported as a success")
        } catch let error as SopsBridgeError {
            #expect(error.description.contains("db.nope"), Comment(rawValue: error.description))
        }
    }

    @Test("a key that is already there cannot be added again")
    func aDuplicateKeyIsRefused() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        do {
            _ = try SopsBridge.applyChanges(
                encrypted,
                format: .yaml, changes: SecretChangeSet(
                    adds: [SecretAddition(parent: ["db"], key: "host", value: "elsewhere", kind: .string)]),
                agePrivateKey: key.private)
            Issue.record("a duplicate key was added")
        } catch let error as SopsBridgeError {
            #expect(error.description.contains("db.host"), Comment(rawValue: error.description))
            #expect(!error.description.contains("elsewhere"))
        }
    }

    @Test("a new key named as YAML's merge key is refused at the boundary")
    func theMergeKeyNameIsRefused() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        do {
            _ = try SopsBridge.applyChanges(
                encrypted,
                format: .yaml, changes: SecretChangeSet(adds: [
                    SecretAddition(parent: ["db"], key: "<<", value: "anything", kind: .string)
                ]),
                agePrivateKey: key.private)
            Issue.record("a key named << was added; the file it produces cannot be read back at all")
        } catch let error as SopsBridgeError {
            #expect(error.description.contains("<<"), Comment(rawValue: error.description))
            #expect(!error.description.contains("anything"))
        }
    }

    @Test("a key removed and added again in one save is a replacement, not a conflict")
    func aKeyCanBeReplacedInOneSave() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(
                adds: [SecretAddition(parent: ["db"], key: "host", value: "5432", kind: .int)],
                removes: [SecretRemoval(path: ["db", "host"])]),
            agePrivateKey: key.private)

        let rows = try SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: key.private)
        #expect(rows.filter { $0.path == ["db", "host"] }.count == 1)
        #expect(try row(rows, "db", "host").kind == .int)
        #expect(try cliDecrypt(saved, key: key).contains("host: 5432"))
    }

    @Test("the set-only entry point is unchanged")
    func applyEditsStillWorks() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        let saved = try SopsBridge.applyEdits(
            encrypted,
            format: .yaml, edits: [SecretEdit(path: ["db", "password"], value: "rotated", kind: .string)],
            agePrivateKey: key.private)
        #expect(try cliDecrypt(saved, key: key).contains("password: rotated"))
    }

    @Test("an added value is encrypted by the file's own rules, not by the caller's wish")
    func addedValuesFollowTheFilesRules() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(
            structuralYAML, key: key, extraArgs: ["--encrypted-regex", "^(password|token)$"])

        let saved = try SopsBridge.applyChanges(
            encrypted,
            format: .yaml, changes: SecretChangeSet(adds: [
                SecretAddition(parent: ["db"], key: "token", value: "t-123", kind: .string),
                SecretAddition(parent: ["db"], key: "region", value: "eu", kind: .string),
            ]),
            agePrivateKey: key.private)

        #expect(!saved.contains("t-123"))
        #expect(saved.contains("region: eu"))
        let rows = try SopsBridge.decryptToRows(saved, format: .yaml, agePrivateKey: key.private)
        #expect(try row(rows, "db", "token").isEncrypted)
        #expect(try !row(rows, "db", "region").isEncrypted)
    }

    @Test("a change set is refused before the identity is even considered valid")
    func anEmptyIdentityIsRefused() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        for bad in ["", "   ", "# comment only\n", key.public] {
            #expect(throws: SopsBridgeError.self) {
                try SopsBridge.applyChanges(
                    encrypted,
                    format: .yaml, changes: SecretChangeSet(removes: [SecretRemoval(path: ["service"])]),
                    agePrivateKey: bad)
            }
        }
    }
}

@Suite("Structural refusals never carry a value")
struct DocumentChangeHygieneTests {

    private static let canary = "STRUCTURALCANARY7777"

    /// Both the rendered error and `stderr` — the stream a crash reporter and
    /// the unified log collect — are checked, for the reason Task 7's own
    /// hygiene tests give: a clean return value is only half the property.
    @Test("no refusal on the add/remove paths carries the value or the document")
    func refusalsCarryNoValue() throws {
        let key = try AgeKeyPair.generate()
        let encrypted = try encryptWithCLI(structuralYAML, key: key)

        let refused: [SecretChangeSet] = [
            SecretChangeSet(adds: [
                SecretAddition(parent: ["db"], key: "host", value: Self.canary, kind: .string)
            ]),
            SecretChangeSet(adds: [
                SecretAddition(parent: ["nope"], key: "k", value: Self.canary, kind: .string)
            ]),
            SecretChangeSet(adds: [
                SecretAddition(parent: ["db"], key: "count", value: Self.canary, kind: .int)
            ]),
            SecretChangeSet(
                sets: [SecretEdit(path: ["service"], value: Self.canary, kind: .string)],
                removes: [SecretRemoval(path: ["db", "nope"])]),
            SecretChangeSet(
                sets: [SecretEdit(path: ["ports", "2"], value: Self.canary, kind: .int)],
                removes: [SecretRemoval(path: ["ports", "1"])]),
        ]

        for changes in refused {
            let (message, stderrText) = try capturingStandardError { () -> String in
                do {
                    _ = try SopsBridge.applyChanges(
                        encrypted, format: .yaml, changes: changes, agePrivateKey: key.private)
                    return ""
                } catch let error as SopsBridgeError {
                    return error.description
                } catch {
                    return "\(error)"
                }
            }
            #expect(!message.isEmpty, "the change set was accepted")
            #expect(!message.contains(Self.canary), Comment(rawValue: message))
            #expect(!message.contains("hunter2"), Comment(rawValue: message))
            #expect(!stderrText.contains(Self.canary), Comment(rawValue: stderrText))
            #expect(!stderrText.contains("hunter2"), Comment(rawValue: stderrText))
        }
    }
}

/// Duplicate of `SopsDocumentTests`' own helper — see its doc comment. Kept
/// local rather than shared so the two suites cannot break each other's
/// `stderr` redirection by sharing state across parallel execution.
private func capturingStandardError<R>(_ body: () throws -> R) throws -> (R, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("stderr-\(UUID().uuidString).log")
        .registeredForCleanup()
        .path
    FileManager.default.createFile(atPath: path, contents: nil)

    let captured = open(path, O_WRONLY)
    #expect(captured >= 0)
    let saved = dup(2)
    #expect(saved >= 0)
    dup2(captured, 2)

    defer {
        fflush(stderr)
        dup2(saved, 2)
        close(saved)
        close(captured)
    }

    let result = try body()
    fflush(stderr)
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return (result, text)
}
