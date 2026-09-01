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
        #expect(!NewSecretFileSheet.canCreate(readiness: .resolving, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .needsSource, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .needsAcknowledgement, isCreating: false))
        #expect(!NewSecretFileSheet.canCreate(readiness: .blocked(message), isCreating: false))
    }
}

@Suite("NewSecretFileSheet.targetFormatText — the target-format line's copy (SOPS-38)")
@MainActor
struct TargetFormatTextTests {

    @Test("no name typed yet renders nothing")
    func nilFormatRendersNothing() {
        #expect(NewSecretFileSheet.targetFormatText(for: nil) == nil)
    }

    @Test("a YAML target names YAML")
    func yamlFormatRendersYAMLSentence() {
        #expect(NewSecretFileSheet.targetFormatText(for: .yaml) == LocalizedKey.newFileTargetFormatYAML.text)
    }

    @Test("a dotenv target names dotenv, distinctly from the YAML sentence")
    func dotenvFormatRendersDotenvSentence() {
        let text = NewSecretFileSheet.targetFormatText(for: .dotenv)
        #expect(text == LocalizedKey.newFileTargetFormatDotEnv.text)
        #expect(text != NewSecretFileSheet.targetFormatText(for: .yaml))
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

// MARK: - The ⓘ line's six shapes, pure — no rendering, no async race
//
// `isResolving` is a plain `Bool` argument to `NewSecretFileSheet
// .infoLineText(isResolving:plan:recipientNames:)`, not read live off a
// model — this app's `CreationPlanResolver.plan(forTarget:in:)` is itself
// synchronous, so `resolvePlan()` never actually suspends, and there is no
// reliable way for a test to interleave with it and observe `model
// .isResolving == true` for any real duration. Passing it as a parameter
// sidesteps that entirely: every shape, including "still resolving", is
// checked directly.

@Suite("NewSecretFileSheet.infoLineText — the ⓘ line's six shapes")
@MainActor
struct InfoLineTextTests {

    private func joinedNames(_ recipients: [String]) -> String { recipients.joined(separator: ", ") }

    @Test("still resolving")
    func resolving() {
        let text = NewSecretFileSheet.infoLineText(
            isResolving: true, plan: .governedByRule(recipients: ["age1abc"], encryptedRegex: ""),
            recipientNames: joinedNames)
        #expect(text == LocalizedKey.newFileInfoResolving.text)
    }

    @Test("resolving takes priority even over an already-resolved plan")
    func resolvingTakesPriorityOverAStalePlan() {
        let text = NewSecretFileSheet.infoLineText(isResolving: true, plan: .noConfig, recipientNames: joinedNames)
        #expect(text == LocalizedKey.newFileInfoResolving.text)
    }

    @Test("no plan yet, not resolving — nothing shown")
    func noPlanYet() {
        #expect(NewSecretFileSheet.infoLineText(isResolving: false, plan: nil, recipientNames: joinedNames) == nil)
    }

    @Test(".governedByRule names the recipients through the injected formatter")
    func governedByRule() {
        let text = NewSecretFileSheet.infoLineText(
            isResolving: false, plan: .governedByRule(recipients: ["age1abc", "age1def"], encryptedRegex: ""),
            recipientNames: joinedNames)
        #expect(text == String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc, age1def"))
    }

    /// The review's own finding: a `.governedByRule` whose own recipient
    /// list is empty is real and sops-admitted (`CreationPlanResolverTests
    /// .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients`), and this was
    /// the one `.governedByRule` reader that read `plan`'s recipients
    /// directly rather than through `NewSecretFileModel
    /// .currentGovernedPlan()`'s own empty-recipients guard. Before this
    /// case was added, nothing here objected to `recipientNames([])`
    /// rendering `""` and the ⓘ line claiming "it will be encrypted for: "
    /// — asserting an encryption that will not happen, directly above
    /// `readiness`'s own `.blocked` banner saying the opposite. Pins that
    /// this arm now says the same thing the banner does, instead.
    @Test(".governedByRule with no recipients at all does not claim encryption will happen")
    func governedByRuleWithNoRecipients() {
        let text = NewSecretFileSheet.infoLineText(
            isResolving: false, plan: .governedByRule(recipients: [], encryptedRegex: ""),
            recipientNames: joinedNames)
        #expect(text == CreationFailurePresenter.messageForRuleWithNoRecipients().detail)
        #expect(text?.localizedCaseInsensitiveContains("no recipients") == true)
        // The specific false claim this case exists to prevent — this must
        // never resolve to the encrypted-for sentence with an empty tail.
        #expect(text != String(format: LocalizedKey.newFileInfoGovernedByRule.text, ""))
    }

    // MARK: - Important 2: a rule that scopes encryption says so

    /// `encrypted_regex` is the one scoping field `CreationPlanResolver`
    /// passes through as *supported* (`CreationPlanResolverTests
    /// .encryptedRegexPassesThrough` measures it against the real bridge), so
    /// a file created under such a rule stores every non-matching value in
    /// plaintext, readable by anyone with the repository. Until this
    /// sentence existed, the ⓘ line — the wizard's whole account of what
    /// `.sops.yaml` decides for this name — said only who could read the
    /// file. Spec §4.1 decision 4 is "do not change access silently".
    @Test(".governedByRule whose rule sets encrypted_regex discloses the plaintext scoping too")
    func governedByRuleWithEncryptedRegex() throws {
        let regex = "^(data|stringData)$"
        let text = try #require(
            NewSecretFileSheet.infoLineText(
                isResolving: false, plan: .governedByRule(recipients: ["age1abc"], encryptedRegex: regex),
                recipientNames: joinedNames))

        let recipientsSentence = String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc")
        let scopingSentence = String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, regex)
        #expect(text.hasPrefix(recipientsSentence), "the recipients sentence must still lead the line")
        #expect(text.contains(scopingSentence), "the scoping sentence is missing: \(text)")
        #expect(
            text != recipientsSentence,
            "naming only who can read a file most of which stays plaintext is a silent access change")
    }

    @Test("a rule that sets no encrypted_regex says nothing about scoping")
    func governedByRuleWithoutEncryptedRegexSaysNothingExtra() throws {
        let text = try #require(
            NewSecretFileSheet.infoLineText(
                isResolving: false, plan: .governedByRule(recipients: ["age1abc"], encryptedRegex: ""),
                recipientNames: joinedNames))
        #expect(text == String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc"))
        // Under `swift test`'s uncompiled catalog both sides are raw keys,
        // which is exactly why this compares against the key's own text
        // rather than English: the sentence must be absent either way.
        #expect(!text.contains(LocalizedKey.newFileInfoEncryptedRegexScoping.text))
    }

    @Test(".noConfig")
    func noConfig() {
        let text = NewSecretFileSheet.infoLineText(isResolving: false, plan: .noConfig, recipientNames: joinedNames)
        #expect(text == LocalizedKey.newFileInfoNoConfig.text)
    }

    @Test(".noRuleMatched")
    func noRuleMatched() {
        let text = NewSecretFileSheet.infoLineText(
            isResolving: false, plan: .noRuleMatched, recipientNames: joinedNames)
        #expect(text == LocalizedKey.newFileInfoNoRuleMatched.text)
    }

    /// The case the reviewer named specifically: a wrong-branch mistake in
    /// the `.unsupportedRule`/`.configUnreadable` arm — say, swapping which
    /// `CreationPlan` case it matches, or forgetting the `?? nil` fallback
    /// — would be silent without this, because both cases already return
    /// non-`nil`, non-empty text from *some* source either way.
    @Test(".unsupportedRule reuses CreationFailurePresenter's own sentence, not a re-worded one")
    func unsupportedRule() {
        let plan = CreationPlan.unsupportedRule(reason: "A rule names pgp, which this app cannot hold.")
        let text = NewSecretFileSheet.infoLineText(isResolving: false, plan: plan, recipientNames: joinedNames)
        #expect(text == CreationFailurePresenter.message(forBlocking: plan)?.detail)
        #expect(text == "A rule names pgp, which this app cannot hold.")
    }

    @Test(".configUnreadable reuses CreationFailurePresenter's own sentence, not a re-worded one")
    func configUnreadable() {
        let plan = CreationPlan.configUnreadable(reason: "yaml: line 3: mapping values are not allowed here")
        let text = NewSecretFileSheet.infoLineText(isResolving: false, plan: plan, recipientNames: joinedNames)
        #expect(text == CreationFailurePresenter.message(forBlocking: plan)?.detail)
        #expect(text?.contains("yaml: line 3") == true)
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

    /// Important 2, at the rendering level and across **every** source: the
    /// ⓘ line lives in `nameSection`, above the per-source preview area, so
    /// one sentence there is the wizard's only disclosure that a rule scopes
    /// which values get encrypted at all. This walks all four
    /// `SourceChoice` cases against one rendered sheet and requires the
    /// sentence in each — a future change that moved the line into any one
    /// source's preview would leave the other three silent, and this is what
    /// would catch it.
    @Test("a rule with encrypted_regex discloses its plaintext scoping for every source")
    func infoLineDisclosesEncryptedRegexForEverySource() async throws {
        let owner = try AgeKeyPair.generate()
        let regex = "^(data|stringData)$"
        let root = try scratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)
                encrypted_regex: '\(regex)'
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        try #require(
            model.plan == .governedByRule(recipients: [owner.public], encryptedRegex: regex),
            "precondition: sops itself must report the regex, or this test proves nothing")

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let scopingSentence = String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, regex)
        for source in NewSecretFileModel.SourceChoice.allCases {
            model.sourceChoice = source
            await host.settleAfterAModelChange()
            let rendered = host.nodes().map(\.value) + host.nodes().map(\.label)
            #expect(
                rendered.contains(where: { $0.contains(scopingSentence) }),
                "the \(source) source's screen never says the rule leaves non-matching values in plaintext")
        }
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

    /// Task 6's own carve-out expired: the Encrypted YAML radio used to be
    /// `.disabled` with a permanently visible explanation. It is selectable
    /// now, and choosing it renders `EncryptedImportPreview`'s own
    /// "no file chosen" sentence — the same `newFileNoFileChosen` every
    /// other unloaded source preview shows — not a dead end.
    @Test("choosing Encrypted YAML selects it and renders EncryptedImportPreview, not a disabled explanation")
    func encryptedYAMLSourceIsSelectableAndRendersItsOwnPreview() async throws {
        let (model, _) = try await readyModel()

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        model.sourceChoice = .encryptedYAML
        await host.settleAfterAModelChange()

        let values = host.nodes().map(\.value)
        let labels = host.nodes().map(\.label)
        #expect(values.contains(LocalizedKey.newFileNoFileChosen.text) || labels.contains(LocalizedKey.newFileNoFileChosen.text),
                "EncryptedImportPreview's own empty state did not render")
        #expect(labels.contains(LocalizedKey.newFileChooseFileButton.text),
                "EncryptedImportPreview's choose-file button did not render")
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
        // Still not ready — no file has been picked yet, so `dotEnvParsed`
        // is `nil` and `computeReadiness()`'s `.dotEnv` branch reports
        // `.needsSource`. `CreateFromSourceTests.dotEnvCreatesAReadableFile`
        // covers the other half: once `loadDotEnv(from:)` actually loads a
        // file, `create()` uses it and `readiness` reaches `.ready`.
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

