import Foundation
import ScratchCleanup
import SopsProjects
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// Real temporary project roots and a real `.sops.yaml` through the real
// bridge (`CreationPlanResolver` -> `SopsBridge.lookupCreationRule`), never a
// constructed `CreationPlan` — the same discipline `CreationPlanResolverTests`
// holds `CreationPlanResolver` itself to. `AgeKeyPair`/`scratchDirectory` are
// redeclared here rather than imported: `ProjectRecipientApplierTests
// .swift`'s `applierScratchDirectory`/`AgeKeyPair` live in `SopsProjectsTests`,
// a different test target, and every existing `SopsUITests` file that needs
// this shape (`NewSecretFileModelTests.swift`, `RecipientAccessTests.swift`,
// `RecipientPickerTests.swift`, ...) already keeps its own file-private copy
// rather than reaching across targets for it.

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func toolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .map { ($0 as NSString).appendingPathComponent(name) }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw FixtureError("\(name) not found in \(candidates)")
    }
    return found
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError(
            "\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: outData, as: UTF8.self)
}

private struct AgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> AgeKeyPair {
        let output = try run(try toolPath("age-keygen"), [])
        var priv = "", pub = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw FixtureError("age-keygen produced no usable key pair")
        }
        return AgeKeyPair(private: priv, public: pub)
    }
}

private func scratchDirectory(_ label: String = "file-list-config-state") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeConfig(_ text: String, in root: URL) throws {
    try text.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
}

/// Five fixtures, one per `CreationPlan` case `FileListModel.configState`
/// must be able to report, all resolved against a probe in the project root
/// rather than a real target file — the same substitution `configState`'s
/// own doc comment describes. `path_regex: .*` is used wherever the test
/// wants the rule to reach the probe (case names would make this test depend
/// on `FileListModel`'s private probe filename, which it deliberately
/// does not know); `path_regex: ^secrets/` is used for the one fixture that
/// specifically wants the probe to miss.
@Suite("FileListModel.configState")
@MainActor
struct FileListModelConfigStateTests {

    @Test("configState is nil before the first refresh()")
    func nilBeforeFirstRefresh() throws {
        let model = FileListModel(projectRoot: try scratchDirectory())
        #expect(model.configState == nil)
    }

    @Test("no .sops.yaml at all resolves to .noConfig")
    func noConfigFixture() async throws {
        let root = try scratchDirectory()

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.configState == .noConfig)
    }

    @Test("an age rule reaching the whole project root governs the probe")
    func governedByRuleFixture() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try writeConfig(
            """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """, in: root)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.configState == .governedByRule(recipients: [owner.public], encryptedRegex: ""))
    }

    /// The load-bearing case: a rule scoped to `secrets/` never reaches a
    /// probe sitting at the project root, so this must come back
    /// `.noRuleMatched` — not `.noConfig`. `.sops.yaml` exists and parses; it
    /// simply has nothing to say about *this* location, which is exactly the
    /// distinction `configState`'s doc comment insists a renderer must not
    /// collapse.
    @Test("a rule scoped under secrets/ does not reach the root probe: .noRuleMatched, not .noConfig")
    func noRuleMatchedFixture() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try writeConfig(
            """
            creation_rules:
              - path_regex: ^secrets/
                age: \(owner.public)
            """, in: root)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.configState == .noRuleMatched)
    }

    @Test("malformed YAML resolves to .configUnreadable")
    func configUnreadableFixture() async throws {
        let root = try scratchDirectory()
        try writeConfig("creation_rules:\n  - this: [is: not: valid\n", in: root)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        guard case .configUnreadable(let reason) = model.configState else {
            Issue.record("expected .configUnreadable, got \(String(describing: model.configState))")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("a pgp rule resolves to .unsupportedRule")
    func unsupportedRuleFixture() async throws {
        let root = try scratchDirectory()
        try writeConfig(
            """
            creation_rules:
              - path_regex: .*
                pgp: 0000000000000000000000000000000000AAAA
            """, in: root)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        guard case .unsupportedRule(let reason) = model.configState else {
            Issue.record("expected .unsupportedRule, got \(String(describing: model.configState))")
            return
        }
        #expect(reason.contains("pgp"))
    }

    /// Proves `configState` is not computed once and cached: a project that
    /// starts with no config and gains one between two `refresh()` calls
    /// must show the new answer on the second call, not the first one stuck
    /// in place. Together with the fixtures above (each of which also checks
    /// `hasScanned`/`files` alongside `configState` implicitly, by calling
    /// `refresh()` the ordinary way), this is the closest a black-box test
    /// can get to pinning "set in the same pass as `files`, never stale" —
    /// short of instrumenting `refresh()` itself to observe an intermediate
    /// state, which the model's own contract (no `await` between the
    /// assignments) makes impossible to construct from outside.
    @Test("a second refresh() reports a newly written config, not the first result")
    func refreshDoesNotStaleConfigState() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        #expect(model.configState == .noConfig)

        try writeConfig(
            """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """, in: root)
        await model.refresh()

        #expect(model.configState == .governedByRule(recipients: [owner.public], encryptedRegex: ""))
    }

    /// `configState` and `files` come from the same `refresh()` call — a
    /// project with an encrypted file *and* a governing rule must show both
    /// together, not one stale against the other.
    @Test("configState and files are both populated by the same refresh()")
    func configStateAndFilesShareOneRefresh() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try writeConfig(
            """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """, in: root)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: \(owner.public)
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.count == 1)
        #expect(model.configState == .governedByRule(recipients: [owner.public], encryptedRegex: ""))
    }
}
