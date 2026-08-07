import Foundation
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func recipientFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("stale-recipients") }!
}

private func run(_ root: URL) async -> [HealthFinding] {
    await ProjectHealthCheck(source: Projects(
        projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
}

/// C2: the `.ok` branch of `recipientFinding` used to print
///
///   "Checked every encrypted file's recipient key list against the rule that
///    governs it — every file's key list matches."
///
/// when it had checked exactly nothing. `verifiedFileCount` existed, with a
/// comment saying a vacuous comparison "must never be counted as a file this
/// app verified" — and the `.ok` branch never read it.
///
/// Every test here asserts on what the sentence *claims*, not only on the
/// status, because the status alone was never the defect. A green tick over
/// "checked every file" is a lie whether or not `.ok` was the right symbol.
@Suite("ProjectHealthCheck recipient verdict vacuity")
struct ProjectRecipientVacuityTests {

    /// Path one: a perfectly valid age-only config and no encrypted files at
    /// all. There is nothing wrong here — but there is also nothing verified.
    @Test("a valid .sops.yaml with no encrypted files does not claim to have checked files")
    func noEncryptedFilesDoesNotClaimAVerification() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")

        let finding = recipientFinding(await run(root))

        #expect(finding.status != .ok, "no file was checked, so this must not be an affirmative OK")
        #expect(!finding.detail.contains("every file's key list matches"))
        #expect(!finding.detail.lowercased().contains("checked every"))
        // It must say plainly that it examined nothing.
        #expect(finding.detail.lowercased().contains("no ")
                || finding.detail.lowercased().contains("nothing"))
    }

    /// Path two, the sharp one: the only encrypted file is *hidden*, and it is
    /// genuinely encrypted to a key the config no longer declares. The old
    /// `.skipsHiddenFiles` made this permanently invisible while the finding
    /// reported a confident all-clear. A sops-encrypted `.env` is a completely
    /// ordinary thing to have.
    @Test("a hidden encrypted file with a stale recipient is found, not skipped")
    func hiddenEncryptedFilesAreScanned() async throws {
        let declared = try ProjectFixture.ageKeyPair()
        let departed = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(declared.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(
            try ProjectFixture.encrypted("DB_PASSWORD: hunter2\n", to: [declared.public, departed.public]),
            to: root, at: ".hidden-secrets.yaml")

        let finding = recipientFinding(await run(root))

        #expect(finding.status == .problem)
        #expect(finding.detail.contains(".hidden-secrets.yaml"))
        #expect(finding.detail.contains(departed.public))
        #expect(!finding.detail.contains("hunter2"))
    }

    /// The same thing one directory deeper, in a hidden directory.
    @Test("an encrypted file inside a hidden directory is found")
    func encryptedFilesInHiddenDirectoriesAreScanned() async throws {
        let declared = try ProjectFixture.ageKeyPair()
        let departed = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(declared.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(
            try ProjectFixture.encrypted("DB_PASSWORD: hunter2\n", to: [declared.public, departed.public]),
            to: root, at: ".config/secrets.yaml")

        let finding = recipientFinding(await run(root))

        #expect(finding.status == .problem)
        #expect(finding.detail.contains(".config/secrets.yaml"))
    }

    /// Path three: an encrypted file exists but no creation rule governs it.
    /// The old code dropped it with a bare `continue` and then reported OK.
    @Test("an encrypted file no rule matches is reported, not silently dropped")
    func unmatchedEncryptedFileIsNotDroppedSilently() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        // The rule only governs secrets/*.yaml; the file lives elsewhere.
        try ProjectFixture.write(
            "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: \(key.public)\n",
            to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("DB_PASSWORD: hunter2\n", to: [key.public]),
                                 to: root, at: "elsewhere/prod.yaml")

        let finding = recipientFinding(await run(root))

        #expect(finding.status != .ok)
        #expect(finding.detail.contains("elsewhere/prod.yaml"))
        #expect(!finding.detail.contains("every file's key list matches"))
    }

    /// The positive control. A file that really was compared, and really does
    /// match, still gets an affirmative OK — and the sentence now states how
    /// many files that verdict rests on.
    @Test("a genuinely verified file still reports OK, with a count")
    func genuinelyVerifiedFileIsStillOK() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: \(key.public)\n",
            to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("DB_PASSWORD: hunter2\n", to: [key.public]),
                                 to: root, at: "secrets/prod.yaml")

        let finding = recipientFinding(await run(root))

        #expect(finding.status == .ok)
        #expect(finding.detail.contains("1"))
        #expect(!finding.detail.contains("hunter2"))
    }

    /// Two verified files, so the count is not accidentally hardcoded.
    @Test("the count reflects the number of files actually compared")
    func countReflectsRealComparisons() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: \(key.public)\n",
            to: root, at: ".sops.yaml")
        for name in ["secrets/a.yaml", "secrets/b.yaml"] {
            try ProjectFixture.write(try ProjectFixture.encrypted("K: v\n", to: [key.public]),
                                     to: root, at: name)
        }

        let finding = recipientFinding(await run(root))

        #expect(finding.status == .ok)
        #expect(finding.detail.contains("2"))
    }

    /// `.git` is git's own storage, not the user's content. It is the one
    /// directory the scan skips, and skipping it must not cost anything the
    /// user would care about.
    @Test("the scan does not descend into .git")
    func gitInternalsAreNotScanned() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("K: v\n", to: [key.public]),
                                 to: root, at: ".git/decoy.yaml")

        let finding = recipientFinding(await run(root))
        #expect(!finding.detail.contains("decoy.yaml"))
    }
}