// MARK: - create() actually uses the chosen source, end to end
//
// Fix round: the coordinator's review found that no task in the plan ever
// wired the source a user picked into `NewSecretFileModel.create()` —
// `create()` unconditionally guarded `sourceChoice == .empty`. These tests
// are the ones that would have caught that: a real `.env`/Plain YAML file on
// disk, `loadDotEnv(from:)`/`loadPlainYAML(from:)`, `create()`, and
// `SopsBridge.decryptToRows` reading back exactly what was in the source
// file — matching how `NewSecretFileModelTests.createOnReadyPlanProducesReadableFile`
// proves the `.empty` path end to end.

@Suite("NewSecretFileModel.create() from a loaded source, through the real bridge")
@MainActor
struct CreateFromSourceTests {

    private func sourceFile(named name: String, containing text: String) throws -> URL {
        let dir = try scratchDirectory("new-secret-file-sheet-source")
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Plain YAML goes through create() verbatim and decrypts back")
    func plainYAMLCreatesAReadableFile() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(
            named: "input.yaml", containing: "db:\n    password: correct-horse-battery-staple-EXAMPLE\n")
        model.loadPlainYAML(from: picked)
        try #require(model.plainYAMLText != nil, "precondition: the file was read")
        try #require(model.plainYAMLLoadError == nil)

        model.sourceChoice = .plainYAML
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("expected .ready once a Plain YAML source is loaded, got \(model.readiness)")
            return
        }

