import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// `ScanLimitation`'s type-level comment admits, in the abstract, that a walk
/// can still fall short in a way that records nothing — "the enum cannot see a
/// statement that never mentions it". This is that gap, in the concrete, and it
/// is the same `fileExists` defect that was fixed for the project root in the
/// same commit and left unchanged a hundred lines below it in the same
/// function: `fileExists` cannot tell "the target is not there" from "I am not
/// allowed to look at the target", and the walk treats both as a broken link
/// with nothing behind it.
@Suite("A symlink this scan could not resolve is a limitation, not an absence")
struct SymlinkLimitationTests {

    private func sopsLikeYAML() -> String {
        """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """
    }

    /// The control: a symlink to a *readable* file outside the root is followed
    /// and counted. Without this the test below could pass simply because
    /// symlinked files are out of scope entirely, which they are not.
    @Test("a symlink to a readable encrypted file is in scope")
    func readableSymlinkTargetIsScanned() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-ok-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(outside)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let target = outside.appendingPathComponent("secrets.yaml")
        try sopsLikeYAML().write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.yaml"), withDestinationURL: target)

        let scanned = await ProjectScanner.scan(root: root)
        #expect(scanned.encrypted.count == 1, "symlinked files are in scope, so the probe below is meaningful")
    }

    /// The defect. The target is deliberately *outside* the root, so the
    /// enumerator never walks the locked directory itself and cannot record the
    /// limitation by some other route — the only chance to notice is the
    /// symlink probe.
    @Test("a symlink whose target cannot be read is recorded, not silently dropped")
    func unreadableSymlinkTargetIsALimitation() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-locked-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        let vault = sandbox.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(vault)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path)
            try? FileManager.default.removeItem(at: sandbox)
        }

        let target = vault.appendingPathComponent("secrets.yaml")
        try sopsLikeYAML().write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.yaml"), withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)

        try #require(!FileManager.default.fileExists(atPath: target.path),
                     "the lock denied nothing — running as root would make this test vacuous")

        let scanned = await ProjectScanner.scan(root: root)

        #expect(scanned.encrypted.isEmpty, "precondition: the scan cannot reach the file")
        #expect(scanned.incompleteScanReason != nil,
                "the scan silently dropped a link it could not resolve, so the file list is free to say the project holds no encrypted files")
    }

    /// A symlink cycle and a link whose path runs through a plain file are
    /// stale links in exactly the same sense as a dangling one — nothing is
    /// behind them, nothing is being denied — but neither reports `ENOENT`.
    /// Recording a limitation for them put the warning banner permanently on
    /// any project carrying one.
    @Test("a stale link that is not ENOENT is still not a limitation", arguments: ["loop", "through-a-file"])
    func staleLinksAreNotLimitations(_ shape: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-stale-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: root) }

        switch shape {
        case "loop":
            // Mutually referential links: resolving either yields ELOOP.
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("a"), withDestinationURL: root.appendingPathComponent("b"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("b"), withDestinationURL: root.appendingPathComponent("a"))
        default:
            let plain = root.appendingPathComponent("plain.txt")
            try "not a directory".write(to: plain, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("through"),
                withDestinationURL: plain.appendingPathComponent("child"))
        }

        let scanned = await ProjectScanner.scan(root: root)
        #expect(scanned.incompleteScanReason == nil,
                "a stale symlink (\(shape)) was reported as content this scan could not read")
    }

    /// A genuinely broken link — the target really is gone — is an absence, not
    /// a limitation. Without this, the fix could be "always record something",
    /// which would put a warning banner on every project carrying a stale
    /// symlink and make the banner meaningless.
    @Test("a link whose target really is gone is not a limitation")
    func danglingSymlinkIsNotALimitation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-dangling-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("gone.yaml"),
            withDestinationURL: root.appendingPathComponent("no-such-file.yaml"))

        let scanned = await ProjectScanner.scan(root: root)
        #expect(scanned.incompleteScanReason == nil,
                "a stale symlink was reported as a gap in the scan")
    }
}
