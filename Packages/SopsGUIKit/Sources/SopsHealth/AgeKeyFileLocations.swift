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
/// `Library/Application Support`. This app's own import button offers that path
/// by name (`SopsUI/Editor/KeyImportView.swift`), which is another reason it
/// would be strange to stop looking at it.
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
enum AgeKeyFileLocations {

    static let userConfigRelativePath = "sops/age/keys.txt"

    /// Every path worth stat-ing, in the order sops itself would consider them,
    /// deduplicated and with empty entries dropped.
    ///
    /// `environment` and `homeDirectory` are injected so this is testable
    /// without touching the machine's real environment — a test that has to set
    /// `XDG_CONFIG_HOME` process-wide is a test that corrupts every other test
    /// running beside it under Swift Testing's parallel execution.
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
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
}
