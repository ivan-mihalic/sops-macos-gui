import AppKit
import Foundation
import ScratchCleanup
import SopsEngine
import SopsHealth
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// A real `age-keygen` identity, needed for exactly one test below
// (`governedByRuleShowsRegistryLabel`): `RecipientRegistry.save` validates
// every `ageRecipient` against the real bech32 shape
// (`looksLikeNativeAgeRecipient`), so a hand-typed placeholder like
// "age1qexample…" is refused with `.invalidAgeRecipient` before it ever
// reaches disk. Duplicated from `FileListModelConfigStateTests.swift`
// rather than shared — that file's own header comment states why every
// `SopsUITests` file needing this shape keeps its own copy.
private struct StartHereFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func startHereToolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .map { ($0 as NSString).appendingPathComponent(name) }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw StartHereFixtureError("\(name) not found in \(candidates)")
    }
    return found
}

private struct StartHereAgeKeyPair {
    let `public`: String

    static func generate() throws -> StartHereAgeKeyPair {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try startHereToolPath("age-keygen"))
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var pub = ""
        for line in output.split(separator: "\n") where line.hasPrefix("# public key: ") {
            pub = String(line.dropFirst("# public key: ".count))
        }
        guard !pub.isEmpty else { throw StartHereFixtureError("age-keygen produced no usable public key") }
        return StartHereAgeKeyPair(public: pub)
    }
}

// MARK: - ProjectStartHereView.presentation — the five configState shapes, decided without rendering
//
// Same shape `NewSecretFileSheetTests.InfoLineTextTests` already established
// for `NewSecretFileSheet.infoLineText`: a pure function over `CreationPlan`,
// tested directly against constructed values rather than through a real
// `.sops.yaml` and the bridge — appropriate here because
// `ProjectStartHereView` never resolves a plan itself, only renders one a
// caller (`FileListModel.configState`) already resolved. Task 1's own tests
// (`FileListModelConfigStateTests`) are what hold *that* resolution to a real
// bridge call; this file's job is only "given each shape, what is said".
@Suite("ProjectStartHereView.presentation — the five configState shapes")
struct ProjectStartHereViewPresentationTests {

    private func joinedNames(_ recipients: [String]) -> String { recipients.joined(separator: ", ") }

    /// `.noConfig` reuses `NewSecretFileSheet`'s own ⓘ-line key verbatim —
    /// review finding: an earlier draft kept a separate, near-duplicate
    /// "start-here.no-config.title" catalog entry that said the identical
    /// fact in slightly different words.
    @Test(".noConfig offers the create-first-file button")
    func noConfig() {
        let presentation = ProjectStartHereView.presentation(for: .noConfig, recipientNames: joinedNames)
        #expect(presentation == .headline(LocalizedKey.newFileInfoNoConfig.text, offersCreateButton: true))
    }

