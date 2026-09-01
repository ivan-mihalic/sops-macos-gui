import Foundation
import SopsEngine
import SopsProjects
import Testing
@testable import SopsUI

/// The second of `String.crossesCBoundaryIntact`'s three known call sites
/// (`SopsBridge.swift:373`; see `HostileFileRefusalTests.swift` for the
/// first, `SecretDocumentViewModel.load()`) — proven here the same way:
/// inject a NUL-bearing string directly as the "file" this model reads, no
/// real disk I/O needed, mirroring `HostileFileRefusalTests`'s own
/// `model(reading:...)` helper.
///
/// `RecipientAccessModel.load()` guards this at `RecipientAccessModel.swift:290`,
/// immediately before `SopsBridge.recipients(in: contents, format: .yaml)` — until this
/// test, that guard had no behavioural proof of its own, only the sibling
/// guard in `SecretDocumentViewModel` did.
@Suite("RecipientAccessModel refuses a document it cannot read whole")
@MainActor
struct RecipientAccessHostileFileRefusalTests {

    private func model(
        reading contents: String,
        fingerprint: @escaping @Sendable (URL) -> FileFingerprint? = { _ in nil },
        url: URL = URL(fileURLWithPath: "/dev/null/hostile-access.yaml")
    ) -> RecipientAccessModel {
        RecipientAccessModel(
            fileURL: url, projectURL: nil, keyStore: SessionKeyStore(), format: .yaml,
            readFile: { _ in contents }, fingerprintFile: fingerprint)
    }

    /// A raw NUL is valid UTF-8, so it survives the read and then ends the
    /// argument at the C boundary — everything after it is gone. Before this
    /// guard, `SopsBridge.recipients(in:)` would have reported whatever
    /// recipient metadata happened to precede the NUL as this document's
    /// complete, authoritative access list.
    @Test("a document carrying a NUL byte is refused rather than misreported")
    func nulBearingDocumentIsRefused() async {
        let model = model(reading: "alpha: one\n\u{0}beta: two\n")
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("a NUL-truncated document was loaded as \(String(describing: model.loadState))")
            return
        }
        #expect(message.contains("NUL"), "the refusal does not say what is wrong: \(message)")
        #expect(model.currentRecipients.isEmpty, "recipients were read from a document read only up to its first NUL")
    }

    @Test("an ordinary document is unaffected")
    func ordinaryDocumentStillLoads() async {
        let model = model(reading: "not a sops file\n")
        await model.load()
        if case .failed(let message) = model.loadState {
            #expect(!message.contains("NUL"), "an ordinary document was refused as NUL-bearing")
        }
    }
}
