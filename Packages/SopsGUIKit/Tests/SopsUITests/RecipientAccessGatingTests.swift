import AppKit
import Foundation
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

/// The pure decision function gating the per-file Apply, and the per-file
/// panel's own rendering. The editor toolbar's Access button — and its
/// `canOpenAccessPanel` gate, once tested here — went with SOPS-42:
/// recipients are managed on the project's Access page now.
///
/// ## Finding C1 — applying access changes silently discarded unsaved edits
/// `SecretEditorView`'s toolbar used to disable the Access button only on
/// `loadState != .loaded || isSaving`, never on `isDirty`. Opening Access
/// with an unsaved row edit, adding a recipient and pressing Apply reloaded
/// the open `SecretDocumentViewModel` (to resync its save-fingerprint with
/// the rewrapped bytes — see `SecretEditorView`'s `.sheet(item:
/// $accessRequest)`), and that reload discards every pending edit, addition
/// and removal with no prompt, no error and no dirty indicator surviving to
/// warn the user. `canOpenAccessPanelTests` below pins the fix — the gate
/// requires `!isDirty` — as a decision testable without any view at all,
/// mirroring `WorkspaceSwitchDecisionTests`/`QuitRequestTests` elsewhere in
/// this module. `theAccessButtonIsUnreachableWhileTheDocumentIsDirty` then
/// checks the same property through an actually-rendered editor, because a
/// correct pure function that nothing calls is not a fix.
@Suite("RecipientAccessView.canApply — the Apply button's gate")
struct CanApplyTests {

    @Test("a loaded, dirty, key-configured, idle model may apply")
    func readyStateApplies() {
        #expect(
            RecipientAccessView.canApply(
                loadState: .loaded, isDirty: true, keyConfigured: true, isApplying: false))
    }

    @Test("a clean model may not apply — nothing staged to apply")
    func cleanModelIsRefused() {
        #expect(
            !RecipientAccessView.canApply(
                loadState: .loaded, isDirty: false, keyConfigured: true, isApplying: false))
    }

    @Test("a model with no key configured may not apply, even if dirty")
    func noKeyIsRefused() {
        #expect(
            !RecipientAccessView.canApply(
                loadState: .loaded, isDirty: true, keyConfigured: false, isApplying: false))
    }

    @Test("a model already applying may not apply again")
    func alreadyApplyingIsRefused() {
        #expect(
            !RecipientAccessView.canApply(
                loadState: .loaded, isDirty: true, keyConfigured: true, isApplying: true))
    }

    @Test("a model that has not loaded may not apply")
    func notLoadedIsRefused() {
        #expect(
            !RecipientAccessView.canApply(
                loadState: .idle, isDirty: true, keyConfigured: true, isApplying: false))
    }
}

// MARK: - Through a real, rendered editor

