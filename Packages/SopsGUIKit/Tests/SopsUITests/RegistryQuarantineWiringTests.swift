import Foundation
import Testing
@testable import SopsUI

/// Every screen that reads the recipient registry must read it through
/// `RecipientRegistry.loadOrQuarantine(in:)`, never the bare
/// `(try? RecipientRegistry.load(in:)) ?? []` idiom that preceded it.
///
/// A source-text guard rather than a behavioural one, and deliberately so:
/// three of these six call sites keep the result in SwiftUI `@State`, which
/// lives on the framework's persistent view identity rather than on the
/// struct value a test can hold, so there is nothing to inspect after a
/// render without either a model refactor or new UI. What can be checked
/// mechanically is that no call site has drifted back to the silent idiom —
/// which is the regression this exists to catch (SOPS-27 claim 5).
///
/// ⚠️ This says nothing about the notice being *shown* — it only pins that
/// every call site *reads* it. SOPS-33 found it set at all six call sites and
/// rendered at none, and closed that for the two dedicated access panels:
/// `ProjectAccessView` (`ProjectAccessTests
/// .thePanelRendersTheRegistryQuarantineBanner`) and `RecipientAccessView`
/// (`RecipientAccessRegistryQuarantineTests.noticeIsRendered`), both through
/// the shared `RegistryQuarantineBanner`. The three wizard `@State` call
/// sites (`EncryptedImportPreview`, `RecipientPicker`, `NewSecretFileSheet`)
/// remain store-only by deliberate choice — see `RegistryQuarantineBanner`'s
/// own doc comment for why a transient file-creation flow is not the place
/// for a banner about the project's registry housekeeping.
@Suite("registry reads route through loadOrQuarantine")
struct RegistryQuarantineWiringTests {
    private static let sources = [
        "Projects/ProjectAccessModel.swift",
        "Projects/ProjectStartHereView.swift",
        "Projects/EncryptedImportPreview.swift",
        "Projects/RecipientPicker.swift",
        "Projects/NewSecretFileSheet.swift",
        "Editor/RecipientAccessModel.swift",
    ]

    private static func read(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SopsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SopsGUIKit
            .appendingPathComponent("Sources/SopsUI")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("no screen reads the registry with the silent idiom")
    func noSilentRegistryReads() throws {
        var offenders: [String] = []
        for source in Self.sources where try Self.read(source).contains("try? RecipientRegistry.load(in:") {
            offenders.append(source)
        }
        #expect(offenders.isEmpty, "these still swallow a corrupt registry: \(offenders)")
    }

    @Test("every screen that reads the registry names loadOrQuarantine")
    func everyReaderQuarantines() throws {
        var missing: [String] = []
        for source in Self.sources where try !Self.read(source).contains("loadOrQuarantine(in:") {
            missing.append(source)
        }
        #expect(missing.isEmpty, "these read the registry without quarantining: \(missing)")
    }
}
