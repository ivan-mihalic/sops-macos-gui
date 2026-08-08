import Foundation

/// Where a plaintext age key file can actually be sitting on this Mac.
///
/// ## Why this is not just `~/.config/sops/age/keys.txt`
///
/// It was, and that path is **wrong on macOS**. `SecurityPostureCheck` stated
/// "No unprotected age key file was found" on the strength of one `stat` of
/// `NSHomeDirectory() + "/.config/sops/age/keys.txt"`, and the `.ok` branch did
/// not even name the path it had checked — so a user with a key file exactly
/// where sops itself puts it read a confident all-clear about a file this app
/// had never looked for.
///
/// The pinned getsops/sops v3.13.3 this app embeds resolves the user-config
/// location in `age/keysource.go`:
///
/// ```go
/// func getUserConfigDir() (string, error) {
///     if runtime.GOOS == "darwin" {
///         if userConfigDir, ok := os.LookupEnv(xdgConfigHome); ok && userConfigDir != "" {
///             return userConfigDir, nil
///         }
///     }
///     return os.UserConfigDir()
/// }
/// ```
///
/// with `SopsAgeKeyUserConfigPath = "sops/age/keys.txt"` joined onto it. On
/// macOS with no `XDG_CONFIG_HOME`, `os.UserConfigDir()` is
/// `$HOME/Library/Application Support` — **not** `$HOME/.config`. The same file
/// reads `SOPS_AGE_KEY_FILE` first, and honours it wherever it points.
///
/// So this app was checking a path sops does not read, and not checking the two
/// it does.
///
/// ## Why `~/.config/…` is still on the list
///
/// It is not there for sops's sake — sops will not read it on macOS without
/// `XDG_CONFIG_HOME` — but because the finding is about *a plaintext age key
/// lying on disk*, and that path is where nearly every tutorial, `age-keygen`
/// invocation and Linux habit puts one. A key sitting there is exactly as
/// readable by every process running as the user as one sitting in
/// `Library/Application Support`.
///
/// ## Why this is `public`
///
/// Because there was a second copy of the list, and the two drifted. Task 18
/// fixed `SecurityPostureCheck` to stat all three paths; `KeyImportView`'s
/// import button went on hardcoding `~/.config/sops/age/keys.txt` — and naming
/// it in its own label — so the app could report a key file in
/// `Library/Application Support` and then offer a button that looked somewhere
/// else and failed. `SopsUI` depends on `SopsHealth` already, so it now asks
/// this type instead of keeping its own answer. One list, one order, one set of
/// tests.
///
/// ## What is deliberately *not* here
///
/// `SOPS_AGE_KEY` holds key material in the environment rather than in a file.
/// It is arguably a worse exposure than either path above, and it is a
/// different finding: this one is about files, reports only existence, and
/// never opens anything. Adding an environment check here would mean this type
/// starts handling a variable whose *value* is a secret, which the never-log
/// rule makes a decision to take deliberately rather than as a side effect. It
/// is not checked today and nothing here implies it was.
public enum AgeKeyFileLocations {

    public static let userConfigRelativePath = "sops/age/keys.txt"

    /// Every path worth stat-ing, in the order sops itself would consider them,
    /// deduplicated and with empty entries dropped.
    ///
    /// `environment` and `homeDirectory` are injected so this is testable
    /// without touching the machine's real environment — a test that has to set
    /// `XDG_CONFIG_HOME` process-wide is a test that corrupts every other test
    /// running beside it under Swift Testing's parallel execution.
    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  homeDirectory: String = NSHomeDirectory()) -> [String] {
        var paths: [String] = []

        func add(_ path: String) {
            guard !path.isEmpty, !paths.contains(path) else { return }
            paths.append(path)
        }

        if let explicit = environment["SOPS_AGE_KEY_FILE"], !explicit.isEmpty {
            add(explicit)
        }
        // The darwin branch of sops's own `getUserConfigDir`.
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (homeDirectory as NSString).appendingPathComponent("Library/Application Support")
        add((configHome as NSString).appendingPathComponent(userConfigRelativePath))
        // The conventional location, whether or not this sops build reads it.
        add((homeDirectory as NSString).appendingPathComponent(".config/" + userConfigRelativePath))

        return paths
    }

    /// Does a regular file sit at `path` right now?
    ///
    /// A `stat`, never an open: `fileExists` needs no read permission on the
    /// file itself, so asking this question about a key file does not read one.
    /// That distinction is the whole reason both callers can ask it without an
    /// explicit user gesture — see `existingFiles(among:isRegularFile:)`.
    ///
    /// `fileExists(atPath:isDirectory:)`, not the plain overload, because a
    /// *directory* named `keys.txt` (someone's stray `mkdir -p`) is not a key
    /// file, and the plain overload cannot tell the two apart.
    public static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Which of `paths` currently hold a regular file, in the order given.
    ///
    /// `isRegularFile` is injected for the same reason `candidates` injects its
    /// environment: a test that has to create real files under a real
    /// `$HOME` to exercise a decision is a test that touches process-wide
    /// state, and Swift Testing runs suites in parallel.
    public static func existingFiles(among paths: [String],
                                     isRegularFile: (String) -> Bool = Self.isRegularFile) -> [String] {
        paths.filter(isRegularFile)
    }

    /// The one command this app offers for a plaintext key file it found:
    /// narrow who can read it. Nil when no honest single-line command can
    /// represent the paths (see `ShellQuoting`).
    ///
    /// Shared rather than spelled out twice. `SecurityPostureCheck`'s
    /// `security.legacy-key-file` remediation and `KeyImportView`'s
    /// post-import callout are deliberately the *same* advice — the callout's
    /// whole point is to repeat the finding the app has already been showing,
    /// not to invent a second fix for one problem — and two string
    /// interpolations of `"chmod 600 …"` is how they would stop being the same.
    public static func protectCommand(for paths: [String]) -> String? {
        ShellQuoting.singleQuotedList(paths).map { "chmod 600 " + $0 }
    }
}
