import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixtures
//
// Encrypted fixtures go through the real in-process bridge, never a
// hand-written string — the discipline every suite on this surface follows.
// Only key generation shells out.
//
// The duplicate itself is real, not simulated: `SopsBridge.encrypt(_,
// format: .yaml, recipients: [x, x])` writes the key twice and `SopsBridge.recipients(in:)`
// reads it back twice, verified directly before this suite was written. sops
// does not deduplicate a flat age list, in a file's metadata or in a
// `.sops.yaml` creation rule, so both panels can be handed one.

private struct DuplicateFixtureError: Error, CustomStringConvertible {
    let description: String
}

private struct DuplicateAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> DuplicateAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DuplicateFixtureError(description: "age-keygen not found in \(candidates)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw DuplicateFixtureError(description: "age-keygen produced no usable key pair")
        }
        return DuplicateAgeKeyPair(private: priv, public: pub)
    }
}

private func duplicateScratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let duplicatePlainYAML = "database:\n    password: correct-horse-battery-staple\n"

// MARK: - The per-file panel

/// D1. `AccessEntry.id` is the `age1…` public key, and `entries` used to walk
/// `currentRecipients` unfiltered — so a file whose metadata names one key twice
/// produced two rows carrying one identity, which is undefined behaviour for
/// `List`. The staging arithmetic underneath was wrong in the same place:
/// `stageRemove` deletes *every* occurrence while set-based `isDirty` cannot see
/// multiplicity at all, so the second copy could never be staged away and an
/// apply carried it forward untouched.
///
/// ## The ruling: collapse, and say so
/// A duplicate is collapsed at the *source* — `currentRecipients` holds distinct
/// recipients — rather than given a positional identity, because access is a set
/// property: a data key wrapped twice for the same public key grants exactly
/// what wrapping it once grants. Positional ids would make `List` legal while
/// leaving two rows that must behave identically (one `stageRemove` strikes
/// both), which is a lie about their independence; making them genuinely
/// independent would need multiset staging, i.e. an ability to "half-remove" a
/// recipient — an operation the rewrap underneath has no meaning for.
///
/// Collapsing silently would be the other failure, so it is not silent:
/// `duplicatedRecipients` names how many keys were listed more than once and
/// both panels render a sentence about it.
@Suite("The per-file Access panel — a key listed twice is one recipient, said out loud")
@MainActor
struct FileAccessDuplicateRecipientTests {