    /// Reuses `NewSecretFileSheet`'s own `new-file.info.governed-by-rule`,
    /// for the identical reason `.noConfig` does above — plus
    /// `startHereProbeLocation` appended, per the Important review finding
    /// below.
    @Test(".governedByRule names the recipients through the injected formatter and offers the button")
    func governedByRule() {
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: ["age1abc", "age1def"], encryptedRegex: ""),
            recipientNames: joinedNames)
        let expected = String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc, age1def")
            + " " + LocalizedKey.startHereProbeLocation.text
        #expect(presentation == .headline(expected, offersCreateButton: true))
    }

    /// Review finding, Important: `new-file.info.governed-by-rule` says "A
    /// rule in .sops.yaml governs **this location**" — true, and fine one
    /// screen over in `NewSecretFileSheet`, where the filename field just
    /// above gives "this location" a referent. On this screen there is no
    /// filename anywhere, and the sentence is the only headline on an
    /// otherwise empty pane, so an unqualified "this location" generalizes
    /// into a claim about the whole project. Failure scenario the review
    /// gave: `path_regex: ^secrets/` for one recipient and a catch-all
    /// `path_regex: .*` for another means the root probe resolves the
    /// catch-all, and this screen would say "…it will be encrypted for:
    /// <catch-all recipient>" — true of the probe, false of a file the user
    /// then names `secrets/…`. `startHereProbeLocation` closes the gap by
    /// naming the location instead of leaving it implicit.
    @Test(".governedByRule names the location the probe answer is actually about")
    func governedByRuleNamesTheLocation() {
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: ["age1abc"], encryptedRegex: ""), recipientNames: joinedNames)
        guard case .headline(let text, _) = presentation else {
            Issue.record("expected .headline, got \(presentation)")
            return
        }
        #expect(text.contains(LocalizedKey.startHereProbeLocation.text),
                "the headline must name the location the probe answer is about: \(text)")
    }

    /// Review finding, Important 1: naming only who can read the file, and
    /// saying nothing about how much of it is encrypted, is the silent half
    /// of an access change (`NewSecretFileSheet.governedByRuleSentence`'s
    /// own doc comment, spec §4.1 decision 4). This screen's own
    /// "…it will be encrypted for: …" sentence needs the identical
    /// disclosure the wizard's ⓘ line already carries for the same
    /// `CreationPlan` case — both now come from that one shared function,
    /// so this test is really pinning that `presentation(for:
    /// recipientNames:)` actually calls it rather than a re-derived copy.
    @Test(".governedByRule whose rule sets encrypted_regex discloses the plaintext scoping too")
    func governedByRuleWithEncryptedRegex() throws {
        let regex = "^(data|stringData)$"
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: ["age1abc"], encryptedRegex: regex), recipientNames: joinedNames)
        guard case .headline(let text, let offersCreateButton) = presentation else {
            Issue.record("expected .headline, got \(presentation)")
            return
        }
        let recipientsSentence = String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc")
        let scopingSentence = String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, regex)
        #expect(text.hasPrefix(recipientsSentence), "the recipients sentence must still lead the line")
        #expect(text.contains(scopingSentence), "the scoping disclosure is missing: \(text)")
        #expect(text.contains(LocalizedKey.startHereProbeLocation.text),
                "the location anchor is missing: \(text)")
        #expect(offersCreateButton)
    }

    @Test("a rule that sets no encrypted_regex says nothing about scoping")
    func governedByRuleWithoutEncryptedRegexSaysNothingExtra() {
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: ["age1abc"], encryptedRegex: ""), recipientNames: joinedNames)
        let expected = String(format: LocalizedKey.newFileInfoGovernedByRule.text, "age1abc")
            + " " + LocalizedKey.startHereProbeLocation.text
        #expect(presentation == .headline(expected, offersCreateButton: true))
    }

    /// The real, sops-admitted shape `CreationPlanResolverTests
    /// .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients` proves: a rule
    /// can match and still name nobody. Claiming "it will be encrypted for:"
    /// with an empty tail would be exactly the false claim
    /// `NewSecretFileSheet.infoLineText`'s own
    /// `governedByRuleWithNoRecipients` test already closed one screen over
    /// — this pins the identical guard here.
    @Test(".governedByRule with no recipients at all does not claim encryption will happen")
    func governedByRuleWithNoRecipients() {
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: [], encryptedRegex: ""), recipientNames: joinedNames)
        #expect(presentation == .failure(CreationFailurePresenter.messageForRuleWithNoRecipients()))
        if case .headline(let text, _) = presentation {
            Issue.record("must not fall back to a headline claiming encryption: \(text)")
        }
    }

    /// The load-bearing case, and the one the review's Critical finding was
    /// about. Two things must both hold:
    ///
    /// 1. The *fact* half reuses `new-file.info.no-rule-matched` verbatim
    ///    ("No rule in .sops.yaml matches this location yet.") — the
    ///    wizard's own careful wording, which never claims rules exist.
    /// 2. The *reassurance* half must never claim recipients here would be
    ///    "chosen by hand" as a certainty: the exact fixture Task 1 wrote to
    ///    pin this distinction (`FileListModelConfigStateTests
    ///    .noRuleMatchedFixture`, `path_regex: ^secrets/`) describes a
    ///    project where a file created under `secrets/` *is* rule-governed,
    ///    automatically — so this sentence is asserted not to contain
    ///    "hand" or "by hand" at all, the literal words the first, wrong
    ///    draft used to make that false promise.
    @Test(".noRuleMatched states the fact and a hedged reassurance, never a project-wide promise")
    func noRuleMatched() {
        let presentation = ProjectStartHereView.presentation(for: .noRuleMatched, recipientNames: joinedNames)
        let expected = LocalizedKey.newFileInfoNoRuleMatched.text + " "
            + LocalizedKey.startHereProbeLocation.text + " "
            + LocalizedKey.startHereNoRuleMatchedReassurance.text
        #expect(presentation == .headline(expected, offersCreateButton: false))

        guard case .headline(let text, _) = presentation else {
            Issue.record("expected .headline")
            return
        }
        #expect(!text.lowercased().contains("by hand"),
                "must not promise every file here needs hand-picked recipients: \(text)")
        #expect(!text.lowercased().contains("already has rules"),
                "must not assert that rules exist — a .sops.yaml with no creation_rules key is .noRuleMatched too: \(text)")
    }

    /// Review finding, Important: `.noRuleMatched` was only partly protected
    /// before this fix — its reassurance makes location salient ("files
    /// created in a **different** location") without ever naming *this*
    /// one. Same `startHereProbeLocation` anchor as `.governedByRule`.
    @Test(".noRuleMatched names the location the probe answer is actually about")
    func noRuleMatchedNamesTheLocation() {
        let presentation = ProjectStartHereView.presentation(for: .noRuleMatched, recipientNames: joinedNames)
        guard case .headline(let text, _) = presentation else {
            Issue.record("expected .headline, got \(presentation)")
            return
        }
        #expect(text.contains(LocalizedKey.startHereProbeLocation.text),
                "the headline must name the location the probe answer is about: \(text)")
    }

    /// Reused verbatim from `CreationFailurePresenter`, not re-worded here —
    /// compared against the actual call, not a literal, so a wrong-branch
    /// mistake (or a re-worded copy) would fail this even though both sides
    /// already look non-empty.
    @Test(".unsupportedRule reuses CreationFailurePresenter's own sentence, not a re-worded one")
    func unsupportedRule() {
        let plan = CreationPlan.unsupportedRule(reason: "A rule names pgp, which this app cannot hold.")
        let presentation = ProjectStartHereView.presentation(for: plan, recipientNames: joinedNames)
        #expect(presentation == .failure(CreationFailurePresenter.message(forBlocking: plan)!))
    }

    @Test(".configUnreadable reuses CreationFailurePresenter's own sentence, not a re-worded one")
    func configUnreadable() {
        let plan = CreationPlan.configUnreadable(reason: "yaml: line 3: mapping values are not allowed here")
        let presentation = ProjectStartHereView.presentation(for: plan, recipientNames: joinedNames)
        #expect(presentation == .failure(CreationFailurePresenter.message(forBlocking: plan)!))
        guard case .failure(let message) = presentation else {
            Issue.record("expected .failure")
            return
        }
        #expect(message.detail.contains("yaml: line 3"))
    }

    /// `start-here.supported-formats` names the formats this app opens by
    /// hand-written prose ("Opens sops files in YAML, dotenv, JSON and
    /// INI.") with no compiler tie back to `SopsFileFormat` — the catalog
    /// entry and the enum can drift apart silently. This guards the drift:
    /// the `switch` below has no `default:`, so a fifth `SopsFileFormat`
    /// case fails *this test's own compile* with no mapping to reach for,
    /// which is a louder failure than a runtime miss would be. Ablation:
    /// deleting one branch's expected token (or adding a fake one nothing in
    /// the sentence satisfies) turns this red — verified by hand before
    /// filing this test.
    @Test("start-here.supported-formats mentions every SopsFileFormat case",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on the real catalog sentence, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value (\"start-here.supported-formats\"), which contains none of the format tokens; run under xcodebuild or swift test --build-system swiftbuild"))
    func supportedFormatsSentenceMentionsEverySopsFileFormat() {
        func expectedToken(for format: SopsFileFormat) -> String {
            switch format {
            case .yaml: return "YAML"
            case .dotenv: return "dotenv"
            case .json: return "JSON"
            case .ini: return "INI"
            }
        }

        let sentence = LocalizedKey.startHereSupportedFormats.text
        for format in SopsFileFormat.allCases {
            let token = expectedToken(for: format)
            #expect(sentence.contains(token),
                    "start-here.supported-formats must mention \(format.rawValue) (expected \"\(token)\"): \(sentence)")
        }
    }
}

