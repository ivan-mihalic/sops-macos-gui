import Foundation

/// What `AtomicFileWriter.write` actually did, so a caller can check it rather
/// than assume it.
///
/// This exists because "the write succeeded" is not the interesting fact about
/// this type. A writer that staged its temp file on another volume succeeds
/// almost every time and destroys the file on the occasion it doesn't — the
/// failure mode is invisible from the return value of a plain `throws` call.
/// Reporting the two paths makes the property testable directly, and the
/// resolved `destination` is genuinely useful to a caller besides: when `url`
/// was a symlink, this is the file that actually changed.
public struct AtomicWriteReceipt: Equatable, Sendable {
    /// The file that was written — `url` with symlinks resolved. Differs from
    /// the `url` passed in exactly when that path went through a symlink.
    public let destination: URL

    /// Where the new bytes were staged before the replace. Always in
    /// `destination`'s own directory (see `AtomicFileWriter`'s doc comment for
    /// why that is the whole point), and no longer present on disk by the time
    /// this is returned.
    public let temporaryFile: URL
}

/// Replaces a file's contents without ever exposing a partial version of it.
///
/// Used for every write of a SOPS document. The file being replaced is the
/// user's only copy of a secret, so the failure this type exists to make
/// impossible is a *partially written* one: a reader — the sops CLI, git,
/// another editor, this app on its next launch — must never be able to observe
/// the file as truncated, empty, or half old and half new.
///
/// ## How
///
/// 1. Resolve symlinks, so everything below happens beside the *real* file.
/// 2. Create a temp file in that same directory, `O_EXCL`, mode `0600`.
/// 3. Write every byte, `F_FULLFSYNC` (falling back to `fsync`), close.
/// 4. `chmod` the temp to the original's mode.
/// 5. `FileManager.replaceItemAt` — a rename within one directory.
/// 6. `fsync` the directory so the new name is on stable storage too.
///
/// Step 2 is the one that carries the whole design. A temp file in `/tmp` and
/// a rename to a destination on another volume is not a rename at all — the OS
/// falls back to a copy, and a copy interrupted halfway leaves exactly the
/// half-written secrets file this type exists to prevent. Same directory means
/// same filesystem means the last step is a single atomic directory operation.
///
/// ## What this guarantees
///
/// - **Atomic visibility.** A reader opening `url` at any instant sees either
///   the complete previous contents or the complete new contents. Never a
///   truncated file, never a missing one. Verified by a concurrent reader in
///   `AtomicFileWriterTests`, sampling ~20,000 times across the write loop:
///   zero partial observations here, ~36 against the same loop with the
///   replace mutated to a plain non-atomic `Data.write(to:)`.
/// - **Failure is inert.** If anything before step 5 fails, the original file
///   has not been touched: it is byte-identical and keeps its mode, and the
///   temp file is removed.
/// - **The new bytes are on stable storage before the replace.**
///   `F_FULLFSYNC` asks the drive to flush its own write cache, which plain
///   `fsync(2)` on macOS does not (`fsync` only gets the data to the device).
///
/// ## What this does *not* guarantee
///
/// - **Which version survives a crash.** A crash or power loss during step 5
///   leaves one of the two complete versions, not necessarily the new one.
///   That is inherent to replacing a file and is not something a writer can
///   promise away.
/// - **Durability of the *rename* itself.** Step 6 (`fsync` on the containing
///   directory) is attempted and its result is deliberately *not* reported: by
///   then the replace has already happened, and turning a successful save into
///   a thrown error would be the more damaging lie. So the directory sync is
///   best-effort. If it fails, the new contents are still safely on disk and
///   the directory entry pointing at them is merely not yet forced out.
/// - **Anything about a device that ignores `F_FULLFSYNC`.** Some external and
///   network filesystems do. This calls it; it cannot make a drive honour it.
/// - **Owner and group.** Changing those needs privileges this app does not
///   have and must not want (CLAUDE.md: the app never mutates the system).
///   `replaceItemAt` preserves what it can; nothing here escalates.
///
/// ## Errors never contain the file's contents
///
/// Every case of `AtomicFileWriter.Error` is built from a path and an `errno`
/// description. The `Data` being written is never interpolated into an error,
/// a message, or anything logged — it is plaintext-derived ciphertext of the
/// user's secrets, and CLAUDE.md's rule is that naming a file is fine and
/// printing its contents is not.
public enum AtomicFileWriter {

