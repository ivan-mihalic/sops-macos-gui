import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

/// `EncryptedFileMetadata` learning the JSON metadata shape, SOPS-38 phase
/// F2 task 3. Mirrors `EncryptedFileMetadataDotenvTests.swift` (age
/// recipients, via the real in-process bridge — `SopsBridge.encrypt(_:
/// format: .json, recipients:)`, F2 task 2 — never a hand-typed `"sops":
/// {...}` object) and `ProjectHealthCheckNonAgeBackendTests`'s
/// `BackendFixtures` pattern (non-age backends: the bridge only ever
/// encrypts to age recipients, so pgp/kms/key_groups JSON output cannot be
/// produced in-process and has to be the literal shape sops's own store
/// writes, verified against `stores/stores.go` in the pinned getsops/sops
/// v3.13.3 source — the exact same struct field names
/// `EncryptedFileMetadata.swift`'s own JSON doc comments cite).
///
/// The real-bridge fixture cited in `EncryptedFileMetadata.jsonSopsBlock`'s
/// doc comment was captured once, by hand, against the real `sops` CLI to
/// see the genuine multi-recipient shape; the tests below round-trip
/// through the real in-process bridge instead, which also supports more
/// than one recipient.
@Suite("EncryptedFileMetadata reads JSON metadata")
struct EncryptedFileMetadataJSONTests {

    @Test("age recipients round-trip through the real bridge's JSON output")
    func recipientsRoundTripThroughTheRealBridge() throws {
        let key1 = try ProjectFixture.ageKeyPair()
        let key2 = try ProjectFixture.ageKeyPair()

        let encrypted = try ProjectFixture.encryptedJSON(
            "{\"db_password\": \"hunter2\", \"api_key\": \"sk-live-abc123\"}", to: [key1.public, key2.public])

        let recipients = EncryptedFileMetadata.recipients(inEncryptedFile: encrypted)

        #expect(Set(recipients) == Set([key1.public, key2.public]))
        #expect(!encrypted.contains("hunter2"))
    }

    @Test("a real JSON file with only age protection has no non-age backend")
    func realJSONFileHasNoNonAgeBackend() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedJSON("{\"foo\": \"bar\"}", to: [key.public])

        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }

    @Test("a single age recipient in JSON metadata is read back exactly")
    func singleRecipient() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedJSON("{\"foo\": \"bar\", \"baz\": \"qux\"}", to: [key.public])

        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: encrypted) == [key.public])
    }

    // MARK: - Non-age backends, as static fixtures (the bridge cannot
    // encrypt to pgp/kms/key_groups) — the literal shape sops's JSON store
    // writes, per `stores/stores.go`'s `pgpkey`/`kmskey`/`gcpkmskey`/
    // `vaultkey`/`azkvkey` struct field names (`mapstructure` tags), the
    // same source `EncryptedFileMetadataDotenvTests` cites for the dotenv
    // shape of the identical fields.

    private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"

    @Test("pgp is recognised by its real field name, with no age recipient")
    func pgpBackend() {
        let text = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "pgp": [
              {"fp": "0000000000000000000000000000000000AAAA", "created_at": "2026-08-06T00:00:00Z", "enc": "notarealpgpmessage=="}
            ],
            "lastmodified": "2026-08-06T00:00:00Z",
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["pgp"])
    }

    @Test("kms, gcp_kms, azure_kv, and hc_vault are each recognised by their real field name")
    func otherBackends() {
        let kms = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "kms": [
              {"arn": "arn:aws:kms:us-east-1:000000000000:key/test", "created_at": "2026-08-06T00:00:00Z", "enc": "AQICAHhexamplenotreal==", "aws_profile": ""}
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        let gcpKMS = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "gcp_kms": [
              {"resource_id": "projects/test/locations/global/keyRings/test/cryptoKeys/test", "created_at": "2026-08-06T00:00:00Z", "enc": "CiQAexamplenotreal=="}
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        let azureKV = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "azure_kv": [
              {"vault_url": "https://test.vault.azure.net", "name": "test-key", "version": "0000000000000000000000000000000", "created_at": "2026-08-06T00:00:00Z", "enc": "notarealencrypteddatakey=="}
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        let hcVault = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "hc_vault": [
              {"vault_address": "https://vault.example.invalid:8200", "engine_path": "transit", "key_name": "test", "created_at": "2026-08-06T00:00:00Z", "enc": "vault:v1:notarealencrypteddatakey=="}
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: kms) == ["kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: gcpKMS) == ["gcp_kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: azureKV) == ["azure_kv"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: hcVault) == ["hc_vault"])
    }

    /// `key_groups` is flagged wholesale, mirroring the YAML/dotenv readers:
    /// sops writes a real `key_groups:` wrapper only for two or more groups
    /// (Shamir) — a single all-age group writes a plain top-level `age:`
    /// array instead, with no `key_groups` key at all (see
    /// `ProjectHealthCheckDeclaredBackendTests
    /// .ageOnlyKeyGroupStillReportsOK`'s doc comment). This fixture pins the
    /// multi-group shape.
    @Test("key_groups is recognised even when the group also contains a real age recipient")
    func keyGroupsWithMixedAge() throws {
        let key = try ProjectFixture.ageKeyPair()
        let text = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "key_groups": [
              {
                "pgp": [
                  {"fp": "0000000000000000000000000000000000AAAA", "created_at": "2026-08-06T00:00:00Z", "enc": "notarealpgpmessage=="}
                ],
                "age": [
                  {"recipient": "\(key.public)", "enc": "notarealagekey=="}
                ]
              }
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["key_groups"])
        // Nested inside a key group, so `recipients(inEncryptedFile:)` does
        // not see it — it only reads the top-level `sops.age` array, not
        // `sops.key_groups[].age`, matching the dotenv reader's identical
        // choice (`EncryptedFileMetadataDotenvTests.keyGroupsWithMixedAge`)
        // to flag `key_groups` wholesale rather than partially trust what is
        // nested inside it.
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
    }

    @Test("a plaintext field named kms in the user's own JSON data is not mistaken for sops metadata")
    func ownDataFieldNamedLikeABackendIsIgnored() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedJSON(
            "{\"kms\": \"not-a-real-backend-this-is-a-plaintext-field\", \"foo\": \"bar\"}", to: [key.public])

        // The user's own top-level "kms" field sits beside "sops", never
        // inside it — `jsonSopsBlock` only ever reads `object["sops"]`, so
        // there is no scope-creep hazard here the way there is for the
        // line-scanning YAML/dotenv/INI readers.
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }

    @Test("an explicitly empty backend, pgp: [], is not flagged")
    func explicitlyEmptyBackendIsNotFlagged() {
        let text = """
        {
          "password": "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]",
          "sops": {
            "pgp": [],
            "age": [
              {"recipient": "\(devKey)", "enc": "notarealagekey=="}
            ],
            "mac": "ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]",
            "version": "3.13.3"
          }
        }
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text).isEmpty)
    }
}
