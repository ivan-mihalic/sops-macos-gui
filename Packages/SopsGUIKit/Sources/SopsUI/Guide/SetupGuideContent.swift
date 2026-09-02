import Foundation
import SopsHealth

/// The snippets `SetupGuideView` shows — PROPOSAL.md §5, "In-App Help (with
/// copy-paste snippets)". Plain `static let` strings, deliberately outside
/// the localization catalog: a command is the same in every language, and
/// `LocalizationTests.noCatalogStringNamesAKeyFilePath` exists precisely so
/// that key-file paths never end up in prose.
///
/// Every snippet has a stable `id` for `CopyFeedback`, and `allSnippets`
/// lists them all so a test can count copy buttons against it.
public enum SetupGuideContent {

    public struct Snippet: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let multiline: Bool
    }

    // MARK: (a) docker-compose

    public static let composeExecEnv = Snippet(
        id: "compose.exec-env",
        text: "sops exec-env secrets/prod.sops.env 'docker compose up -d'",
        multiline: false)

    public static let composeMakefile = Snippet(
        id: "compose.makefile",
        text: """
        .env: secrets/prod.sops.yaml
        \tsops -d secrets/prod.sops.yaml | yq -o=props > .env
        \tchmod 600 .env
        """,
        multiline: true)

    // MARK: (b) without compose

    public static let plainExecEnv = Snippet(
        id: "plain.exec-env",
        text: "sops exec-env secrets/prod.sops.env 'node server.js'",
        multiline: false)

    public static let direnvEnvrc = Snippet(
        id: "plain.direnv",
        text: """
        # .envrc — direnv loads the decrypted values into this shell only
        eval "$(sops -d --output-type dotenv secrets/dev.sops.env | sed 's/^/export /')"
        """,
        multiline: true)

    public static let systemdEnvironmentFile = Snippet(
        id: "plain.systemd",
        text: """
        sops -d --output-type dotenv secrets/prod.sops.env > /etc/myapp/env
        chmod 600 /etc/myapp/env

        # /etc/systemd/system/myapp.service
        [Service]
        EnvironmentFile=/etc/myapp/env
        """,
        multiline: true)

    // MARK: (c) a key on a Linux server

    public static let serverInstall = Snippet(
        id: "server.install",
        text: "sudo apt install age    # Debian/Ubuntu — or: sudo dnf install age",
        multiline: false)

    public static let serverKeygen = Snippet(
        id: "server.keygen",
        text: """
        sudo install -d -m 700 -o root -g root /etc/age
        sudo age-keygen -o /etc/age/server.key
        sudo chmod 600 /etc/age/server.key
        """,
        multiline: true)

    public static let serverPublicKey = Snippet(
        id: "server.public-key",
        text: "sudo grep '^# public key:' /etc/age/server.key",
        multiline: false)

    public static let serverKeyFile = Snippet(
        id: "server.key-file",
        text: "export SOPS_AGE_KEY_FILE=/etc/age/server.key",
        multiline: false)

    // MARK: (d) a key for a colleague

    /// The path this app itself looks for a key at, so the command and the
    /// health check can never disagree about where a key belongs.
    static let macOSKeyPath = "~/Library/Application Support/" + AgeKeyFileLocations.userConfigRelativePath
    static let linuxKeyPath = "~/.config/" + AgeKeyFileLocations.userConfigRelativePath

    private static func directory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    public static let colleagueMacOS = Snippet(
        id: "colleague.macos",
        text: """
        brew install age
        mkdir -p "\(directory(of: macOSKeyPath))"
        age-keygen -o "\(macOSKeyPath)"
        chmod 600 "\(macOSKeyPath)"
        """,
        multiline: true)

    public static let colleagueLinux = Snippet(
        id: "colleague.linux",
        text: """
        sudo apt install age    # or your distro's package
        mkdir -p \(directory(of: linuxKeyPath))
        age-keygen -o \(linuxKeyPath)
        chmod 600 \(linuxKeyPath)
        """,
        multiline: true)

    public static let colleagueWindows = Snippet(
        id: "colleague.windows",
        text: """
        winget install FiloSottile.age    # or: scoop install age
        age-keygen -o %APPDATA%\\sops\\age\\keys.txt
        """,
        multiline: true)

    public static let colleagueShare = Snippet(
        id: "colleague.share",
        text: "grep '^# public key:' \(linuxKeyPath)    # send ONLY this age1… line",
        multiline: false)

    // MARK: (e) .sops.yaml cookbook

    public static let sopsYamlSingleRule = Snippet(
        id: "sops-yaml.single",
        text: """
        keys:
          - &alice age1exampleexampleexampleexampleexampleexampleexampleexamplee0
        creation_rules:
          - path_regex: \\.sops\\.(env|ya?ml|json)$
            age:
              - *alice
        """,
        multiline: true)

    public static let sopsYamlEncryptedRegex = Snippet(
        id: "sops-yaml.encrypted-regex",
        text: """
        creation_rules:
          - path_regex: config/.*\\.yaml$
            encrypted_regex: '^(password|secret|token|key)$'
            age:
              - *alice
        """,
        multiline: true)

    public static let sopsYamlPerEnvironment = Snippet(
        id: "sops-yaml.per-environment",
        text: """
        keys:
          - &alice   age1exampleexampleexampleexampleexampleexampleexampleexamplee0
          - &bob     age1exampleexampleexampleexampleexampleexampleexampleexamplee1
          - &server  age1exampleexampleexampleexampleexampleexampleexampleexamplee2
        creation_rules:
          # first match wins — the specific rule goes first
          - path_regex: secrets/prod\\.sops\\.env$
            age:
              - *alice
              - *bob
              - *server
          - path_regex: \\.sops\\.(env|ya?ml|json)$
            age:
              - *alice
              - *bob
        """,
        multiline: true)

    // MARK: (f) the AI assistant prompt

    /// Pasted into a third-party chat. It therefore names nothing about the
    /// user's own project — no file names, no recipients — and it states
    /// the one thing an assistant must not talk the user out of: the
    /// private key stays where it was made.
    public static let aiAssistantPrompt = Snippet(
        id: "ai.prompt",
        text: """
        I am setting up secrets management with sops and age for a project. \
        Help me install and configure it on a server and for my colleagues. \
        Before anything else, these security rules are non-negotiable and \
        you must never suggest otherwise:

        1. The age PRIVATE key (the file age-keygen writes, starting with \
        AGE-SECRET-KEY-1) never leaves the machine it was generated on. \
        Never ask me to paste it into this chat, never put it in a script, \
        never commit it to git, never send it by email or messenger. Only the \
        PUBLIC key (the line starting with age1) is shared, and that is safe \
        to share with anyone.
        2. The private key file must be readable only by its owner: chmod 600, \
        and on a server it lives under /etc/age owned by root with mode 700 \
        on the directory. Never set SOPS_AGE_KEY in a shell profile or a \
        Dockerfile; point SOPS_AGE_KEY_FILE at the file instead.
        3. Encrypted files (*.sops.env, *.sops.yaml, *.sops.json) and the \
        .sops.yaml config are safe to commit. Decrypted output (.env, plain \
        YAML) must be git-ignored and never committed.
        4. Every recipient listed in .sops.yaml can decrypt everything the \
        rule covers. When a person or machine is removed from a rule, the \
        files must be re-encrypted (sops updatekeys / rewrap) AND the values \
        rotated, because a removed recipient keeps whatever it already read.
        5. Prefer `sops exec-env` / `sops exec-file` so plaintext only exists \
        in the process environment, never on disk.

        Now, with those rules fixed, walk me through: installing age and sops \
        (macOS via Homebrew, Linux via the distro package, Windows via winget), \
        generating a key for each person and for the server, collecting the \
        public keys into .sops.yaml with named anchors, encrypting the first \
        file, and wiring decryption into the application start (docker \
        compose or systemd). Ask me which platform and runtime I use before \
        giving platform-specific commands.
        """,
        multiline: true)

    /// Every snippet the page shows, in page order.
    public static let allSnippets: [Snippet] = [
        composeExecEnv, composeMakefile,
        plainExecEnv, direnvEnvrc, systemdEnvironmentFile,
        serverInstall, serverKeygen, serverPublicKey, serverKeyFile,
        colleagueMacOS, colleagueLinux, colleagueWindows, colleagueShare,
        sopsYamlSingleRule, sopsYamlEncryptedRegex, sopsYamlPerEnvironment,
        aiAssistantPrompt,
    ]
}
