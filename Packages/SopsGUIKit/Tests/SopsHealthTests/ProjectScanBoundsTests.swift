import Foundation
import Testing
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

    @Test("a truncated scan never lets the recipients finding report OK")
    func truncationBlocksOK() async throws {
        let root = try makeTree(dirName: "src", count: ProjectHealthCheck.maxScannedFiles + 50)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        creation_rules:
          - age: age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let check = ProjectHealthCheck(source: FixedProjects(projects: [
            InspectedProject(name: "big", rootPath: root.path)
        ]))
        let findings = await check.run()
        let recipients = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(recipients.status != .ok, "a partial scan cannot vouch for the whole project")
    }
}

private struct FixedProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}