        let created = await model.create()
        let destination = try #require(created, "create() must succeed for a loaded Plain YAML source")
        #expect(destination.path == root.appendingPathComponent("secret.yaml").path)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        let password = try #require(rows.first { $0.path == ["db", "password"] })
        #expect(password.value == "correct-horse-battery-staple-EXAMPLE")
    }

    /// `SecretFileCreator.create` never reserialises `.verbatimYAML` — the
    /// bridge's own YAML loader is what turns invalid input into a refusal,
    /// at the encrypt step (`Failure.engine`), matching
    /// `SecretFileCreatorTests`' own account of that error text.
    @Test("Plain YAML that is not valid YAML is refused, not silently emptied or written")
    func invalidPlainYAMLIsRefused() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        // An unterminated flow sequence — not valid YAML.
        let picked = try sourceFile(named: "input.yaml", containing: "db: [unterminated\n")
        model.loadPlainYAML(from: picked)
        try #require(model.plainYAMLText != nil, "precondition: the (invalid) text was still read")

        model.sourceChoice = .plainYAML
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        let created = await model.create()

        #expect(created == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.yaml").path))
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked after an invalid-YAML create() failure, got \(model.readiness)")
            return
        }
        #expect(!message.detail.isEmpty)
    }

    @Test(".env goes through create() as the exact parsed entries, and decrypts back")
    func dotEnvCreatesAReadableFile() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(
            named: "input.env",
            containing: "DB_PASSWORD=correct-horse-battery-staple-EXAMPLE\nAPI_KEY=sk_live_EXAMPLE\n")
        model.loadDotEnv(from: picked)
        try #require(model.dotEnvParsed?.entries.count == 2, "precondition: both entries parsed")
        try #require(model.dotEnvLoadError == nil)

        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("expected .ready once a .env source is loaded, got \(model.readiness)")
            return
        }

        let created = await model.create()
        let destination = try #require(created, "create() must succeed for a loaded .env source")

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        let dbPassword = try #require(rows.first { $0.path == ["DB_PASSWORD"] })
        let apiKey = try #require(rows.first { $0.path == ["API_KEY"] })
        #expect(dbPassword.value == "correct-horse-battery-staple-EXAMPLE")
        #expect(apiKey.value == "sk_live_EXAMPLE")
        // Exactly the two entries — nothing extra, nothing dropped.
        #expect(rows.count == 2)
    }

    /// Task SOPS-38, end to end through the model: naming the target
    /// `.sops.env` — rather than `.yaml`, `dotEnvCreatesAReadableFile`'s own
    /// destination above — is what makes `create()` write a genuine dotenv
    /// document instead of a flat YAML map, purely because of
    /// `NewSecretFileModel.targetFormat`/`SecretFileCreator`'s own name-based
    /// decision. No `.sops.yaml` exists in this fixture on purpose: the
    /// point is that the *destination name* decides the format, not
    /// anything about how the recipients were resolved — `.noConfig` with a
    /// manually-chosen recipient exercises `readiness`/`create()`'s other
    /// major path (`RecipientPicker`'s own), proving the two concerns
    /// (recipients, format) are genuinely independent.
    @Test(".env source into a .sops.env target creates a genuine dotenv document, not YAML")
    func dotEnvSourceIntoDotEnvTargetCreatesGenuineDotenv() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(
            named: "input.env",
            containing: "DB_PASSWORD=correct-horse-battery-staple-EXAMPLE\nAPI_KEY=sk_live_EXAMPLE\n")
        model.loadDotEnv(from: picked)
        try #require(model.dotEnvParsed?.entries.count == 2, "precondition: both entries parsed")

        model.sourceChoice = .dotEnv
        model.relativeName = ".sops.env"
        await model.resolvePlan()
        #expect(model.plan == .noConfig, "precondition: no .sops.yaml in this fixture")
        #expect(model.targetFormat == .dotenv)

        model.manuallyChosenRecipients = [owner.public]
        guard case .ready = model.readiness else {
            Issue.record("expected .ready once a recipient is chosen by hand, got \(model.readiness)")
            return
        }

        let created = await model.create()
        let destination = try #require(created, "create() must succeed")
        #expect(destination.path == root.appendingPathComponent(".sops.env").path)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)

        // Genuinely dotenv: reading it back as YAML must fail, the same
        // discriminating proof `SecretFileCreatorTests
        // .dotEnvTargetIsGenuineDotenv` uses at the layer below this one.
        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        }

        let rows = try SopsBridge.decryptToRows(encrypted, format: .dotenv, agePrivateKey: owner.private)
        let dbPassword = try #require(rows.first { $0.path == ["DB_PASSWORD"] })
        let apiKey = try #require(rows.first { $0.path == ["API_KEY"] })
        #expect(dbPassword.value == "correct-horse-battery-staple-EXAMPLE")
        #expect(apiKey.value == "sk_live_EXAMPLE")
        #expect(rows.count == 2)
    }

    @Test("a .env file that is not valid UTF-8 is blocked with DotEnvParseFailure's own sentence")
    func invalidDotEnvIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let dir = try scratchDirectory("new-secret-file-sheet-source")
        let picked = dir.appendingPathComponent("input.env")
        // 0xFF is never valid UTF-8 on its own.
        try Data([0xFF, 0xFE, 0x00]).write(to: picked)

        model.loadDotEnv(from: picked)
        #expect(model.dotEnvParsed == nil)
        #expect(model.dotEnvLoadError == CreationFailurePresenter.message(for: DotEnvParseFailure.notUTF8))

        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(!message.detail.isEmpty)

        let created = await model.create()
        #expect(created == nil)
    }

    @Test("a source file that vanished after being picked is reported through message(forUnreadableSourceFile:)")
    func unreadableSourceFileIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let missing = try scratchDirectory("new-secret-file-sheet-missing-source")
            .appendingPathComponent("does-not-exist.env")

        model.loadDotEnv(from: missing)

        #expect(model.dotEnvParsed == nil)
        #expect(model.dotEnvLoadError == CreationFailurePresenter.message(forUnreadableSourceFile: ()))

        // Same for Plain YAML — one read failure, one presenter method,
        // both sources.
        model.loadPlainYAML(from: missing)
        #expect(model.plainYAMLText == nil)
        #expect(model.plainYAMLLoadError == CreationFailurePresenter.message(forUnreadableSourceFile: ()))
    }

    // MARK: - Fix round: acknowledging unreadability must survive re-picking the source
    //
    // The reopened door the reviewer found: `acknowledgedUnreadable`'s own
    // `didSet` sets `readiness = .ready` directly but never clears
    // `discoveredUnreadable` — only `resolvePlan()` and a successful
    // `create()` do. `loadPlainYAML(from:)`/`loadDotEnv(from:)` are a
    // *second* path into `computeReadiness()` beyond those two, and before
    // this fix it read `discoveredUnreadable` alone, reintroducing
    // `.needsAcknowledgement` with the checkbox still rendered ticked — and
    // re-ticking an already-`true` checkbox is a no-op per the `didSet`
    // guard, so there was no visible way out except unticking and
    // re-ticking. `computeReadiness()` now reads
    // `discoveredUnreadable && !acknowledgedUnreadable`.

    @Test("acknowledging unreadability survives re-picking a .env source file")
    func acknowledgementSurvivesReloadingDotEnv() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(named: "input.env", containing: "KEY=value\n")
        model.loadDotEnv(from: picked)
        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)

        model.acknowledgedUnreadable = true
        try #require(model.readiness == .ready(recipients: [stranger.public]))

        let repicked = try sourceFile(named: "input2.env", containing: "OTHER=value\n")
        model.loadDotEnv(from: repicked)

        #expect(model.acknowledgedUnreadable, "the tick itself must survive re-picking the source")
        #expect(model.readiness == .ready(recipients: [stranger.public]))
    }

    @Test("acknowledging unreadability survives re-picking a Plain YAML source file")
    func acknowledgementSurvivesReloadingPlainYAML() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(named: "input.yaml", containing: "a: b\n")
        model.loadPlainYAML(from: picked)
        model.sourceChoice = .plainYAML
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)

        model.acknowledgedUnreadable = true
        try #require(model.readiness == .ready(recipients: [stranger.public]))

        let repicked = try sourceFile(named: "input2.yaml", containing: "c: d\n")
        model.loadPlainYAML(from: repicked)

        #expect(model.acknowledgedUnreadable, "the tick itself must survive re-picking the source")
        #expect(model.readiness == .ready(recipients: [stranger.public]))
    }

    // MARK: - Second review round: the un-acknowledged half of the same door
    //
    // The first fix guarded `.governedByRule`'s branch with
    // `!acknowledgedUnreadable`, but `computeReadiness()` short-circuits one
    // line earlier on `if let planError`. `create()`'s `wouldBeUnreadable`
    // branch used to set `planError` unconditionally, even on the path into
    // `.needsAcknowledgement` — so a user who does *not* tick and instead
    // re-picks a source (the most natural response to "this file would be
    // unreadable") hit that earlier short-circuit and silently lost the
    // checkbox affordance, with no way back except changing the name or the
    // source radio. Fixed by never setting `planError` on that branch.

    @Test("re-picking a .env source after a failed create(), without ticking, still shows the checkbox")
    func acknowledgementAffordanceSurvivesRePickingDotEnvWithoutTicking() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(named: "input.env", containing: "KEY=value\n")
        model.loadDotEnv(from: picked)
        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)
        try #require(!model.acknowledgedUnreadable, "precondition: not ticked")

        // Re-picking *without* ticking first — this used to hit the
        // `planError` short-circuit before the `discoveredUnreadable`/
        // `acknowledgedUnreadable` check ever ran.
        let repicked = try sourceFile(named: "input2.env", containing: "OTHER=value\n")
        model.loadDotEnv(from: repicked)

        #expect(model.readiness == .needsAcknowledgement, "the checkbox affordance must still be reachable")
        #expect(model.planError == nil, "no stale failure banner should show instead of the checkbox")

        // The affordance is not just present but functional.
        model.acknowledgedUnreadable = true
        #expect(model.readiness == .ready(recipients: [stranger.public]))
    }

    @Test("re-picking a Plain YAML source after a failed create(), without ticking, still shows the checkbox")
    func acknowledgementAffordanceSurvivesRePickingPlainYAMLWithoutTicking() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(named: "input.yaml", containing: "a: b\n")
        model.loadPlainYAML(from: picked)
        model.sourceChoice = .plainYAML
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        _ = await model.create()  // discovers wouldBeUnreadable
        try #require(model.readiness == .needsAcknowledgement)
        try #require(!model.acknowledgedUnreadable, "precondition: not ticked")

        let repicked = try sourceFile(named: "input2.yaml", containing: "c: d\n")
        model.loadPlainYAML(from: repicked)

        #expect(model.readiness == .needsAcknowledgement, "the checkbox affordance must still be reachable")
        #expect(model.planError == nil, "no stale failure banner should show instead of the checkbox")

        model.acknowledgedUnreadable = true
        #expect(model.readiness == .ready(recipients: [stranger.public]))
    }

    // MARK: - Minor A: the preview-then-create guarantee, pinned with a test
    //
    // Nothing currently re-reads the source file at `create()` time — but
    // nothing proved it. Deleting the file between `loadDotEnv(from:)` and
    // `create()` makes a future re-read impossible to land green, and
    // comparing against `model.dotEnvParsed?.entries` (not string literals)
    // means this test would fail if `create()` ever diverged from what was
    // actually previewed, not just from what this test happened to type.

    @Test("what create() writes is exactly what was previewed, even after the source file is deleted")
    func previewedEntriesSurviveTheSourceFileDisappearing() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(
            named: "input.env",
            containing: "DB_PASSWORD=correct-horse-battery-staple-EXAMPLE\nAPI_KEY=sk_live_EXAMPLE\n")
        model.loadDotEnv(from: picked)
        let previewedEntries = try #require(model.dotEnvParsed?.entries)
        #expect(previewedEntries.count == 2)

        // Deleted the moment the preview has its own copy — a real re-read
        // at `create()` time would fail right here, not silently diverge.
        try FileManager.default.removeItem(at: picked)

        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        let created = await model.create()
        let destination = try #require(created, "create() must not need the source file to still exist")

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        #expect(rows.count == previewedEntries.count)
        for entry in previewedEntries {
            let row = try #require(rows.first { $0.path == [entry.key] })
            #expect(row.value == entry.value)
        }
    }

    // MARK: - Minor B: a zero-entry .env is decided, not accidental
    //
    // A genuinely empty or comments-only `.env` (`entries` and `skipped`
    // both empty) creates the same legitimate `{}` document `.empty`'s own
    // source does — `FlatYAMLEmitter.emit([])` already treats it that way.
    // The state to avoid is different: lines that looked like assignments,
    // held onto by `skipped`, with nothing salvaged into `entries` — that
    // must not offer an enabled Create next to a preview showing only
    // unreadable lines that very plausibly held secrets.

    @Test("a .env with lines that all failed to parse, and nothing salvaged, is blocked, not silently empty")
    func dotEnvWithOnlySkippedLinesIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        // No `=` and no `: ` anywhere on this line — `DotEnvParser` cannot
        // read it as an assignment at all, so it lands in `skipped`, not
        // `entries` with a suspicion (that's what a line like
        // `KEY="unterminated` gets instead — still an accepted entry).
        let picked = try sourceFile(named: "input.env", containing: "not a valid config line at all\n")
        model.loadDotEnv(from: picked)
        let parsed = try #require(model.dotEnvParsed)
        try #require(parsed.entries.isEmpty, "precondition: nothing was salvaged")
        try #require(!parsed.skipped.isEmpty, "precondition: something looked like an assignment and failed")

        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(!message.detail.isEmpty)
        #expect(message == CreationFailurePresenter.message(forDotEnvWithNoUsableEntries: ()))

        let created = await model.create()
        #expect(created == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.yaml").path))
    }

    @Test("a genuinely empty or comments-only .env is ready, and creates the same {} document .empty would")
    func emptyOrCommentsOnlyDotEnvIsReadyAndCreatable() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let picked = try sourceFile(named: "input.env", containing: "# just a comment\n\n")
        model.loadDotEnv(from: picked)
        let parsed = try #require(model.dotEnvParsed)
        try #require(parsed.entries.isEmpty)
        try #require(parsed.skipped.isEmpty, "precondition: nothing even looked like a failed assignment")

        model.sourceChoice = .dotEnv
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("expected .ready for a genuinely empty .env, got \(model.readiness)")
            return
        }

        let created = await model.create()
        let destination = try #require(created)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        #expect(rows.isEmpty)
    }
}

