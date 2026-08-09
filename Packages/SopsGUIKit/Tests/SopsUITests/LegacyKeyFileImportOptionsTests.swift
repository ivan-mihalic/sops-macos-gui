import Foundation
import SopsHealth
import Testing
import SopsProjects
@testable import SopsUI

/// The half of the wrong-path defect that lived in the UI.
///
/// Task 18 fixed `SecurityPostureCheck` to stat every place the embedded sops
/// actually reads an age key file from — `SOPS_AGE_KEY_FILE`, then
/// `$XDG_CONFIG_HOME`/`~/Library/Application Support`, and `~/.config` on top
/// because a plaintext key there is a plaintext key. The import button did not
/// move: it hardcoded `NSHomeDirectory() + "/.config/sops/age/keys.txt"` and
/// its own label read *"Import from ~/.config/sops/age/keys.txt"*. So the app
/// could report a key file in `Library/Application Support` and then offer a
/// button that looked somewhere else, failed, and named the place it had looked
/// — leaving the user no way to see the two halves disagreed.
///
/// Every test here injects `environment`, `homeDirectory` and `isRegularFile`.
/// None touches the real ones: Swift Testing runs suites in parallel in one
/// process, so a `setenv` here is a corrupted test somewhere else.
@Suite("the key-file import control's choices")
struct LegacyKeyFileImportOptionsTests {

    private static let home = "/Users/probe"
    private static let library = "/Users/probe/Library/Application Support/sops/age/keys.txt"
    private static let dotConfig = "/Users/probe/.config/sops/age/keys.txt"

    private static func resolve(existing: Set<String>,
                                environment: [String: String] = [:]) -> LegacyKeyFileImportOptions {
        LegacyKeyFileImportOptions.resolve(
            environment: environment, homeDirectory: home,
            isRegularFile: { existing.contains($0) })
    }

    // MARK: - Which file a click reads

    /// The regression, stated directly. A key file sitting exactly where the
    /// embedded sops keeps one, and nowhere else, is the file this control must
    /// offer — the old button would have tried `~/.config` and failed.
    @Test("a key file only in the Library location is the one the button offers")
    func libraryLocationIsOffered() {
        let options = Self.resolve(existing: [Self.library])

        #expect(options == .one(Self.library))
        #expect(options.found == [Self.library])
        #expect(!options.found.contains(Self.dotConfig),
                "the button must not offer the path this app used to hardcode")
    }

    /// `~/.config` is still a real place to find a plaintext key — it is where
    /// every tutorial and Linux habit puts one. It just is not the *only* one.
    @Test("a key file only in ~/.config is still offered")
    func dotConfigIsStillOffered() {
        #expect(Self.resolve(existing: [Self.dotConfig]) == .one(Self.dotConfig))
    }

    /// sops reads `SOPS_AGE_KEY_FILE` before either well-known location, so an
    /// import that claims to be "the key file on this Mac" has to as well.
    @Test("SOPS_AGE_KEY_FILE wins, as it does for sops itself")
    func explicitEnvironmentPathWins() {
        let explicit = "/opt/keys/age.txt"
        let options = Self.resolve(existing: [explicit, Self.library],
                                   environment: ["SOPS_AGE_KEY_FILE": explicit])

        // Both exist, so this is the several case — and `SOPS_AGE_KEY_FILE`
        // leads, because `AgeKeyFileLocations.candidates` puts it first.
        #expect(options == .several([explicit, Self.library]))
        #expect(options.found.first == explicit)
    }

    // MARK: - Nothing to import

    /// Not silence, and not an enabled button whose only outcome is a failure
    /// alert. The searched paths are carried through so the footer can name
    /// them: "nothing found" is indistinguishable from "looked in the wrong
    /// place" unless the places are named — which is the exact untruth this
    /// app told for a whole milestone.
    @Test("with no key file anywhere, the control still says where it looked")
    func noneFoundNamesWhereItLooked() {
        let options = Self.resolve(existing: [])

        guard case .noneFound(let searched) = options else {
            Issue.record("expected noneFound, got \(options)")
            return
        }
        #expect(options.found.isEmpty)
        #expect(searched == AgeKeyFileLocations.candidates(environment: [:],
                                                           homeDirectory: Self.home),
                "every candidate must be named, in sops's own order: \(searched)")
        #expect(searched.contains(Self.library))
        #expect(searched.contains(Self.dotConfig))
    }

    // MARK: - More than one

    /// Two plaintext key files at once is an ordinary state of a developer's
    /// Mac. The app must not pick: first-one-wins would import a key the user
    /// never chose, and — unlike
    /// `SessionKeyStore.Error.multipleKeysInFile`, which at least tells them a
    /// file held several — they would never learn a second candidate existed.
    @Test("two key files become a choice, not a guess")
    func severalIsAChoice() {
        let options = Self.resolve(existing: [Self.library, Self.dotConfig])

        #expect(options == .several([Self.library, Self.dotConfig]),
                "both must be offered, in candidate order")
        #expect(options.found.count == 2)
    }

    /// A duplicate is one file, not two: `SOPS_AGE_KEY_FILE` pointing at the
    /// same file `~/.config` holds must not turn a single key file into a
    /// menu asking the user to choose between it and itself.
    @Test("the same file named twice is one candidate, not a choice")
    func duplicateCandidateIsNotAChoice() {
        let options = Self.resolve(existing: [Self.dotConfig],
                                   environment: ["SOPS_AGE_KEY_FILE": Self.dotConfig])

        #expect(options == .one(Self.dotConfig))
    }

    // MARK: - What is offered is what would be protected

    /// The `chmod` the app hands the user after an import has to name the file
    /// it actually read. It used to be built from the same hardcoded constant
    /// the button was, so on a Mac whose key lives in `Library/Application
    /// Support` it named a file that does not exist — a command a user pastes
    /// into a shell, about the wrong file.
    @Test("the protect command names the file that was imported, quoted")
    func protectCommandNamesTheImportedFile() throws {
        let command = try #require(AgeKeyFileLocations.protectCommand(for: [Self.library]))

        #expect(command == "chmod 600 '\(Self.library)'")
        #expect(!command.contains(".config"), "the wrong path must not reappear here")
    }
}

/// The snapshot catalog's "configured" fixture must actually configure.
///
/// It was 72 characters and `importKey` requires 74, so `try?` swallowed the
/// refusal, the store stayed `.empty`, and the PNG named `key-import-configured`
/// showed the empty state. Snapshots are read by people deciding whether a
/// screen is right; one that renders the opposite state is worse than none.
@MainActor
@Suite("The snapshot catalog's configured key fixture really configures")
struct SnapshotKeyFixtureTests {

    @Test("the key literal in Catalog.swift is accepted by SessionKeyStore")
    func catalogKeyIsAccepted() throws {
        let catalog = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SnapshotTool/Catalog.swift").path,
            encoding: .utf8)

        let literals = catalog
            .components(separatedBy: "\"")
            .filter { $0.hasPrefix("AGE-SECRET-KEY-1") }
        #expect(!literals.isEmpty, "no key literal found — has the catalog moved?")

        for literal in literals {
            let store = SessionKeyStore()
            #expect(throws: Never.self) { try store.importKey(literal) }
            #expect(
                store.state == .configured,
                "a catalog key literal is refused, so any snapshot built from it renders the empty state")
        }
    }
}
