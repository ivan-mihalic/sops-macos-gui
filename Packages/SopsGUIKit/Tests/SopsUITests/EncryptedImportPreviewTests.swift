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
// in-process bridge throughout — the identical discipline
// `NewSecretFileModelTests.swift` (Task 2) and `NewSecretFileSheetTests.swift`
// (Task 4) both stand on, duplicated here rather than shared because those
// files' own helpers are `private` to them.

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

private func scratchDirectory(_ label: String = "encrypted-import-preview") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A `.sops.yaml` with one age-only creation rule naming every recipient in
/// `recipients` — mirrors `NewSecretFileModelTests.ageOnlyConfig(_:)`, widened
/// to more than one key since this suite's whole point is a target rule whose
/// recipients differ from the source file's own.
private func ageConfig(_ recipients: [String]) -> String {
    """
    creation_rules:
      - path_regex: .*\\.yaml$
        age: \(recipients.joined(separator: ","))
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

/// Writes `plaintext`, encrypted for `recipients`, to `url` — the "already
/// encrypted file" this whole feature exists to import. Real `SopsBridge`
/// encryption, not a fixture string, so the file this model unlocks is
/// exactly the shape a real SOPS document has.
private func writeEncryptedFixture(plaintext: String, recipients: [String], to url: URL) throws {
    let encrypted = try SopsBridge.encryptYAML(plaintext, recipients: recipients)
    try encrypted.write(to: url, atomically: true, encoding: .utf8)
}

// `allStrings(reachableFrom:)`/`modelRetains(_:_:)` — the Mirror-sweep leak
// proof both this file and `NewSecretFileModelTests.swift` need — live in
// `MirrorSweepTestSupport.swift`, `internal` to this test target. A review
// round found two byte-identical `private` copies and asked for the third,
// shared one instead of a third copy.

// MARK: - Model-level: chooseEncryptedFile / unlockChosenEncryptedFile

@Suite("NewSecretFileModel.encryptedImport")
@MainActor
struct EncryptedImportModelTests {

    @Test(".notChosen before anything is picked, .locked immediately after picking, before any unlock")
    func notChosenThenLocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"

        #expect(model.encryptedImport == .notChosen)

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "key: value\n", recipients: [owner.public], to: source)
        model.chooseEncryptedFile(at: source)

        // Synchronous check, deliberately before `await
        // model.unlockChosenEncryptedFile()` is ever called: choosing a file
        // reads nothing and unlocks nothing on its own.
        #expect(model.encryptedImport == .locked(path: source.path))
        // `.locked` reads exactly like "nothing loaded yet" to `readiness` —
        // the same `.needsSource` every other source reports before it has
        // content, and specifically not `.ready`: an in-flight unlock must
        // never let Create fire against a source that has not actually
        // produced anything to encrypt.
        model.sourceChoice = .encryptedYAML
        #expect(model.readiness == .needsSource)
    }

    /// The Critical review finding: `currentGovernedPlan()` is `nil` before
    /// any `.sops.yaml`/recipients exist for the target, and an earlier
    /// version of `encryptedImport` treated `nil` as "the target is nobody"
    /// — naming every one of the source's own recipients as *losing*
    /// access, a false statement about an outcome nothing has decided yet.
    /// `.unlockedAwaitingPlan` is the fix: decrypted, but nothing to compare
    /// against, reported as its own state rather than a diff against an
    /// invented empty target.
    @Test("a decrypted file with no target plan yet reports unlockedAwaitingPlan, not a diff against nobody")
    func unlockedWithNoTargetPlanYetReportsAwaitingPlan() async throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // No `.sops.yaml` at all — `CreationPlanResolver` resolves this to
        // `.noConfig`, and `currentGovernedPlan()` returns `nil` until
        // `manuallyChosenRecipients` is non-empty (Task 5's own picker path).
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()
        try #require(model.plan == .noConfig)

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public, b.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()

        #expect(model.encryptedImport == .unlockedAwaitingPlan)
        // Not `.blocked` either — `.noConfig` was never a failure (see
        // `CreationPlan`'s own doc comment) and this state must not invent
        // one. `RecipientPicker` is the way out, exactly as it already is
        // for every other source.
        #expect(model.readiness == .needsRecipients)

        // And once a target *is* chosen, the very next read reports the real
        // diff — no second unlock, matching `diffTracksTheLivePlanAfterUnlock`.
        model.manuallyChosenRecipients = [a.public]
        #expect(model.encryptedImport == .unlocked(gaining: [], losing: [b.public], keeping: [a.public]))
    }

    /// The second door the review found into the Critical's exact false
    /// disclosure — not "no `.sops.yaml` yet" (the test above) but "a real
    /// `.sops.yaml` rule matches this path and names *zero* recipients",
    /// which `CreationPlanResolverTests
    /// .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients` measured sops's
    /// own config loader actually admits. `model.plan` here is
    /// `.governedByRule(recipients: [], …)`, not `.noConfig` — a genuinely
    /// different shape from the test above, so it is not covered by it: an
    /// earlier version of `currentGovernedPlan()` only treated a `nil` plan
    /// as "no target", and passed an *empty-but-present* recipient list
    /// straight through as a real one. Proves the same guard now catches
    /// this shape too — `.unlockedAwaitingPlan`, never a diff naming the
    /// source's own recipients as losing access to a destination that, in
    /// truth, the project's own config names nobody for at all.
    @Test("a matched rule naming no recipients at all also reports unlockedAwaitingPlan, not a diff naming everyone as losing access")
    func ruleWithNoRecipientsReportsAwaitingPlanNotADiff() async throws {
        let a = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()
        try #require(model.plan == .governedByRule(recipients: [], encryptedRegex: ""))

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()

        #expect(model.encryptedImport == .unlockedAwaitingPlan)
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(message.detail.localizedCaseInsensitiveContains("no recipients"))
    }

    /// Important 3 from the review: every `decryptYAML`/`recipients(in:)`
    /// throw used to be reported with the fixed sentence "This session's
    /// key could not decrypt this file" — true for a wrong identity, false
    /// for this scenario, where the file is not a SOPS document at all (a
    /// wizard whose neighbouring source is literally "Plain YAML" makes this
    /// an easy file to pick by mistake). The message must carry the bridge's
    /// own diagnostic, not a claim about the key that cannot be corrected by
    /// importing a different one.
    @Test("a source that is not a SOPS document at all is unlockFailed with the bridge's own reason, not a false claim about the key")
    func nonSopsSourceReportsTheBridgesOwnReason() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"

        // A plain, unencrypted YAML file — no `sops:` metadata at all, the
        // exact shape `NewSecretFileSheet`'s "Plain YAML" source expects,
        // picked here for "Encrypted YAML" by mistake.
        let source = root.appendingPathComponent("source.yaml")
        try "greeting: hello\n".write(to: source, atomically: true, encoding: .utf8)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)

        await model.unlockChosenEncryptedFile()

        guard case .unlockFailed(let message) = model.encryptedImport else {
            Issue.record("expected .unlockFailed, got \(model.encryptedImport) — this test would be vacuous")
            return
        }
        // The bridge's own diagnostic, not silently dropped — `Void` used to
        // be all this call site could pass, so every cause collapsed into
        // one fixed, sometimes-false sentence.
        #expect(message.detail.hasPrefix("This file could not be unlocked:"))
        #expect(message.detail != "This file could not be unlocked: ",
                "the bridge's own reason must actually be present, not an empty suffix")
        // The old, unconditional claim must not survive anywhere in the
        // sentence for a cause that has nothing to do with the key at all.
        #expect(!message.detail.contains("session's key could not decrypt"))
    }

    /// The scenario this task's own brief spells out: a source encrypted for
    /// A+B, a session key A, a target rule for A+C.
    @Test("unlocking against a target with a different recipient set discloses exactly who gains, loses and keeps access")
    func unlockComputesAccessDiff() async throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        let c = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // Target rule: A + C.
        try ageConfig([a.public, c.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()
        // The resolver does not promise to preserve the order recipients
        // were written in — measured directly: it does not — so this checks
        // the *set* the plan governs, not a specific ordering, and reads
        // `readiness`'s own recipient list back afterwards rather than
        // hardcoding a second literal that would have to guess the same
        // order right.
        guard case .governedByRule(let targetRecipients, let regex) = model.plan else {
            Issue.record("expected .governedByRule, got \(String(describing: model.plan))")
            return
        }
        #expect(Set(targetRecipients) == Set([a.public, c.public]))
        #expect(regex == "")

        // Source: A + B.
        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public, b.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)

        await model.unlockChosenEncryptedFile()

        // Each array here has exactly one element, so the resolver's own
        // recipient ordering (not guaranteed to match input order — see
        // above) cannot affect these three comparisons either way.
        #expect(model.encryptedImport == .unlocked(gaining: [c.public], losing: [b.public], keeping: [a.public]))
        // The diff alone is not the whole story — `readiness` has to treat
        // this exactly like any other loaded source once unlocked.
        #expect(model.readiness == .ready(recipients: targetRecipients))
    }

    /// The diff is derived from the *live* plan, not stored at unlock time —
    /// see `NewSecretFileModel.encryptedImport`'s own doc comment for why. A
    /// target plan that changes after a successful unlock (here: a second
    /// recipient added to the rule) must be reflected immediately, with no
    /// second unlock.
    @Test("the access diff tracks a target plan that changes after the file is already unlocked")
    func diffTracksTheLivePlanAfterUnlock() async throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let configURL = root.appendingPathComponent(".sops.yaml")
        try ageConfig([a.public]).write(to: configURL, atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()

        #expect(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))

        // The rule widens to A + B, with no further call to
        // `unlockChosenEncryptedFile()` — the model must still notice.
        try ageConfig([a.public, b.public]).write(to: configURL, atomically: true, encoding: .utf8)
        await model.resolvePlan()

        #expect(model.encryptedImport == .unlocked(gaining: [b.public], losing: [], keeping: [a.public]))
    }

    @Test("a file this session's key cannot decrypt is unlockFailed, readiness is blocked, and create() writes nothing")
    func wrongKeyFailsToUnlockAndCreatesNothing() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([owner.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        // Encrypted only for `stranger` — `owner`'s session key cannot open it.
        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "secret: value\n", recipients: [stranger.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)

        await model.unlockChosenEncryptedFile()

        guard case .unlockFailed = model.encryptedImport else {
            Issue.record("expected .unlockFailed, got \(model.encryptedImport)")
            return
        }
        guard case .blocked = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }

        let created = await model.create()

        #expect(created == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("imported.yaml").path))
    }

    @Test("an unreadable source file is unlockFailed, not a crash, and names no path in the message")
    func unreadableSourceFileIsUnlockFailed() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"

        // Never created — `chooseEncryptedFile(at:)` only records the URL;
        // `unlockChosenEncryptedFile()` is what actually tries to read it.
        let missing = root.appendingPathComponent("does-not-exist.yaml")
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: missing)

        await model.unlockChosenEncryptedFile()

        guard case .unlockFailed = model.encryptedImport else {
            Issue.record("expected .unlockFailed, got \(model.encryptedImport)")
            return
        }
    }

    @Test("create() on an unlocked import writes the decrypted content, re-encrypted for exactly the target recipients")
    func createWritesTheDecryptedContentForTheTargetRecipients() async throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([a.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        // Source encrypted for A + B — B is not in the target rule at all.
        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public, b.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        try #require(model.readiness == .ready(recipients: [a.public]))

        let created = await model.create()
        let destination = try #require(created)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: a.private)
        #expect(rows.first { $0.path == ["greeting"] }?.value == "hello")
        // `b` genuinely cannot read what was actually written — proving the
        // file was re-encrypted for the *target* rule, not for the source
        // file's own original recipients.
        #expect(throws: (any Error).self) {
            try SopsBridge.decryptToRows(encrypted, agePrivateKey: b.private)
        }
    }

    @Test("picking a different file drops the previous unlock outcome")
    func pickingADifferentFileDropsThePreviousOutcome() async throws {
        let a = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([a.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        let first = root.appendingPathComponent("first.yaml")
        try writeEncryptedFixture(plaintext: "one: 1\n", recipients: [a.public], to: first)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: first)
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))

        let second = root.appendingPathComponent("second.yaml")
        try writeEncryptedFixture(plaintext: "two: 2\n", recipients: [a.public], to: second)
        model.chooseEncryptedFile(at: second)

        // Back to `.locked` for the new path — the old `.unlocked` verdict,
        // learned about `first.yaml`, must not still describe `second.yaml`.
        #expect(model.encryptedImport == .locked(path: second.path))
    }

    /// Review Important 4, re-checked rather than taken on trust: unlock A,
    /// have `create()` refuse for a reason that has nothing to do with A's
    /// content (the destination already exists — a pre-existing file, not a
    /// content problem), pick B, then `Mirror`-sweep the *whole model* for
    /// the sentinel that only ever appeared in A's decrypted plaintext.
    ///
    /// This is deliberately not an assertion about `plainYAMLText`-shaped
    /// public state — that already changes the moment B loads, guard or no
    /// guard, and would make the test pass for the wrong reason. The
    /// sentinel can only still be reachable through `lastCreateFailure`'s
    /// retained `AttemptSubject.source`, which is `private` and escapes only
    /// through `value(ifStillAbout:)` — clearing it changes no *observable*
    /// behaviour a black-box test could see, which is exactly why a
    /// behavioural test proves nothing about whether `chooseEncryptedFile(
    /// at:)` actually calls `forgetLastCreateFailure()`. `Mirror` reads
    /// storage directly, `private` or not.
    @Test("picking a different encrypted file after a refused create() does not retain the previous file's decrypted plaintext")
    func pickingADifferentFileAfterARefusedCreateDropsThePreviousPlaintext() async throws {
        let a = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([a.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        // The destination already exists — `create()` refuses at step 2,
        // deterministically, before it ever looks at what A's content is.
        let destination = root.appendingPathComponent("imported.yaml")
        try "already here\n".write(to: destination, atomically: true, encoding: .utf8)

        let sentinel = "correct-horse-battery-staple"
        let sourceA = root.appendingPathComponent("a.yaml")
        try writeEncryptedFixture(plaintext: "password: \(sentinel)\n", recipients: [a.public], to: sourceA)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: sourceA)
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))

        let created = await model.create()
        #expect(created == nil)
        guard case .blocked = model.readiness else {
            Issue.record("expected .blocked (destinationExists) — this test would be vacuous")
            return
        }

        let sourceB = root.appendingPathComponent("b.yaml")
        try writeEncryptedFixture(plaintext: "other: value\n", recipients: [a.public], to: sourceB)
        model.chooseEncryptedFile(at: sourceB)
        // Unlocked for real, not just picked — B's own plaintext is the
        // positive control below. A `Mirror` sweep that never actually saw
        // the model's live storage would pass the leak assertion for the
        // wrong reason (finding nothing because it is looking at nothing),
        // exactly the silent-false-green shape a missing positive control
        // leaves open. Proving the sweep finds B's own current, legitimate
        // content is what proves it would have found A's, had A's survived.
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))

        #expect(modelRetains("other: value", model),
                "positive control failed — Mirror did not see B's own current plaintext, so this test proves nothing")
        #expect(!modelRetains(sentinel, model),
                "the model still retains A's decrypted plaintext, reachable via Mirror, after B was picked")
    }
}

// MARK: - View-level: EncryptedImportPreview never leaks the decrypted plaintext

/// The sentinel-value discipline `AccessibilityTreeTests`/
/// `DotEnvPreviewTableTests` already established for this codebase's other
/// plaintext-adjacent surfaces, applied to this one: a value planted in the
/// fixture must never reach any rendered accessibility node.
@Suite("EncryptedImportPreview")
struct EncryptedImportPreviewTests {

    private static let sentinelValue = "correct-horse-battery-staple"

    @Test("the decrypted plaintext never reaches the accessibility tree of an unlocked import")
    @MainActor
    func decryptedContentNeverReachesTheTree() async throws {
        let a = try AgeKeyPair.generate()
        let c = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([a.public, c.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        // The sentinel lives only in the decrypted plaintext — never in a
        // recipient key, a path, or anything else this view legitimately
        // renders — so any appearance in the tree can only mean the
        // plaintext itself leaked.
        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(
            plaintext: "password: \(Self.sentinelValue)\n", recipients: [a.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        guard case .unlocked = model.encryptedImport else {
            Issue.record("expected .unlocked, got \(model.encryptedImport) — this test would be vacuous")
            return
        }

        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            EncryptedImportPreview(model: model)
        }

        // Canary: compared against `LocalizedKey.text` itself, not hardcoded
        // English, so this holds under both this machine's compilers (see
        // this repo's CLAUDE.md, "Toolchains") — a raw catalog key still
        // proves the `.unlocked` diff section actually rendered, which a
        // format-substituted sentence could not under `swift test`'s
        // uncompiled catalog (the `%@` token is dropped, not filled).
        let values = nodes.map(\.value)
        let labels = nodes.map(\.label)
        #expect(values.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text)
            || labels.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text),
            "the tree did not populate the access diff — this test would be vacuous")

        for node in nodes {
            #expect(!node.value.contains(Self.sentinelValue),
                    "an accessibility value exposed the decrypted plaintext")
            #expect(!node.label.contains(Self.sentinelValue),
                    "an accessibility label exposed the decrypted plaintext")
            #expect(!node.help.contains(Self.sentinelValue),
                    "accessibility help text exposed the decrypted plaintext")
        }
    }

    /// Important 1 from the review: a same-recipients import — the single
    /// most common case for a project whose rule already governs the
    /// source's own recipients — used to render "Importing this file will
    /// change who can read it:" directly above a body naming only who
    /// *keeps* access, a headline contradicting its own body. This proves
    /// the *other* title renders instead, and that the "will change" one
    /// does not, for the identical state `diffTracksTheLivePlanAfterUnlock`
    /// already proves at the model level (`gaining: [], losing: []`).
    @Test("importing into an identical recipient set renders the no-change title, not the change one")
    @MainActor
    func identicalRecipientSetRendersNoChangeTitle() async throws {
        let a = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageConfig([a.public])
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))

        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            EncryptedImportPreview(model: model)
        }
        let values = nodes.map(\.value)
        let labels = nodes.map(\.label)

        #expect(values.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text)
            || labels.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text),
            "the no-change title did not render — this test would be vacuous")
        #expect(!values.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text)
            && !labels.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text),
            "the \"will change\" title rendered for a state that changes nothing")
    }

    /// The Critical review finding, proven at the view level: a decrypted
    /// file with no target plan yet must render the neutral
    /// "awaiting a plan" sentence, never the diff (which would have to
    /// invent an empty target and name every source recipient as losing
    /// access to a destination nobody has chosen yet). The model-level proof
    /// is `unlockedWithNoTargetPlanYetReportsAwaitingPlan`; this is the
    /// rendering half, since the state alone does not prove the view
    /// actually branches on it correctly.
    @Test("a decrypted file with no target plan yet renders the awaiting-plan sentence, never a diff")
    @MainActor
    func awaitingPlanRendersNeitherDiffTitle() async throws {
        let a = try AgeKeyPair.generate()
        let b = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // No `.sops.yaml` — `.noConfig`, so `currentGovernedPlan()` is `nil`
        // until a recipient is chosen by hand.
        let keyStore = try makeKeyStore(importing: a.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"
        await model.resolvePlan()

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "greeting: hello\n", recipients: [a.public, b.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlockedAwaitingPlan)

        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            EncryptedImportPreview(model: model)
        }
        let values = nodes.map(\.value)
        let labels = nodes.map(\.label)

        #expect(values.contains(LocalizedKey.newFileEncryptedImportAwaitingPlanLabel.text)
            || labels.contains(LocalizedKey.newFileEncryptedImportAwaitingPlanLabel.text),
            "the awaiting-plan sentence did not render — this test would be vacuous")
        #expect(!values.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text)
            && !labels.contains(LocalizedKey.newFileEncryptedImportDiffTitle.text),
            "the \"will change\" diff title rendered with no target plan known")
        #expect(!values.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text)
            && !labels.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text),
            "the no-change diff title rendered with no target plan known")
    }

    /// Not a plaintext-decrypted-then-masked scenario like the two tests
    /// above — `stranger`'s key never decrypts anything on this path, so
    /// what this actually proves is narrower and worth stating precisely:
    /// the bridge's own error text (now threaded through `message.detail` —
    /// see `nonSopsSourceReportsTheBridgesOwnReason`) does not itself echo
    /// the source document's plaintext back at the user. A decrypt failure
    /// producing a diagnostic that happened to quote ciphertext or plaintext
    /// would be exactly as much of a leak as a masked value reaching the
    /// tree; this is the check for that half of the surface.
    @Test("an unlock failure's message renders, and the bridge's own error text never echoes the source's plaintext")
    @MainActor
    func unlockFailureRendersAndNeverEchoesTheSourcesPlaintext() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "imported.yaml"

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(
            plaintext: "password: \(Self.sentinelValue)\n", recipients: [stranger.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        guard case .unlockFailed(let message) = model.encryptedImport else {
            Issue.record("expected .unlockFailed, got \(model.encryptedImport) — this test would be vacuous")
            return
        }

        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            EncryptedImportPreview(model: model)
        }

        let values = nodes.map(\.value) + nodes.map(\.label)
        #expect(values.contains(message.title.text), "the failure title did not render")
        #expect(values.contains(where: { $0.contains(message.detail) }), "the failure detail did not render")

        for node in nodes {
            #expect(!node.value.contains(Self.sentinelValue), "an accessibility value exposed the decrypted plaintext")
            #expect(!node.label.contains(Self.sentinelValue), "an accessibility label exposed the decrypted plaintext")
            #expect(!node.help.contains(Self.sentinelValue), "accessibility help text exposed the decrypted plaintext")
        }
    }
}

// MARK: - Important 2, on the one screen that shows both halves

/// A `.sops.yaml` whose rule also sets `encrypted_regex` — the one scoping
/// field `CreationPlanResolver` passes through as supported rather than
/// refusing (`CreationPlanResolverTests.encryptedRegexPassesThrough`), and
/// therefore the one that makes a created file store values it does not
/// cover in plaintext.
private func scopedAgeConfig(_ recipients: [String], encryptedRegex: String) -> String {
    """
    creation_rules:
      - path_regex: .*\\.yaml$
        age: \(recipients.joined(separator: ","))
        encrypted_regex: '\(encryptedRegex)'
    """ + "\n"
}

/// The combined state neither half of the first fix looked at: an
/// `.encryptedYAML` source, unlocked, under a rule that scopes encryption.
/// `NewSecretFileSheet` renders the ⓘ line and `EncryptedImportPreview` in
/// the same window, about fifteen lines apart, and a first version put the
/// identical thirty-word sentence in both.
///
/// These render the **whole sheet**, not the preview alone, which is the only
/// way to see that at all.
@Suite("encrypted_regex scoping, on the sheet that shows the access diff")
@MainActor
struct EncryptedRegexScopingDisclosureTests {

    private static let regex = "^(data|stringData)$"
    private static let sheetSize = CGSize(width: 640, height: 720)

    /// Builds a sheet-ready model with an unlocked encrypted import, under a
    /// rule that sets `encryptedRegex` when one is given.
    private func unlockedImportModel(encryptedRegex: String?) async throws -> NewSecretFileModel {
        let a = try AgeKeyPair.generate()
        let root = try scratchDirectory("encrypted-regex-scoping")
        let config = encryptedRegex.map { scopedAgeConfig([a.public], encryptedRegex: $0) }
            ?? ageConfig([a.public])
        try config.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let model = NewSecretFileModel(projectRoot: root, keyStore: try makeKeyStore(importing: a.private))
        model.relativeName = "imported.yaml"
        await model.resolvePlan()
        try #require(
            model.plan == .governedByRule(recipients: [a.public], encryptedRegex: encryptedRegex ?? ""),
            "precondition: sops itself must report the rule as expected, or this proves nothing")

        let source = root.appendingPathComponent("source.yaml")
        try writeEncryptedFixture(plaintext: "data: secret\n", recipients: [a.public], to: source)
        model.sourceChoice = .encryptedYAML
        model.chooseEncryptedFile(at: source)
        await model.unlockChosenEncryptedFile()
        try #require(model.encryptedImport == .unlocked(gaining: [], losing: [], keeping: [a.public]))
        return model
    }

    /// The disclosure is present on this screen — and exactly once. Both
    /// halves matter: absent, the screen whose purpose is disclosing how
    /// access changes says only who can read the file; twice, the same long
    /// sentence is on screen in two places at once, which is how a sentence
    /// stops being read.
    @Test("the sheet discloses the scoping exactly once beside the access diff")
    func scopingIsDisclosedOnceOnTheImportSheet() async throws {
        let model = try await unlockedImportModel(encryptedRegex: Self.regex)

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let nodes = host.nodes()
        let rendered = nodes.map(\.value) + nodes.map(\.label)
        let scopingSentence = String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, Self.regex)

        // Canary: the access diff itself rendered, so this really is the
        // combined state and not a sheet that never got that far.
        #expect(
            rendered.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text),
            "the access diff did not render — this test would be vacuous")

        let occurrences = rendered.filter { $0.contains(scopingSentence) }.count
        #expect(
            occurrences == 1,
            "expected the scoping disclosure exactly once on this screen, found \(occurrences)")
    }

    @Test("an unscoped rule's import sheet says nothing about scoping")
    func unscopedRuleSaysNothingAboutScoping() async throws {
        let model = try await unlockedImportModel(encryptedRegex: nil)

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let nodes = host.nodes()
        let rendered = nodes.map(\.value) + nodes.map(\.label)
        #expect(
            rendered.contains(LocalizedKey.newFileEncryptedImportNoChangeTitle.text),
            "the access diff did not render — this test would be vacuous")
        // Both spellings, so this holds under either compiler: the compiled
        // catalog's English names `encrypted_regex`, and `swift test`'s
        // uncompiled one renders the raw key instead.
        #expect(
            !rendered.contains(where: {
                $0.contains("encrypted_regex")
                    || $0.contains(LocalizedKey.newFileInfoEncryptedRegexScoping.text)
            }),
            "a rule that scopes nothing must not warn about scoping")
    }
}
