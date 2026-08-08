import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func run(_ root: URL) async -> [HealthFinding] {
    await ProjectHealthCheck(source: Projects(
        projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
}

private func leak(_ findings: [HealthFinding]) -> HealthFinding? {
    findings.first { $0.id.hasSuffix("gitignore") }
}

private func recipients(_ findings: [HealthFinding]) -> HealthFinding? {
    findings.first { $0.id.hasSuffix("stale-recipients") }
}

private func dump(_ label: String, _ findings: [HealthFinding]) {
    print("······ \(label)")
    for finding in findings {
        print("--- [\(finding.status)] \(finding.title)\n\(finding.detail)")
    }
    print("······ end \(label)")
}

/// PROPOSAL.md §6 D, second round.
///
/// Task 14 closed three of the ways this check reported OK about files it had
/// not looked at. A whole-branch review then found five more, each verified end
/// to end against the real `ProjectHealthCheck` with fixtures built by the real
/// `git`, `age-keygen` and `SopsBridge.encryptYAML`. They are all the same
/// defect wearing different clothes: a place the walk does not reach, which
/// `ScannedTree` had no way to record and therefore no finding could admit to.
///
/// One suite, one fixture shape per path, because the thing being asserted is
/// identical every time — *the finding says so, and it does not claim OK*.
@Suite("project scan: paths the walk does not reach")
struct ProjectScanUndisclosedScopeTests {

    /// A real git repository with a `.sops.yaml` declaring `good`, one root
    /// file genuinely encrypted to `good`, and whatever else the caller asks
    /// for. The root file is what makes the affirmative branch reachable —
    /// without it the finding is `.skipped` for lack of subject and the false
    /// `.ok` under test never appears.
    private func makeProject(
        stale: [String] = [],
        plaintext: [String: String] = [:],
        extraFiles: [String: String] = [:]
    ) throws -> (root: URL, good: String, other: String) {
        let good = try ProjectFixture.ageKeyPair()
        let other = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(good.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("db_password: hunter2\n", to: [good.public]),
                                 to: root, at: "secrets.yaml")
        for path in stale {
            try ProjectFixture.write(try ProjectFixture.encrypted("api_key: hunter2\n", to: [other.public]),
                                     to: root, at: path)
        }
        for (path, contents) in plaintext { try ProjectFixture.write(contents, to: root, at: path) }
        for (path, contents) in extraFiles { try ProjectFixture.write(contents, to: root, at: path) }
        return (root, good.public, other.public)
    }

    private func chmod(_ url: URL, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - 1. macOS package directories

    /// `.skipsPackageDescendants` was a second exclusion mechanism sitting
    /// beside `skippedDirectoryNames` with no comment and no reporting
    /// anywhere — literally §6 D's "buried in a constant". Everything inside
    /// any macOS package (`.xcodeproj`, `.app`, `.bundle`, …) was invisible,
    /// and both findings said so in the affirmative.
    ///
    /// Reproduced on this app's own repository: `SopsGUI.xcodeproj/project.pbxproj`
    /// was never opened and nothing said so.
    @Test("a plaintext secret inside a package directory is found, not silently skipped")
    func packageDescendantsAreScanned() async throws {
        let project = try makeProject(
            stale: ["App.xcodeproj/hidden-secrets.yaml"],
            plaintext: ["App.xcodeproj/.env": "STRIPE_KEY=sk_live_51H8xQ2abcdefg\n"],
            extraFiles: ["App.xcodeproj/project.pbxproj": "// objects\n"])
        defer { try? FileManager.default.removeItem(at: project.root) }

        let findings = await run(project.root)
        dump("package descendants", findings)

        let plaintext = try #require(leak(findings))
        #expect(plaintext.status == .problem,
                "a live key in App.xcodeproj/.env is not gitignored — got \(plaintext.status): \(plaintext.detail)")
        #expect(plaintext.detail.contains("App.xcodeproj/.env"))
        #expect(!plaintext.detail.contains("sk_live_51H8xQ2abcdefg"))

        let recipientFinding = try #require(recipients(findings))
        #expect(recipientFinding.status == .problem,
                "an encrypted file inside the package is on an undeclared key — got \(recipientFinding.status): \(recipientFinding.detail)")
        #expect(recipientFinding.detail.contains(project.other))
    }

    // MARK: - 2. A file that could not be read

    /// `tailBytes` returned `nil` for a file it could not open, and the file
    /// vanished: `ScannedTree` had no field for it, so a `chmod 000` on a
    /// stale-recipient yaml produced `.ok`, "it matches" — an affirmative
    /// verdict over a file whose contents this app never saw.
    @Test("a file that could not be read is named, and no affirmative verdict is claimed over it")
    func unreadableFileIsDisclosed() async throws {
        let project = try makeProject(stale: ["locked.yaml"])
        let locked = project.root.appendingPathComponent("locked.yaml")
        chmod(locked, 0o000)
        defer {
            chmod(locked, 0o600)
            try? FileManager.default.removeItem(at: project.root)
        }

        let findings = await run(project.root)
        dump("unreadable file", findings)

        let recipientFinding = try #require(recipients(findings))
        #expect(recipientFinding.status != .ok,
                "a file this app could not open cannot be part of an affirmative verdict: \(recipientFinding.detail)")
        #expect(recipientFinding.detail.contains("locked.yaml"),
                "the finding must name the file it could not read: \(recipientFinding.detail)")
    }

    // MARK: - 3. A directory that could not be listed

    /// An unreadable subdirectory was `continue`d and its children never
    /// appeared at all, so both findings reported `.ok` over a part of the
    /// tree this app never saw the contents of.
    @Test("a directory that could not be listed is named, and blocks both affirmative verdicts")
    func unreadableDirectoryIsDisclosed() async throws {
        let project = try makeProject(
            stale: ["vault/stale.yaml"],
            plaintext: ["vault/.env": "AWS_SECRET=hunter2\n"])
        let vault = project.root.appendingPathComponent("vault")
        chmod(vault, 0o000)
        defer {
            chmod(vault, 0o700)
            try? FileManager.default.removeItem(at: project.root)
        }

        let findings = await run(project.root)
        dump("unreadable directory", findings)

        let plaintext = try #require(leak(findings))
        #expect(plaintext.status != .ok,
                "\"found none\" over a directory that could not be listed: \(plaintext.detail)")
        #expect(plaintext.detail.contains("vault"))

        let recipientFinding = try #require(recipients(findings))
        #expect(recipientFinding.status != .ok,
                "\"it matches\" over a directory that could not be listed: \(recipientFinding.detail)")
        #expect(recipientFinding.detail.contains("vault"))
    }

    // MARK: - 4. Symbolic links

    /// `FileManager.enumerator` does not follow directory symlinks, and this
    /// was never stated: a `linked -> /elsewhere` holding a stale yaml and a
    /// `.env` produced `.ok` from both findings.
    ///
    /// The link is *not* followed after this fix either — following one is how
    /// a scan escapes the project, loops, or walks the whole disk. It is named.
    @Test("a symlink to a directory is named as not followed, and blocks both affirmative verdicts")
    func directorySymlinkIsDisclosed() async throws {
        let project = try makeProject()
        let outside = try ProjectFixture.makeDirectory("outside")
        try ProjectFixture.write("AWS_SECRET=hunter2\n", to: outside, at: ".env")
        try FileManager.default.createSymbolicLink(
            at: project.root.appendingPathComponent("linked"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: project.root)
            try? FileManager.default.removeItem(at: outside)
        }

        let findings = await run(project.root)
        dump("directory symlink", findings)

        let plaintext = try #require(leak(findings))
        #expect(plaintext.status != .ok,
                "\"found none\" over a symlinked directory never entered: \(plaintext.detail)")
        #expect(plaintext.detail.contains("linked"))

        let recipientFinding = try #require(recipients(findings))
        #expect(recipientFinding.status != .ok,
                "\"it matches\" over a symlinked directory never entered: \(recipientFinding.detail)")
        #expect(recipientFinding.detail.contains("linked"))
    }

    /// A symlink to a *file* is a different case and needs no disclosure: it
    /// can be read exactly like the file it points at. It was being dropped
    /// too — `URLResourceValues.isRegularFile` is `false` for a symlink,
    /// whatever it points at — so a `.env` reachable through one was invisible.
    @Test("a symlink to a file is read like the file it points at")
    func fileSymlinkIsFollowed() async throws {
        let project = try makeProject()
        let outside = try ProjectFixture.makeDirectory("outside")
        try ProjectFixture.write("AWS_SECRET=hunter2\n", to: outside, at: "real.env")
        try FileManager.default.createSymbolicLink(
            at: project.root.appendingPathComponent("linked.env"),
            withDestinationURL: outside.appendingPathComponent("real.env"))
        defer {
            try? FileManager.default.removeItem(at: project.root)
            try? FileManager.default.removeItem(at: outside)
        }

        let plaintext = try #require(leak(await run(project.root)))
        #expect(plaintext.detail.contains("linked.env"),
                "a .env reachable through a symlink is still a .env: \(plaintext.detail)")
        #expect(!plaintext.detail.contains("hunter2"))
    }

    // MARK: - 5. A project root that could not be read

    /// An unreadable root produced three separate falsehoods at once: a
    /// `[warning] No .sops.yaml in <root>` about a file that is right there, an
    /// `.ok` gitignore finding with no scope paragraph at all, and no
    /// recipients finding whatsoever. The walk's own comment admitted this;
    /// the findings did not.
    @Test("a project root that could not be read says so instead of reporting on it")
    func unreadableRootIsAdmitted() async throws {
        let project = try makeProject(plaintext: [".env": "AWS_SECRET=hunter2\n"])
        chmod(project.root, 0o000)
        defer {
            chmod(project.root, 0o755)
            try? FileManager.default.removeItem(at: project.root)
        }

        let findings = await run(project.root)
        dump("unreadable root", findings)

        #expect(findings.count == 1,
                "a root this app cannot read supports exactly one honest finding, not three guesses: \(findings.map(\.title))")
        for finding in findings {
            #expect(finding.status != .ok, "\(finding.title) claimed OK: \(finding.detail)")
            #expect(!finding.detail.contains("No .sops.yaml"),
                    "the .sops.yaml is right there; the app simply could not look: \(finding.detail)")
        }
        #expect(findings.first?.detail.contains(project.root.path) == true)
    }

    // MARK: - 6. A sops metadata block larger than the tail read

    /// `maxSniffedFileBytes`'s doc comment claimed "even a file with a few
    /// hundred recipients stays well under 64 KiB". Measured against real
    /// `SopsBridge.encryptYAML` output, the threshold is around 112 recipients.
    /// Past it the file was invisible and the check reported
    /// `.skipped("No sops-encrypted files were found under <root>.")` about a
    /// directory that demonstrably has one.
    @Test("an encrypted file whose metadata block is bigger than the tail read is not reported as absent",
          .timeLimit(.minutes(5)))
    func oversizedMetadataBlockIsNotInvisible() async throws {
        let root = try ProjectFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectFixture.gitInit(root)

        var recipientKeys: [String] = []
        for _ in 0..<200 { recipientKeys.append(try ProjectFixture.ageKeyPair().public) }
        try ProjectFixture.write("creation_rules:\n  - age: \(recipientKeys.joined(separator: ","))\n",
                                 to: root, at: ".sops.yaml")
        let body = try ProjectFixture.encrypted("db_password: hunter2\n", to: recipientKeys)
        try ProjectFixture.write(body, to: root, at: "secrets.yaml")

        let size = body.utf8.count
        print("······ 200-recipient sops file is \(size) bytes; tail read is \(ProjectScanner.maxSniffedFileBytes)")
        #expect(size > ProjectScanner.maxSniffedFileBytes,
                "test setup bug: the fixture must exceed the tail read to prove anything")

        let findings = await run(root)
        dump("oversized metadata block", findings)

        let recipientFinding = try #require(recipients(findings))
        #expect(!recipientFinding.detail.contains("hunter2"))
        if case .skipped(let reason) = recipientFinding.status {
            Issue.record("reported no encrypted files over a directory that has one: \(reason)")
        }
    }
}