// MARK: - Rendered — what a user (or VoiceOver) actually sees

/// Reflective AX probe, duplicated from `AccessibilityTreeTests.AXProbe`
/// rather than shared — same reasoning `RecipientAccessGatingTests
/// .GatingAXProbe` and `RevealedRowTests` both give for their own duplicates:
/// each is file-private by design, so one suite's change cannot silently
/// alter another's meaning. This copy also exposes a button-press action,
/// which none of the existing probes need.
@MainActor
private enum StartHereAXProbe {
    struct Node {
        let role: String
        let label: String
        let value: String
        let help: String
    }

    /// Renders `build()` offscreen and returns every accessibility node —
    /// the same technique `AXProbe.tree` uses, see that type's own doc
    /// comment for why `AXEnhancedUserInterface` is required at all.
    static func tree(size: CGSize, _ build: @MainActor () -> some View) -> [Node] {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(false, forAttribute: enhanced) }

        let hosting = NSHostingView(rootView: build())
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        var nodes: [Node] = []
        var seen: Set<ObjectIdentifier> = []
        walk(hosting, depth: 0, seen: &seen, into: &nodes)

        // Same reasoning as `AXProbe.tree` (`AccessibilityTreeTests.swift`),
        // corrected the same way: an empty tree is never legitimate, but it
        // is not evidence about `AXEnhancedUserInterface` being off. This is
        // a one-shot probe — the flag is set synchronously right above with
        // no suspension before the walk, so it is never actually observed
        // cleared here — and even a walk built with it off from the start
        // still returns most of the tree (measured: 68 of 92 nodes on a
        // 12-row `List`, not 0). So non-empty proves nothing about the flag
        // either way; this stays a minimal sanity check for a more total
        // failure (the view never rendered, etc.), not a flag diagnostic.
        #expect(!nodes.isEmpty,
                "StartHereAXProbe.tree saw a completely empty accessibility tree — that is never a valid result for a rendered view (even a walk built with AXEnhancedUserInterface off from the start still returns most of the tree). Something more total than the usual bug is wrong here.")
        return nodes
    }

    /// Renders `build()` offscreen, finds the first `AXButton` whose label
    /// matches `label`, and performs the standard AX press action on it
    /// directly — the same `accessibilityPerformPress` method a VoiceOver
    /// "double-tap" invokes, called here in-process because there is no
    /// window server this app is allowed to hand a real click to (see
    /// CLAUDE.md, "Visual verification"). Returns whether a matching,
    /// pressable button was found at all, independent of whether the press
    /// action itself reported success — SwiftUI's hosted button element
    /// answers `true` from `accessibilityPerformPress` regardless, so the
    /// real proof a click landed is always the caller's own side effect
    /// (see `ProjectStartHereViewButtonTests.buttonInvokesOnNewFile`).
    ///
    /// `accessibilityPerformPress` is declared to return `BOOL` on the
    /// informal `NSAccessibility` protocol, but this calls it through plain
    /// `perform(_:)` (`Selector` → `Unmanaged<AnyObject>?`), which is
    /// formally undefined for a method whose real return type is not an
    /// object pointer. This is safe *only* because the result is discarded
    /// unread below (`_ = object.perform(pressSelector)`) — do not
    /// "improve" this into `.takeUnretainedValue()` or any other read of
    /// the return value; that would reinterpret raw bits as `Unmanaged`
    /// noise and can crash.
    @discardableResult
    static func pressButton(labeled label: String, size: CGSize, _ build: @MainActor () -> some View) -> Bool {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(false, forAttribute: enhanced) }

        let hosting = NSHostingView(rootView: build())
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        var seen: Set<ObjectIdentifier> = []
        return pressFirstMatch(hosting, label: label, depth: 0, seen: &seen)
    }

    private static func pressFirstMatch(
        _ element: Any, label: String, depth: Int, seen: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard depth < 24 else { return false }
        let object = element as AnyObject
        guard seen.insert(ObjectIdentifier(object)).inserted else { return false }

        func string(_ name: String) -> String {
            let selector = Selector((name))
            guard object.responds(to: selector), let raw = object.perform(selector)?.takeUnretainedValue()
            else { return "" }
            return raw as? String ?? ""
        }

        if string("accessibilityLabel") == label {
            let pressSelector = Selector(("accessibilityPerformPress"))
            if object.responds(to: pressSelector) {
                // See this type's own doc comment on `pressButton` — the
                // result is intentionally never read.
                _ = object.perform(pressSelector)
                return true
            }
        }

        var children: [Any] = []
        for name in ["accessibilityChildren", "accessibilityRows", "accessibilityContents"] {
            let selector = Selector((name))
            if object.responds(to: selector),
                let found = object.perform(selector)?.takeUnretainedValue() as? [Any]
            {
                children += found
            }
        }
        if let view = element as? NSView { children += view.subviews }

        for child in children {
            if pressFirstMatch(child, label: label, depth: depth + 1, seen: &seen) { return true }
        }
        return false
    }

    private static func walk(_ element: Any, depth: Int, seen: inout Set<ObjectIdentifier>, into nodes: inout [Node]) {
        guard depth < 24 else { return }
        let object = element as AnyObject
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }

        func string(_ name: String) -> String {
            let selector = Selector((name))
            guard object.responds(to: selector), let raw = object.perform(selector)?.takeUnretainedValue()
            else { return "" }
            if let text = raw as? String { return text }
            if let role = raw as? NSAccessibility.Role { return role.rawValue }
            return "\(raw)"
        }

        let node = Node(
            role: string("accessibilityRole"), label: string("accessibilityLabel"),
            value: string("accessibilityValue"), help: string("accessibilityHelp"))
        if !(node.role.isEmpty && node.label.isEmpty && node.value.isEmpty) {
            nodes.append(node)
        }

        var children: [Any] = []
        for name in ["accessibilityChildren", "accessibilityRows", "accessibilityContents"] {
            let selector = Selector((name))
            if object.responds(to: selector),
                let found = object.perform(selector)?.takeUnretainedValue() as? [Any]
            {
                children += found
            }
        }
        if let view = element as? NSView { children += view.subviews }

        for child in children { walk(child, depth: depth + 1, seen: &seen, into: &nodes) }
    }
}

