import Darwin
import Foundation

/// Marks a file `SecretFileCreator` just created with
/// `ResolvedEncryption.acknowledgedUnreadable == true` — written with **no
/// content verification at all**, because the session that created it could
/// not decrypt it back to check (see that type's own doc comment, "With
/// `acknowledgedUnreadable == true`…"). Ticket #10, claim 3: that fact used
/// to live nowhere once `create()` returned. A user looking at the file
/// later — even one holding the right key now — had no way to learn it was
/// never actually verified when it was written.
///
/// ## Why an extended attribute, not a project-level registry
///
/// This is local, advisory, machine-specific metadata about *how a file was
/// created*, not project data. Unlike `RecipientRegistry` it carries no
/// access-control meaning that a lost or stale marker could break — nothing
/// here decides who can read the file, only what a health finding says about
/// it — and it is not meant to travel with the file: an extended attribute
/// does not survive `git`, `scp`, or a zip archive, which is right for a fact
/// that is true of *this copy on this machine*, not of the document's
/// content. A `RecipientRegistry`-style fingerprint-guarded JSON file would
/// buy correctness this fact does not need at a cost (a second file per
/// project, a concurrent-writer story) it should not have to pay.
///
/// ## Best-effort by construction
///
/// `mark(_:)` never throws. The file it is called on was already written
/// successfully by the time `SecretFileCreator.create` calls it — that write
/// is the primary fact — so a failure to *also* tag it (a filesystem that
/// does not support extended attributes, a permissions oddity) must never be
/// reported as a failure to create the file. The cost of that choice is
/// symmetric with the benefit: a mark that silently did not take means the
/// health finding below does not know about this file either, which is a
/// gap, not a lie — nothing claims the file *was* verified.
public enum AcknowledgedUnreadableMarker {

    /// Namespaced with this app's own reverse-DNS prefix, the same
    /// convention `org.nspasteboard.*` follows for the identical reason:
    /// unambiguous provenance for anyone who lists a file's extended
    /// attributes by hand (`xattr -l`) and wonders what set it.
    static let attributeName = "dev.sopsmacosgui.acknowledgedUnreadable"

    /// Tags `url` as created unreadable. See this type's doc comment,
    /// "Best-effort by construction" — never throws, and a failure here is
    /// silently swallowed.
    public static func mark(_ url: URL) {
        var value: UInt8 = 1
        withUnsafeBytes(of: &value) { buffer in
            _ = setxattr(url.path, attributeName, buffer.baseAddress, 1, 0, 0)
        }
    }

    /// Whether `url` was tagged by `mark(_:)`. `false` for a file that was
    /// never marked, one whose marker could not be read for any reason
    /// (including a filesystem that does not support extended attributes),
    /// and one that does not exist — never throws.
    public static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, attributeName, nil, 0, 0, 0) >= 0
    }
}
