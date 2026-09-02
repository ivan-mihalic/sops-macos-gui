import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

/// A real, on-disk project shaped like momentak's: a `.sops.yaml` whose age
/// keys are declared once under a top-level `keys:` list with YAML anchors
/// (`&studio`, `&laptop`, `&vps`) and referenced by alias from two creation
/// rules, and two genuinely sops-encrypted dotenv files — one of which has
/// **drifted** from the rule that governs it.
///
/// Built through the real bridge (`SopsBridge.encrypt`), never hand-written
/// ciphertext: what the Access page shows is derived from `AccessInventory`,
/// which reads a file's own recipients out of its sops metadata and compares
/// them against what sops's own config parser says the governing rule wants.
/// Hand-written text would let a fixture agree with the page while disagreeing
/// with sops. Only key generation shells out, because there is no in-process
/// keygen — the same compromise `MomentakShapedDotenvIntegrationTests` makes.
///
/// ## The drift is deliberate and specific
/// Rule 0 (`secrets/prod\.sops\.env$`) wants **three** keys through a
/// `key_groups` block; `secrets/prod.sops.env` is encrypted for only
/// studio+laptop, so it reports `.ruleDiffers` — "encrypted for 2 of 3".
/// Rule 1 (`\.sops\.(env|ya?ml|json)$`) wants studio+laptop and
/// `secrets/local.sops.env` has exactly those, so it is `.inSync`. One rule
/// drifted and one in sync is the pair the page's per-rule pill exists to
/// tell apart — a fixture where every rule agrees cannot fail the way a real
/// project does.
@MainActor
enum AccessPageFixture {

    struct KeyPair {
        let `private`: String
        let `public`: String
    }

    struct Project {
        let root: URL
        let keyStore: SessionKeyStore
        /// The drifted file: rule 0 wants three keys, this has two.
        let prod: URL
        /// In sync with rule 1.
        let local: URL
        /// Encrypted, but matched by no rule at all — `nil` unless the
        /// fixture was asked for one.
        let stray: URL?
        /// Drifted under a rule that declares no age recipient, so a rewrap
        /// of it must be refused rather than applied empty. `nil` unless the
        /// fixture was asked for one.
        let legacy: URL?
        let studio: KeyPair
        let laptop: KeyPair
        let vps: KeyPair
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func generateKey() throws -> KeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard
            let tool = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { throw FixtureError("age-keygen not found in \(candidates)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw FixtureError("age-keygen produced no usable key pair")
        }
        return KeyPair(private: priv, public: pub)
    }

    /// - Parameters:
    ///   - includeUngoverned: adds `stray.env` — genuinely encrypted, and
    ///     matched by no `path_regex` in the config. The page has to say so
    ///     somewhere; organised by rule, it would otherwise show the file
    ///     nowhere at all.
    ///   - includeRefusingRule: adds a **first** rule that declares only a
    ///     pgp recipient and no age one, governing `legacy/old.sops.env`.
    ///     Its files drift (the rule wants an empty age set) and re-wrapping
    ///     them must be refused, not applied — `applyToFiles` returns
    ///     `.emptyRecipients`. First on purpose: a rewrap that gave up on the
    ///     first refusal would then never reach `prod`, which is exactly the
    ///     regression `RewrapCoordinatorTests` pins.
    ///   - inlineCatchAllRecipients: writes the catch-all rule's two
    ///     recipients as literal keys rather than aliases, so the rule is not
    ///     `usesAnchors` and the page will offer to edit it. Every rule in
    ///     this fixture goes through anchors otherwise — which is what
    ///     momentak's real config does, and which makes the whole page
    ///     read-only.
    static func momentakShaped(
        includeUngoverned: Bool = false, includeRefusingRule: Bool = false,
        inlineCatchAllRecipients: Bool = false
    ) async throws -> Project {
        let studio = try generateKey()
        let laptop = try generateKey()
        let vps = try generateKey()

        // ⚠️ These URLs are the *unresolved* spelling. On this machine
        // `$TMPDIR` lives under a symlinked `/var`, while
        // `FileManager.enumerator` — what the scanner walks with — hands back
        // `/private/var/…`, and `URL.resolvingSymlinksInPath()` deliberately
        // maps `/private/var` back to `/var`, so there is no spelling that
        // makes both sides equal. Compare by `FileAccess.relativePath` (or
        // `lastPathComponent`), never by `url ==`: the same hazard
        // `ProjectRecipientApplier.ruleMatchingPath` exists for.
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("access-page")

        let catchAllRule = inlineCatchAllRecipients ? """
              - path_regex: \\.sops\\.(env|ya?ml|json)$
                age:
                  - \(studio.public)
                  - \(laptop.public)

            """ : """
              - path_regex: \\.sops\\.(env|ya?ml|json)$
                age:
                  - *studio
                  - *laptop

            """
        // A pgp-only rule: sops accepts it, `ConfigRules.Rule.recipients`
        // (age only) comes back empty, and every file under it therefore
        // reads as drifted against an empty wanted set.
        let refusingRule = includeRefusingRule ? """
              - path_regex: legacy/.*\\.sops\\.env$
                pgp: 85D77543B3D624B63CEA9E6DBC17301B491B3F21

            """ : ""
        let config = """
            keys:
              - &studio \(studio.public)
              - &laptop \(laptop.public)
              - &vps \(vps.public)

            creation_rules:
            """ + "\n" + refusingRule + """
              # Production secrets: everyone, including the deploy host.
              - path_regex: secrets/prod\\.sops\\.env$
                key_groups:
                  - age:
                      - *studio
                      - *laptop
                      - *vps
            """ + "\n" + catchAllRule
        try config.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)

        let prod = secrets.appendingPathComponent("prod.sops.env")
        let local = secrets.appendingPathComponent("local.sops.env")
        // Encrypted for studio+laptop only — rule 0 wants vps too. This is
        // the drift the page has to notice.
        try SopsBridge.encrypt(
            "DATABASE_URL=postgres://prod\n", format: .dotenv,
            recipients: [studio.public, laptop.public]
        ).write(to: prod, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(
            "DATABASE_URL=postgres://local\n", format: .dotenv,
            recipients: [studio.public, laptop.public]
        ).write(to: local, atomically: true, encoding: .utf8)

        var stray: URL?
        if includeUngoverned {
            // Named so no rule's `path_regex` can reach it — it is the
            // `.sops.` infix every rule here keys on that it lacks, not the
            // directory.
            let url = root.appendingPathComponent("stray.env")
            try SopsBridge.encrypt(
                "STRAY=1\n", format: .dotenv, recipients: [studio.public]
            ).write(to: url, atomically: true, encoding: .utf8)
            stray = url
        }

        var legacy: URL?
        if includeRefusingRule {
            let dir = root.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("old.sops.env")
            try SopsBridge.encrypt(
                "LEGACY=1\n", format: .dotenv, recipients: [studio.public]
            ).write(to: url, atomically: true, encoding: .utf8)
            legacy = url
        }

        let keyStore = SessionKeyStore()
        try keyStore.importKey(studio.private)

        return Project(
            root: root, keyStore: keyStore, prod: prod, local: local,
            stray: stray, legacy: legacy,
            studio: studio, laptop: laptop, vps: vps)
    }
}
