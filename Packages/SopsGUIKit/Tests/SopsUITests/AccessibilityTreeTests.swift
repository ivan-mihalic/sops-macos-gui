import AppKit
import SopsEngine
import SopsHealth
import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// What VoiceOver would actually read.
///
/// M1 and M2 both shipped with this unverified, and it is the one property
/// the eye cannot check: `./Scripts/snapshots.sh` renders pixels, and pixels
/// prove the *mask* is drawn — not that the plaintext behind it stayed out of
/// the accessibility tree. A secret read aloud by VoiceOver, or scraped by
/// any assistive client, is exactly the leak CLAUDE.md's "no secret values in
/// logs, errors or crash reports" rule exists to prevent, one channel over.
///
/// Two things make this testable at all without launching the app (which
/// CLAUDE.md forbids — it steals the machine owner's focus):
///
/// 1. The same never-shown `NSHostingView`/`NSWindow` pair `SnapshotTool`
///    uses. See `Snapshot.swift`'s header for why that works headless.
/// 2. `AXEnhancedUserInterface`. **Without it these tests are vacuous** —
///    SwiftUI builds its accessibility elements lazily, only once an
///    assistive client has attached, so an offscreen host reports a single
///    empty `AXGroup` and every assertion below passes by finding nothing.
///    Setting the attribute is what an assistive client's attach does, and
///    `statusRowsAnnounceTheirStatus` is the canary: it asserts the tree is
///    genuinely populated, so if this stops working the suite fails loudly
///    instead of going quiet.
@MainActor
private enum AXProbe {

    /// One node of a rendered accessibility tree.
    struct Node {
        let role: String
        let label: String
        let value: String
        let help: String
    }

    static func tree(size: CGSize, _ build: @MainActor () -> some View) -> [Node] {
        // The deprecated attribute API on purpose: `AXEnhancedUserInterface`
        // has no replacement on the `NSAccessibility` protocol — that protocol
        // is for *vending* accessibility, and this is the process-level switch
        // an assistive client flips when it attaches. Nothing else turns
        // SwiftUI's lazy element construction on.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        // Turned back off before returning: this is a process-wide switch,
        // and `swift test`'s default (llbuild) build system runs every suite
        // in this package in one process. Leaving AppKit in enhanced mode
        // would make every other suite's view work build accessibility
        // elements it never asked for — measurable cost, in a package that
        // already has wall-clock assertions on the ledger for being tight.
        defer { NSApplication.shared.accessibilitySetValue(false, forAttribute: enhanced) }

        let hosting = NSHostingView(rootView: build())
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        // Twice, and with a display in between, for the same reason
        // `Snapshot.render` does it: the first pass sizes the host, the
        // second lets content that depends on that size settle.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        var nodes: [Node] = []
        var seen: Set<ObjectIdentifier> = []
        walk(hosting, depth: 0, seen: &seen, into: &nodes)
        return nodes
    }

    /// Reflective rather than typed: SwiftUI's accessibility elements are
    /// private `NSAccessibilityElement` subclasses, not `NSView`s, so there
    /// is no public type to cast to — only the informal protocol's selectors,
    /// which they do respond to.
    private static func walk(
        _ element: Any, depth: Int, seen: inout Set<ObjectIdentifier>, into nodes: inout [Node]
    ) {
        guard depth < 24 else { return }
        let object = element as AnyObject
        // The two child sources below overlap heavily — the same row arrives
        // once as an accessibility element and again through its host view's
        // `subviews` — and without this the walk re-descends each overlap,
        // which is exponential in the nesting depth of a `List` row. That is
        // not just slow in the abstract: this suite runs concurrently with
        // `ClipboardClearingTests`, whose 50ms clear timer needs the main
        // actor back inside 400ms.
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }

        func string(_ name: String) -> String {
            let selector = Selector((name))
            guard object.responds(to: selector),
                  let raw = object.perform(selector)?.takeUnretainedValue() else { return "" }
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
               let found = object.perform(selector)?.takeUnretainedValue() as? [Any] {
                children += found
            }
        }
        // SwiftUI hosts some controls (text fields, buttons) as real AppKit
        // views, which carry their accessibility on the view itself and do
        // not appear in the element children above. The editor's value field
        // — the whole subject of `maskedValuesNeverReachTheAccessibilityTree`
        // — is one of them, so missing this branch would make that test
        // vacuous.
        if let view = element as? NSView { children += view.subviews }

        for child in children { walk(child, depth: depth + 1, seen: &seen, into: &nodes) }
    }
}

