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

    static func momentakShaped() async throws -> Project {
        let studio = try generateKey()
        let laptop = try generateKey()
        let vps = try generateKey()

        let root = try ScratchDirectoryRegistry.shared.makeDirectory("access-page")

        let config = """
            keys:
              - &studio \(studio.public)
              - &laptop \(laptop.public)
              - &vps \(vps.public)

            creation_rules:
              # Production secrets: everyone, including the deploy host.
              - path_regex: secrets/prod\\.sops\\.env$
                key_groups:
                  - age:
                      - *studio
                      - *laptop
                      - *vps
              - path_regex: \\.sops\\.(env|ya?ml|json)$
                age:
                  - *studio
                  - *laptop

            """
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

        let keyStore = SessionKeyStore()
        try keyStore.importKey(studio.private)

        return Project(
            root: root, keyStore: keyStore, prod: prod, local: local,
            studio: studio, laptop: laptop, vps: vps)
    }
}
