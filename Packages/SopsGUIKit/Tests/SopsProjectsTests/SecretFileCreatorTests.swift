import Foundation
import ScratchCleanup
import SopsEngine
import SopsHealth
import Testing

@testable import SopsProjects

/// Recognisable value planted in every fixture this file's tests build, so
/// `noThrownErrorEverNamesTheSentinelValue` has something concrete to look
/// for. Reused everywhere rather than each test inventing its own string, so
/// that one test's failure to plant it correctly cannot masquerade as a
/// clean result.
private let sentinelValue = "correct-horse-battery-staple"

/// `SecretFileCreator` is the type in this whole feature that actually
/// writes a secret to disk, so every negative test here proves two things,
/// not one: which `Failure` came back, *and* that nothing on disk changed —
/// see `fileTreeSnapshot`. A test that only checked the thrown case would
/// pass just as happily against an implementation that wrote the file and
/// then reported failure, which is exactly the defect this type's own doc
/// comment says there is no code path for.
@Suite("SecretFileCreator")
struct SecretFileCreatorTests {

    // MARK: - Fixture plumbing

    private func plan(
        _ recipients: [String], regex: String = "", acknowledgedUnreadable: Bool = false
    ) -> ResolvedEncryption {
        ResolvedEncryption(
            recipients: recipients, encryptedRegex: regex,
            acknowledgedUnreadable: acknowledgedUnreadable)
    }

    /// Every entry under `root`, as paths relative to it — cheap enough to
    /// take before and after a call a test expects to write nothing, so
    /// "nothing was written" is something this file actually checks rather
    /// than infers from a thrown error alone.
    private func fileTreeSnapshot(_ root: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return Set(enumerator.compactMap { $0 as? String })
    }