/// Deliberately **not** `@MainActor` at the suite level, though every probe
/// inside it is.
///
/// `ClipboardClearing.copy` schedules its wipe as a `Task` on the main actor,
/// and `ClipboardClearingTests` asserts the pasteboard is clear 400ms after a
/// 50ms copy. Swift Testing runs suites concurrently, so anything here that
/// holds the main actor across that window starves that timer and fails
/// somebody else's test. Measured: with the fixture work (a real `age-keygen`
/// subprocess plus a `sops` encrypt, both synchronous) on the main actor, that
/// suite went from 6/6 green to 1 failure in 4 runs. Keeping the expensive
/// parts off-actor and hopping over only for the layout keeps it green.
@Suite("the accessibility tree", .serialized)
struct AccessibilityTreeTests {

    // MARK: - The editor

    /// The plaintext behind the fixture, so the leak test and the fixture
    /// cannot drift apart.
    private static let plaintext = """
        db:
            password: correct-horse-battery-staple-EXAMPLE
            host: db.internal.example
        api_key: sk_live_EXAMPLEEXAMPLEEXAMPLE0001
        """
    private static let secrets = [
        "correct-horse-battery-staple-EXAMPLE", "db.internal.example",
        "sk_live_EXAMPLEEXAMPLEEXAMPLE0001",
    ]

    private func loadedEditor() async throws -> SecretDocumentViewModel {
        // Off the main actor on purpose — see the suite's doc comment.
        let key = try AgeKey.generate()
        let encrypted = try SopsBridge.encryptYAML(Self.plaintext, recipients: [key.public])
        return try await MainActor.run {
            let store = SessionKeyStore()
            try store.importKey(key.private)
            return SecretDocumentViewModel(
                fileURL: URL(fileURLWithPath: "/dev/null/accessibility.yaml"),
                keyStore: store, readFile: { _ in encrypted })
        }
    }

    @Test("no plaintext value reaches the accessibility tree of a masked editor")
    func maskedValuesNeverReachTheAccessibilityTree() async throws {
        let model = try await loadedEditor()
        await model.load()
        // The fixture is only meaningful if the view model really decrypted
        // it — a `.needsKey`/`.failed` editor has no values to leak.
        #expect(await model.rows.contains { $0.path == ["db", "password"] })

        let nodes = await AXProbe.tree(size: CGSize(width: 760, height: 560)) {
            SecretEditorView(viewModel: model, fileName: "production.secrets.yaml",
                             unsavedChanges: UnsavedChangesTracker())
        }
        let secrets = Self.secrets

        // Canary: a tree that never populated cannot leak anything, and would
        // let the assertion below pass while proving nothing.
        #expect(nodes.contains { $0.value == "db.password" },
                "the tree did not populate — this test would be vacuous")