@Suite("ProjectStartHereView renders")
@MainActor
struct ProjectStartHereViewRenderTests {

    private static let size = CGSize(width: 360, height: 320)

    /// A project root that is never created on disk. `RecipientRegistry
    /// .load(in:)` degrades to an empty registry for a path that does not
    /// exist (`try?`, the same contract every other caller of that function
    /// keeps), so every render test that does not care about registry
    /// labels can share this fixed, non-existent path rather than standing
    /// up a real temp directory per test.
    private static let noRegistryProjectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-start-here-render-tests-no-registry")

    private func text(_ configState: CreationPlan?, otherFormatCount: Int = 0, projectRoot: URL = noRegistryProjectRoot) -> String {
        StartHereAXProbe.tree(size: Self.size) {
            ProjectStartHereView(
                configState: configState, otherFormatCount: otherFormatCount, projectRoot: projectRoot,
                onNewFile: {})
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    @Test("configState == nil renders nothing extra")
    func nilConfigStateRendersNothing() {
        let shown = text(nil)
        for key: LocalizedKey in [
            .newFileInfoNoConfig, .newFileInfoNoRuleMatched, .startHereCreateFirstFileButton,
            .startHereProbeLocation,
        ] {
            #expect(!shown.contains(key.text), "rendered \(key.rawValue) before configState resolved: \(shown)")
        }
    }

    /// SOPS-38 phase F3 task 3 (spec §7 b.1, F2 review I4): a first-time user
    /// looking at an empty project has no way to learn which sops formats
    /// this app actually opens — this factual sentence names all four
    /// (YAML/dotenv/JSON/INI). Independent of `configState`: it is a fact
    /// about the app, not about this project's rules, so it shows even
    /// before `configState` resolves — the same reasoning
    /// `FileListView.footnotes`'s own `otherFormatCount` note already
    /// applies one guard up.
    @Test("names the four sops formats this app opens, regardless of configState")
    func namesSupportedFormats() {
        for configState: CreationPlan? in [nil, .noConfig, .noRuleMatched] {
            let shown = text(configState)
            #expect(shown.contains(LocalizedKey.startHereSupportedFormats.text),
                    "configState \(String(describing: configState)) did not show the supported-formats sentence: \(shown)")
        }
    }

    @Test(".noConfig shows its title and the create-first-file button")
    func noConfigRenders() {
        let shown = text(.noConfig)
        // Canary: an empty tree cannot contain anything, and the assertions
        // below would pass by finding nothing.
        #expect(shown.contains(LocalizedKey.newFileInfoNoConfig.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
        #expect(shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
    }

    @Test(".governedByRule names the shortened recipient and shows the button",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %@ to substitute into, so the recipient name would never appear at all; run under xcodebuild or swift test --build-system swiftbuild"))
    func governedByRuleRenders() {
        let recipient = "age1qexampleexampleexampleexampleexampleexampleexampleexamplex"
        let shown = text(.governedByRule(recipients: [recipient], encryptedRegex: ""))
        #expect(shown.contains(NewSecretFileSheet.shortenedKey(recipient)),
                "the shortened recipient key is missing: \(shown)")
        #expect(shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
        #expect(shown.contains(LocalizedKey.startHereProbeLocation.text),
                "the location anchor is missing from the rendered screen: \(shown)")
    }

