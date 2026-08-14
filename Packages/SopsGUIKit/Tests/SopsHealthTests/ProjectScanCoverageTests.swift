import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// Ticket #25 claim 4. `ScanLimitation`'s own doc comment says plainly what
/// is *not* enforced: "a new `continue` in the walk that records nothing.
/// The enum cannot see a statement that never mentions it... this needs a
/// test that pins the walk's own coverage — a fixture with a known file
/// count asserted against what the scan reports having examined — which
/// does not exist yet." That sentence was proven true by review, not just
/// asserted: a plausible size-cap `continue` added to `ProjectScanner.walk`,
/// recording no `ScanLimitation` at all, compiled and left the whole suite
/// green.
///
/// This is that test. `ScannedTree.filesVisited` — added alongside this
/// test — is the count `ProjectScanner.walk` already keeps internally
/// (`visitedFileCount`, used only to compare against the budget) but never
/// exposed, so nothing outside the function could ever ask "did the walk
/// actually look at everything I expect it to have looked at". A fixture
/// built entirely from ordinary, unexcluded, readable regular files makes
/// the expected answer computable in advance — `K` files in, `K` files
/// visited — so any future `continue` that drops one of them silently,
/// wherever in the loop it is added, moves `filesVisited` away from `K`
/// with no `ScanLimitation` required to notice.
///
/// Proven able to fail, not just written to pass: a `continue` matching the
/// doc comment's own illustrative defect (a plausible size-cap check, added
/// to the walk, recording nothing) was introduced during this work,
/// observed to redden exactly this test with every other test in the
/// package still green, and reverted. See the session report for the
/// transcript.
@Suite("the walk's own coverage of the files it should have visited")
struct ProjectScanCoverageTests {

    private func makeFlatFixture(fileCount: Int, label: String = "coverage") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            // Deliberately ordinary: no sops metadata, no `.env`-shaped name,
            // no dotfile, nothing that would route it through a different
            // code path than "an unremarkable file this walk should see".
            try "ordinary contents \(i)".write(
                to: root.appendingPathComponent("plain-file-\(i).txt"),
                atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("a flat tree of ordinary files is visited in full, and the walk says so")
    func flatTreeIsFullyVisited() async throws {
        let fileCount = 250
        let root = try makeFlatFixture(fileCount: fileCount)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = await ProjectScanner.scan(root: root)

        let message = "expected every one of \(fileCount) plain files to be visited; the walk "
            + "reports \(scanned.filesVisited) — a file was silently dropped somewhere in "
            + "ProjectScanner.walk with no ScanLimitation to explain the gap"
        #expect(scanned.filesVisited == fileCount, "\(message)")
        #expect(!scanned.wasTruncated, "the fixture is far under the budget")
        #expect(scanned.limitations.isEmpty, "an all-ordinary fixture has nothing to disclose")
    }

    /// The budget itself has to be reflected in the same count, or
    /// `filesVisited` would be a second, disagreeing notion of "how many
    /// files did this walk look at" right alongside `wasTruncated` — the
    /// exact "two places to record the same fact" `ScannedTree.wasTruncated`
    /// itself is a computed property to avoid.
    @Test("filesVisited stops at the budget, matching wasTruncated")
    func filesVisitedStopsAtTheBudget() async throws {
        let over = ProjectScanner.maxScannedFiles + 25
        let root = try makeFlatFixture(fileCount: over, label: "coverage-budget")
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = await ProjectScanner.scan(root: root)

        #expect(scanned.wasTruncated)
        let message = "a truncated walk must report having visited exactly the budget, not the "
            + "full fixture count and not some other number"
        #expect(scanned.filesVisited == ProjectScanner.maxScannedFiles, "\(message)")
    }
}
