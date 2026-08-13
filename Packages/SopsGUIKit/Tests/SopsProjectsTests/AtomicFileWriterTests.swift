import Foundation
import ScratchCleanup
import Testing

@testable import SopsProjects

/// The five properties `AtomicFileWriter` exists to hold.
///
/// Every test builds its own throwaway directory under
/// `FileManager.temporaryDirectory` and touches nothing else — no
/// `UserDefaults`, no real project, no shared fixture between tests, because
/// Swift Testing runs these in parallel.
@Suite("AtomicFileWriter")
struct AtomicFileWriterTests {

    // MARK: - Scaffolding

    /// A fresh, empty directory nothing else in the suite can see.
    private func makeScratchDirectory(
        _ label: String = "atomicwriter", function: String = #function
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(url)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// `st_dev` of `url`, via `lstat` so a symlink reports its own device
    /// rather than its target's.
    private func deviceID(of url: URL) -> dev_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_dev
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: - 1. Atomicity

    /// A reader hammering the file while it is replaced must only ever see a
    /// *whole* version of it — the old one or the new one. Never a truncated
    /// file, never a missing one, never a mix of both payloads.
    ///
    /// Deliberately sized (1 MB) and deliberately repeated: a non-atomic
    /// implementation's window is one `open(O_TRUNC)`-to-last-`write` span,
    /// which is microseconds for a small payload and easy to miss once.
    ///
    /// ## Why the reader `stat`s and `pread`s instead of reading the file
    ///
    /// The first version of this test read the whole file with
    /// `Data(contentsOf:)` every sample — and **passed against a deliberately
    /// non-atomic writer**, which is the worst thing a test like this can do.
    /// Measured: a 4 MB `Data(contentsOf:)` costs ~28 ms, so across the entire
    /// 0.39 s write loop the reader managed **14 samples** and never once
    /// landed inside the truncation window.
    ///
    /// `fstat` for the size plus three one-byte `pread`s costs microseconds.
    /// Same loop, same writer: ~8,000 samples, and the non-atomic mutation is
    /// caught 9–11 times per run while the real writer produces zero. That gap
    /// is what makes this a test rather than a ritual.
    ///
    /// ## Why only 1 MB × 6
    ///
    /// It was 4 MB × 20 first, which is ~320 MB of writes and 40 `F_FULLFSYNC`
    /// calls. `swift test` runs every suite in one process in parallel, and
    /// that much drive-cache flushing measurably slowed the wall-clock
    /// assertions in `ProjectHealthCheckLargeFileTests` — those already sit
    /// close to their ceiling on this machine, and this pushed them from ~3.8 s
    /// to ~5.6 s against a 3 s limit. This size keeps the discrimination
    /// (9–11 catches, measured over three runs) at a fifteenth of the I/O.
    /// A test that makes its neighbours flaky is a cost the suite pays forever.
    @Test("the file is replaced atomically — no partial content is ever observable")
    func replacedAtomically() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")

        let size = 1_000_000
        let oldPayload = Data(repeating: UInt8(ascii: "A"), count: size)
        let newPayload = Data(repeating: UInt8(ascii: "B"), count: size)
        try oldPayload.write(to: destination)

        let observations = Observations()
        let path = destination.path
        let reader = Thread {
            while !observations.shouldStop {
                observations.record(Self.sample(path, expectedSize: size))
            }
        }
        reader.qualityOfService = .userInitiated
        reader.start()
        // Let the reader actually get going before the first replace.
        Thread.sleep(forTimeInterval: 0.05)

        for _ in 0..<6 {
            try AtomicFileWriter.write(newPayload, to: destination)
            try AtomicFileWriter.write(oldPayload, to: destination)
        }

        observations.stop()
        Thread.sleep(forTimeInterval: 0.1)

        let seen = observations.snapshot()
        #expect(!seen.contains(.absent), "the file vanished mid-replace")
        #expect(!seen.contains(.partial), "a reader saw a truncated file")
        #expect(!seen.contains(.torn), "a reader saw a mix of the old and new payloads")
        // The reader has to have actually been looking — and often enough to
        // have had a real chance at the window — or the three assertions above
        // pass for free. The measured rate is ~8,000 samples for this loop;
        // 1,000 is a floor a machine under heavy load still clears, while
        // still failing a reader that has effectively stopped (the 14-sample
        // version this test started as would not come close).
        #expect(seen.contains(.wholeNew), "the reader never observed the new contents at all")
        #expect(
            observations.sampleCount > 1_000,
            "only \(observations.sampleCount) samples — too few to have exercised the window")
    }

    /// One cheap look at the file: is it the whole old payload, the whole new
    /// one, or something no reader should ever be able to see?
    ///
    /// First, middle and last byte rather than just the ends, so a writer that
    /// managed to get both edges right while the interior was still being
    /// filled in is still caught as `.torn`.
    private static func sample(_ path: String, expectedSize: Int) -> Observation {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return .absent }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .absent }
        guard Int(info.st_size) == expectedSize else { return .partial }

        var bytes: [UInt8] = [0, 0, 0]
        let offsets = [0, expectedSize / 2, expectedSize - 1]
        for (index, offset) in offsets.enumerated() {
            guard pread(descriptor, &bytes[index], 1, off_t(offset)) == 1 else { return .partial }
        }
        guard bytes[0] == bytes[1], bytes[1] == bytes[2] else { return .torn }
        return bytes[0] == UInt8(ascii: "A") ? .wholeOld : .wholeNew
    }

    private enum Observation: Hashable {
        case absent, partial, torn, wholeOld, wholeNew
    }

    /// The reader thread's shared state. A class with a lock rather than an
    /// actor because the reader is a real `Thread` in a tight synchronous
    /// loop — the point is to sample the file as fast as possible, and an
    /// `await` per sample would widen the sampling interval far past the
    /// window this test is trying to catch.
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<Observation> = []
        private var count = 0
        private var stopped = false

        var shouldStop: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
        var sampleCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func record(_ observation: Observation) {
            lock.lock(); defer { lock.unlock() }
            seen.insert(observation)
            count += 1
        }
        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
        }
        func snapshot() -> Set<Observation> {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
    }

    // MARK: - 2. Permissions

    /// A secrets file the user chmodded to 0600 must still be 0600 afterwards,
    /// and one left at the group-readable 0640 a shared checkout might use
    /// must not be silently tightened either. Both directions matter: this is
    /// the user's access-control decision, and a writer that overwrites it
    /// with its own default has made that decision for them.
    @Test("the original file's POSIX permissions are preserved")
    func permissionsPreserved() throws {
        let directory = try makeScratchDirectory()

        for originalMode in [0o600, 0o640, 0o644, 0o660] {
            let destination = directory
                .appendingPathComponent("secrets-\(String(originalMode, radix: 8)).yaml")
            try Data("before".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: originalMode], ofItemAtPath: destination.path)

            try AtomicFileWriter.write(Data("after".utf8), to: destination)

            let resulting = try mode(of: destination)
            #expect(
                resulting == originalMode,
                "mode \(String(originalMode, radix: 8)) became \(String(resulting, radix: 8))")
            #expect(try Data(contentsOf: destination) == Data("after".utf8))
        }
    }

    /// A file that does not exist yet has no mode to preserve, so the writer
    /// picks the conservative one rather than whatever the process umask
    /// happens to allow. Pinned because "0644 by default" for a file this app
    /// only ever writes secrets into would be a silent widening.
    @Test("a file that did not exist is created owner-only")
    func newFileIsOwnerOnly() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("brand-new.yaml")

        try AtomicFileWriter.write(Data("fresh".utf8), to: destination)

        #expect(try mode(of: destination) == 0o600)
        #expect(try Data(contentsOf: destination) == Data("fresh".utf8))
    }

    /// A read-only file is refused, by name, with nothing staged and nothing
    /// changed — and *not* chmodded out of the way.
    ///
    /// Found while writing the permissions test above: `replaceItemAt` will
    /// not replace a destination its owner cannot write (mode `0444` →
    /// `NSCocoaErrorDomain` 513), even though the bare `rename(2)` underneath
    /// it only needs the containing directory and succeeds happily. So this
    /// is a real limit of the chosen mechanism, and the writer states it
    /// rather than letting Foundation's message — which blames the *folder* —
    /// send the user to look at the wrong permission bits.
    @Test("a read-only file is refused by name, not chmodded out of the way")
    func readOnlyDestinationIsRefused() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("locked.yaml")
        let original = Data("do not touch\n".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)

        var captured: (any Error)?
        #expect(throws: (any Error).self) {
            do { try AtomicFileWriter.write(Data("nope".utf8), to: destination) }
            catch { captured = error; throw error }
        }

        #expect(AtomicFileWriter.Error.destinationNotWritable(path: destination.path)
            == captured as? AtomicFileWriter.Error)
        #expect(try Data(contentsOf: destination) == original)
        let unchangedMode = try mode(of: destination)
        #expect(unchangedMode == 0o444, "the writer changed the file's permissions to get past them")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["locked.yaml"], "something was staged before the refusal: \(leftovers)")
    }

    // MARK: - 3. Symlinks

    /// Writing to a path that is a symlink must update the file it points at
    /// and leave the link a link.
    ///
    /// This is not hypothetical: a repository whose `secrets.yaml` is a
    /// symlink into a shared config directory is a normal layout, and so is a
    /// project reached through a symlinked home (iCloud Desktop/Documents) or
    /// a symlinked dev volume — the same two cases `ProjectStore.normalize`
    /// exists for. Replacing the link with a regular file would silently
    /// detach the file from everything else that points at it, and the user
    /// would find out when the *other* consumer of that path kept reading the
    /// stale contents.
    @Test("a symlinked path writes through to the target, not over the link")
    func symlinkWritesThrough() throws {
        let directory = try makeScratchDirectory()
        let targetDirectory = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(targetDirectory)

        let target = targetDirectory.appendingPathComponent("real.yaml")
        try Data("before".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let link = directory.appendingPathComponent("secrets.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try AtomicFileWriter.write(Data("after".utf8), to: link)

        #expect(isSymbolicLink(link), "the symlink was replaced by a regular file")
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(linkDestination == target.path, "the symlink now points somewhere else")
        #expect(try Data(contentsOf: target) == Data("after".utf8), "the target was not updated")
        let targetMode = try mode(of: target)
        #expect(targetMode == 0o600, "the target's mode was not preserved")
        // And reading back through the link must agree with the target — the
        // whole point of the property.
        #expect(try Data(contentsOf: link) == Data("after".utf8))
    }

    // MARK: - 4. Failure leaves the original alone

    /// A write that cannot complete must leave the file exactly as it was —
    /// same bytes, same mode — and must not leave a temp file behind next to
    /// it either.
    ///
    /// The failure is induced by making the containing directory read-only
    /// (0500), so no new entry can be created in it. The destination file
    /// itself is still writable by its owner: directory permissions gate
    /// creating and removing names, not modifying an existing file. That is
    /// deliberate — it means a writer that opened the destination directly
    /// would *succeed at clobbering it* and only fail later, which is exactly
    /// the failure this test has to be able to see.
    @Test("a failed write leaves the original file byte-identical")
    func failedWriteLeavesOriginalIntact() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        let original = Data("the original contents, every byte of them\n".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        #expect(throws: (any Error).self) {
            try AtomicFileWriter.write(Data("replacement that must never land".utf8), to: destination)
        }

        #expect(try Data(contentsOf: destination) == original, "the original was modified")
        let survivingMode = try mode(of: destination)
        #expect(survivingMode == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["secrets.yaml"], "a temp file was left behind: \(leftovers)")
    }

    /// The error a caller gets back must name the path and nothing else. A
    /// writer that interpolated the bytes it was handed into its error would
    /// put a decrypted secret into whatever logs that error — the one thing
    /// this app must never do (CLAUDE.md).
    @Test("a failed write never puts the contents in the error")
    func failureNeverLeaksContents() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let secret = "correct-horse-battery-staple"
        var captured: String?
        do {
            try AtomicFileWriter.write(Data(secret.utf8), to: destination)
        } catch {
            captured = "\(error)  \((error as? any CustomStringConvertible)?.description ?? "")"
        }

        let message = try #require(captured)
        #expect(!message.contains(secret))
        #expect(message.contains("secrets.yaml"))
    }

    // MARK: - 5. The temp file lands beside the target

    /// The property the whole type exists for: the staging file must be in the
    /// *same directory* as the destination, so the final step is a rename
    /// within one filesystem.
    ///
    /// A temp file in `/tmp` (or anywhere else on another volume) makes the
    /// last step a copy, not a rename — and a copy is exactly the
    /// half-written-secrets-file failure this writer is supposed to make
    /// impossible. Asserted on the receipt's `temporaryFile`, which is the
    /// path actually used, not on the write merely having succeeded: a
    /// cross-device staging directory produces a perfectly successful write
    /// almost every time, and destroys the file on the one occasion it
    /// doesn't.
    @Test("the temp file is created in the same directory so the rename is atomic")
    func tempFileIsBesideTheTarget() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)

        let receipt = try AtomicFileWriter.write(Data("after".utf8), to: destination)

        #expect(receipt.destination == destination.resolvingSymlinksInPath())
        #expect(
            receipt.temporaryFile.deletingLastPathComponent().standardizedFileURL
                == receipt.destination.deletingLastPathComponent().standardizedFileURL,
            "staged at \(receipt.temporaryFile.path), which is not beside \(receipt.destination.path)")

        // Same directory is the mechanism; same device is the property it
        // buys. Assert the property directly too, so a future change that
        // "resolves" the staging directory to something equivalent-looking
        // on another volume still fails here.
        let stagingDevice = deviceID(of: receipt.temporaryFile.deletingLastPathComponent())
        let destinationDevice = deviceID(of: receipt.destination.deletingLastPathComponent())
        #expect(stagingDevice != nil)
        #expect(stagingDevice == destinationDevice, "staging and destination are on different volumes")

        // And it must not survive the write.
        #expect(!FileManager.default.fileExists(atPath: receipt.temporaryFile.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining == ["secrets.yaml"], "the staging file was left behind: \(remaining)")
    }

    /// The same property through a symlink, which is where a naive
    /// implementation gets it wrong twice over: staging beside the *link*
    /// rather than beside the *target* is a cross-device rename whenever the
    /// link crosses a volume, which is the main reason people make such links
    /// in the first place.
    @Test("through a symlink the temp file lands beside the target, not beside the link")
    func tempFileIsBesideTheSymlinkTarget() throws {
        let directory = try makeScratchDirectory()
        let targetDirectory = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(targetDirectory)
        let target = targetDirectory.appendingPathComponent("real.yaml")
        try Data("before".utf8).write(to: target)
        let link = directory.appendingPathComponent("secrets.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let receipt = try AtomicFileWriter.write(Data("after".utf8), to: link)

        #expect(receipt.destination == target.resolvingSymlinksInPath())
        #expect(
            receipt.temporaryFile.deletingLastPathComponent().standardizedFileURL
                == targetDirectory.resolvingSymlinksInPath().standardizedFileURL,
            "staged at \(receipt.temporaryFile.path), not beside the symlink's target")
    }

    // MARK: - A second writer

    /// The property the whole `expecting:` parameter exists for: a write over
    /// a file somebody else has touched is refused, and refused *inertly* —
    /// the other writer's bytes are still there afterwards.
    @Test("a write with a stale expectation is refused and the other writer's file survives")
    func staleExpectationIsRefused() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("as this caller read it".utf8).write(to: destination)

        let expectation = FileFingerprint.of(destination)
        #expect(expectation != nil)

        // Somebody else writes the file. `AtomicFileWriter` itself, because
        // that is what a second instance of this app would use, and because it
        // replaces the inode rather than editing in place — the case a
        // size-and-mtime-only check could plausibly miss.
        try AtomicFileWriter.write(Data("what the other writer put there".utf8), to: destination)

        #expect(throws: AtomicFileWriter.Error.destinationChangedOnDisk(path: destination.path)) {
            try AtomicFileWriter.write(Data("the clobbering write".utf8), to: destination,
                expecting: expectation)
        }

        #expect(
            try Data(contentsOf: destination) == Data("what the other writer put there".utf8),
            "the refused write must have left the other writer's bytes alone")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining == ["secrets.yaml"], "a refused write left a staging file behind: \(remaining)")
    }

    /// Same-size, in-place, no inode change: the case that separates a real
    /// fingerprint from a `size` comparison.
    @Test("a same-size in-place overwrite by someone else is still caught")
    func sameSizeInPlaceChangeIsCaught() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("AAAAAAAAAA".utf8).write(to: destination)
        let expectation = FileFingerprint.of(destination)

        // Straight into the same inode — no rename, no size change.
        let descriptor = open(destination.path, O_WRONLY)
        #expect(descriptor >= 0)
        _ = "BBBBBBBBBB".withCString { Darwin.write(descriptor, $0, 10) }
        close(descriptor)

        #expect(throws: AtomicFileWriter.Error.destinationChangedOnDisk(path: destination.path)) {
            try AtomicFileWriter.write(Data("clobber".utf8), to: destination, expecting: expectation)
        }
        #expect(try Data(contentsOf: destination) == Data("BBBBBBBBBB".utf8))
    }

    /// A file deleted out from under the caller is a change, not "nothing to
    /// compare against". `git checkout` of a branch without the file does
    /// exactly this.
    @Test("a destination that has vanished is refused rather than recreated")
    func vanishedDestinationIsRefused() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)
        let expectation = FileFingerprint.of(destination)

        try FileManager.default.removeItem(at: destination)

        #expect(throws: AtomicFileWriter.Error.destinationChangedOnDisk(path: destination.path)) {
            try AtomicFileWriter.write(Data("recreated".utf8), to: destination, expecting: expectation)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a matching expectation writes exactly as an unchecked write would")
    func matchingExpectationWrites() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)

        let receipt = try AtomicFileWriter.write(
            Data("after".utf8), to: destination, expecting: FileFingerprint.of(destination))

        #expect(try Data(contentsOf: destination) == Data("after".utf8))
        #expect(receipt.fingerprint != nil)
    }

    /// `AtomicWriteReceipt.fingerprint` is read from the *staged* file before
    /// the replace, on the claim that a replace is a rename and the
    /// destination therefore inherits the staged file's identity. That claim
    /// is what makes a caller's next `expecting:` correct, so it is checked
    /// against a real `stat` rather than assumed.
    @Test("the receipt's fingerprint is what a fresh stat of the destination reports")
    func receiptFingerprintMatchesTheDestination() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)

        let receipt = try AtomicFileWriter.write(Data("after".utf8), to: destination)

        #expect(receipt.fingerprint != nil)
        #expect(receipt.fingerprint == FileFingerprint.of(destination))
    }

    /// Chained writes, each expecting what the previous one reported. This is
    /// the editor's own save-twice path, and the thing that would break if the
    /// receipt's fingerprint were taken from anywhere other than the file the
    /// write actually produced.
    @Test("the receipt's fingerprint is accepted as the next write's expectation")
    func receiptFingerprintChains() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("one".utf8).write(to: destination)

        var expectation = FileFingerprint.of(destination)
        for round in 2...5 {
            let receipt = try AtomicFileWriter.write(
                Data("round \(round)".utf8), to: destination, expecting: expectation)
            expectation = receipt.fingerprint
        }

        #expect(try Data(contentsOf: destination) == Data("round 5".utf8))
    }

    /// `nil` means "no expectation", which is what `ProjectStore` and every
    /// pre-existing caller pass. It must not have quietly become a check
    /// against an absent file.
    @Test("no expectation means no check, including for a file that does not exist yet")
    func noExpectationSkipsTheCheck() throws {
        let directory = try makeScratchDirectory()
        let fresh = directory.appendingPathComponent("new.yaml")
        try AtomicFileWriter.write(Data("created".utf8), to: fresh)
        #expect(try Data(contentsOf: fresh) == Data("created".utf8))

        // And over an existing file that something else just rewrote.
        try Data("changed by someone else".utf8).write(to: fresh)
        try AtomicFileWriter.write(Data("overwritten anyway".utf8), to: fresh)
        #expect(try Data(contentsOf: fresh) == Data("overwritten anyway".utf8))
    }

    /// The refusal message names the file and says what to do. It must never
    /// name anything else — this writer's errors are shown to the user
    /// verbatim by `SecretDocumentViewModel.save()`.
    @Test("the refusal message carries the path and no file contents")
    func refusalMessageCarriesNoContents() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        let canary = "SUPERSECRETCANARY9999"
        try Data(canary.utf8).write(to: destination)
        let expectation = FileFingerprint.of(destination)
        try Data("\(canary)-and-more".utf8).write(to: destination)

        do {
            try AtomicFileWriter.write(Data(canary.utf8), to: destination, expecting: expectation)
            Issue.record("expected the write to be refused")
        } catch let error as AtomicFileWriter.Error {
            #expect(!error.description.contains(canary), Comment(rawValue: error.description))
            #expect(error.description.contains(destination.path))
            #expect(error.description.contains("reload"))
        }
    }

    // MARK: - 6. Create-only, never clobber

    /// The straightforward case: nothing is at the destination, so `.absent`
    /// writes exactly as `.unchecked` would, and the new file gets the same
    /// owner-only mode as any other file this writer creates.
    @Test("`.absent` creates the file when the destination is empty")
    func absentCreatesInEmptyDirectory() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")

        let receipt = try AtomicFileWriter.write(Data("fresh".utf8), to: destination, expecting: .absent)

        #expect(try Data(contentsOf: destination) == Data("fresh".utf8))
        #expect(try mode(of: destination) == 0o600)
        #expect(receipt.destination == destination.resolvingSymlinksInPath())
    }

    /// A destination that already exists is refused by name, and refused
    /// *before* anything is staged — the same "cheap early refusal" shape as
    /// `.matching`'s stale-fingerprint case, just with a different reason.
    @Test("`.absent` onto an existing file is refused and the original is untouched")
    func absentOntoExistingFileIsRefused() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        let original = Data("do not touch\n".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        #expect(throws: AtomicFileWriter.Error.destinationExists(path: destination.path)) {
            try AtomicFileWriter.write(Data("clobber".utf8), to: destination, expecting: .absent)
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(try mode(of: destination) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["secrets.yaml"], "something was staged before the refusal: \(leftovers)")
    }

    /// A dangling symlink is "something at that path" too, even though there
    /// is no file behind it to collide with. `.absent` must still refuse:
    /// letting the write through would have `RENAME_EXCL` land the new file
    /// on top of the link name, silently detaching it from whatever expected
    /// to find a symlink there.
    @Test("`.absent` refuses a dangling symlink at the destination too")
    func absentRefusesADanglingSymlink() throws {
        let directory = try makeScratchDirectory()
        let missingTarget = directory.appendingPathComponent("nowhere.yaml")
        let link = directory.appendingPathComponent("secrets.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)
        #expect(!FileManager.default.fileExists(atPath: missingTarget.path))

        #expect(throws: AtomicFileWriter.Error.destinationExists(path: link.path)) {
            try AtomicFileWriter.write(Data("nope".utf8), to: link, expecting: .absent)
        }

        #expect(isSymbolicLink(link), "the dangling symlink itself must survive the refusal")
    }

    /// The property the `RENAME_EXCL` choice specifically buys, and the
    /// reason `.absent` needs something more than a "create it first" test: a
    /// destination that exists *before* `write` is called is caught by the
    /// cheap early check alone (see `absentOntoExistingFileIsRefused` above),
    /// which would pass identically if the final step were a manually-guarded
    /// `replaceItemAt` instead of `renamex_np`. The only thing that actually
    /// needs OS-level exclusivity is a destination that appears *during*
    /// staging, after the early check already returned "nothing there" —
    /// `.absent` deliberately does not repeat that check right before the
    /// replace (see the comment there), so `RENAME_EXCL` is the sole guard
    /// for that window.
    ///
    /// **Landed deterministically, not raced.** An earlier version of this
    /// test raced a second thread's plain `open(O_CREAT | O_EXCL)` against
    /// staging of a multi-megabyte payload, on the theory that `write(2)` +
    /// `F_FULLFSYNC` gives a wide enough window for GCD to reliably schedule
    /// the racer inside it. Measured on this machine: comfortable, 33 of 40
    /// rounds landed the race. But "comfortable on this machine" is not the
    /// same claim as "will not flake in CI or a loaded VM with different
    /// dispatch latency" — a run where the racer thread never got scheduled
    /// in time would have failed this test red with no actual regression,
    /// which is exactly the flake risk review caught. `beforeReplaceHookForTesting`
    /// (see its own doc comment) removes the coin flip: it fires
    /// synchronously, on `write`'s own calling thread, at exactly the point
    /// in question, so the scenario in this test's name happens on every
    /// single run rather than most of them.
    ///
    /// The assertion still cannot pass vacuously: the planted marker bytes
    /// only end up on disk if the hook actually ran, and `write` only throws
    /// `.destinationExists` if the final rename actually saw them there —
    /// under a "check, then unconditionally replace" implementation (see the
    /// falsifiability note below), the hook still runs and plants the
    /// marker, but the replace silently overwrites it and no error is
    /// thrown, so both assertions below catch that failure mode directly
    /// rather than depending on who "won."
    ///
    /// **Falsifiability, checked by hand, not just asserted:** with the
    /// `.absent` branch of the final step temporarily reverted to plain,
    /// unconditional `FileManager.replaceItemAt` (no `RENAME_EXCL`), this
    /// test failed — the hook's planted marker was gone, silently replaced
    /// by the writer's payload, and no error was thrown. See
    /// `task-2-report.md`'s fix report for the actual failing output; that
    /// revert is not part of this commit.
    @Test("a destination that appears mid-staging is refused, proving the final rename is RENAME_EXCL")
    func absentRefusesADestinationThatAppearsMidStaging() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        let marker = Data("PLANTED-MID-STAGING".utf8)

        // Plants a plain (non-atomic, not-through-this-writer) file at
        // `destination` from inside `write` itself, standing in for "another
        // process created this file while we were staging". Guards on the
        // URL so a concurrently-running, unrelated `write` call from another
        // suite — `swift test` runs suites in parallel — is a no-op here
        // rather than getting a marker file planted underneath it.
        AtomicFileWriter.beforeReplaceHookForTesting = { url in
            guard url == destination else { return }
            try? marker.write(to: url)
        }
        defer { AtomicFileWriter.beforeReplaceHookForTesting = nil }

        #expect(throws: AtomicFileWriter.Error.destinationExists(path: destination.path)) {
            try AtomicFileWriter.write(Data("the write that must be refused".utf8), to: destination, expecting: .absent)
        }

        #expect(
            try Data(contentsOf: destination) == marker,
            "the planted file is missing or was overwritten — either the hook never fired, or the refusal did not actually stop the replace"
        )
    }

    /// `.matching` and `.unchecked` behave exactly the same reached through
    /// the `Expectation` overload directly as they do through the
    /// `FileFingerprint?` convenience tested elsewhere in this file — the
    /// convenience is a thin forwarding wrapper, not a second implementation.
    @Test("the Expectation overload's .matching behaves like the FileFingerprint overload")
    func expectationMatchingBehavesLikeFingerprintOverload() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)
        let fingerprint = try #require(FileFingerprint.of(destination))

        let receipt = try AtomicFileWriter.write(
            Data("after".utf8), to: destination, expecting: .matching(fingerprint))

        #expect(try Data(contentsOf: destination) == Data("after".utf8))
        #expect(receipt.fingerprint != nil)

        // And a stale one is still refused.
        #expect(throws: AtomicFileWriter.Error.destinationChangedOnDisk(path: destination.path)) {
            try AtomicFileWriter.write(Data("clobber".utf8), to: destination, expecting: .matching(fingerprint))
        }
    }

    @Test("the Expectation overload's .unchecked skips the check, including over an existing file")
    func expectationUncheckedSkipsTheCheck() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        try Data("before".utf8).write(to: destination)

        try AtomicFileWriter.write(Data("overwritten".utf8), to: destination, expecting: .unchecked)

        #expect(try Data(contentsOf: destination) == Data("overwritten".utf8))
    }

    // MARK: - The String convenience the editor actually calls

    @Test("the String overload round-trips UTF-8 exactly")
    func stringOverloadRoundTrips() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("secrets.yaml")
        let contents = "klíč: hodnota 🔐\nlist:\n  - a\n"

        try AtomicFileWriter.write(contents, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == contents)
        #expect(try Data(contentsOf: destination) == Data(contents.utf8))
    }
}