// MARK: - A verdict may not outlive what it was a verdict about
//
// Four rounds of this task fixed four separate instances of one class of
// defect: `readiness` was a *stored* verdict, and the facts it was computed
// from — `planError` above all — were cleared by only some of the code paths
// that change what is being created. Every new path that recomputed
// readiness, or every new way to change the inputs without recomputing it,
// was another chance for the sheet to describe a situation that no longer
// existed.
//
// These tests do not check four particular doors. They check the property
// the fix rests on, along every axis by which "what would be created" can
// change: **the name**, **the source kind**, and **the source content**. A
// verdict about a previous create attempt must not survive any of them, and
// `readiness` must follow the model's inputs with no recompute call in
// between — because there is no stored verdict left to go stale.

@Suite("A stale verdict cannot outlive what it describes")
@MainActor
struct StaleVerdictTests {

    private func sourceFile(named name: String, containing text: String) throws -> URL {
        let dir = try scratchDirectory("new-secret-file-sheet-stale-source")
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A project whose one rule names this session's own key, so nothing but
    /// the thing under test can block a create.
    private func ownedProject() throws -> (root: URL, owner: AgeKeyPair, keyStore: SessionKeyStore) {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        return (root, owner, try makeKeyStore(importing: owner.private))
    }

    // MARK: - The source content changed

    /// The fourth instance, exactly as the review described it: a malformed
    /// Plain YAML source makes `create()` fail with `SecretFileCreator
    /// .Failure.engine`, which is *not* `wouldBeUnreadable`, so the failure
    /// message was recorded and `readiness` went `.blocked`. The natural next
    /// action is to pick a different file — and `NewSecretFileSheet` calls
    /// `loadPlainYAML(from:)` directly, deliberately not through
    /// `resolvePlan()`. The load succeeded, the content was replaced, and the
    /// banner still described the file the user had already thrown away, with
    /// Create still disabled and no signposted way out.
    @Test("a create failure about one Plain YAML source does not survive picking a different one")
    func createFailureDoesNotSurviveANewPlainYAMLSource() async throws {
        let (root, owner, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let broken = try sourceFile(named: "broken.yaml", containing: "db: [unterminated\n")
        model.loadPlainYAML(from: broken)
        model.sourceChoice = .plainYAML
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        #expect(await model.create() == nil)
        guard case .blocked = model.readiness else {
            Issue.record("precondition: expected .blocked after the malformed source, got \(model.readiness)")
            return
        }

        // The user picks a different, valid file. Nothing else happens — no
        // rename, no source-radio toggle, no `resolvePlan()`.
        let good = try sourceFile(named: "good.yaml", containing: "db:\n    password: fine-EXAMPLE\n")
        model.loadPlainYAML(from: good)

        #expect(model.planError == nil, "the failure was about content that has been replaced")
        guard case .ready = model.readiness else {
            Issue.record("expected .ready for the freshly loaded source, got \(model.readiness)")
            return
        }

        // And it is not merely cosmetic: creating now actually works.
        let destination = try #require(await model.create())
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        #expect(rows.first { $0.path == ["db", "password"] }?.value == "fine-EXAMPLE")
    }

    /// The same axis through `loadDotEnv(from:)`, the second of the two
    /// loaders that recompute readiness without going through
    /// `resolvePlan()` — a fix that happened to work for one source and not
    /// the other is exactly what the previous rounds kept producing.
    ///
    /// The refusal here (`SecretFileCreator.Failure.destinationExists`) is
    /// about the *name*, not the content, and it deliberately does not
    /// survive the content change either: forgetting the last attempt
    /// wholesale returns the model to the state it would be in had that
    /// attempt never happened, and for an occupied destination that state is
    /// `.ready` — nothing in this model ever looks at the filesystem before
    /// `create()` does, so a fresh model here reports `.ready` too. Erring
    /// toward forgetting costs a repeated, accurate refusal; erring the other
    /// way is what produced four rounds of stale banners with no way out.
    @Test("a create failure does not survive picking a different .env source either")
    func createFailureDoesNotSurviveANewDotEnvSource() async throws {
        let (root, _, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        try "occupied\n".write(
            to: root.appendingPathComponent("taken.yaml"), atomically: true, encoding: .utf8)

        let picked = try sourceFile(named: "input.env", containing: "API_KEY=sk_live_EXAMPLE\n")
        model.loadDotEnv(from: picked)
        model.sourceChoice = .dotEnv
        model.relativeName = "taken.yaml"
        await model.resolvePlan()

        #expect(await model.create() == nil)
        guard case .blocked = model.readiness else {
            Issue.record("precondition: expected .blocked for an occupied destination, got \(model.readiness)")
            return
        }

        let repicked = try sourceFile(named: "other.env", containing: "OTHER=value-EXAMPLE\n")
        model.loadDotEnv(from: repicked)

        #expect(model.planError == nil, "the verdict was about an attempt that is no longer the one in hand")
        guard case .ready = model.readiness else {
            Issue.record("expected the fresh-model state for the new content, got \(model.readiness)")
            return
        }

        // And the refusal comes straight back, accurate, the moment it is
        // earned again — forgetting is not the same as excusing.
        #expect(await model.create() == nil)
        guard case .blocked(let repeated) = model.readiness else {
            Issue.record("expected .blocked again on the next attempt, got \(model.readiness)")
            return
        }
        #expect(repeated.detail.contains("taken.yaml"))
    }

    // MARK: - The source kind changed

    /// Switching the source radio is a change to what would be created that
    /// goes through no model method at all — `sourceChoice` is a plain
    /// property with no observer (the view calls `resolvePlan()` afterwards,
    /// but a stored verdict is already wrong by then, and nothing obliges a
    /// future caller to make that call).
    @Test("a create failure does not survive switching to a source that has nothing loaded")
    func createFailureDoesNotSurviveASourceChoiceChange() async throws {
        let (root, _, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        // Something is already at the destination, so `create()` refuses with
        // `SecretFileCreator.Failure.destinationExists` — a failure with
        // nothing to do with the source, which is exactly the point.
        try "occupied\n".write(
            to: root.appendingPathComponent("taken.yaml"), atomically: true, encoding: .utf8)
        model.relativeName = "taken.yaml"
        await model.resolvePlan()

        #expect(await model.create() == nil)
        guard case .blocked = model.readiness else {
            Issue.record("precondition: expected .blocked for an occupied destination, got \(model.readiness)")
            return
        }

        model.sourceChoice = .plainYAML

        #expect(
            model.readiness == .needsSource,
            "a Plain YAML source with nothing picked yet is .needsSource, not a verdict about the empty source")
    }

    // MARK: - The name changed

    @Test("a create failure about one name does not survive typing a different one")
    func createFailureDoesNotSurviveANameChange() async throws {
        let (root, _, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        try "occupied\n".write(
            to: root.appendingPathComponent("taken.yaml"), atomically: true, encoding: .utf8)
        model.relativeName = "taken.yaml"
        await model.resolvePlan()

        #expect(await model.create() == nil)
        guard case .blocked = model.readiness else {
            Issue.record("precondition: expected .blocked for an occupied destination, got \(model.readiness)")
            return
        }

        // One keystroke's worth of change, inside the view's own 200ms
        // debounce window — before any resolve has run for the new name.
        model.relativeName = "free.yaml"

        if case .blocked = model.readiness {
            Issue.record("the refusal named taken.yaml; the name is now free.yaml")
        }
        #expect(model.planError == nil)

        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("expected .ready once free.yaml resolves, got \(model.readiness)")
            return
        }
    }

    // MARK: - Readiness follows its inputs with nothing in between

    /// The property the three tests above all rest on, checked directly:
    /// `readiness` is derived on every read, never a value some earlier call
    /// happened to store. Clearing the name is the cheapest way to prove it —
    /// no method call, no observer, no resolve.
    @Test("readiness follows the name with no recompute call in between")
    func readinessIsDerivedNotStored() async throws {
        let (root, _, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("precondition: expected .ready, got \(model.readiness)")
            return
        }

        model.relativeName = ""

        #expect(
            model.readiness == .needsName,
            "readiness must be derived from the model's inputs, not stored by whoever last recomputed it")
    }

    // MARK: - A name that has changed since the last resolve describes nothing

    @Test("a name typed since the last resolve is .resolving, not the previous name's verdict")
    func aNameNotYetResolvedIsResolving() async throws {
        let (root, owner, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        try #require(model.readiness == .ready(recipients: [owner.public]))

        model.relativeName = "other.yaml"

        #expect(
            model.readiness == .resolving,
            "the plan in hand was resolved for secret.yaml and says nothing about other.yaml")
        #expect(!NewSecretFileSheet.canCreate(readiness: model.readiness, isCreating: false))
        // And `create()` still refuses, as it always did — the change is that
        // the button is no longer offered in the first place.
        #expect(await model.create() == nil)
    }

    // MARK: - The probe the other tests trust must itself be sound

    /// `planError` is what three of the tests above assert `== nil` as their
    /// proof that a verdict was dropped. That makes it the one surface that
    /// must not itself be expressible-stale — a probe that can lie makes every
    /// test using it worthless.
    ///
    /// Reachable by typing alone: a name with a `..` component throws
    /// `CreationPlanResolver.Error.targetOutsideProjectRoot`, so the
    /// resolution carries an error. Fixing the name must retire that error
    /// with it, exactly as `readiness` already does — it is a refusal about
    /// the name that was resolved, not about the one in the field now.
    @Test("a resolve failure about one name is not reported for a different one")
    func resolveFailureIsNotReportedForALaterName() async throws {
        let (root, _, keyStore) = try ownedProject()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        model.relativeName = "../escaped.yaml"
        await model.resolvePlan()
        try #require(model.planError != nil, "precondition: the escape was refused")
        guard case .blocked = model.readiness else {
            Issue.record("precondition: expected .blocked for a .. name, got \(model.readiness)")
            return
        }

        // The user fixes the name. No resolve has run for it yet.
        model.relativeName = "fine.yaml"

        #expect(model.readiness == .resolving)
        #expect(
            model.planError == nil,
            "the refusal named ../escaped.yaml and says nothing about fine.yaml")
    }

    // MARK: - The mechanism itself

    @Test("a fact filed about one subject cannot be read back for another")
    func aLearnedFactIsUnreadableOnceItsSubjectChanges() {
        let message = CreationFailureMessage(title: .creationFailureTitle, detail: "refused", recovery: nil)
        let plan = NewSecretFileModel.GovernedPlan(recipients: ["age1aaa"], encryptedRegex: "")
        let subject = NewSecretFileModel.AttemptSubject(
            name: "secret.yaml", plan: plan, source: .verbatimYAML("a: b\n"),
            acknowledgedUnreadable: false)
        let learned = NewSecretFileModel.Learned(message, about: subject)

        #expect(learned.value(ifStillAbout: subject) == message)

        // Every field of the subject, one at a time — this is the whole
        // surface by which "what is being created" can differ, and the test
        // has to be updated by anyone who widens that surface.
        let renamed = NewSecretFileModel.AttemptSubject(
            name: "other.yaml", plan: plan, source: subject.source,
            acknowledgedUnreadable: subject.acknowledgedUnreadable)
        let reaimed = NewSecretFileModel.AttemptSubject(
            name: subject.name,
            plan: NewSecretFileModel.GovernedPlan(recipients: ["age1bbb"], encryptedRegex: ""),
            source: subject.source, acknowledgedUnreadable: subject.acknowledgedUnreadable)
        let rescoped = NewSecretFileModel.AttemptSubject(
            name: subject.name,
            plan: NewSecretFileModel.GovernedPlan(recipients: ["age1aaa"], encryptedRegex: "^data$"),
            source: subject.source, acknowledgedUnreadable: subject.acknowledgedUnreadable)
        let refilled = NewSecretFileModel.AttemptSubject(
            name: subject.name, plan: plan, source: .verbatimYAML("c: d\n"),
            acknowledgedUnreadable: subject.acknowledgedUnreadable)
        let resourced = NewSecretFileModel.AttemptSubject(
            name: subject.name, plan: plan, source: .empty,
            acknowledgedUnreadable: subject.acknowledgedUnreadable)
        // The waiver that turns off `SecretFileCreator`'s round-trip
        // verification entirely — a refusal learned without it is not a
        // refusal about the same attempt.
        let waived = NewSecretFileModel.AttemptSubject(
            name: subject.name, plan: plan, source: subject.source, acknowledgedUnreadable: true)

        for changed in [renamed, reaimed, rescoped, refilled, resourced, waived] {
            #expect(learned.value(ifStillAbout: changed) == nil)
        }
    }
}

// MARK: - The structure the four fix rounds were missing
//
// Every instance of the stale-verdict defect had the same two ingredients: a
// verdict held in a stored property, and a fact behind it that some code path
// forgot to clear. Both are now impossible to write in `NewSecretFileModel` —
// `readiness` and `planError` are computed, so there is no verdict to store,
// and the facts they read are `Learned` values whose only accessor demands the
// current subject.
//
// The `Learned` half is enforced by the compiler: there is no accessor that
// does not take a subject, so no call site can read a fact without saying what
// it would be a fact about. The computed half cannot be enforced by the
// compiler — nothing stops someone turning `readiness` back into a `var` and
// assigning it — so it is enforced here instead. This suite is the reason a
// fifth instance would be caught before it shipped rather than in a fifth
// review, and it reads the source directly for the same reason
// `CreateButtonWiringTests` does.

@Suite("NewSecretFileModel stores no verdicts")
struct NoStoredVerdictTests {

