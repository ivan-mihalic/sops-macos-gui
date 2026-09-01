import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

/// `EncryptedFileMetadata` learning the INI metadata shape, SOPS-38 phase
/// F2 task 3. Mirrors `EncryptedFileMetadataDotenvTests.swift` (age
/// recipients, via the real in-process bridge — `SopsBridge.encrypt(_:
/// format: .ini, recipients:)`, F2 task 2 — never a hand-typed `[sops]`
/// section) and `ProjectHealthCheckNonAgeBackendTests`'s `BackendFixtures`
/// pattern (non-age backends: the bridge only ever encrypts to age
/// recipients, so pgp/kms/key_groups INI output cannot be produced
/// in-process and has to be the literal flattened shape sops's own store
/// writes, per `stores/stores.go`'s field names — the same source
/// `EncryptedFileMetadata.swift`'s own INI doc comments cite — flattened
/// below a `[sops]` section header the way `EncryptedFileMetadata
/// .iniSopsBlockLines`'s doc comment describes, verified against the real
/// `sops` CLI once by hand).
///
/// Every fixture here holds its plaintext data in an ordinary `[data]`
/// section — the INI store's root must stay sections (a bare top-level key
/// has nowhere to live), matching every real `sops`-written INI document.
@Suite("EncryptedFileMetadata reads INI metadata")
struct EncryptedFileMetadataINITests {

    @Test("age recipients round-trip through the real bridge's INI output")
    func recipientsRoundTripThroughTheRealBridge() throws {
        let key1 = try ProjectFixture.ageKeyPair()
        let key2 = try ProjectFixture.ageKeyPair()

        let encrypted = try ProjectFixture.encryptedINI(
            "[data]\npassword = hunter2\napi_key = sk-live-abc123\n", to: [key1.public, key2.public])

        let recipients = EncryptedFileMetadata.recipients(inEncryptedFile: encrypted)

        #expect(Set(recipients) == Set([key1.public, key2.public]))
        #expect(!encrypted.contains("hunter2"))
    }

    @Test("a real INI file with only age protection has no non-age backend")
    func realINIFileHasNoNonAgeBackend() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedINI("[data]\nfoo = bar\n", to: [key.public])

        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }

    @Test("a single age recipient in INI metadata is read back exactly")
    func singleRecipient() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedINI("[data]\nfoo = bar\nbaz = qux\n", to: [key.public])

        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: encrypted) == [key.public])
    }

    // MARK: - Non-age backends, as static fixtures (the bridge cannot
    // encrypt to pgp/kms/key_groups) — the literal flattened shape sops's
    // INI store writes below its `[sops]` section, per `stores/stores.go`'s
    // struct field names, the same source `EncryptedFileMetadataJSONTests`
    // cites for the identical fields' JSON shape.

    @Test("pgp is recognised by its flattened field name, with no age recipient")
    func pgpBackend() {
        let text = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        pgp__list_0__map_fp         = 0000000000000000000000000000000000AAAA
        pgp__list_0__map_created_at = 2026-08-06T00:00:00Z
        pgp__list_0__map_enc        = notarealpgpmessage==
        lastmodified                = 2026-08-06T00:00:00Z
        mac                         = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version                     = 3.13.3
        """
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["pgp"])
    }

    @Test("kms, gcp_kms, azure_kv, and hc_vault are each recognised by their real flattened field name")
    func otherBackends() {
        let kms = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        kms__list_0__map_arn = arn:aws:kms:us-east-1:000000000000:key/test
        kms__list_0__map_enc = AQICAHhexamplenotreal==
        mac                  = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version              = 3.13.3
        """
        let gcpKMS = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        gcp_kms__list_0__map_resource_id = projects/test/locations/global/keyRings/test/cryptoKeys/test
        gcp_kms__list_0__map_enc         = CiQAexamplenotreal==
        mac                              = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version                          = 3.13.3
        """
        let azureKV = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        azure_kv__list_0__map_vault_url = https://test.vault.azure.net
        azure_kv__list_0__map_name      = test-key
        azure_kv__list_0__map_enc       = notarealencrypteddatakey==
        mac                              = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version                          = 3.13.3
        """
        let hcVault = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        hc_vault__list_0__map_vault_address = https://vault.example.invalid:8200
        hc_vault__list_0__map_engine_path   = transit
        hc_vault__list_0__map_enc           = vault:v1:notarealencrypteddatakey==
        mac                                  = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version                              = 3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: kms) == ["kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: gcpKMS) == ["gcp_kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: azureKV) == ["azure_kv"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: hcVault) == ["hc_vault"])
    }

    /// `key_groups` is flagged wholesale, mirroring the YAML/dotenv/JSON
    /// readers — see `EncryptedFileMetadataJSONTests.keyGroupsWithMixedAge`'s
    /// doc comment for why a real single-group all-age file never actually
    /// reaches this shape.
    @Test("key_groups is recognised even when the group also contains a real age recipient")
    func keyGroupsWithMixedAge() throws {
        let key = try ProjectFixture.ageKeyPair()
        let text = """
        [data]
        password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]

        [sops]
        key_groups__list_0__map_pgp__list_0__map_fp = 0000000000000000000000000000000000AAAA
        key_groups__list_0__map_pgp__list_0__map_enc = notarealpgpmessage==
        key_groups__list_0__map_age__list_0__map_recipient = \(key.public)
        key_groups__list_0__map_age__list_0__map_enc = notarealagekey==
        mac = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version = 3.13.3
        """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: text) == ["key_groups"])
        // Nested inside a key group, so `recipients(inEncryptedFile:)` does
        // not see it — its key is `key_groups__...__map_recipient`, not
        // `age__...__map_recipient`, matching the dotenv reader's own
        // `key_groups` handling one section up.
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: text).isEmpty)
    }

    @Test("a plaintext field named kms in the user's own INI data is not mistaken for sops metadata")
    func ownDataFieldNamedLikeABackendIsIgnored() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try ProjectFixture.encryptedINI("[data]\nkms = ENC[not-real]\nfoo = bar\n", to: [key.public])

        // The user's own "kms" key lives in the `[data]` section, never in
        // `[sops]`, so it is never a candidate metadata line in the first
        // place — `iniSopsBlockLines` only ever scans lines after the last
        // `[sops]` header.
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: encrypted).isEmpty)
    }

    // No "explicitly empty backend" test here, unlike the YAML/JSON
    // suites: INI's flattened shape has no `[]`/`{}` literal to write in
    // the first place — sops's flattener never emits a key for an empty
    // list at all (see `nonAgeBackendsFromINI`'s doc comment), so an empty
    // backend and an absent one are the same shape on disk, already covered
    // by `realINIFileHasNoNonAgeBackend` above.
}