/// Reflective AX probe, duplicated from `AccessibilityTreeTests.AXProbe`
/// rather than shared — same reasoning `RevealedRowTests` gives for its own
/// duplicate: both are file-private by design, and a shared probe is how one
/// suite's change silently alters another's meaning.
@MainActor
enum GatingAXProbe {
    struct Node {
        let role: String
        let label: String
        let help: String
        /// Where a SwiftUI `Text`'s own content lands — `accessibilityLabel`
        /// is empty for one. `AccessibilityTreeTests` and `RevealedRowTests`
        /// both read this for the same reason; captured here too since Task 4,
        /// whose disclosure checks are about rendered sentences rather than
        /// control labels.
        let value: String
    }

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
                "GatingAXProbe.tree saw a completely empty accessibility tree — that is never a valid result for a rendered view (even a walk built with AXEnhancedUserInterface off from the start still returns most of the tree). Something more total than the usual bug is wrong here.")
        return nodes
    }

    fileprivate static func walk(
        _ element: Any, depth: Int, seen: inout Set<ObjectIdentifier>, into nodes: inout [Node]
    ) {
        guard depth < 24 else { return }
        let object = element as AnyObject
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }

        func string(_ name: String) -> String {
            let selector = Selector((name))
            guard object.responds(to: selector),
                let raw = object.perform(selector)?.takeUnretainedValue()
            else { return "" }
            if let text = raw as? String { return text }
            if let role = raw as? NSAccessibility.Role { return role.rawValue }
            return "\(raw)"
        }

        let node = Node(
            role: string("accessibilityRole"), label: string("accessibilityLabel"),
            help: string("accessibilityHelp"), value: string("accessibilityValue"))
        if !(node.role.isEmpty && node.label.isEmpty && node.help.isEmpty && node.value.isEmpty) {
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

/// A persistent host whose accessibility tree can be walked more than once,
/// with the underlying model mutated in between — mirrors
/// `RevealedRowTests.EditorHost` for the identical reason: a fresh
/// `GatingAXProbe.tree(...)` call throws the host away, which is right for a
/// one-shot check and useless for "does the view reflect a state change made
/// to a model it is already bound to."
///
/// `RecipientAccessView` also carries a `.task { await model.load() }` that
/// fires once on first appearance, asynchronously — so a synchronous walk
/// immediately after construction races that task and sees the pre-load
/// state. `settleAfterLoad()` gives it the same real time budget
/// `EditorHost.settleAfterAModelChange()` gives a model change: 120ms, then
/// a relayout.
///
/// Internal rather than `private` since Task 4: the project-wide Access
/// surface needs the identical treatment (it carries its own
/// `.task { await model.load() }` over a real project scan), and a *third*
/// hand-copied probe in this one test target would be worse than the two that
/// already exist. Nothing outside
/// `SopsUITests` can see it either way.
@MainActor
final class GatingHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow
    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    init(size: CGSize, _ build: @MainActor () -> AnyView) {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhanced)
        hosting = NSHostingView(rootView: build())
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        settle()
    }

    private func settle() {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }

    /// Waits for the view's own `.task { await model.load() }` (or any other
    /// pending async work scheduled on appearance) to complete, then
    /// relayouts. Call once, right after `init`, before trusting `nodes()`.
    func settleAfterLoad() async {
        try? await Task.sleep(for: .milliseconds(120))
        settle()
    }

    /// The same wait, for a state change made to the model *after* the
    /// initial load — a mutation via `@Observable` does not re-run `.task`
    /// (that only fires on first appearance), but SwiftUI still needs a
    /// turn of the run loop to re-render before a new walk reflects it.
    func settleAfterAModelChange() async {
        try? await Task.sleep(for: .milliseconds(120))
        settle()
    }

    /// Relayouts until `condition` holds, or until `timeout` elapses.
    ///
    /// Preferred over `settleAfterLoad()` whenever the thing being waited for
    /// is observable — a fixed 120 ms is a guess, and it is a guess that was
    /// measured wrong: the project Access surface's own `.task` runs a real
    /// `ProjectScanner` walk plus a bridge call, and under the swiftly
    /// toolchain's more contended parallel test run it was still `.loading`
    /// when the walk resumed, so three disclosure checks failed against a
    /// half-built view rather than against anything the view got wrong.
    /// Polling costs nothing when the condition is already true and does not
    /// pretend to know how long a scan takes on a loaded machine.
    func settle(until condition: @MainActor () -> Bool, timeout: Duration = .seconds(10),
                location: SourceLocation = #_sourceLocation) async {
        // The condition is about the *model*, which advances on its own — so
        // the wait must not relayout on every tick. An earlier version did,
        // and a synchronous `NSHostingView` layout+display every 20 ms is real
        // main-actor work: it pushed `CopyFeedbackTests`' expiry check (whose
        // own comment documents it as contention-sensitive, with a deliberately
        // generous deadline) over its limit in a full-suite run. Polling a
        // boolean costs nothing; the relayouts happen once, at the end.
        let started = ContinuousClock.now
        while !condition(), ContinuousClock.now - started < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Say so when the wait ran out. Without this the helper returns the
        // same way whether the condition held or never did, and the caller
        // fails at its next assertion — which then describes something else.
        //
        // Measured twice: a full-suite run reported
        // `(model.plan?.governingRuleIdentified → nil) == false` in
        // `ProjectAccessTests`, which reads as "the panel computed the wrong
        // thing". The panel had computed nothing; this wait had given up on a
        // loaded machine and told nobody. `SecretDocumentViewModelTests` hit
        // the same shape two days later.
        //
        // One definition serves about thirty call sites, so the silence was
        // thirty chances to read a slow machine as a broken view.
        // `#filePath`/`#line` are the caller's, so the report points at the
        // wait that ran out rather than at this line.
        if !condition() {
            Issue.record("""
                waited \(timeout) for a condition that never became true. Whatever this \
                test asserts next is about a view that never finished setting up — treat \
                a failure below as a consequence of this, not a separate defect. On a \
                loaded machine this is usually contention rather than a real fault; \
                confirm by running this suite on its own.
                """, sourceLocation: location)
        }

        settle()
        try? await Task.sleep(for: .milliseconds(50))
        settle()
    }

    func nodes() -> [GatingAXProbe.Node] {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhanced)
        var found: [GatingAXProbe.Node] = []
        var seen: Set<ObjectIdentifier> = []
        GatingAXProbe.walk(hosting, depth: 0, seen: &seen, into: &found)

        // Same reasoning as `AXProbe.tree` (`AccessibilityTreeTests.swift`),
        // corrected the same way — but `GatingHost` is one of the two
        // probes (with `RevealedRowTests.EditorHost`) where
        // `AXEnhancedUserInterface` really *is* measured to get cleared out
        // from under a live walk: ~90 times across a full suite run, because
        // this host is kept alive and re-walked while a concurrent probe's
        // own `defer` can flip the process-wide flag off in between. That
        // clearing turned out to cost nothing: a control walk, a walk
        // cleared then relaid out, and a fresh walk all returned the
        // identical 92 nodes on a 12-row `List` — only a walk built with the
        // flag off from the very start undercounts (68, not 0). So even
        // here, a non-empty tree is not evidence the flag stayed on, and
        // this assertion is not a diagnostic for that mechanism — it is a
        // minimal sanity check that nothing more total went wrong.
        #expect(!found.isEmpty,
                "GatingHost.nodes() saw a completely empty accessibility tree — that is never a valid result for a rendered view (even a walk built with AXEnhancedUserInterface off from the start still returns most of the tree; see this function's comment). Something more total than the usual bug is wrong here.")
        return found
    }

    func finish() {
        NSApplication.shared.accessibilitySetValue(false, forAttribute: Self.enhanced)
        window.contentView = nil
    }
}

