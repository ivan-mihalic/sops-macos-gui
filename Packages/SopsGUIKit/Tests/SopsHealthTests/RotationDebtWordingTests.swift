import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// The rotation-debt finding has to say, in its own detail, that only the user
/// can clear it.
///
/// It is the one finding in the report that **stays red after the condition
/// that produced it is gone** — deliberately, because this app cannot verify
/// that a password was actually changed. A user who gitignores the plaintext
/// file, or re-wraps the stale recipient, then re-runs the report and still
/// sees red will reasonably conclude the app is not re-scanning.
///
/// The remediation already explains it. The detail did not, and the detail is
/// what a reader sees first — the remediation sits behind the finding's
/// disclosure in the panel. A correct explanation nobody reaches at the moment
/// of confusion is not doing the work.
@Suite("Rotation debt says who can clear it")
struct RotationDebtWordingTests {

    private struct Ledger: RotationDebtSource {
        let entries: [RotationDebtEntry]
        func rotationDebt(in project: URL) -> [RotationDebtEntry] { entries }
        func record(path: String, reason: RotationDebtReason, in project: URL) {}
    }

    private struct OneProject: ProjectSourceProviding {
        let projects: [InspectedProject]
    }

    private func debtFinding() async throws -> HealthFinding {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("rotation-debt-wording")
        let check = ProjectHealthCheck(
            source: OneProject(projects: [InspectedProject(name: "demo", rootPath: root.path)]),
            rotationDebt: Ledger(entries: [
                RotationDebtEntry(path: "secrets/prod.yaml",
                                  reason: .recipientRemoved,
                                  recordedAt: Date(timeIntervalSince1970: 1_750_000_000))
            ]))
        let findings = await check.run()
        return try #require(findings.first { $0.id.hasSuffix(".rotation-debt") })
    }

    @Test("the detail itself says the reminder only stops when you settle it")
    func detailNamesTheOnlyWayOut() async throws {
        let finding = try await debtFinding()
        let detail = finding.detail.lowercased()

        // Not a phrase match — any wording is fine as long as the detail
        // carries both halves of the idea, because both are needed to stop a
        // reader concluding the app is stuck: that *they* clear it, and that
        // fixing the original cause does not.
        #expect(detail.contains("mark") || detail.contains("settle"),
                Comment(rawValue: """
                    The rotation-debt detail does not say how the entry is cleared. \
                    This is the one finding that survives its own cause being fixed, so a \
                    reader who fixed it and still sees red has no way to tell that from a \
                    broken re-scan. Detail was: \(finding.detail)
                    """))
        #expect(detail.contains("stay") || detail.contains("remain") || detail.contains("until"),
                Comment(rawValue: """
                    The rotation-debt detail does not say the entry survives the original \
                    condition being fixed. Detail was: \(finding.detail)
                    """))
    }

    /// The remediation keeps carrying the full explanation — this is an
    /// addition to the detail, not a move out of the remediation.
    @Test("the remediation still explains why the app cannot check for you")
    func remediationStillExplains() async throws {
        let finding = try await debtFinding()
        let explanation = try #require(finding.remediation?.explanation)
        #expect(explanation.lowercased().contains("cannot verify"))
    }
}
