import Foundation
import SopsHealth

/// What the "import from a key file on disk" control can honestly offer right
/// now: nothing, one named file, or a choice the app must not make.
///
/// ## Why this is a type and not three `if`s inside the view
///
/// The button had a path baked into it — `NSHomeDirectory() +
/// "/.config/sops/age/keys.txt"` — and, worse, baked into its own label:
/// *"Import from ~/.config/sops/age/keys.txt"*. On macOS that is not where the
/// embedded sops keeps a key (`AgeKeyFileLocations` has the citation), so once
/// `SecurityPostureCheck` was fixed to look in the right places the app could
/// report a key file in `Library/Application Support` and then offer a button
/// that read somewhere else and failed — while naming the place it was looking,
/// so the user had no way to see the mismatch. The list of places lives in
/// exactly one type now; this one turns that list into a decision, in a value a
/// test can hold.
///
/// ## The decision, and why
///
/// **Nothing found** → `noneFound(searched:)`. The control is present but
/// disabled, and the footer names every path that was stat'd. Offering an
/// enabled button here would offer an action whose only possible outcome is a
/// failure alert; saying nothing at all would be the same untruth
/// `SecurityPostureCheck`'s old unqualified all-clear told — "we found nothing"
/// is worthless unless the user can see *where* it was looked for, because a
/// check pointed at the wrong place produces exactly that sentence.
///
/// **Exactly one** → `one(_:)`. Only here can a path be named up front, because
/// only here is the named path certainly the one a click will read. So this is
/// the one case whose label carries a path.
///
/// **Several** → `several(_:)`. Two or more plaintext key files is not
/// far-fetched: `SOPS_AGE_KEY_FILE` pointing at a project key while an old
/// `age-keygen` default sits in `~/.config` is an ordinary state of a
/// developer's Mac. The app must not choose between them — first-one-wins is
/// the same silent pick `SessionKeyStore.importFromKeysFileContents` already
/// refuses to make *within* a file, and picking here would be worse, since the
/// user cannot even see there was a second candidate. The control becomes a
/// menu whose items each name one path; the app reads only the one that is
/// clicked, and the menu's own label names no path, because before the click
/// there is no true answer to "which file?".
///
/// ## What every case keeps
///
/// Nothing here opens a file. Resolving asks `FileManager.fileExists` — a
/// `stat`, which needs no read permission on the file and cannot see its
/// contents — and that is the same question `SecurityPostureCheck` already
/// asks to raise `security.legacy-key-file`. The read happens on a click and
/// only on a click, which is the property `KeyImportView`'s header comment
/// exists to protect: this app warns that these files sit unprotected, and an
/// app that quietly slurps one on `onAppear` would be contradicting its own
/// warning.
public enum LegacyKeyFileImportOptions: Equatable, Sendable {
    /// No candidate holds a regular file. `searched` is every path stat'd, in
    /// the order sops itself would consider them — carried so the UI can name
    /// them, for the reason above.
    case noneFound(searched: [String])
    /// Exactly one candidate holds a file. This path, and no other, is what a
    /// click reads — so this is the only case that may name a path in a label.
    case one(String)
    /// More than one candidate holds a file. The user picks; the app does not.
    case several([String])

    /// Which paths actually hold a file. Empty for `noneFound`.
    public var found: [String] {
        switch self {
        case .noneFound: []
        case .one(let path): [path]
        case .several(let paths): paths
        }
    }

    /// Every path that was looked at, whether or not something was there.
    public var searched: [String] {
        switch self {
        case .noneFound(let searched): searched
        case .one(let path): [path]
        case .several(let paths): paths
        }
    }

    /// Stats each of `AgeKeyFileLocations.candidates` and classifies the result.
    ///
    /// `environment`, `homeDirectory` and `isRegularFile` are all injected, and
    /// the defaults are the only place the real machine is consulted. A test
    /// that had to `setenv("XDG_CONFIG_HOME", …)` or write into the real `$HOME`
    /// to reach a case would corrupt every test running beside it — Swift
    /// Testing runs suites in parallel in one process.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isRegularFile: (String) -> Bool = AgeKeyFileLocations.isRegularFile
    ) -> LegacyKeyFileImportOptions {
        let searched = AgeKeyFileLocations.candidates(
            environment: environment, homeDirectory: homeDirectory)
        let found = AgeKeyFileLocations.existingFiles(among: searched, isRegularFile: isRegularFile)
        switch found.count {
        case 0: return .noneFound(searched: searched)
        case 1: return .one(found[0])
        default: return .several(found)
        }
    }
}