    /// `root` is a fresh scratch directory (registered for cleanup);
    /// `project` is an empty directory inside it that every test treats as
    /// `projectRoot`. Kept as siblings under one registered root so a test
    /// that also needs somewhere *outside* the project (`root.appendingPathComponent("outside")`)
    /// gets it cleaned up along with everything else.
    private func makeProject() throws -> (root: URL, project: URL) {
        let root = try applierScratchDirectory("secret-file-creator")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project)
    }

    // MARK: - Positive: every source round-trips

    @Test("an empty document creates a file decryptToRows can read back")
    func emptySourceCreatesReadableFile() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let receipt = try SecretFileCreator.create(
            .empty, plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        #expect(receipt.destination.path == destination.path)
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.isEmpty)
    }

    @Test("pasted YAML creates a file decryptToRows can read back")
    func verbatimYAMLSourceCreatesReadableFile() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        // sops re-emits with four-space indent, so the fixture is already in
        // that shape — same reason `applierPlainYAML` is, and why this test
        // reads back through `decryptToRows` rather than comparing text.
        let yaml = "database:\n    password: \(sentinelValue)\n"
        _ = try SecretFileCreator.create(
            .verbatimYAML(yaml), plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(!rows.isEmpty)
        #expect(rows.first { $0.path == ["database", "password"] }?.value == sentinelValue)
    }

    /// Human ruling on the plan's Task 6 review: a legitimately empty
    /// `.verbatimYAML` document must be created, not reported as
    /// `roundTripMismatch`. A user pasting `{}` means to create the file and
    /// fill it in afterward — the same intent `.empty` already serves
    /// deliberately — and the engine agrees: an empty document has nothing
    /// to encrypt, which is not a broken rule (`Engine/gobridge/bridge.go
    /// :332-333`). A comments-only template is a different case entirely —
    /// see the comment just below this test for the measurement showing why
    /// it does not reach this check at all.
    /// Ticket #10, claim 4: `.verbatimYAML`'s round trip only ever checked
    /// that `decryptToRows` succeeded, never anything about the row *count*
    /// — deliberately, because `{}` and blank documents are legitimate (see
    /// `verbatimYAMLEmptyDocumentIsCreated` just below). But that meant real
    /// content coming back as *zero* rows — total data loss on the one source
    /// with no Swift-side emitter standing between the user's paste and the
    /// bridge — was indistinguishable from a deliberately empty document.
    /// This is not a full count comparison (that would need parsing the
    /// user's YAML on the Swift side, which ADR 0002 forbids) — it is the one
    /// shape of loss cheap to catch without parsing: non-trivial text that
    /// comes back with nothing in it at all. This test cannot occur through
    /// the real bridge (a real encrypt/decrypt round trip of non-empty YAML
    /// does not lose everything), so it drives `verifyRoundTrip` directly
    /// with a hand-built "rows came back empty" result — the shape a genuine
    /// engine regression would take.
    @Test("non-trivial pasted YAML that comes back with zero rows is caught, not created")
    func verbatimYAMLThatLosesAllContentIsCaught() throws {
        #expect(throws: SecretFileCreator.Failure.roundTripMismatch) {
            try SecretFileCreator.verifyRoundTrip(.verbatimYAML("database:\n    password: hunter2\n"), rows: [])
        }
    }

    @Test("pasted YAML that is legitimately empty is created, not reported as corrupted")
    func verbatimYAMLEmptyDocumentIsCreated() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let receipt = try SecretFileCreator.create(
            .verbatimYAML("{}\n"), plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        #expect(receipt.destination.path == destination.path)
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.isEmpty)
    }

    // A comments-only variant (`"# TODO: fill this in\n"`) was tried as a
    // second case for the ruling above and measured to fail earlier and for
    // an unrelated reason: the bridge's own YAML loader rejects a document
    // with no actual node in it — `.engine("the document is not valid
    // YAML")` — before this type's round-trip logic is ever reached. That
    // is a pre-existing constraint of `SopsBridge.encryptYAML` (and, one
    // level down, the underlying store's `LoadPlainFile`), not something
    // this fix touches or should paper over, so it is not asserted here.
    // `{}\n` above is the actually-empty document this ruling is about.

    @Test("a parsed .env creates a file decryptToRows can read back, entry for entry")
    func dotEnvSourceCreatesReadableFile() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let entries = [
            DotEnvEntry(key: "DATABASE_PASSWORD", value: sentinelValue, line: 1),
            DotEnvEntry(key: "API_KEY", value: "sk-abc123", line: 2),
        ]
        _ = try SecretFileCreator.create(
            .dotEnv(entries), plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.count == entries.count)
        for entry in entries {
            #expect(rows.first { $0.path == [entry.key] }?.value == entry.value, "key \(entry.key)")
        }
    }

    @Test("a target under a not-yet-existing directory creates it, mode 0700")
    func missingIntermediateDirectoryIsCreated() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secrets/prod.yaml")
        let directory = destination.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        _ = try SecretFileCreator.create(
            .empty, plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("the created file's mode is 0600")
    func createdFileModeIs0600() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        _ = try SecretFileCreator.create(
            .empty, plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    // MARK: - Negative: every refusal leaves nothing on disk

    @Test("an existing destination is refused, and it is left exactly as it was")
    func existingDestinationIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")
        try "not sops".write(to: destination, atomically: true, encoding: .utf8)

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationExists(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "not sops")
    }

    /// A regular file sitting where an intermediate directory needs to be —
    /// `project/secrets` exists as a plain file, `destination` is
    /// `project/secrets/prod.yaml`. Step 2's `lstat` on the *full*
    /// destination path returns `ENOTDIR` (not `0`), so `refuseIfPresent`
    /// does not fire, and everything through step 6 succeeds — this is
    /// exactly the shape that used to escape `Failure` entirely and throw a
    /// raw `NSCocoaErrorDomain` error straight out of `create` before step 7
    /// gained its own case.
    @Test("a regular file in the way of an intermediate directory is refused as a typed Failure")
    func regularFileBlockingIntermediateDirectoryIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let blocking = project.appendingPathComponent("secrets")
        try "not a directory".write(to: blocking, atomically: true, encoding: .utf8)
        let destination = blocking.appendingPathComponent("prod.yaml")

        let before = fileTreeSnapshot(root)
        let result = Result(catching: {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        })
        guard case .failure(let error) = result,
            case SecretFileCreator.Failure.couldNotCreateDirectory(let path, let reason) = error
        else {
            Issue.record("expected .couldNotCreateDirectory, got \(result)")
            return
        }
        #expect(path == blocking.path)
        #expect(!reason.isEmpty)
        #expect(fileTreeSnapshot(root) == before)
        #expect(try String(contentsOf: blocking, encoding: .utf8) == "not a directory")
    }

    @Test("a destination reached through .. is refused as outside the project")
    func dotDotEscapeIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("../mimo.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mimo.yaml").path))
    }

    @Test("an absolute destination outside the project root is refused")
    func absoluteOutsideDestinationIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let destination = outside.appendingPathComponent("mimo.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
    }

    /// The case this type's own doc comment names as the one most likely to
    /// be implemented wrong: a *real* symlinked directory inside the
    /// project, pointing at a real directory outside it, with the file
    /// itself not existing yet — the shape a naive
    /// `resolvingSymlinksInPath()`-based check misses, because that call
    /// needs the *entire* path to exist before it resolves anything at all.
    @Test("a symlinked directory that leads out of the project is refused, not followed")
    func symlinkEscapeIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let escapeLink = project.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let destination = escapeLink.appendingPathComponent("secret.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.yaml").path))
    }

    /// Same escape, with a second missing directory level below the
    /// symlink — the shape that would slip past a containment check built
    /// on `CanonicalPath.ofLeaf` alone (which only resolves *one* missing
    /// leaf, not an arbitrary number of missing levels below an existing
    /// symlinked ancestor).
    @Test("two missing levels below a symlinked directory are still refused")
    func symlinkEscapeThroughTwoMissingLevelsIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let escapeLink = project.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let destination = escapeLink.appendingPathComponent("nested/secret.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
    }

    /// The escape a lexical `..` collapse misses: `link -> outside` is a
    /// *real* symlink, and `destination` walks through it and then back out
    /// with `..`. `URL.standardizedFileURL` cancels `link/..` textually —
    /// without knowing `link` is a symlink — and reports a path back inside
    /// the project; the real filesystem resolves `link` to `outside` first
    /// and only then applies `..`, landing at `root/inside.yaml`, a sibling
    /// of `project`, not inside it. Measured directly (see this type's doc
    /// comment, "Why `..` is refused rather than resolved") before this test
    /// was written: the containment check approved the write while
    /// `open(2)`/`renamex_np` on the identical raw path landed outside.
    ///
    /// The escaped file would land at `root/inside.yaml`, not under
    /// `outside/` — so the snapshot has to be `fileTreeSnapshot(root)`,
    /// which already covers that.
    @Test("a .. component that crosses a symlink is refused, not resolved")
    func dotDotThroughASymlinkIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let link = project.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let destination = link.appendingPathComponent("../inside.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inside.yaml").path))
    }

    /// A `projectRoot` that is not there yet makes "inside `projectRoot`" an
    /// unprovable claim — without this guard, both sides of the containment
    /// check reduce to unresolved literal strings sharing a prefix, so the
    /// check passes vacuously and step 7's `createDirectory(withIntermediateDirectories:
    /// true)` would go on to create the "project" itself as a side effect of
    /// creating the file inside it.
    @Test("a project root that does not exist is refused, and nothing is created")
    func missingProjectRootIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("secret-file-creator")
        let ghostProject = root.appendingPathComponent("ghost")
        let destination = ghostProject.appendingPathComponent("a/b/secret.yaml")
        #expect(!FileManager.default.fileExists(atPath: ghostProject.path))

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.destinationOutsideProject(path: destination.path)) {
            try SecretFileCreator.create(
                .empty, plan: plan([owner.public]), at: destination, in: ghostProject,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
        #expect(!FileManager.default.fileExists(atPath: ghostProject.path))
    }

    /// Until `FlatYAMLEmitter.quotedValue` learned to escape `U+0085` (NEL),
    /// a `.dotEnv` value containing it reached this exact route: the
    /// reviewer's first-suggested way to trigger `roundTripMismatch`
    /// (`DotEnvParser` bypassed to hand `emit` two entries sharing one key)
    /// was tried and measured, not assumed, and does not reach the check at
    /// all — sops's own YAML loader rejects a document with a literal
    /// duplicate mapping key outright, `.engine("the document is not valid
    /// YAML (line 2)")`, before `decryptToRows` is ever called. A second
    /// route (a `.dotEnv` key literally named `sops`, colliding with the
    /// metadata block sops itself adds) was also tried and is separately
    /// guarded — `.engine("file already encrypted: it has a top-level
    /// \"sops\" entry")`. NEL was the one value shape that survived
    /// `quotedValue` unescaped and came back different from what was
    /// written, which is what made it reachable through the public `create`
    /// API rather than only through a synthetic call to a private function.
    ///
    /// Now that the escape table covers `U+0085`, this test proves the fix
    /// end to end — through `DotEnvParser`'s shape of input, `emit`,
    /// `encryptYAML` and `decryptToRows`, not just `FlatYAMLEmitter` in
    /// isolation (`FlatYAMLEmitterTests.lineBreakLookalikesSurviveRoundTrip`
    /// covers the emitter directly) — and stands as the regression guard for
    /// this specific route: if the escape table ever regressed, `create`
    /// would start throwing `roundTripMismatch` for a legitimate `.dotEnv`
    /// value again, and this test would catch it here, at the API boundary
    /// a real caller uses.
    @Test("a value containing U+0085 (NEL) round-trips intact and the file is created")
    func dotEnvNELValueRoundTripsAndIsCreated() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let entries = [DotEnvEntry(key: "KEY", value: "before\u{0085}after", line: 1)]

        let receipt = try SecretFileCreator.create(
            .dotEnv(entries), plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        #expect(receipt.destination.path == destination.path)
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.count == entries.count)
        #expect(rows.first { $0.path == ["KEY"] }?.value == entries[0].value)
    }

    @Test("a recipient set without this session's identity is refused by default")
    func unreadableSetIsRefusedByDefault() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let before = fileTreeSnapshot(root)
        #expect(throws: SecretFileCreator.Failure.wouldBeUnreadable) {
            try SecretFileCreator.create(
                .empty, plan: plan([stranger.public]), at: destination, in: project,
                sessionKey: owner.private)
        }
        #expect(fileTreeSnapshot(root) == before)
    }

    @Test("an acknowledged-unreadable set is created anyway, with the round trip skipped")
    func acknowledgedUnreadableSetIsCreated() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let receipt = try SecretFileCreator.create(
            .empty,
            plan: plan([stranger.public], acknowledgedUnreadable: true),
            at: destination, in: project, sessionKey: owner.private)

        #expect(receipt.destination.path == destination.path)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        // Written for the recipient it was actually encrypted for, proving
        // the write went through rather than being silently skipped too.
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        #expect(try SopsBridge.recipients(in: encrypted) == [stranger.public])
    }

    /// Ticket #10, claim 3: `create()` must record, durably, that this file
    /// was written with no content verification — see
    /// `AcknowledgedUnreadableMarker`'s own doc comment for the mechanism and
    /// why it is an extended attribute rather than a project-level registry.
    @Test("a file created via acknowledgedUnreadable is marked on disk")
    func acknowledgedUnreadableFileIsMarked() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let receipt = try SecretFileCreator.create(
            .empty,
            plan: plan([stranger.public], acknowledgedUnreadable: true),
            at: destination, in: project, sessionKey: owner.private)

        #expect(AcknowledgedUnreadableMarker.isMarked(receipt.destination))
    }

    /// The converse: a normal creation — this session's own key among the
    /// recipients, round trip verified — must not be marked. The marker
    /// means "written unverified", never "created via this code path".
    @Test("an ordinary creation is not marked")
    func ordinaryCreationIsNotMarked() throws {
        let owner = try AgeKeyPair.generate()
        let (_, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let receipt = try SecretFileCreator.create(
            .empty, plan: plan([owner.public]), at: destination, in: project,
            sessionKey: owner.private)

        #expect(!AcknowledgedUnreadableMarker.isMarked(receipt.destination))
    }

    // MARK: - Distinguishing "not a recipient" from a genuine engine fault (ticket #10, claim 2)

    /// `acknowledgedUnreadable` trades away content verification for a
    /// recipient set that legitimately excludes this session — it was never
    /// meant to paper over an actual bridge bug. An empty `sessionKey` fails
    /// for a completely different reason than "wrong identity"
    /// (`parseDecryptionIdentities` refuses before any decrypt is even
    /// attempted — see `Engine/gobridge/bridge.go`), so `SopsBridgeError.kind`
    /// is `nil` here, not `.noMatchingIdentity`, and this must surface as
    /// `.engine`, never be silently absorbed into `.wouldBeUnreadable`'s
    /// "write anyway" branch.
    @Test("acknowledgedUnreadable does not swallow a genuine engine fault as wouldBeUnreadable")
    func acknowledgedUnreadableSurfacesGenuineEngineFaults() throws {
        let stranger = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let before = fileTreeSnapshot(root)
        let result = Result(catching: {
            try SecretFileCreator.create(
                .empty, plan: plan([stranger.public], acknowledgedUnreadable: true),
                at: destination, in: project, sessionKey: "")
        })
        guard case .failure(let error) = result, case SecretFileCreator.Failure.engine = error else {
            Issue.record("expected .engine for an invalid session key even with acknowledgedUnreadable, got \(result)")
            return
        }
        // Nothing was written for a failure this type cannot yet class as
        // "this session cannot read it" — same "no delete-on-failure path"
        // discipline every other refusal in this suite proves.
        #expect(fileTreeSnapshot(root) == before)
    }

    @Test("an age plugin recipient is refused by the bridge, propagated as .engine")
    func pluginRecipientIsRefused() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        // Shaped like a real age plugin recipient (`age1<name>1<data>`) —
        // this app supports native age recipients only and never runs a
        // plugin binary; `Engine/gobridge/bridge.go:239-247` refuses it.
        // Only that refusal is asserted here, never a home-grown message.
        let before = fileTreeSnapshot(root)
        let result = Result(catching: {
            try SecretFileCreator.create(
                .empty, plan: plan(["age1se1qqrz9pksmumhdwx0v0pmn8vzp"]), at: destination,
                in: project, sessionKey: owner.private)
        })
        guard case .failure(let error) = result, case SecretFileCreator.Failure.engine = error else {
            Issue.record("expected .engine, got \(result)")
            return
        }
        #expect(fileTreeSnapshot(root) == before)
    }

    @Test("a recipient not starting with age1 is refused, and the error never names it")
    func nonAgeRecipientIsRefusedWithoutLeakingIt() throws {
        let owner = try AgeKeyPair.generate()
        let (root, project) = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        // The realistic version of this mistake: a private key pasted into
        // the recipients field instead of a public one.
        let pastedPrivateKey = owner.private

        let before = fileTreeSnapshot(root)
        let result = Result(catching: {
            try SecretFileCreator.create(
                .empty, plan: plan([pastedPrivateKey]), at: destination, in: project,
                sessionKey: owner.private)
        })
        guard case .failure(let error) = result, case SecretFileCreator.Failure.engine(let message) = error
        else {
            Issue.record("expected .engine, got \(result)")
            return
        }
        #expect(!message.contains(pastedPrivateKey))
        #expect(fileTreeSnapshot(root) == before)
    }

    // MARK: - No thrown error ever names a secret value

    @Test("no thrown Failure's description ever names the sentinel value")
    func noThrownErrorEverNamesTheSentinelValue() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let (_, project) = try makeProject()

        let yaml = "database:\n    password: \(sentinelValue)\n"
        let entries = [DotEnvEntry(key: "SECRET", value: sentinelValue, line: 1)]

        var descriptions: [String] = []
        func attempt(_ body: () throws -> AtomicWriteReceipt) {
            do {
                _ = try body()
                Issue.record("expected this attempt to fail")
            } catch {
                descriptions.append(String(describing: error))
            }
        }

        // Existing destination — plaintext never even gets built.
        let existing = project.appendingPathComponent("existing.yaml")
        try yaml.write(to: existing, atomically: true, encoding: .utf8)
        attempt {
            try SecretFileCreator.create(
                .verbatimYAML(yaml), plan: plan([owner.public]), at: existing, in: project,
                sessionKey: owner.private)
        }

        // Outside the project.
        attempt {
            try SecretFileCreator.create(
                .verbatimYAML(yaml), plan: plan([owner.public]),
                at: project.appendingPathComponent("../mimo.yaml"), in: project,
                sessionKey: owner.private)
        }

        // Unreadable by this session — the sentinel reaches `encryptYAML`
        // but the refusal itself carries no content.
        attempt {
            try SecretFileCreator.create(
                .dotEnv(entries), plan: plan([stranger.public]),
                at: project.appendingPathComponent("unreadable.yaml"), in: project,
                sessionKey: owner.private)
        }

        // A pasted private key as a recipient — the sentinel reaches
        // `encryptYAML` too, and the bridge's own refusal names an index,
        // never the recipient or the plaintext.
        attempt {
            try SecretFileCreator.create(
                .dotEnv(entries), plan: plan([owner.private]),
                at: project.appendingPathComponent("bad-recipient.yaml"), in: project,
                sessionKey: owner.private)
        }

        #expect(descriptions.count == 4)
        for description in descriptions {
            #expect(!description.contains(sentinelValue), "leaked in: \(description)")
        }
    }

    // MARK: - Structural verification without a readable identity (ticket #10, claim 1)
    //
    // `acknowledgedUnreadable` skips the round trip entirely — there is no
    // identity in hand to decrypt the result and compare. But sops's own
    // recipient metadata is public and readable without any identity
    // (`SopsBridge.recipients(in:)`), so it is the one structural fact this
    // call can still check even when nothing can be decrypted:
    // `verifyRecipientsStructurally` catches the class of bug the round trip
    // exists for — the file just produced does not actually declare the
    // recipients this call meant to encrypt for — for exactly the one path
    // where nothing else checks anything at all.

    @Test("matching recipients pass structural verification")
    func matchingRecipientsPassStructuralVerification() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML("{}\n", recipients: [owner.public, stranger.public])

        // Must not throw.
        try SecretFileCreator.verifyRecipientsStructurally(
            encrypted, expected: [owner.public, stranger.public])
    }

    @Test("a recipient set that does not match what was actually written is caught")
    func mismatchedRecipientsAreCaught() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        // Encrypted for `owner` only, but this call claims it was meant for
        // both — the shape a bridge bug producing the wrong recipient set
        // would take.
        let encrypted = try SopsBridge.encryptYAML("{}\n", recipients: [owner.public])

        #expect(throws: SecretFileCreator.Failure.recipientsMismatch) {
            try SecretFileCreator.verifyRecipientsStructurally(
                encrypted, expected: [owner.public, stranger.public])
        }
    }

    // MARK: - Step 7's directory does not survive a step 8 failure (#19 item 4)

    /// Both halves of the property in one test, run strictly one after the
    /// other: `afterDirectoryCreatedHookForTesting` is process-wide mutable
    /// state (`swift test` parallelizes within a suite, not just across
    /// suites — measured directly against an earlier, two-test version of
    /// this: with each half in its own `@Test`, one intermittently observed
    /// the *other's* directory-scoped hook closure clobbering its own in the
    /// window between being set and firing, which sometimes let a write
    /// intended to fail land untouched instead). A single test has no such
    /// window against itself, and nothing else in this suite touches this
    /// particular hook.
    ///
    /// **Empty case:** a losing `RENAME_EXCL` race — or, as forced here,
    /// `AtomicFileWriter` refusing for a different reason — used to leave
    /// the intermediate directory step 7 created sitting on disk forever,
    /// empty, with the secrets file itself still never having existed.
    /// Forced deterministically: the hook fires right after step 7 succeeds
    /// and strips write permission from the directory it just created, so
    /// `AtomicFileWriter`'s own temp-file staging (`open(O_CREAT|O_EXCL)`,
    /// which needs write on its containing directory) fails before anything
    /// is ever placed inside it.
    ///
    /// **Non-empty case**, and the reason cleanup checks "is it empty"
    /// rather than "did I create it": a directory a second writer has since
    /// put a real file into must never be removed just because *this* call's
    /// own write failed. Simulated by having the hook plant an unrelated
    /// file in the directory before also revoking write permission — from
    /// this call's point of view indistinguishable from a race it lost after
    /// already creating the directory.
    @Test("step 7's directory survives exactly when something real is in it, never otherwise")
    func directoryFromFailedWriteSurvivesOnlyWhenNonEmpty() throws {
        let owner = try AgeKeyPair.generate()

        // Empty case.
        do {
            let (_, project) = try makeProject()
            let nested = project.appendingPathComponent("a", isDirectory: true)
                .appendingPathComponent("b", isDirectory: true)
            let destination = nested.appendingPathComponent("secret.yaml")

            SecretFileCreator.afterDirectoryCreatedHookForTesting = { directory in
                // Every other test in this suite also calls `create(...)`
                // concurrently and would otherwise trip this same hook with
                // its own, unrelated directory — see this test's own doc
                // comment.
                guard directory == nested else { return }
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
            defer {
                SecretFileCreator.afterDirectoryCreatedHookForTesting = nil
                // In case an assertion above fails first and leaves it locked.
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
            }

            #expect(throws: (any Error).self) {
                try SecretFileCreator.create(
                    .empty, plan: plan([owner.public]), at: destination, in: project,
                    sessionKey: owner.private)
            }

            #expect(
                !FileManager.default.fileExists(atPath: nested.path),
                "the leaf directory this call created should not have survived the failed write")
            #expect(
                !FileManager.default.fileExists(atPath: project.appendingPathComponent("a").path),
                "the intermediate directory this call created should not have survived either")
        }

        // Non-empty case.
        do {
            let (_, project) = try makeProject()
            let directory = project.appendingPathComponent("secrets", isDirectory: true)
            let destination = directory.appendingPathComponent("secret.yaml")

            SecretFileCreator.afterDirectoryCreatedHookForTesting = { hookDirectory in
                guard hookDirectory == directory else { return }
                // A "second writer" landed something real in here first —
                // before write permission is revoked, or this write itself
                // could not have placed it either.
                try? Data("someone else's file".utf8).write(
                    to: hookDirectory.appendingPathComponent("other.yaml"))
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hookDirectory.path)
            }
            defer {
                SecretFileCreator.afterDirectoryCreatedHookForTesting = nil
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }

            #expect(throws: (any Error).self) {
                try SecretFileCreator.create(
                    .empty, plan: plan([owner.public]), at: destination, in: project,
                    sessionKey: owner.private)
            }

            #expect(
                FileManager.default.fileExists(atPath: directory.path),
                "a directory holding another writer's file must survive")
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #expect(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.yaml").path),
                "the other writer's file must still be there")
        }
    }
}
