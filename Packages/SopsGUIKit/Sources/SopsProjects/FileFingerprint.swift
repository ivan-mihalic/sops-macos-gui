import Foundation

/// Enough of a file's identity to tell "nobody has touched this since I read
/// it" from "somebody has".
///
/// ## Why this type exists
///
/// `AtomicFileWriter` is atomic with respect to *readers*: nobody ever
/// observes a half-written secrets file. It says nothing at all about a second
/// *writer*, and until this type there was nothing in the app that did. The
/// editor read a file, held its ciphertext in memory, re-encrypted from that
/// held copy and replaced the file unconditionally — so a `git pull`, a
/// `sops updatekeys`, a `sops set` in another terminal, or a second instance
/// of this app could add a key to the file and the next save would silently
/// delete it again, reporting success. For an app whose worst failure is
/// destroying a secrets file, that was an open hole.
///
/// ## Why metadata rather than a content hash
///
/// A hash of the bytes is the obvious alternative and it was rejected for a
/// specific reason: the editor reads through
/// `String(contentsOf:encoding:.utf8)`, so the bytes it holds have already
/// been through a decode. Comparing a hash of *those* against a hash of what
/// is on disk compares a round trip, not the file, and any place the round
/// trip is not byte-exact (a BOM, most obviously) turns into a save refused
/// over a file nobody changed. `stat` sidesteps the encoding question
/// entirely.
///
/// The four fields are what a second writer cannot avoid moving:
///
/// - `deviceID` + `inode` catch a *replacement*. Every atomic writer, this one
///   included, lands a new inode over the old name, so the identity changes
///   even if the bytes and the timestamp happened not to.
/// - `size` catches the common in-place edit.
/// - `modifiedSeconds`/`modifiedNanoseconds` catch a same-size in-place edit.
///   APFS stores mtime to the nanosecond, so two writes have to land inside
///   the same nanosecond to collide.
///
/// ## What it does not establish
///
/// A file can change and change back — restore a backup, `git checkout` the
/// same content twice — and produce a fingerprint that differs from the one
/// held even though the *contents* are identical. That direction is a save
/// refused over a file that is effectively unchanged: annoying, recoverable by
/// reloading, and the safe way to be wrong. This type never errs the other
/// way, because there is no way to write a file without moving at least one of
/// the four fields.
public struct FileFingerprint: Equatable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public init(
        deviceID: UInt64, inode: UInt64, size: Int64,
        modifiedSeconds: Int64, modifiedNanoseconds: Int64
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    /// The fingerprint of the regular file at `url`, or `nil` when there is no
    /// regular file there — it does not exist, or it is a directory, or the
    /// `stat` failed.
    ///
    /// Symlinks are followed (`stat`, not `lstat`), because the file a
    /// symlinked path denotes is the file that gets replaced — see
    /// `AtomicFileWriter.write(_:to:)`'s symlink note. A fingerprint of the
    /// *link* would never change no matter what happened to the target.
    public static func of(_ url: URL) -> FileFingerprint? {
        of(path: url.path)
    }

    public static func of(path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return FileFingerprint(
            deviceID: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}