    @Test("a file that names one key twice produces one row, with a unique identity")
    func duplicateCollapsesToOneEntry() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let other = try DuplicateAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            duplicatePlainYAML, format: .yaml, recipients: [owner.public, other.public, owner.public])
        try #require(
            try SopsBridge.recipients(in: encrypted, format: .yaml).count == 3,
            "precondition: sops really did write the duplicate — this test is vacuous without it")

        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/duplicate.yaml"), projectURL: nil,
            keyStore: SessionKeyStore(), format: .yaml, readFile: { _ in encrypted })
        await model.load()

        #expect(model.currentRecipients == [owner.public, other.public])
        #expect(model.stagedRecipients == [owner.public, other.public])
        #expect(model.duplicatedRecipients == [owner.public])
        #expect(model.entries.count == 2)
        #expect(Set(model.entries.map(\.id)).count == model.entries.count,
                "two rows sharing one List id is undefined row identity")
        #expect(!model.isDirty, "collapsing a duplicate is not a staged change")
    }

    /// The half of D1 that reaches disk. Before the collapse, `stagedRecipients`
    /// started as `[X, X]`, so *any* applied change re-wrapped the file for a
    /// list that still named X twice — the panel propagated the defect it could
    /// not show.
    @Test("applying any change writes each key exactly once")
    func applyWritesEachKeyOnce() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let added = try DuplicateAgeKeyPair.generate()
        let root = try duplicateScratchDirectory("access-duplicate-apply")
        let file = root.appendingPathComponent("secrets.yaml")
        try SopsBridge.encrypt(duplicatePlainYAML, format: .yaml, recipients: [owner.public, owner.public])
            .write(to: file, atomically: true, encoding: .utf8)
        try #require(
            try SopsBridge.recipients(in: String(contentsOf: file, encoding: .utf8), format: .yaml) == [
                owner.public, owner.public,
            ])

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: file, projectURL: nil, keyStore: keyStore, format: .yaml)
        await model.load()
        model.stageAdd(added.public)

        #expect(await model.apply() == .applied)

        let after = try SopsBridge.recipients(in: String(contentsOf: file, encoding: .utf8), format: .yaml)
        #expect(after.sorted() == [owner.public, added.public].sorted())
        #expect(after.count == 2, "the duplicate was carried forward into the rewrapped file")
    }

    @Test("the panel says the file lists a key more than once")
    func thePanelDisclosesTheDuplicate() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            duplicatePlainYAML, format: .yaml, recipients: [owner.public, owner.public])

        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/duplicate-disclosure.yaml"), projectURL: nil,
            keyStore: SessionKeyStore(), format: .yaml, readFile: { _ in encrypted })
        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        try #require(model.duplicatedRecipients == [owner.public])
        // Key-derived on both sides: plain `swift test` copies the catalog
        // uncompiled, so `LocalizedKey.text` is the raw key there.
        let expected = String(format: LocalizedKey.accessDuplicateRecipients.text, 1)
        let rendered = host.nodes().flatMap { [$0.label, $0.value] }
        #expect(rendered.contains(expected),
                "a file that names a key twice must be told about, not silently tidied")
    }
}

// MARK: - The project panel

@Suite("The project Access panel — a creation rule that names one key twice")
@MainActor
struct ProjectAccessDuplicateRecipientTests {

    private func makeProject(owner: DuplicateAgeKeyPair, twice: Bool) throws -> URL {
        let root = try duplicateScratchDirectory("project-access-duplicate")
        let ageList =
            twice
            ? "      - \(owner.public)\n      - \(owner.public)\n"
            : "      - \(owner.public)\n"
        try ("creation_rules:\n  - path_regex: .*\\.yaml$\n    age:\n" + ageList)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(duplicatePlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(to: root.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("a rule that names one key twice produces one row, with a unique identity")
    func duplicateCollapsesToOneEntry() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let root = try makeProject(owner: owner, twice: true)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        try #require(model.loadState == .loaded)
        try #require(model.plan?.configRecipients == [owner.public, owner.public],
                     "precondition: sops read the rule's duplicate back — vacuous otherwise")
        #expect(model.configRecipients == [owner.public])
        #expect(model.stagedRecipients == [owner.public])
        #expect(model.duplicatedRecipients == [owner.public])
        #expect(model.entries.count == 1)
        #expect(Set(model.entries.map(\.id)).count == model.entries.count)
        #expect(!model.isDirty)
    }

    /// SOPS-39 task 10. Ported from `ProjectAccessView` to the Access page
    /// that replaced it: the staged set is a set, so a rule naming one key
    /// twice is still drawn as one chip — and the sentence saying so has to
    /// survive the move, or the config on disk says something the page does
    /// not.
    @Test("the Access page says the creation rule lists a key more than once")
    func thePageDisclosesTheDuplicate() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let root = try makeProject(owner: owner, twice: true)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        try #require(model.duplicatedRecipients == [owner.public])

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: nil, onFilesApplied: {})
        }
        let expected = String(format: LocalizedKey.projectAccessDuplicateRecipients.text, 1)
        let rendered = nodes.flatMap { [$0.label, $0.value] }
        #expect(rendered.contains(expected))
    }

    /// The branch that must stay quiet: an ordinary rule naming each key once.
    @Test("an ordinary rule claims no duplicates")
    func anOrdinaryRuleSaysNothing() async throws {
        let owner = try DuplicateAgeKeyPair.generate()
        let root = try makeProject(owner: owner, twice: false)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.duplicatedRecipients.isEmpty)
    }
}