    /// Review finding, "Decision on your disclosed limitation": a labeled
    /// recipient must read as its registry label here, exactly as it does
    /// in `RecipientPicker`/`NewSecretFileSheet`. Uses a real, throwaway
    /// project root and a real `RecipientRegistry.save`, not a mock — the
    /// same discipline `FileListModelConfigStateTests` holds `configState`
    /// resolution to, applied to the registry read this task's review added.
    @Test(".governedByRule shows a registry label when one exists, and a shortened key when it doesn't",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %@ to substitute into, so neither the label nor the shortened key would ever appear; run under xcodebuild or swift test --build-system swiftbuild"))
    func governedByRuleShowsRegistryLabel() throws {
        // Real, from `age-keygen` — `RecipientRegistry.save` validates the
        // bech32 shape before writing, so a hand-typed placeholder would be
        // refused with `.invalidAgeRecipient` before this test ever reaches
        // the assertion it exists to make. Never used to encrypt or decrypt
        // anything, and thrown away with the temp directory below.
        let labeled = try StartHereAgeKeyPair.generate().public
        // Deliberately *not* a real age key — nothing here ever validates
        // an unlabeled recipient's shape (`CreationPlan.governedByRule`
        // carries raw `[String]`), so a placeholder is fine, and using one
        // makes clear at a glance that this value is never looked up in the
        // registry, only shortened.
        let unlabeled = "age1qunlabeledunlabeledunlabeledunlabeledunlabeledunlabeledunla"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-here-registry-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RecipientRegistry.save(
            [RecipientRecord(label: "Alice", kind: .person, ageRecipient: labeled)], in: root)

        let shown = text(.governedByRule(recipients: [labeled, unlabeled], encryptedRegex: ""), projectRoot: root)

        #expect(shown.contains("Alice"), "the labeled recipient must read as its registry label: \(shown)")
        #expect(shown.contains(NewSecretFileSheet.shortenedKey(unlabeled)),
                "the unlabeled recipient must still fall back to a shortened key, never an invented name: \(shown)")
        #expect(!shown.contains(labeled), "the labeled recipient's raw key must not also be shown: \(shown)")
    }