    /// The mode a file this writer *creates* gets. Only reached when the
    /// destination did not already exist — an existing file's own mode always
    /// wins (see `write(_:to:)`).
    ///
    /// Owner-only rather than "whatever the umask allows", because every file
    /// this writer creates is a secrets document. `0644` from a default umask
    /// would make a new one world-readable, and nothing about the write would
    /// say so.
    private static let modeForNewFiles: Int = 0o600

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The file exists but this process may not write to it — a `chmod`ded
        /// read-only file, or an ACL denying write.
        ///
        /// Checked up front, before anything is staged, for two reasons.
        /// `FileManager.replaceItemAt` refuses a destination its owner cannot
        /// write (verified: mode `0444` fails with `NSCocoaErrorDomain` 513
        /// where a bare `rename(2)` would have succeeded, because a rename
        /// only needs the *directory*), and its message blames the containing
        /// folder — "you don't have permission to save the file X in the
        /// folder Y" — which sends the user to look at the wrong thing. This
        /// says what is actually true.
        ///
        /// The app does not `chmod` its way past this. A file the user made
        /// read-only stays read-only; CLAUDE.md's rule is that remediation is
        /// an explanation, not a mutation. It is also what the sops CLI does
        /// in the same situation.
        case destinationNotWritable(path: String)
        /// The temp file beside the destination could not be created — an
        /// unwritable directory, a full volume, a read-only mount.
        case couldNotStage(path: String, reason: String)
        /// The bytes could not be written to the temp file.
        case couldNotWrite(path: String, reason: String)
        /// The temp file could not be flushed to stable storage. Treated as
        /// fatal for the write rather than shrugged off: the point of this
        /// type is that what lands is complete, and an unflushed temp file
        /// promoted by `replaceItemAt` is precisely a file that might not be.
        case couldNotFlush(path: String, reason: String)
        /// The temp file's mode could not be set to the original's.
        case couldNotPreservePermissions(path: String, reason: String)
        /// The atomic replace itself failed. The original is untouched.
        case couldNotReplace(path: String, reason: String)

