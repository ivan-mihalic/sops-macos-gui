import Foundation
import SopsEngine
import Testing
@testable import SopsProjects

/// The third of `String.crossesCBoundaryIntact`'s three known call sites
/// (`SopsEngine.SopsBridge.swift:373`) — proven here the same way
/// `Tests/SopsUITests/HostileFileRefusalTests.swift` proves the first
/// (`SecretDocumentViewModel.load()`) and
/// `RecipientAccessHostileFileRefusalTests.swift` proves the second
/// (`RecipientAccessModel.load()`): inject a NUL-bearing string directly as
/// the "file" this applier reads, no real disk I/O needed.
///
/// `ProjectRecipientApplier.applyToOne(_:_:_:_:)` guards this, immediately
/// before `readRecipients(contents, format)` (which defaults to
/// `SopsBridge.recipients(in:format:)`) — until this test, that guard had no
/// behavioural proof of its own; only the load-path guard in
/// `SecretDocumentViewModel` did.
@Suite("ProjectRecipientApplier refuses a file it cannot read whole")
struct ProjectRecipientApplierHostileFileRefusalTests {

    /// A raw NUL is valid UTF-8, so it survives the read and then ends the
    /// argument at the C boundary — everything after it is gone. Before this
    /// guard, a project-wide rewrap would have re-wrapped and overwritten a
    /// file using only its own metadata read up to the first NUL as the
    /// full picture, silently discarding the rest of the document on write.
    @Test("a file carrying a NUL byte is recorded as failed, not silently misread")
    func nulBearingFileIsRecordedAsFailed() async {
        let url = URL(fileURLWithPath: "/dev/null/hostile-applier.yaml")
        let applier = ProjectRecipientApplier(
            readFile: { _ in "alpha: one\n\u{0}beta: two\n" },
            fingerprintFile: { _ in nil })

        let outcome = await applier.apply(
            files: [ProjectRecipientApplier.ScopedFile(url: url, format: .yaml)],
            recipients: ["age1anything"], agePrivateKey: "")

        guard case .failed(let message) = outcome.results.first?.outcome else {
            Issue.record("a NUL-truncated file was not recorded as .failed: \(String(describing: outcome.results.first?.outcome))")
            return
        }
        #expect(message.contains("NUL"), "the failure reason does not say what is wrong: \(message)")
    }

    @Test("an ordinary file's failure (e.g. not a SOPS document) is unaffected")
    func ordinaryFailureIsNotMisreportedAsNUL() async {
        let url = URL(fileURLWithPath: "/dev/null/ordinary-applier.yaml")
        let applier = ProjectRecipientApplier(
            readFile: { _ in "not a sops document\n" },
            fingerprintFile: { _ in nil })

        let outcome = await applier.apply(
            files: [ProjectRecipientApplier.ScopedFile(url: url, format: .yaml)],
            recipients: ["age1anything"], agePrivateKey: "")

        if case .failed(let message) = outcome.results.first?.outcome {
            #expect(!message.contains("NUL"), "an ordinary failure was reported as NUL-bearing")
        }
    }
}