    private func modelSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SopsUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/SopsUI/Projects/NewSecretFileModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines of `source` with comment tails removed, so a property *named* in
    /// a doc comment cannot make this check pass or fail.
    private func codeLines(_ source: String) -> [Substring] {
        source.split(whereSeparator: \.isNewline).map { line in
            guard let comment = line.range(of: "//") else { return line }
            return line[line.startIndex..<comment.lowerBound]
        }
    }

    /// Lines that assign to `name`: the identifier, any amount of whitespace,
    /// then a single `=`.
    ///
    /// **What it catches:** `name = x`, `name=x`, `name   =  x`,
    /// `self.name = x`. Not `name == x`, and not the compound operators
    /// (`+=`, `??=`, …), whose character before the `=` is neither whitespace
    /// nor part of the identifier. Not `nameSomething = x` or `_name = x`
    /// either — the identifier has to stand on its own.
    ///
    /// **What it does not catch, stated rather than implied:** an assignment
    /// split across two source lines (`name`, newline, `= x` — legal Swift,
    /// never written here), and an assignment routed through a function
    /// (`setReadiness(.needsName)`). `declarationsMentioning(_:)` covers the
    /// other shape this could miss — a differently-named stored property
    /// behind a computed passthrough — which is the case a name-based scan
    /// cannot see on its own.
    private func assigns(_ name: String, in lines: [Substring]) -> [String] {
        lines.compactMap { line -> String? in
            var search = line.startIndex
            while let found = line.range(of: name, range: search..<line.endIndex) {
                search = found.upperBound
                // The identifier must stand alone: `_readiness` and
                // `readinessValue` are different properties.
                if found.lowerBound > line.startIndex {
                    let before = line[line.index(before: found.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                var cursor = found.upperBound
                while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                    cursor = line.index(after: cursor)
                }
                guard cursor < line.endIndex, line[cursor] == "=" else { continue }
                let afterEquals = line.index(after: cursor)
                // `==` is a comparison, not an assignment.
                if afterEquals < line.endIndex, line[afterEquals] == "=" { continue }
                return String(line).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// Code lines declaring a `var` whose text mentions `name`, case
    /// insensitively — the check that a computed property has not simply
    /// become a passthrough in front of a stored `_name`/`storedName`, which
    /// would leave both assignment scans above perfectly green while the
    /// verdict went right back to being stored.
    private func declarationsMentioning(_ name: String, in lines: [Substring]) -> [String] {
        lines.filter { $0.contains("var ") && $0.lowercased().contains(name.lowercased()) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    @Test("readiness is computed, never assigned, with nothing stored behind it")
    func readinessIsComputed() throws {
        let source = try modelSource()
        let lines = codeLines(source)
        #expect(
            source.contains("public var readiness: Readiness {"),
            "readiness must stay a computed property — a stored one is what four fix rounds kept patching")
        #expect(
            assigns("readiness", in: lines).isEmpty,
            "nothing may assign readiness; it is derived from the model's inputs on every read")
        #expect(
            declarationsMentioning("readiness", in: lines) == ["public var readiness: Readiness {"],
            "exactly one var may mention readiness — a second is a stored property behind a passthrough")
    }

    @Test("planError is computed, never assigned, with nothing stored behind it")
    func planErrorIsComputed() throws {
        let source = try modelSource()
        let lines = codeLines(source)
        // `internal`, not `public`: nothing outside this module reads it and
        // nothing renders it — it is this suite's own staleness probe. See
        // its doc comment for why promoting it would mean reconciling its
        // precedence with `readiness`'s first.
        #expect(source.contains("var planError: CreationFailureMessage? {"))
        #expect(
            !source.contains("public var planError"),
            "planError is the tests' probe, not a second failure sentence for a view to render")
        #expect(
            assigns("planError", in: lines).isEmpty,
            "planError describes the attempt in hand, not one that was in hand when someone last set it")
        #expect(
            declarationsMentioning("planError", in: lines) == ["var planError: CreationFailureMessage? {"])
    }

    /// The third computed verdict of exactly this class — and the one whose
    /// staleness would be an **access disclosure** error rather than a UI
    /// annoyance: `encryptedImport` names, by recipient, who gains and loses
    /// access to a file that does not exist yet. A stored version of it would
    /// go stale on every keystroke in the name field after an unlock, telling
    /// a user "Alice gains access" for a plan that no longer names Alice —
    /// which is exactly what spec §4.1 decision 4 exists to prevent. This
    /// suite's stated purpose is that a further instance is caught before it
    /// ships; leaving the highest-stakes verdict unguarded would defeat that.
    @Test("encryptedImport is computed, never assigned, with only its learned fact stored")
    func encryptedImportIsComputed() throws {
        let source = try modelSource()
        let lines = codeLines(source)
        #expect(source.contains("public var encryptedImport: EncryptedImportState {"))
        #expect(
            assigns("encryptedImport", in: lines).isEmpty,
            "nothing may assign encryptedImport; the diff is derived on every read against the live plan")
        // Exactly two `var`s may mention it, in declaration order: the
        // `Learned` fact keyed to the file path that was actually unlocked —
        // the one thing that genuinely cannot change without another unlock
        // — and the computed property that diffs it against the live plan. A
        // third would be a stored diff, which is the defect.
        #expect(
            declarationsMentioning("encryptedImport", in: lines) == [
                "private var encryptedImportOutcome: Learned<String, EncryptedImportOutcome>?",
                "public var encryptedImport: EncryptedImportState {",
            ],
            "a third var mentioning encryptedImport is a stored diff waiting to go stale")
    }

    /// The negative-space check: these guards are only worth anything if they
    /// can actually fail. Proven against lines of the exact shapes they exist
    /// to reject — including the whitespace variants a narrower scan would
    /// have let through — rather than trusted because they returned green.
    @Test("the guards can fail — every rejected shape is detected, and no accepted one is")
    func theGuardsDetectWhatTheyClaim() {
        for planted in ["readiness = x", "readiness=x", "readiness   =   x", "self.readiness = x"] {
            #expect(assigns("readiness", in: codeLines(planted)).count == 1, "missed: \(planted)")
        }
        for innocent in [
            "if readiness == .needsName { return }", "// readiness = .needsName",
            "_readiness = x", "readinessValue = x", "count += readiness",
        ] {
            #expect(assigns("readiness", in: codeLines(innocent)).isEmpty, "false positive: \(innocent)")
        }

        // The passthrough shape, which no assignment scan can see.
        let passthrough = """
            private var _readiness: Readiness = .needsName
            public var readiness: Readiness { _readiness }
            """
        #expect(declarationsMentioning("readiness", in: codeLines(passthrough)).count == 2)
    }
}