        public var description: String {
            switch self {
            case .destinationNotWritable(let path):
                return "\(path) is not writable, so it was left exactly as it is"
            case .couldNotStage(let path, let reason):
                return "could not create a temporary file next to \(path): \(reason)"
            case .couldNotWrite(let path, let reason):
                return "could not write to \(path): \(reason)"
            case .couldNotFlush(let path, let reason):
                return "could not flush \(path) to disk: \(reason)"
            case .couldNotPreservePermissions(let path, let reason):
                return "could not preserve the file permissions of \(path): \(reason)"
            case .couldNotReplace(let path, let reason):
                return "could not replace \(path): \(reason)"
            }
        }
    }

    /// Writes `contents` as UTF-8. See `write(_:to:)`.
    @discardableResult
    public static func write(_ contents: String, to url: URL) throws -> AtomicWriteReceipt {
        try write(Data(contents.utf8), to: url)
    }

    /// Replaces the file at `url` with `data`, atomically.
    ///
    /// - Parameter url: The file to replace. May be a symlink, in which case
    ///   the file it points at is what gets replaced and the link is left a
    ///   link — see the symlink note below. The containing directory must
    ///   already exist; this never creates one, because a save is always over
    ///   a file the user already opened.
    /// - Returns: What was written where, including the staging path. See
    ///   `AtomicWriteReceipt`.
    ///
    /// ## Symlinks
    ///
    /// `url` is put through `resolvingSymlinksInPath()` first — the same
    /// canonicalization `ProjectStore.normalize(_:)` uses, for a related
    /// reason. Two things forced this, both established empirically on this
    /// machine rather than reasoned about:
    ///
    /// - `FileManager.replaceItemAt` **does not follow a symlink**. Handed a
    ///   path that is one, it fails outright with `NSCocoaErrorDomain` 4
    ///   ("the file doesn't exist") even though both the link and its target
    ///   are right there. So resolving is not a nicety here; without it a
    ///   symlinked secrets file simply cannot be saved at all.
    /// - `String.write(to:atomically:true)` — which is what this type
    ///   replaces — *does* follow the path, and in doing so **destroys the
    ///   link**: it leaves a regular file where the symlink was, with the
    ///   original target still holding the old contents. Anything else
    ///   pointing at that target silently keeps reading stale secrets. That
    ///   is the concrete defect this parameter handling closes.
    ///
    /// Resolving also puts the temp file beside the *target* rather than
    /// beside the link, which matters for the same reason step 2 matters: a
    /// symlink that crosses a volume is the common case for making one.
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> AtomicWriteReceipt {
        let destination = url.resolvingSymlinksInPath()
        let directory = destination.deletingLastPathComponent()
        let temporaryFile = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")

        // The mode to end up with: the original's if there is an original,
        // otherwise owner-only. Read before anything is created, so a failure
        // partway through has nothing to undo.
        let originalMode = existingMode(of: destination)
        let finalMode = originalMode ?? modeForNewFiles

        // Before anything is staged. See `Error.destinationNotWritable`.
        if originalMode != nil, access(destination.path, W_OK) != 0 {
            throw Error.destinationNotWritable(path: destination.path)
        }

        // Created 0600 unconditionally, then chmodded to `finalMode` below.
        // Never the other way round: for the window in which the temp file
        // holds the full new ciphertext, it must not be readable by anyone the
        // final file would not be readable by either.
        let descriptor = open(temporaryFile.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(modeForNewFiles))
        guard descriptor >= 0 else {
            throw Error.couldNotStage(path: destination.path, reason: describeErrno())
        }

        // Runs on every exit from here on, including the success path — where
        // the replace has already renamed the temp away, so this is a no-op.
        // On every failure path it is what keeps the destination's directory
        // clean, which `AtomicFileWriterTests` asserts.
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        do {
            try writeAll(data, to: descriptor, path: destination.path)
            try flush(descriptor, path: destination.path)
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)

        // Explicit, rather than left to `replaceItemAt`'s own metadata
        // copying. `replaceItemAt` with default options does carry the
        // original's mode across (checked), but that is one undocumented
        // behaviour standing between the user's `chmod 600` and a
        // world-readable secrets file. Setting it here means the result is
        // right under either option set, and it is also the only thing that
        // sets the mode at all when the destination did not exist yet.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: finalMode], ofItemAtPath: temporaryFile.path)
        } catch {
            throw Error.couldNotPreservePermissions(
                path: destination.path, reason: (error as NSError).localizedDescription)
        }

        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryFile)
        } catch {
            throw Error.couldNotReplace(
                path: destination.path, reason: (error as NSError).localizedDescription)
        }

        syncDirectory(directory)

        return AtomicWriteReceipt(destination: destination, temporaryFile: temporaryFile)
    }

    // MARK: - Steps

    /// The destination's current mode, or `nil` if there is no destination
    /// yet. Deliberately *not* following a symlink here — `destination` is
    /// already resolved by the caller, so anything still a symlink at this
    /// point is a dangling one, and a dangling link's own mode is not the
    /// mode of any file.
    private static func existingMode(of destination: URL) -> Int? {
        var info = stat()
        guard lstat(destination.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return Int(info.st_mode & 0o7777)
    }

    /// `write(2)` in a loop until every byte is out.
    ///
    /// A single `write` is allowed to be short, and `EINTR` is allowed to
    /// interrupt it. Both are rare enough that a version of this that ignored
    /// them would pass every test and truncate a large secrets file in
    /// production — which is the exact class of bug this type exists to close,
    /// so it is handled rather than assumed away.
    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Error.couldNotWrite(path: path, reason: describeErrno())
                }
                if written == 0 {
                    throw Error.couldNotWrite(path: path, reason: "the write stopped making progress")
                }
                offset += written
            }
        }
    }

    /// Forces the temp file's bytes out to stable storage.
    ///
    /// `F_FULLFSYNC` first: on macOS, `fsync(2)` returns once the data has
    /// reached the device, which may still hold it in a volatile write cache —
    /// only `F_FULLFSYNC` asks the drive to flush that cache. Not every
    /// filesystem implements the fcntl (network and some external volumes do
    /// not), and there it fails with `ENOTTY`/`ENOTSUP` rather than meaning
    /// anything is wrong, so `fsync` is the fallback. A failure of *that* is
    /// real and aborts the write, leaving the original untouched.
    private static func flush(_ descriptor: Int32, path: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw Error.couldNotFlush(path: path, reason: describeErrno())
        }
    }

    /// Best-effort `fsync` of the directory the replace happened in, so the
    /// new directory entry is durable and not just the file's contents.
    ///
    /// Deliberately returns nothing and reports nothing. It runs *after* the
    /// replace, so by the time it could fail the save has already succeeded —
    /// see the "What this does not guarantee" section of the type's doc
    /// comment, which states exactly this rather than letting the code imply
    /// a stronger promise than it keeps.
    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    /// `strerror` for the current `errno`. A path is safe to name; this never
    /// sees the file's contents at all.
    private static func describeErrno() -> String {
        String(cString: strerror(errno))
    }
}