// MARK: - RecipientAccessView's own a11y labels

@Suite("RecipientAccessView row controls carry the right accessibility label for their state")
@MainActor
struct RecipientAccessRowLabelTests {

    @Test("an unchanged recipient's row offers to remove it; a pending-removal row offers to undo")
    func rowLabelMatchesStatus() async throws {
        let owner = try AgeKeyPairForTests.generate()
        let kept = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(
            "db:\n    password: fixture-EXAMPLE\n", format: .yaml, recipients: [owner.public, kept.public])
        let store = SessionKeyStore()
        try store.importKey(owner.private)
        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/access-row-labels.yaml"), projectURL: nil, keyStore: store,
            format: .yaml, readFile: { _ in encrypted })

        // Rendered on an unloaded model, exactly as the real toolbar button
        // does it — `RecipientAccessView`'s own `.task { await model.load() }`
        // is what populates it. Staging *before* this settles would just be
        // wiped by that load, so the sequence here is: settle past the
        // load, mutate, settle past the resulting re-render, then read.
        let host = GatingHost(size: CGSize(width: 480, height: 360)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settleAfterLoad()
        try #require(model.loadState == .loaded, "precondition: the view's own task loaded the model")

        model.stageRemove(owner.public)
        await host.settleAfterAModelChange()

        let labels = Set(host.nodes().map(\.label))
        #expect(
            labels.contains(LocalizedKey.accessRemoveRecipient.text),
            "the unchanged row (kept) must offer to remove it")
        #expect(
            labels.contains(LocalizedKey.accessUndoRemoval.text),
            "the pending-removal row (owner) must offer to undo, not remove again")
    }
}

// MARK: - SOPS-33: the registry-quarantine notice, actually rendered

/// `RegistryQuarantineWiringTests` (`RegistryQuarantineWiringTests.swift`)
/// already pins that `RecipientAccessModel.load()` routes through
/// `loadOrQuarantine(in:)` and stores whatever it returns in
/// `registryQuarantineNotice`. This is the other half that suite's own
/// doc comment says it cannot check: that the notice reaches the screen,
/// through the real `RegistryQuarantineBanner` wired into
/// `RecipientAccessView.loadedContent` — not just the model.
@Suite("RecipientAccessView shows the registry-quarantine banner")
@MainActor
struct RecipientAccessRegistryQuarantineTests {

    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    @Test("a moved-aside registry's notice is shown, not just held on the model")
    func noticeIsRendered() async throws {
        let owner = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(
            "db:\n    password: fixture-EXAMPLE\n", format: .yaml, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(owner.private)
        let notice = "Your recipient names at /fixture/.sops-gui/recipients.json could not be read, " +
            "so the file has been moved aside to /fixture/.sops-gui/recipients-corrupt-x.json."

        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/access-registry-quarantine.yaml"),
            projectURL: URL(fileURLWithPath: "/dev/null/never-read-project"), keyStore: store,
            format: .yaml, readFile: { _ in encrypted },
            loadRegistry: { _ in ([], notice) })

        let host = GatingHost(size: CGSize(width: 480, height: 360)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settleAfterLoad()
        try #require(model.loadState == .loaded, "precondition: the view's own task loaded the model")

        let seen = labels(in: host.nodes())
        #expect(seen.contains(LocalizedKey.accessRegistryQuarantineTitle.text),
                "the panel must show the registry-quarantine banner's title")
        #expect(seen.contains(notice),
                "the panel must show the notice text itself, not just the title")
    }

    /// The negative case: a registry that loaded cleanly (`quarantineNotice
    /// == nil`, the default seam over an empty project) must render no
    /// banner at all — without this, an unconditionally-rendered banner
    /// would still pass the positive test above.
    @Test("an ordinary load shows no registry-quarantine banner")
    func ordinaryLoadShowsNoRegistryQuarantineBanner() async throws {
        let owner = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(
            "db:\n    password: fixture-EXAMPLE\n", format: .yaml, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(owner.private)

        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/access-registry-quarantine-clean.yaml"),
            projectURL: URL(fileURLWithPath: "/dev/null/never-read-project"), keyStore: store,
            format: .yaml, readFile: { _ in encrypted },
            loadRegistry: { _ in ([], nil) })

        let host = GatingHost(size: CGSize(width: 480, height: 360)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settleAfterLoad()
        try #require(model.loadState == .loaded, "precondition: the view's own task loaded the model")

        try #require(model.registryQuarantineNotice == nil, "precondition: nothing was quarantined")
        #expect(!labels(in: host.nodes()).contains(LocalizedKey.accessRegistryQuarantineTitle.text),
                "an ordinary load must not show the registry-quarantine banner")
    }
}
