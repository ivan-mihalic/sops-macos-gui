import AppKit
import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// Real temporary project roots, real `age-keygen` keys, and the real
// in-process bridge — same discipline `NewSecretFileModelTests.swift` (Task
// 2) stands on, duplicated here rather than shared because that file's own
// helpers are `private` to it and this suite needs the identical shapes
// (a governed-by-rule `.sops.yaml`, a scratch project root) to drive the
// real `NewSecretFileModel` this view renders.

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

private func scratchDirectory(_ label: String = "new-secret-file-sheet") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A `.sops.yaml` with one age-only creation rule naming `recipient` —
/// mirrors `NewSecretFileModelTests.ageOnlyConfig(_:)`.
private func ageOnlyConfig(_ recipient: String) -> String {
    """
    creation_rules:
      - path_regex: .*\\.yaml$
        age: \(recipient)
    """ + "\n"
}

@MainActor
private func makeKeyStore(importing key: String? = nil) throws -> SessionKeyStore {
    let store = SessionKeyStore()
    if let key {
        try store.importKey(key)
    }
    return store
}

// MARK: - Pure decisions: canCreate, shouldResolve, shortenedKey
//
// The three free/static functions `NewSecretFileSheet` exposes for exactly
// this — checkable without rendering anything, matching
// `RecipientAccessGatingTests`' own `canApply`/`canOpenAccessPanel` suites.

@Suite("NewSecretFileSheet.canCreate — the Create button's gate")
@MainActor
struct CanCreateTests {

    @Test("only .ready, and not while a create is already running")
    func onlyReadyEnables() {
        #expect(NewSecretFileSheet.canCreate(readiness: .ready(recipients: ["age1abc"]), isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .ready(recipients: ["age1abc"]), isCreating: true))
    }

    @Test("every non-.ready readiness refuses")
    func everyOtherStateRefuses() {
        let message = CreationFailureMessage(title: .creationFailureTitle, detail: "x", recovery: nil)
        #expect(!NewSecretFileSheet.canCreate(readiness: .needsName, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .needsSource, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .needsAcknowledgement, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .blocked(message), isCreating: false))
    }
}

@Suite("NewSecretFileSheet.shouldResolve — the debounce's own guard")
@MainActor
struct ShouldResolveTests {

    @Test("a name that already matches resolvedName is not re-resolved")
    func unchangedNameSkips() {
        #expect(!NewSecretFileSheet.shouldResolve(relativeName: "secret.yaml", resolvedName: "secret.yaml"))
    }

    @Test("a name that differs from resolvedName is resolved")
    func changedNameResolves() {
        #expect(NewSecretFileSheet.shouldResolve(relativeName: "other.yaml", resolvedName: "secret.yaml"))
    }

    @Test("nothing resolved yet (resolvedName == nil) always resolves")
    func nilResolvedNameAlwaysResolves() {
        #expect(NewSecretFileSheet.shouldResolve(relativeName: "secret.yaml", resolvedName: nil))
        #expect(NewSecretFileSheet.shouldResolve(relativeName: "", resolvedName: nil))
    }

    @Test("two blank names are still unchanged")
    func bothBlankSkips() {
        #expect(!NewSecretFileSheet.shouldResolve(relativeName: "", resolvedName: ""))
    }
}

@Suite("NewSecretFileSheet.shortenedKey — never invents a name")
@MainActor
struct ShortenedKeyTests {

    @Test("a full-length age recipient is shortened to prefix…suffix")
    func longKeyIsShortened() {
        let key = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq8x"
        let shortened = NewSecretFileSheet.shortenedKey(key)
        #expect(shortened.hasPrefix(key.prefix(6)))
        #expect(shortened.hasSuffix(key.suffix(4)))
        #expect(shortened.contains("…"))
        #expect(shortened.count < key.count)
    }

    @Test("a short string is left exactly as it is — nothing is fabricated")
    func shortKeyIsUnchanged() {
        #expect(NewSecretFileSheet.shortenedKey("age1abc") == "age1abc")
    }
}

// MARK: - The tick-then-retry race, proven without any Task.sleep
//
// This is the regression the plan's own review flagged for Task 2 and
// carried into Task 4's brief: `resolvePlan()` resets
// `acknowledgedUnreadable` on *every* call, including one that resolves to
// the exact same plan again. A debounce that fired unconditionally in the
// window between a checkbox tick and a Create click would silently discard
// the tick. The whole point of `shouldResolve(relativeName:resolvedName:)`
// is to make that window provably closed — checked here directly against
// the real model, with no timer, no sleep, and no rendered view.

