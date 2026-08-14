import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// Ticket #10, claim 3's other half: `AcknowledgedUnreadableMarkerTests`
/// covers the marker itself, this covers `ProjectHealthCheck` actually
/// reading it back and turning it into a finding a user can see — the
/// "health nález" the ticket's Zadání asks for, mirroring the shape
/// `filePermissionsFinding` already established for a per-file property read
/// straight off disk.
private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

@Suite("ProjectHealthCheck: files created unreadable")
struct ProjectHealthCheckAcknowledgedUnreadableTests {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acknowledged-unreadable-health-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ProjectFixture.gitInit(root)
        return root
    }

    private func finding(_ findings: [HealthFinding], suffix: String) -> HealthFinding? {
        findings.first { $0.id.hasSuffix(suffix) }
    }

    @Test("a project with no marked files draws an OK finding")
    func noMarkedFilesIsOK() async throws {
        let root = try makeProject()
        let recipient = try ProjectFixture.ageKeyPair().public
        try ProjectFixture.write(
            try ProjectFixture.encrypted("password: hunter2\n", to: [recipient]),
            to: root, at: "secret.yaml")

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let result = await check.run()
        let unreadable = try #require(finding(result, suffix: "acknowledged-unreadable"))
        #expect(unreadable.status == .ok)
    }

    @Test("a file marked acknowledged-unreadable is named in a warning finding")
    func markedFileWarns() async throws {
        let root = try makeProject()
        let recipient = try ProjectFixture.ageKeyPair().public
        let target = root.appendingPathComponent("unreadable.yaml")
        try ProjectFixture.encrypted("password: hunter2\n", to: [recipient])
            .write(to: target, atomically: true, encoding: .utf8)
        AcknowledgedUnreadableMarker.mark(target)

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let result = await check.run()
        let unreadable = try #require(finding(result, suffix: "acknowledged-unreadable"))
        #expect(unreadable.status == .warning)
        #expect(unreadable.detail.contains("unreadable.yaml"))
    }

    @Test("a project with no encrypted files at all draws an OK finding, not a warning")
    func noEncryptedFilesIsOK() async throws {
        let root = try makeProject()
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let result = await check.run()
        let unreadable = try #require(finding(result, suffix: "acknowledged-unreadable"))
        #expect(unreadable.status == .ok)
    }
}