    /// #27 tvrzení 5: `init` now reads through `RecipientRegistry
    /// .loadOrQuarantine(in:)`, not the bare `(try? load) ?? []` idiom every
    /// call site here used before — this proves that wiring end to end
    /// through the view's real, non-injectable initializer, the same way
    /// `ProjectAccessTests.corruptRegistrySurfacesAQuarantineNotice` proves it
    /// for `ProjectAccessModel`'s default `loadRegistry`.
    @Test("a corrupt registry surfaces a quarantine notice, and the recipient still shows unlabelled")
    func corruptRegistrySurfacesAQuarantineNotice() throws {
        let recipient = "age1qexampleexampleexampleexampleexampleexampleexampleexamplex"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-here-corrupt-registry-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        let registryDirectory = root.appendingPathComponent(".sops-gui", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data(#"{"records": "not an array"}"#.utf8)
            .write(to: registryDirectory.appendingPathComponent("recipients.json"))

        let view = ProjectStartHereView(
            configState: .governedByRule(recipients: [recipient], encryptedRegex: ""),
            otherFormatCount: 0, projectRoot: root, onNewFile: {})

        #expect(view.registryQuarantineNotice != nil)
        // The corrupt file no longer sits at the path a future save would
        // have to fight the fingerprint of — the same contract
        // `RecipientRegistryCorruptionTests` pins for the backend.
        #expect(!FileManager.default.fileExists(
            atPath: registryDirectory.appendingPathComponent("recipients.json").path))

        // Same degrade `governedByRuleShowsRegistryLabel` pins for a registry
        // that was simply never created: labels are unavailable, but the
        // recipient itself is never hidden.
        let shown = text(.governedByRule(recipients: [recipient], encryptedRegex: ""), projectRoot: root)
        #expect(shown.contains(NewSecretFileSheet.shortenedKey(recipient)),
                "the recipient must still show, unlabelled, once the corrupt registry is quarantined: \(shown)")
    }

    /// Review finding, Important 1: the plaintext-scoping disclosure must
    /// reach this screen too, not only the wizard's ⓘ line.
    @Test(".governedByRule with encrypted_regex discloses the plaintext scoping",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %@ to substitute into; run under xcodebuild or swift test --build-system swiftbuild"))
    func governedByRuleWithEncryptedRegexRenders() {
        let recipient = "age1qexampleexampleexampleexampleexampleexampleexampleexamplex"
        let regex = "^(data|stringData)$"
        let shown = text(.governedByRule(recipients: [recipient], encryptedRegex: regex))
        #expect(shown.contains(String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, regex)),
                "the plaintext-scoping disclosure is missing from the rendered screen: \(shown)")
    }

    @Test(".governedByRule with no recipients shows the no-recipients refusal, not the button")
    func governedByRuleWithNoRecipientsRenders() {
        let shown = text(.governedByRule(recipients: [], encryptedRegex: ""))
        #expect(shown.contains(CreationFailurePresenter.messageForRuleWithNoRecipients().detail))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text),
                "must not offer to create a file nothing will be encrypted for: \(shown)")
    }

    @Test(".noRuleMatched explains the state, hedged, and shows no button")
    func noRuleMatchedRenders() {
        let shown = text(.noRuleMatched)
        #expect(shown.contains(LocalizedKey.newFileInfoNoRuleMatched.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
        #expect(shown.contains(LocalizedKey.startHereNoRuleMatchedReassurance.text))
        #expect(shown.contains(LocalizedKey.startHereProbeLocation.text),
                "the location anchor is missing from the rendered screen: \(shown)")
        #expect(!shown.lowercased().contains("by hand"),
                "must not promise every file here needs hand-picked recipients: \(shown)")
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text),
                ".noRuleMatched must not offer the create-first-file button: \(shown)")
    }

    @Test(".unsupportedRule shows CreationFailurePresenter's own sentence, not a composed one")
    func unsupportedRuleRenders() {
        let plan = CreationPlan.unsupportedRule(reason: "A rule names pgp, which this app cannot hold.")
        let expected = CreationFailurePresenter.message(forBlocking: plan)!
        let shown = text(plan)
        #expect(shown.contains(expected.title.text))
        #expect(shown.contains(expected.detail))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
    }

    @Test(".configUnreadable shows CreationFailurePresenter's own sentence, not a composed one")
    func configUnreadableRenders() {
        let plan = CreationPlan.configUnreadable(reason: "yaml: line 3: mapping values are not allowed here")
        let expected = CreationFailurePresenter.message(forBlocking: plan)!
        let shown = text(plan)
        #expect(shown.contains(expected.title.text))
        #expect(shown.contains(expected.detail))
        #expect(shown.contains("yaml: line 3"))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
    }

    @Test("otherFormatCount is surfaced alongside the guidance",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %d to substitute into; run under xcodebuild or swift test --build-system swiftbuild"))
    func otherFormatCountIsSurfaced() {
        let shown = text(.noConfig, otherFormatCount: 2)
        #expect(shown.contains(String(format: LocalizedKey.filesOtherFormatNote.text, 2)))
    }
}