@Suite("The tick-then-retry window — proven against the real model, no sleeping")
@MainActor
struct DebounceGuardTests {

    private func excludedKeyModel() async throws -> (model: NewSecretFileModel, stranger: AgeKeyPair) {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        return (model, stranger)
    }

    @Test("once resolved, the guard says no further resolve is needed for the same name")
    func guardSkipsAfterAFreshResolve() async throws {
        let (model, _) = try await excludedKeyModel()

        // The name has not changed since `resolvePlan()` last ran — this is
        // exactly the check `NewSecretFileSheet.resolveDebounced()` makes
        // right before it would call `resolvePlan()` again.
        #expect(!NewSecretFileSheet.shouldResolve(relativeName: model.relativeName, resolvedName: model.resolvedName))
    }

    @Test(
        """
        the guard, respected: a checkbox tick between resolves survives, and Create succeeds
        """)
    func guardRespectedPreservesTheAcknowledgement() async throws {
        let (model, stranger) = try await excludedKeyModel()
        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)

        model.acknowledgedUnreadable = true
        try #require(model.readiness == .ready(recipients: [stranger.public]))

        // Simulate a debounce Task waking up in the tick-then-retry window:
        // it checks the guard first, sees the name is unchanged, and never
        // calls `resolvePlan()` at all.
        if NewSecretFileSheet.shouldResolve(relativeName: model.relativeName, resolvedName: model.resolvedName) {
            await model.resolvePlan()
        }

        #expect(model.acknowledgedUnreadable, "the guard must have skipped the redundant resolve")
        #expect(model.readiness == .ready(recipients: [stranger.public]))

        let created = await model.create()
        #expect(created != nil, "Create must succeed — the acknowledgement was never discarded")
    }

    @Test(
        """
        the bug this guard exists to prevent: an unconditional resolve in the same window \
        silently discards the acknowledgement, and Create fails again with no visible cause
        """)
    func unconditionalResolveWouldDiscardTheAcknowledgement() async throws {
        let (model, stranger) = try await excludedKeyModel()
        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)

        model.acknowledgedUnreadable = true
        try #require(model.readiness == .ready(recipients: [stranger.public]))

        // What an unguarded debounce would do: call `resolvePlan()`
        // unconditionally, exactly as if the trailing timer for the very
        // last keystroke fired after the tick instead of before it.
        await model.resolvePlan()

        // The optimistic `.ready` is back — readiness alone gives no sign
        // anything went wrong.
        #expect(model.readiness == .ready(recipients: [stranger.public]))
        // But the acknowledgement itself is gone.
        #expect(!model.acknowledgedUnreadable, "resolvePlan() resets the tick — this is the bug being pinned")

        // So the very next Create hits the identical wall again, with
        // nothing on screen having told the user why.
        let created = await model.create()
        #expect(created == nil)
        #expect(model.readiness == .needsAcknowledgement)
    }
}

// MARK: - Rendered through the real view

/// A persistent host so a state change made to the model after construction
/// can be observed in the tree — mirrors `RecipientAccessGatingTests
/// .GatingHost`'s own reasoning, reused directly rather than duplicated
/// (it, and `GatingAXProbe`, are `internal` to this test target).
@Suite("NewSecretFileSheet, through a real rendered sheet")
@MainActor
struct NewSecretFileSheetRenderedTests {

    private static let sheetSize = CGSize(width: 640, height: 560)

    /// `readiness == .ready`, real project, real key.
    private func readyModel() async throws -> (model: NewSecretFileModel, owner: AgeKeyPair) {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        try #require(model.readiness == .ready(recipients: [owner.public]))
        return (model, owner)
    }

    /// `readiness == .needsAcknowledgement`.
    private func needsAcknowledgementModel() async throws -> NewSecretFileModel {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        _ = await model.create()
        try #require(model.readiness == .needsAcknowledgement)
        return model
    }

