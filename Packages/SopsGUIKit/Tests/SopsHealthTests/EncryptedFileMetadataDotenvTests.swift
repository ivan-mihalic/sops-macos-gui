import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

/// `EncryptedFileMetadata` learning the dotenv metadata shape, Task 5
/// (SOPS-38). Mirrors `ProjectHealthCheckRealBridgeTests.swift` (age
/// recipients, via the real in-process bridge — never a hand-typed
/// `sops_age__list_0__map_recipient=` string) and
/// `ProjectHealthCheckNonAgeBackendTests.swift`'s `BackendFixtures` pattern
/// (non-age backends, as static fixtures — the bridge only ever encrypts to
/// age recipients, so pgp/kms/key_groups dotenv output cannot be produced
/// in-process and has to be the literal shape sops's own flattener writes,
/// verified against `stores/flatten.go`/`stores/stores.go` in the pinned
/// getsops/sops v3.13.3 source — see `EncryptedFileMetadata.swift`'s own
/// doc comments for the citations).
///
/// The real-bridge fixture below was captured once, by hand, against
/// `SopsBridge.encrypt("FOO=bar\nBAZ=qux\n", format: .dotenv, recipients:
/// [key])`, to pin down the exact shape these tests assume:
/// ```
/// FOO=ENC[...]
/// BAZ=ENC[...]
/// sops_age__list_0__map_enc=-----BEGIN AGE ENCRYPTED FILE-----\n...
/// sops_age__list_0__map_recipient=age1...
/// sops_lastmodified=2026-09-01T08:02:32Z
/// sops_mac=ENC[...]
/// sops_unencrypted_suffix=_unencrypted
/// sops_version=3.13.3
/// ```
/// — no `sops:` line anywhere, one `sops_`-prefixed `KEY=value` line at
/// column 0 per metadata field, `age` entries flattened as
/// `sops_age__list_<n>__map_<field>=`.
@Suite("EncryptedFileMetadata reads dotenv metadata")
struct EncryptedFileMetadataDotenvTests {

    @Test("age recipients round-trip through the real bridge's dotenv output")
    func recipientsRoundTripThroughTheRealBridge() throws {
        let key1 = try ProjectFixture.ageKeyPair()
        let key2 = try ProjectFixture.ageKeyPair()

        let encrypted = try ProjectFixture.encryptedDotenv(
            "DB_PASSWORD=hunter2\nAPI_KEY=sk-live-abc123\n", to: [key1.public, key2.public])

        let recipients = EncryptedFileMetadata.recipients(inEncryptedFile: encrypted)

        #expect(Set(recipients) == Set([key1.public, key2.public]))
        #expect(!encrypted.contains("hunter2"))
    }

    @Test("a real dotenv file with only age protection has no non-age backend")
    func realDotenvFileHasNoNonAgeBackend() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedDotenv("FOO=bar\n", to: [key.public])

        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }

    @Test("a single age recipient in dotenv metadata is read back exactly")
    func singleRecipient() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedDotenv("FOO=bar\nBAZ=qux\n", to: [key.public])

        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: encrypted) == [key.public])
    }

    // MARK: - Non-age backends, as static fixtures (the bridge cannot
    // encrypt to pgp/kms/key_groups) — the literal shape sops's dotenv
    // flattener writes, per `stores/flatten.go`'s `flattenTreeBranch` and
    // `stores/stores.go`'s `mapstructure` field names.

    @Test("pgp is recognised by its flattened field name, with no age recipient")
    func pgpBackend() {
        let text = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_pgp__list_0__map_fp=0000000000000000000000000000000000AAAA
        sops_pgp__list_0__map_created_at=2026-08-06T00:00:00Z
        sops_pgp__list_0__map_enc=notarealpgpmessage==
        sops_lastmodified=2026-08-06T00:00:00Z
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["pgp"])
    }

    @Test("kms, gcp_kms, azure_kv, and hc_vault are each recognised by their real flattened field name")
    func otherBackends() {
        let kms = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_kms__list_0__map_arn=arn:aws:kms:us-east-1:000000000000:key/test
        sops_kms__list_0__map_enc=AQICAHhexamplenotreal==
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        let gcpKMS = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_gcp_kms__list_0__map_resource_id=projects/test/locations/global/keyRings/test/cryptoKeys/test
        sops_gcp_kms__list_0__map_enc=CiQAexamplenotreal==
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        let azureKV = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_azure_kv__list_0__map_vault_url=https://test.vault.azure.net
        sops_azure_kv__list_0__map_name=test-key
        sops_azure_kv__list_0__map_enc=notarealencrypteddatakey==
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        let hcVault = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_hc_vault__list_0__map_vault_address=https://vault.example.invalid:8200
        sops_hc_vault__list_0__map_engine_path=transit
        sops_hc_vault__list_0__map_enc=vault:v1:notarealencrypteddatakey==
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: kms) == ["kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: gcpKMS) == ["gcp_kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: azureKV) == ["azure_kv"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: hcVault) == ["hc_vault"])
    }

    /// `key_groups` is flagged wholesale, mirroring the YAML reader: a
    /// deeply-nested `sops_key_groups__list_0__map_pgp__list_0__map_fp=`
    /// line reduces to the top-level segment `key_groups`, not `pgp` — see
    /// `EncryptedFileMetadata.dotenvTopLevelSegment(of:)`'s doc comment.
    @Test("key_groups is recognised even when the group also contains a real age recipient")
    func keyGroupsWithMixedAge() throws {
        let key = try ProjectFixture.ageKeyPair()
        let text = """
        password=ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops_key_groups__list_0__map_pgp__list_0__map_fp=0000000000000000000000000000000000AAAA
        sops_key_groups__list_0__map_pgp__list_0__map_enc=notarealpgpmessage==
        sops_key_groups__list_0__map_age__list_0__map_recipient=\(key.public)
        sops_key_groups__list_0__map_age__list_0__map_enc=notarealagekey==
        sops_mac=ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        sops_version=3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["key_groups"])
        // Nested inside a key group, so `recipients(inEncryptedFile:)` does
        // not see it — its key is `sops_key_groups__...__map_recipient`, not
        // `sops_age__...__map_recipient`, matching the YAML reader's own
        // `key_groups` handling one section up.
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
    }

    @Test("a plaintext field named kms in the user's own dotenv data is not mistaken for sops metadata")
    func ownDataFieldNamedLikeABackendIsIgnored() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedDotenv("KMS=ENC[not-real]\nFOO=bar\n", to: [key.public])

        // The user's own `KMS=` line has no `sops_` prefix, so it is never a
        // candidate metadata line in the first place.
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }
}