@Suite("ProjectStartHereView's button")
@MainActor
struct ProjectStartHereViewButtonTests {

    private static let noRegistryProjectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-start-here-button-tests-no-registry")

    /// Proof the button is actually wired to `onNewFile`, not merely present
    /// with the right label — the same distinction
    /// `AppShellTests`'s own `onNewFile` source check exists for one layer
    /// up, done here by actually invoking the rendered control's AX press
    /// action rather than scanning source text.
    @Test("pressing the create-first-file button invokes onNewFile")
    func buttonInvokesOnNewFile() {
        var invoked = false
        let pressed = StartHereAXProbe.pressButton(
            labeled: LocalizedKey.startHereCreateFirstFileButton.text, size: CGSize(width: 360, height: 320)
        ) {
            ProjectStartHereView(
                configState: .noConfig, otherFormatCount: 0, projectRoot: Self.noRegistryProjectRoot,
                onNewFile: { invoked = true })
        }
        #expect(pressed, "no pressable button with the expected label was found")
        #expect(invoked, "the button's AX press action did not call onNewFile")
    }
}

// MARK: - FileListView: ProjectStartHereView shows only where it is honest to
//
// `FileListModelConfigStateTests` proves the *model* resolves `configState`
// correctly. This proves the *view* renders `ProjectStartHereView` only in
// the branch this task's brief names — a genuinely empty, completely scanned
// project — and never over `rootMissing`, `rootUnreadable`, or a non-nil
// `incompleteScanReason`, mirroring the discipline
// `FileListViewWiringTests` already holds `FileListView` to for the sibling
// finding (a model that knows something and a view that drops it).
@Suite("FileListView shows ProjectStartHereView only over a genuinely empty, complete scan")
@MainActor
struct FileListViewStartHereWiringTests {

