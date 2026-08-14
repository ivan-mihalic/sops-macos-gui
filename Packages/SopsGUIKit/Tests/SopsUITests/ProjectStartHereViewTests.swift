import AppKit
import ScratchCleanup
import SopsHealth
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

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

    @Test(".noConfig offers the create-first-file button")
    func noConfig() {
        let presentation = ProjectStartHereView.presentation(for: .noConfig, recipientNames: joinedNames)
        #expect(presentation == .headline(LocalizedKey.startHereNoConfigTitle.text, offersCreateButton: true))
    }

    @Test(".governedByRule names the recipients through the injected formatter and offers the button")
    func governedByRule() {
        let presentation = ProjectStartHereView.presentation(
            for: .governedByRule(recipients: ["age1abc", "age1def"], encryptedRegex: ""),
            recipientNames: joinedNames)
        #expect(presentation == .headline(
            String(format: LocalizedKey.startHereGovernedTitle.text, "age1abc, age1def"),
            offersCreateButton: true))
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

    /// The load-bearing case: `.sops.yaml` exists and has rules, they simply
    /// do not reach this location — never collapsed into "no config". No
    /// button, unlike the two cases above — see `ProjectStartHereView`'s own
    /// doc comment for why.
    @Test(".noRuleMatched explains that rules exist but do not cover this path, and offers no button")
    func noRuleMatched() {
        let presentation = ProjectStartHereView.presentation(for: .noRuleMatched, recipientNames: joinedNames)
        #expect(
            presentation == .headline(LocalizedKey.startHereNoRuleMatchedTitle.text, offersCreateButton: false))
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

    private func text(_ configState: CreationPlan?, otherFormatCount: Int = 0) -> String {
        StartHereAXProbe.tree(size: Self.size) {
            ProjectStartHereView(configState: configState, otherFormatCount: otherFormatCount, onNewFile: {})
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    @Test("configState == nil renders nothing extra")
    func nilConfigStateRendersNothing() {
        let shown = text(nil)
        for key: LocalizedKey in [
            .startHereNoConfigTitle, .startHereNoRuleMatchedTitle, .startHereCreateFirstFileButton,
        ] {
            #expect(!shown.contains(key.text), "rendered \(key.rawValue) before configState resolved: \(shown)")
        }
    }

    @Test(".noConfig shows its title and the create-first-file button")
    func noConfigRenders() {
        let shown = text(.noConfig)
        // Canary: an empty tree cannot contain anything, and the assertions
        // below would pass by finding nothing.
        #expect(shown.contains(LocalizedKey.startHereNoConfigTitle.text),
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
    }

    @Test(".governedByRule with no recipients shows the no-recipients refusal, not the button")
    func governedByRuleWithNoRecipientsRenders() {
        let shown = text(.governedByRule(recipients: [], encryptedRegex: ""))
        #expect(shown.contains(CreationFailurePresenter.messageForRuleWithNoRecipients().detail))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text),
                "must not offer to create a file nothing will be encrypted for: \(shown)")
    }

    @Test(".noRuleMatched explains the state and shows no button")
    func noRuleMatchedRenders() {
        let shown = text(.noRuleMatched)
        #expect(shown.contains(LocalizedKey.startHereNoRuleMatchedTitle.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
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
            ProjectStartHereView(configState: .noConfig, otherFormatCount: 0, onNewFile: { invoked = true })
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
        #expect(shown.contains(LocalizedKey.startHereNoConfigTitle.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
    }

    @Test("a missing project root never shows the start-here guidance")
    func missingRootNeverShowsGuidance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-here-wiring-missing-\(UUID().uuidString)")
        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.rootMissing)

        let shown = text(of: model)
        #expect(!shown.contains(LocalizedKey.startHereNoConfigTitle.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
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
        #expect(!shown.contains(LocalizedKey.startHereNoConfigTitle.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
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
        #expect(!shown.contains(LocalizedKey.startHereNoConfigTitle.text))
        #expect(!shown.contains(LocalizedKey.startHereCreateFirstFileButton.text))
        #expect(shown.contains(LocalizedKey.filesEmptyPartialTitle.text),
                "the narrowed empty-partial state must still be shown")
    }

    /// A project holding only a dotenv-format sops file used to hit the
    /// empty placeholder with `otherFormatCount`'s note nested where the
    /// branch could never reach it (`FileListViewWiringTests
    /// .otherFormatNoteSurvivesAnEmptyList` pins the model-and-view
    /// combination for the old placeholder branch). This pins the same
    /// property for the new branch, and that the note appears exactly once —
    /// `FileListView.footnotes` and `ProjectStartHereView` both know about
    /// `otherFormatCount`, and only one of them may say it out loud.
    @Test("an other-format-only project shows the note exactly once, alongside the guidance")
    func otherFormatNoteAppearsOnceAlongsideGuidance() async throws {
        let root = try project("other-format")
        try """
        API_KEY=ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops_mac=ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops_version=3.9.4
        """.write(to: root.appendingPathComponent(".env.production"), atomically: true, encoding: .utf8)

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.files.isEmpty && model.otherFormatCount == 1)

        let nodes = AXProbe.tree(size: Self.size) {
            FileListView(model: model, selection: .constant(nil), onNewFile: {})
        }
        let shown = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
        #expect(shown.contains(LocalizedKey.startHereNoConfigTitle.text),
                "the tree did not populate — this test would be vacuous: \(shown)")

        let noteText = String(format: LocalizedKey.filesOtherFormatNote.text, 1)
        let occurrences = nodes.filter { $0.value == noteText || $0.label == noteText }.count
        #expect(occurrences == 1, "the other-format note appeared \(occurrences) times, expected exactly 1: \(shown)")
    }
}