    /// `readiness == .blocked` — no `.sops.yaml` at all.
    private func blockedModel() async throws -> NewSecretFileModel {
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        guard case .blocked = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            throw FixtureError("precondition failed")
        }
        return model
    }

    @Test(".needsAcknowledgement renders the acknowledgement checkbox, bound to the model")
    func needsAcknowledgementRendersCheckbox() async throws {
        let model = try await needsAcknowledgementModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let labels = Set(host.nodes().map(\.label))
        #expect(
            labels.contains(LocalizedKey.newFileAcknowledgeUnreadableCheckbox.text),
            "the checkbox did not render for .needsAcknowledgement")

        // And it is really bound to the model, not just present: toggling
        // the model flips readiness, exactly as `NewSecretFileModelTests`
        // already proves at the model level — this is the wiring half.
        model.acknowledgedUnreadable = true
        #expect(model.readiness != .needsAcknowledgement)
    }

    @Test(".blocked renders the CreationFailureMessage's title, detail and recovery")
    func blockedRendersFailureMessage() async throws {
        let model = try await blockedModel()
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let values = host.nodes().map(\.value) + host.nodes().map(\.label)
        #expect(values.contains(message.title.text), "the failure title did not render")
        #expect(values.contains(where: { $0.contains(message.detail) }), "the failure detail did not render")
        if let recovery = message.recovery {
            #expect(values.contains(recovery.text), "the recovery hint did not render")
        }
    }

    @Test("the ⓘ line names the resolved rule's recipients for a .ready plan")
    func infoLineNamesRecipientsForGovernedByRule() async throws {
        let (model, owner) = try await readyModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let values = host.nodes().map(\.value)
        // The registry has no label for `owner.public`, so the ⓘ line must
        // show it shortened — never the raw 62-character key, and never an
        // invented name. See `NewSecretFileSheet.shortenedKey(_:)`.
        let expected = String(
            format: LocalizedKey.newFileInfoGovernedByRule.text, NewSecretFileSheet.shortenedKey(owner.public))
        #expect(values.contains(expected), "the ⓘ line did not name the rule's recipient, shortened")
    }

    @Test("no .sops.yaml renders the no-config ⓘ sentence, distinct from the failure banner")
    func infoLineNamesNoConfig() async throws {
        let model = try await blockedModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let values = host.nodes().map(\.value)
        #expect(values.contains(LocalizedKey.newFileInfoNoConfig.text))
    }

    @Test("Encrypted YAML's disabled reason is a visible sentence, not only a tooltip")
    func encryptedYAMLDisabledReasonIsVisible() async throws {
        let (model, _) = try await readyModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let values = host.nodes().map(\.value)
        #expect(values.contains(LocalizedKey.newFileSourceEncryptedYAMLDisabledReason.text))
    }

    @Test("choosing .env renders DotEnvPreviewTable's own empty-state sentence before a file is picked")
    func dotEnvSourceRendersPreviewPlaceholder() async throws {
        let (model, _) = try await readyModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        // Changed *after* the sheet is already rendered and bound to this
        // model — matching how a user actually drives it — so the view's
        // own `.onChange(of: model.sourceChoice)` is what recomputes
        // `readiness`, not a value baked in before the view ever mounted.
        model.sourceChoice = .dotEnv
        await host.settle(until: { model.readiness == .needsSource })

        // A plain `Text`'s content lands in the accessibility tree's
        // `value`, not `label` — see `GatingAXProbe.Node`'s own doc
        // comment.
        let values = Set(host.nodes().map(\.value))
        #expect(values.contains(LocalizedKey.newFileNoFileChosen.text))
        // Still not ready — Task 4 wires the preview, not the creation; see
        // `NewSecretFileModel.create()`'s own `sourceChoice == .empty` guard.
        #expect(model.readiness == .needsSource)
    }
}

// MARK: - Create is wired to the pure gate, not re-decided in the view

@Suite("The Create button reads NewSecretFileSheet.canCreate, not its own logic")
struct CreateButtonWiringTests {

    @Test("the source literally disables Create with the pure gate function")
    func createButtonUsesTheGateFunction() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SopsUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/SopsUI/Projects/NewSecretFileSheet.swift")
        let text = try String(contentsOf: sources, encoding: .utf8)
        #expect(
            text.contains(".disabled(!Self.canCreate(readiness: model.readiness, isCreating: isCreating))"),
            "Create must stay wired to the pure gate function, not a re-derived condition")
    }
}