    private static let size = CGSize(width: 360, height: 520)

    private func text(of model: FileListModel) -> String {
        AXProbe.tree(size: Self.size) {
            FileListView(model: model, selection: .constant(nil), onNewFile: {})
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    private func project(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-here-wiring-\(name)-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a genuinely empty, fully scanned project shows the guidance")
    func emptyCompleteScanShowsGuidance() async throws {
        let root = try project("empty")
        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.files.isEmpty && model.incompleteScanReason == nil)

        let shown = text(of: model)
        #expect(shown.contains(LocalizedKey.newFileInfoNoConfig.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
    }

    /// Pinned against the specific branch, not just "nothing start-here
    /// showed": review finding — for a missing root, `FileListModel
    /// .resolveConfigState` also returns `nil`, so the start-here guidance
    /// text would be absent whether or not `showsStartHere` correctly
    /// excluded `rootMissing` at all. Asserting `filesProjectMissingTitle`
    /// is what actually proves the `rootMissing` placeholder — not a blank
    /// pane — is what rendered.
    @Test("a missing project root never shows the start-here guidance")
    func missingRootNeverShowsGuidance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-here-wiring-missing-\(UUID().uuidString)")
        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.rootMissing)

        let shown = text(of: model)
        #expect(!shown.contains(LocalizedKey.newFileInfoNoConfig.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
        #expect(shown.contains(LocalizedKey.filesProjectMissingTitle.text),
                "the rootMissing placeholder itself must still be shown, not a blank pane")
    }

    @Test("an unreadable project root never shows the start-here guidance")
    func unreadableRootNeverShowsGuidance() async throws {
        let root = try project("unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil,
                     "the lock denied nothing — running as root would make this test vacuous")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.rootUnreadable)

        let shown = text(of: model)
        #expect(!shown.contains(LocalizedKey.newFileInfoNoConfig.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
        #expect(shown.contains(LocalizedKey.filesProjectUnreadableTitle.text),
                "the rootUnreadable placeholder itself must still be shown, not a blank pane")
    }

    /// The exact claim this whole task must not make: an incomplete walk
    /// that happens to find zero files must still show the narrowed
    /// "empty-partial" placeholder, never the confident start-here guidance.
    @Test("an incomplete scan that found nothing never shows the start-here guidance")
    func incompleteScanNeverShowsGuidance() async throws {
        let root = try project("incomplete-empty")
        let vault = root.appendingPathComponent("vault")
        try writeSopsLike(root, at: "vault/secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) == nil,
                     "the lock denied nothing — running as root would make this test vacuous")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.incompleteScanReason != nil && model.files.isEmpty)

        let shown = text(of: model)
        #expect(!shown.contains(LocalizedKey.newFileInfoNoConfig.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
        #expect(shown.contains(LocalizedKey.filesEmptyPartialTitle.text),
                "the narrowed empty-partial state must still be shown")
    }

    /// A project holding only a sops file in an unsupported format used to
    /// hit the empty placeholder with `otherFormatCount`'s note nested where
    /// the branch could never reach it, and this test used to pin that the
    /// note appeared exactly once across `FileListView.footnotes` and
    /// `ProjectStartHereView` — both know about `otherFormatCount`, and only
    /// one of them may say it out loud.
    ///
    /// The fixture behind that scenario moved twice, and each move is real
    /// project history worth keeping rather than a test quietly deleted: it
    /// was dotenv-shaped until Task 6 (SOPS-38) taught the editor to open
    /// dotenv too, so dotenv stopped being "another format" and the fixture
    /// became JSON, the last real "other format" this build had. SOPS-38
    /// phase F2 task 3 closed that gap as well —
    /// `FileListViewWiringTests.jsonFileIsListedNotHiddenBehindOtherFormatNote`
    /// is JSON's own version of exactly this move — and with it, the
    /// combination this test pinned (a real file, `showsStartHere` true,
    /// `otherFormatCount` positive) is no longer reachable through any real
    /// sops document at all: `ScannedTree.encryptedInOtherFormats` is empty
    /// for every project this build can classify (see that field's own doc
    /// comment). Retired rather than rewritten a third time around a fixture
    /// that would have to lie about being sops's own output to keep failing
    /// this way — `otherFormatCountIsSurfaced` above still pins
    /// `ProjectStartHereView`'s own rendering of a positive count directly,
    /// which is the part of this claim that remains testable without one.
}
