import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// Ticket #25 claim 1. `ProjectScanner.scan(root:)` used to have no way to
/// visit more — or fewer — than the hardcoded `maxScannedFiles`. This pins
/// the new `maxScannedFiles:` parameter directly, ahead of the higher-level
/// `ScanBudgetSetting`/`ProjectHealthCheck` wiring, which is covered
/// separately.
@Suite("ProjectScanner.scan honours a caller-supplied budget")
struct ProjectScanConfigurableBudgetTests {

    private func makeFlatFixture(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("configurable-budget-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try "x".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("omitting the parameter keeps the hard-constant default")
    func defaultParameterMatchesTheConstant() async throws {
        let root = try makeFlatFixture(fileCount: 10)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = await ProjectScanner.scan(root: root)

        #expect(scanned.scanBudget == ProjectScanner.maxScannedFiles)
        #expect(!scanned.wasTruncated)
    }

    @Test("a caller-supplied budget smaller than the constant truncates at that smaller number")
    func aSmallerBudgetTruncatesEarlier() async throws {
        let root = try makeFlatFixture(fileCount: 10)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = await ProjectScanner.scan(root: root, maxScannedFiles: 4)

        #expect(scanned.wasTruncated, "4 of 10 files must read as truncated")
        #expect(scanned.filesVisited == 4)
        #expect(scanned.scanBudget == 4, "the disclosure needs to know which budget was actually used")
    }

    @Test("a caller-supplied budget larger than the old constant lets a bigger tree scan in full")
    func aLargerBudgetCoversMoreFiles() async throws {
        let over = ProjectScanner.maxScannedFiles + 200
        let root = try makeFlatFixture(fileCount: over)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = await ProjectScanner.scan(root: root, maxScannedFiles: over + 50)

        #expect(!scanned.wasTruncated,
                "raising the budget past the tree's real size must let it finish uncapped")
        #expect(scanned.filesVisited == over)
    }
}
