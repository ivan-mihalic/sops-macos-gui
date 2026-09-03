import AppKit
import Foundation
import SopsEngine

/// Turning a freshly generated age identity into the two files a user
/// actually needs, and writing them the way `age-keygen` would (SOPS-44).
///
/// ## Why the file text is built here rather than in the view
/// A private key file is the one artefact of this app that a user can lose
/// irrecoverably, and its exact contents matter: sops and age read the
/// `AGE-SECRET-KEY-1…` line and ignore the `#` comments, but the comments are
/// what tells a human, a year later, which public key that file belongs to.
/// Reproducing `age-keygen`'s own layout means a file written here is
/// interchangeable with one written by the tool the setup guide tells people
/// to run — and it means this text can be asserted by a test, which a string
/// built inside a `Button` closure cannot.
///
/// ## What is deliberately not here
/// Nothing installs the key. The app does not write to `~/.config/sops`, does
/// not touch `SOPS_AGE_KEY_FILE`, and does not import the identity into the
/// session — the user chooses a location in a save panel, or copies the line
/// and puts it wherever their team keeps such things. "The app never mutates
/// the system" (CLAUDE.md) is not suspended because the app made the key.
public enum GeneratedKeyFiles {

    /// The private key file, byte for byte the shape `age-keygen -o` writes:
    /// a created-at comment, the public key as a comment, then the identity
    /// on its own line.
    ///
    /// `created` is a parameter so the text is testable; production passes
    /// the current time.
    public static func privateKeyFile(_ key: GeneratedAgeKey, created: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: created)
        return """
            # created: \(stamp)
            # public key: \(key.publicKey)
            \(key.privateKey)

            """
    }

    /// The public key file: the recipient on its own line. No comments — this
    /// is the string that gets pasted into a `.sops.yaml`, mailed to a
    /// colleague, or dropped on a server, and every extra line is something
    /// someone will paste by accident.
    ///
    /// Written as a multi-line literal rather than a concatenated `"\n"`:
    /// this package's own guard refuses the bare literal anywhere in
    /// `Sources/` (`CRLFToleranceTests`), and it is right to — a trailing
    /// newline built by hand is one keystroke from the CRLF-blind idiom that
    /// caused four bugs here.
    public static func publicKeyFile(_ key: GeneratedAgeKey) -> String {
        """
        \(key.publicKey)

        """
    }

    /// The file name offered for each half. A name the user typed for the key
    /// leads, so a project with three keys does not end up with three files
    /// called `key.txt`; an unnamed key falls back to `age`.
    ///
    /// The names are not localized on purpose: a file name is not prose, and
    /// a `.sops.yaml` referring to `klíč.txt` on one machine and `key.txt` on
    /// another is a support call.
    public static func fileName(for name: String, isPrivate: Bool) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let safe = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        let base = safe.isEmpty ? "age" : safe
        return isPrivate ? "\(base).key" : "\(base).pub"
    }

    /// Writes `contents` to `url` with the permissions its sensitivity
    /// deserves: a private key file is `0600` — readable by nobody but its
    /// owner — set on the file *after* it exists, since `NSSavePanel` may
    /// have created it already.
    ///
    /// Returns the reason it could not be written, or `nil` on success. The
    /// message names the file, never the key.
    public static func write(_ contents: String, to url: URL, isPrivate: Bool) -> String? {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            if isPrivate {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return nil
        } catch {
            return String(
                format: LocalizedKey.accessGenerateSaveFailed.text, url.lastPathComponent)
        }
    }

    /// The save panel, configured but not run — same seam as
    /// `ProjectOpenPanel`, and for the same reason: a panel built inline in
    /// the method that runs it cannot be looked at by a test.
    @MainActor
    public static func savePanel(suggesting fileName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = LocalizedKey.accessGenerateSaveButton.text
        return panel
    }
}