        for node in nodes {
            for secret in secrets {
                #expect(!node.value.contains(secret),
                        "an accessibility value exposed a decrypted secret")
                #expect(!node.label.contains(secret),
                        "an accessibility label exposed a decrypted secret")
                #expect(!node.help.contains(secret),
                        "accessibility help text exposed a decrypted secret")
            }
        }
    }

    @Test("a masked row still announces its key, type and the actions on it")
    func maskedRowIsStillNavigable() async throws {
        let model = try await loadedEditor()
        await model.load()
        let nodes = await AXProbe.tree(size: CGSize(width: 760, height: 560)) {
            SecretEditorView(viewModel: model, fileName: "production.secrets.yaml",
                             unsavedChanges: UnsavedChangesTracker())
        }

        let values = Set(nodes.map(\.value))
        let labels = Set(nodes.map(\.label))
        // Masking must not make a row anonymous: without the key path and the
        // type, a VoiceOver user hearing "bullet bullet bullet" has no way to
        // tell which field they are on.
        #expect(values.contains("db.password"))
        // Resolved through `LocalizedKey`, never spelled "string"/"Copy" here:
        // SwiftPM's native build copies `Localizable.xcstrings` uncompiled, so
        // under bare `swift test` every key resolves to its own raw key while
        // `xcodebuild` resolves real English (CLAUDE.md, "Toolchains"). A
        // literal would pass under one compiler and fail under the other —
        // which is exactly what it did, first run.
        #expect(values.contains(LocalizedKey.editorKindString.text))
        #expect(labels.contains(LocalizedKey.editorRevealValue.text))
        #expect(labels.contains(LocalizedKey.actionCopy.text))
        // The value that *is* announced is the mask, never the plaintext.
        #expect(nodes.contains { $0.role == "AXTextField" && $0.value.allSatisfy { $0 == "•" } })
    }

    /// The plaintext behind the length fixture. Two secrets whose lengths
    /// could not be more different: a four-digit PIN and a 64-character
    /// token.
    private static let lengthPlaintext = """
        pin: 1234
        token: \(String(repeating: "T", count: 64))
        """

    /// The leak the mask itself still had.
    ///
    /// `maskedValuesNeverReachTheAccessibilityTree` proves no *character* of a
    /// secret reaches the tree. It does not prove nothing about the secret
    /// does: a `SecureField` bound to the real value publishes one bullet per
    /// character as its accessibility value, so an assistive client — or
    /// anything else attached to the tree, which is any process with the
    /// accessibility entitlement — could read off the exact length of every
    /// secret in the file. This is that property, stated as the only thing
    /// that closes it: two secrets of very different lengths must be
    /// indistinguishable in the tree.
    @Test("two secrets of very different lengths present identically to the accessibility tree")
    func maskDoesNotLeakTheLengthOfTheSecret() async throws {
        let key = try AgeKey.generate()
        let encrypted = try SopsBridge.encryptYAML(Self.lengthPlaintext, recipients: [key.public])
        let model = try await MainActor.run {
            let store = SessionKeyStore()
            try store.importKey(key.private)
            return SecretDocumentViewModel(
                fileURL: URL(fileURLWithPath: "/dev/null/lengths.yaml"),
                keyStore: store, readFile: { _ in encrypted })
        }
        await model.load()
        #expect(await model.rows.count == 2, "the fixture must produce exactly the two value rows")

        let nodes = await AXProbe.tree(size: CGSize(width: 760, height: 300)) {
            SecretEditorView(viewModel: model, fileName: "lengths.yaml",
                             unsavedChanges: UnsavedChangesTracker())
        }

        // Canary, same role as in the test above: an empty tree cannot leak
        // anything and would make every assertion below pass by finding
        // nothing.
        #expect(nodes.contains { $0.value == "pin" }, "the tree did not populate — this test would be vacuous")

        let fieldValues = nodes.filter { $0.role == "AXTextField" }.map(\.value)
        #expect(fieldValues.count == 2,
                "expected one value field per row, got \(fieldValues.count)")
        #expect(Set(fieldValues).count == 1,
                "the two rows' fields are distinguishable: \(fieldValues.map(\.count))")
        // And stated the other way round, so a future mask that happened to
        // be exactly 4 or exactly 64 characters wide could not pass the
        // assertion above by coincidence.
        for value in fieldValues {
            #expect(value.count != 4 && value.count != 64,
                    "a masked field's width still tracks its secret's length")
        }
    }

    // MARK: - HealthFindingRow, every status

    /// The expectation is a `LocalizedKey`, not English text, for the reason
    /// spelled out in `maskedRowIsStillNavigable`. What this pins is that the
    /// five statuses map to five *distinct* announcements and that each row
    /// gets the right one — a property that holds in any language, and would
    /// be broken by copy-pasting the wrong case into `statusDescription`.
    @Test("every finding status announces itself, distinctly", arguments: [
        (HealthStatus.ok, LocalizedKey.statusOK),
        (.warning, .statusWarning),
        (.problem, .statusProblem),
        (.skipped(reason: "Keychain key storage arrives in M3."), .statusSkipped),
        (.unknown(reason: "Update checks are turned off."), .statusUnknown),
    ])
    @MainActor
    func statusRowsAnnounceTheirStatus(status: HealthStatus, key: LocalizedKey) {
        let expected = key.text
        let finding = HealthFinding(
            id: "tool.sops", title: "sops", status: status,
            detail: "Found sops 3.9.4 at /opt/homebrew/bin/sops.")
        let nodes = AXProbe.tree(size: CGSize(width: 560, height: 170)) {
            HealthFindingRow(finding: finding, copyFeedback: CopyFeedback()).padding()
        }

        // The status is carried by a glyph, so it exists for a VoiceOver user
        // only through this label — colour and shape convey nothing.
        #expect(nodes.contains { $0.role == "AXImage" && $0.label == expected },
                "no AXImage announced the status as \"\(expected)\"")
        // And the row is not just a glyph: title and detail are readable too.
        #expect(nodes.contains { $0.value == "sops" })
        #expect(nodes.contains { $0.value.contains("/opt/homebrew/bin/sops") })
    }

    // MARK: - KeyImportView: what the import control claims about the disk

    /// The label was the worst part of the wrong-path defect.
    ///
    /// `KeyImportView`'s button read *"Import from ~/.config/sops/age/keys.txt"*
    /// unconditionally while `SecurityPostureCheck` had already been fixed to
    /// look in the three places the embedded sops really reads
    /// (`AgeKeyFileLocations`). Naming a path the click will not use is not a
    /// cosmetic slip: it is the app asserting, in the one place the user looks,
    /// that it is looking somewhere it is not.
    ///
    /// These render the real view — `./Scripts/snapshots.sh` shows the same
    /// three states as pixels, and pixels are the better proof of layout, but
    /// only the tree can be asserted on in CI.
    private static let libraryKeyFile =
        "/Users/probe/Library/Application Support/sops/age/keys.txt"
    private static let dotConfigKeyFile = "/Users/probe/.config/sops/age/keys.txt"

    @MainActor
    private func keyImportTree(_ options: LegacyKeyFileImportOptions,
                               store: SessionKeyStore = SessionKeyStore()) -> [AXProbe.Node] {
        AXProbe.tree(size: CGSize(width: 560, height: 460)) {
            KeyImportView(store: store, legacyKeyFiles: { options })
        }
    }

    @Test("with exactly one key file, the control names the path it will read")
    @MainActor
    func oneKeyFileIsNamedInTheControl() {
        let nodes = keyImportTree(.one(Self.libraryKeyFile))
        let text = nodes.map { $0.label + " " + $0.value }.joined(separator: "\n")

        // Canary: an empty tree cannot name anything, and every assertion
        // below would pass by finding nothing.
        #expect(text.contains(LocalizedKey.keyImportLegacyButton.text),
                "the tree did not populate — this test would be vacuous")
        #expect(text.contains(Self.libraryKeyFile),
                "the control must name the file a click actually reads: \(text)")
        #expect(!text.contains(Self.dotConfigKeyFile),
                "the path this app used to hardcode must not appear: \(text)")
    }

    /// With two candidates there is no true answer to "which file?" until the
    /// user gives one, so the control's own label must not pretend there is.
    /// The paths live on the menu's items, which do not exist until it is
    /// opened — and opening it is the user's gesture, not this app's.
    @Test("with several key files, the control names no path before the click")
    @MainActor
    func severalKeyFilesNameNoPathUpFront() {
        let nodes = keyImportTree(.several([Self.libraryKeyFile, Self.dotConfigKeyFile]))
        let text = nodes.map { $0.label + " " + $0.value }.joined(separator: "\n")

        #expect(text.contains(LocalizedKey.keyImportLegacyChooseButton.text),
                "the tree did not populate — this test would be vacuous: \(text)")
        #expect(!text.contains(Self.libraryKeyFile), "a path was named up front: \(text)")
        #expect(!text.contains(Self.dotConfigKeyFile), "a path was named up front: \(text)")
    }

    /// "No key file found" is worth nothing unless the user can see *where*
    /// this app looked — the same lesson `SecurityPostureCheck`'s all-clear
    /// had to learn, one view over.
    @Test("with no key file, the control names every place it looked")
    @MainActor
    func noKeyFileNamesEveryPlaceSearched() {
        let searched = [Self.libraryKeyFile, Self.dotConfigKeyFile]
        let nodes = keyImportTree(.noneFound(searched: searched))
        let text = nodes.map { $0.label + " " + $0.value }.joined(separator: "\n")

        #expect(text.contains(LocalizedKey.keyImportLegacyNoneButton.text),
                "the tree did not populate — this test would be vacuous: \(text)")
        for path in searched {
            #expect(text.contains(path), "an all-clear must say where it looked: \(text)")
        }
    }

    /// The property `KeyImportView`'s header comment exists to protect, tested
    /// against a real file rather than asserted in prose: building and laying
    /// out the whole view over a key file that genuinely exists on disk must
    /// leave the store empty. Resolving the candidates is a `stat` per path;
    /// the `open` happens on a click and nowhere else.
    @Test("showing the view never reads a key file that is really there")
    @MainActor
    func showingTheViewImportsNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyfile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("keys.txt")
        // A real, well-formed identity would be imported successfully if this
        // view ever read the file on its own — which is the point. Obviously
        // fake per CLAUDE.md: never generated, never a usable key.
        try "AGE-SECRET-KEY-1EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE\n"
            .write(to: keyFile, atomically: true, encoding: .utf8)

        let store = SessionKeyStore()
        let nodes = keyImportTree(.one(keyFile.path), store: store)

        #expect(!nodes.isEmpty, "the tree did not populate — this test would be vacuous")
        #expect(store.state == .empty,
                "the view imported a key nobody asked it to import")
    }
}

/// A throwaway age identity from the real `age-keygen`. Mirrors
/// `SopsEngineTests/TestSupport.swift`'s `AgeKeyPair` — duplicated because
/// that lives in a test target this one has no dependency path to.
private struct AgeKey {
    let `private`: String
    let `public`: String

    static func generate() throws -> AgeKey {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("AGE-SECRET-KEY-") { priv = String(line) }
            if line.hasPrefix("# public key: ") { pub = String(line.dropFirst("# public key: ".count)) }
        }
        struct Failure: Error {}
        guard !priv.isEmpty, !pub.isEmpty else { throw Failure() }
        return AgeKey(private: priv, public: pub)
    }
}
