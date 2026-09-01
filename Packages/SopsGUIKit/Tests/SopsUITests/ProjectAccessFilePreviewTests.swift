import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixtures

private struct PreviewFixtureError: Error, CustomStringConvertible {
    let description: String
}

private struct PreviewAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> PreviewAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PreviewFixtureError(description: "age-keygen not found in \(candidates)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw PreviewFixtureError(description: "age-keygen produced no usable key pair")
        }
        return PreviewAgeKeyPair(private: priv, public: pub)
    }
}

private func previewScratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A project with two encrypted files in different directories, so a preview
/// that showed only `lastPathComponent` would be ambiguous where a real project
/// is ambiguous — `prod/db.yaml` and `dev/db.yaml` are two different files.
private func makeNestedProject(owner: PreviewAgeKeyPair) throws -> URL {
    let root = try previewScratchDirectory("project-access-preview")
    try """
        creation_rules:
          - path_regex: .*\\.yaml$
            age:
              - \(owner.public)

        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    let encrypted = try SopsBridge.encrypt(
        "database:\n    password: correct-horse-battery-staple\n", format: .yaml, recipients: [owner.public])
    for directory in ["dev", "prod"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for path in ["dev/db.yaml", "prod/db.yaml"] {
        try encrypted.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    return root
}

// MARK: - D2

/// D2. The panel said "N of M" and an unmatched count; the file *names* only
/// ever appeared as results, after the run — so the one screen where the user
/// could still change their mind named no file at all. The design spec's
/// Produces line asked for a preview.
@Suite("ProjectAccessView — which files an apply would touch, before it touches them")
@MainActor
struct ProjectAccessFilePreviewTests {

    private func rendered(_ nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    /// A bare `lastPathComponent` is not a preview of anything in a project
    /// that keeps `db.yaml` under two directories, which is the ordinary shape.
    @Test("a previewed file is named by its path within the project")
    func previewPathIsProjectRelative() {
        let root = URL(fileURLWithPath: "/tmp/preview-fixture")
        #expect(
            ProjectAccessView.previewPath(
                of: root.appendingPathComponent("prod/db.yaml"), in: root) == "prod/db.yaml")
        #expect(
            ProjectAccessView.previewPath(
                of: root.appendingPathComponent("a.yaml"), in: root) == "a.yaml")
    }

    /// The path-spelling trap this repo has already been bitten by once, and
    /// exercised against a real scan rather than a hand-built pair of strings:
    /// `ProjectScanner` returns `/private/var/…` while the project root keeps
    /// the `/var/…` spelling `FileManager.temporaryDirectory` hands out, so a
    /// literal prefix strip is a no-op and every previewed file would show its
    /// absolute path instead of a name.
    @Test("the two spellings of the same directory do not defeat the strip")
    func previewPathResolvesSymlinkedSpellings() async throws {
        let owner = try PreviewAgeKeyPair.generate()
        let root = try makeNestedProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        let plan = try #require(model.plan)
        let scanned = try #require(model.filesToApply.first)
        try #require(!scanned.url.path.hasPrefix(plan.projectRoot.path),
                     "precondition: the scan and the root really do disagree on the spelling")
        #expect(ProjectAccessView.previewPath(of: scanned.url, in: plan.projectRoot) == "dev/db.yaml")
    }

    /// A preview whose cost grows with the project is not a preview a project
    /// with thousands of encrypted files can afford to draw. It is bounded, and
    /// the remainder is stated rather than dropped.
    @Test("a project past the preview limit shows a bounded list and counts the rest")
    func previewIsBounded() {
        let many = (0..<(ProjectAccessView.filesPreviewLimit + 7)).map {
            URL(fileURLWithPath: "/tmp/preview-fixture/f\($0).yaml")
        }
        let preview = ProjectAccessView.previewedFiles(many)
        #expect(preview.shown.count == ProjectAccessView.filesPreviewLimit)
        #expect(preview.overflow == 7)

        let few = Array(many.prefix(3))
        #expect(ProjectAccessView.previewedFiles(few).shown.count == 3)
        #expect(ProjectAccessView.previewedFiles(few).overflow == 0)
    }

    /// A file outside the project has no relative name to give. Falling back to
    /// its own last component is honest; a half-stripped absolute path is not.
    @Test("a file outside the project falls back to its own name")
    func previewPathFallsBack() {
        #expect(
            ProjectAccessView.previewPath(
                of: URL(fileURLWithPath: "/elsewhere/db.yaml"),
                in: URL(fileURLWithPath: "/tmp/preview-fixture")) == "db.yaml")
    }

    @Test("the panel lists the files an apply would re-wrap, before the run")
    func thePanelPreviewsTheFiles() async throws {
        let owner = try PreviewAgeKeyPair.generate()
        let root = try makeNestedProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        try #require(model.filesToApply.count == 2)
        #expect(model.fileResults.isEmpty, "precondition: nothing has been applied — this is a preview")

        let text = rendered(host.nodes())
        #expect(text.contains(LocalizedKey.projectAccessFilesPreviewTitle.text))
        #expect(text.contains("dev/db.yaml"))
        #expect(text.contains("prod/db.yaml"))
    }

    /// A project with nothing in scope must not grow an empty heading.
    @Test("a project with no files in scope shows no preview at all")
    func noFilesNoPreview() async throws {
        let root = try previewScratchDirectory("project-access-preview-empty")
        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        try #require(model.filesToApply.isEmpty)
        #expect(!rendered(host.nodes()).contains(LocalizedKey.projectAccessFilesPreviewTitle.text))
    }
}
