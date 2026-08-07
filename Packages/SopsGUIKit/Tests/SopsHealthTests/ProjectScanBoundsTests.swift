import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

@Suite("project scan bounds")
struct ProjectScanBoundsTests {

    /// Builds a tree with `count` files inside `dirName`, plus one real file at the root.
    private func makeTree(dirName: String, count: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-" + UUID().uuidString)
        let noise = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        for i in 0..<count {
            try "x".write(to: noise.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        try "API_KEY=live".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("dependency directories are not walked", arguments: [
        "node_modules", ".build", ".worktrees", "target", "vendor", "Pods", ".venv", "dist",
    ])
    func skipsDependencyDirectories(dirName: String) throws {
        let root = try makeTree(dirName: dirName, count: 200)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = ProjectHealthCheck.scanTree(under: root)

        #expect(scanned.plaintextCandidates.contains { $0.path.hasSuffix(".env") },
                "the root .env must still be found")
        #expect(!scanned.wasTruncated, "200 files is nowhere near the budget")
        #expect(scanned.skippedDirectoryNames.contains(dirName))
    }

    // A budget that is silently hit is the same defect class as a check that
    // reports OK about something it never looked at.
    @Test("hitting the file budget is reported, not swallowed")
    func truncationIsDisclosed() throws {
        let root = try makeTree(dirName: "src", count: ProjectHealthCheck.maxScannedFiles + 50)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = ProjectHealthCheck.scanTree(under: root)

        #expect(scanned.wasTruncated)
    }

    /// A fixture with zero encrypted files is not decisive here: without the
    /// truncation guard, `recipientFinding` still lands on `.skipped` (via
    /// `guard verifiedFileCount > 0 else { guard !tree.encrypted.isEmpty ...
    /// else return .skipped }`), never `.ok` — so `status != .ok` would pass
    /// whether or not the guard under test does anything. This fixture
    /// instead includes files that genuinely match the declared age rule
    /// (encrypted once through the real `SopsBridge`, not hand-written), so
    /// that *without* the truncation guard the run would be a real,
    /// affirmative `.ok`: every check that ran matched, and only the guard
    /// itself stands between that and reporting so.
    ///
    /// Filesystem enumeration order is not something to rely on for which
    /// specific files survive truncation — verified empirically on this
    /// machine (a 5,000-file APFS temp directory) that neither creation
    /// order nor filename order predicts `FileManager`'s enumerator order.
    /// So instead of hoping the matching files happen to be visited before
    /// the budget is hit, their *count* makes it true regardless of order:
    /// `matchingCount` genuinely-encrypted files and a much smaller number of
    /// harmless filler files share the same directory. Truncation always
    /// drops exactly `total - maxScannedFiles` files, `dropped`, in whatever
    /// order the enumerator chose — so even in the adversarial case where
    /// every dropped file happens to be one of the matching ones, at least
    /// `matchingCount - dropped` of them remain counted. With the numbers
    /// below that floor is comfortably positive, so this is deterministic,
    /// not merely likely.
    @Test("a truncated scan never lets the recipients finding report OK")
    func truncationBlocksOK() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-" + UUID().uuidString)
        let noise = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
        try "creation_rules:\n  - age: \(devKey)\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // One real encryption through the bridge, its ciphertext then copied
        // to many paths — each copy is still a genuine, real sops-encrypted
        // file (real recipients, real MAC), not a fixture faking the shape.
        let matchingCipherText = try SopsBridge.encryptYAML(
            "db_password: hunter2\n", recipients: [devKey])
        let matchingCount = 300
        for i in 0..<matchingCount {
            try matchingCipherText.write(
                to: noise.appendingPathComponent("secret\(i).yaml"), atomically: true, encoding: .utf8)
        }

        // Enough filler, alongside the matching files above, to push the
        // total past the budget by 50 — the same margin `truncationIsDisclosed`
        // uses.
        let total = ProjectHealthCheck.maxScannedFiles + 50
        for i in 0..<(total - matchingCount) {
            try "x".write(to: noise.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        // dropped = total + 1 (.sops.yaml) - maxScannedFiles = 51; floor of
        // surviving matching files = matchingCount - 51 = 249, regardless of
        // enumeration order. Sanity-checked, not just asserted, below.
        #expect(matchingCount > total + 1 - ProjectHealthCheck.maxScannedFiles,
                "the combinatorial guarantee this test relies on requires more matching files than can possibly be dropped")

        let check = ProjectHealthCheck(source: FixedProjects(projects: [
            InspectedProject(name: "big", rootPath: root.path)
        ]))
        let findings = await check.run()
        let recipients = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(recipients.status != .ok, "a partial scan cannot vouch for the whole project")
        // Decisive, not incidental: this must be `.unknown` *because of
        // truncation* — not because nothing was found (that would be
        // `.skipped`, which the old version of this test could not tell
        // apart from a real guard). The reason and detail text only appear
        // via the truncation branch in `recipientFinding`.
        guard case .unknown(let reason) = recipients.status else {
            Issue.record("expected .unknown naming the scan budget, got \(recipients.status)")
            return
        }
        #expect(reason.contains("scan budget"))
        #expect(recipients.detail.contains("scan budget of \(ProjectHealthCheck.maxScannedFiles)"))
        // Proof that files were genuinely verified as matching — the run
        // would be an affirmative OK on their account alone if truncation
        // did not intervene.
        #expect(recipients.detail.contains("Checked"))
        #expect(recipients.detail.contains("they all match"))
    }
}

private struct FixedProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}
