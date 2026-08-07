import Foundation
import Testing

@testable import SopsEngine

/// `lookupCreationRule` answers "which rule governs *this file*", so a rule
/// with no matching file is invisible to it. `inspectConfigBackends` is the
/// whole-config counterpart: which key backends does this `.sops.yaml` name
/// anywhere, files or no files.
@Suite("SopsBridge.inspectConfigBackends")
struct ConfigBackendsTests {

    @Test("an age-only config declares no backend this app cannot read")
    func ageOnly() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key.public)
        """)

        #expect(try SopsBridge.inspectConfigBackends(configPath: dir.path).backends.isEmpty)
    }

    @Test("a pgp rule with no matching file anywhere is still reported")
    func pgpWithNoFiles() throws {
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            pgp: 0000000000000000000000000000000000AAAA
        """)

        #expect(try SopsBridge.inspectConfigBackends(configPath: dir.path).backends == ["pgp"])
    }

    @Test("a healthy age rule alongside a pgp rule does not hide the pgp rule")
    func mixedConfig() throws {
        let key = try AgeKeyPair.generate()
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(key.public)
          - path_regex: legacy/.*\\.yaml$
            pgp: 0000000000000000000000000000000000AAAA
        """)

        #expect(try SopsBridge.inspectConfigBackends(configPath: dir.path).backends == ["pgp"])
    }

    @Test("cloud backends come back under the same identifiers a rule lookup uses")
    func cloudBackends() throws {
        let dir = try TempFile(named: ".sops.yaml", contents: """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            kms: arn:aws:kms:us-east-1:000000000000:key/test
            hc_vault_transit_uri: https://vault.example.invalid:8200/v1/transit/keys/test
        """)

        #expect(try SopsBridge.inspectConfigBackends(configPath: dir.path).backends == ["hc_vault", "kms"])
    }

    @Test("a malformed config throws rather than reporting no backends")
    func malformed() throws {
        let dir = try TempFile(named: ".sops.yaml", contents: "creation_rules:\n  - this: [is: not: valid\n")

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.inspectConfigBackends(configPath: dir.path)
        }
    }
}
