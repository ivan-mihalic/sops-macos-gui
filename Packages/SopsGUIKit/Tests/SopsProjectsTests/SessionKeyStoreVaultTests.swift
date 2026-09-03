import Foundation
import Testing
@testable import SopsProjects
import SopsHealth
import SopsEngine

/// Same fixture shape as `SessionKeyStoreTests`' — 74 characters, Bech32 body.
/// Deliberately a *different* key from that file's, so a test here can never
/// pass because of something that file's fixture arranged.
private let vaultKey = "AGE-SECRET-KEY-1QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"
private let otherKey = "AGE-SECRET-KEY-1L7AUM6ECHK45NJ3S0WDVT2FG8X9YRZPQL7AUM6ECHK45NJ3S0WDVT2FG8X"

/// A controllable clock. Duplicated from `SessionKeyStoreTests` rather than
/// shared: that one is `private` inside an `@MainActor` suite, and lifting it
/// out to a shared helper is a change to a file this ticket has no other
/// reason to touch.
private final class FakeClock {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(minutes: Int) { current = current.addingTimeInterval(Double(minutes) * 60) }
}

/// SOPS-46. The behaviour this ticket buys: a key that survives a relaunch,
/// reachable again with one user-presence check rather than a re-import.
///
/// Every test here drives `InMemoryAgeKeyVault`, never the Keychain — see
/// that type's doc comment for why the real vault cannot appear in a test
/// process at all.
@Suite("SessionKeyStore + vault")
@MainActor
struct SessionKeyStoreVaultTests {

    // MARK: - The three states

    @Test("with no vault at all, nothing about the store changes")
    func noVaultBehavesAsBefore() throws {
        let store = SessionKeyStore()

        #expect(store.state == .empty)
        try store.importKey(vaultKey)
        #expect(store.state == .configured)
        store.forget()
        // Without a vault there is nothing to fall back to, so `forget()`
        // still means `.empty` — the pre-SOPS-46 contract, unchanged for
        // every caller that does not opt in.
        #expect(store.state == .empty)
    }

    @Test("an empty vault reports empty, not locked")
    func emptyVaultIsEmpty() {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault())

        #expect(store.state == .empty)
    }

    @Test("a vault holding a key reports locked before anything is unlocked")
    func storedKeyIsLocked() {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault(storedKey: vaultKey))

        #expect(store.state == .locked)
        // Locked is not usable: nothing is lent out until the user presence
        // check has actually happened.
        #expect(store.withKey { $0 } == nil)
    }

    @Test("unlocking makes the stored key usable")
    func unlockMakesKeyUsable() async throws {
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        let store = SessionKeyStore(vault: vault)

        try await store.unlock()

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == vaultKey)
    }

    /// The whole point of "once per launch": a second unlock while a key is
    /// already in memory must not put another Touch ID prompt in front of the
    /// user. `loadCount` is the only way to see that from outside.
    @Test("unlocking twice authenticates only once")
    func unlockIsIdempotentWhileConfigured() async throws {
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        let store = SessionKeyStore(vault: vault)

        try await store.unlock()
        try await store.unlock()

        #expect(vault.loadCount == 1)
        #expect(store.state == .configured)
    }

    // MARK: - What forget means now

    /// Sleep-lock (`AppDelegate`'s `NSWorkspace.willSleepNotification`) calls
    /// `forget()`. After SOPS-46 that must land on `.locked`, not `.empty` —
    /// waking the Mac has to cost a Touch ID, not a re-import.
    @Test("forget drops to locked when the vault still holds the key")
    func forgetDropsToLocked() async throws {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault(storedKey: vaultKey))
        try await store.unlock()

        store.forget()

        #expect(store.state == .locked)
        #expect(store.withKey { $0 } == nil)
    }

    @Test("forgetting permanently empties the vault as well")
    func forgetPermanentlyClearsVault() async throws {
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        let store = SessionKeyStore(vault: vault)
        try await store.unlock()

        try store.forgetPermanently()

        #expect(store.state == .empty)
        #expect(vault.hasStoredKey() == false)
    }

    // MARK: - TTL

    /// The TTL decision for this ticket, stated as a test: expiry keeps its
    /// exact old meaning (the key leaves memory on schedule) and only its
    /// consequence changes (`.locked`, so the way back is Touch ID).
    @Test("an expired key falls back to locked, and unlocking authenticates again")
    func expiryFallsBackToLocked() async throws {
        let clock = FakeClock()
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        let store = SessionKeyStore(vault: vault, now: clock.now, ttlMinutes: { 15 })
        try await store.unlock()

        clock.advance(minutes: 16)

        #expect(store.state == .locked)
        #expect(store.withKey { $0 } == nil)

        try await store.unlock()

        #expect(store.state == .configured)
        #expect(vault.loadCount == 2)
    }

    /// An unlock has to start the TTL clock the same way an import does —
    /// otherwise a key restored from the vault would sit in memory forever,
    /// which is the opposite of what the TTL exists for.
    @Test("unlocking starts a fresh TTL")
    func unlockStartsTTL() async throws {
        let clock = FakeClock()
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault(storedKey: vaultKey),
                                    now: clock.now, ttlMinutes: { 10 })

        try await store.unlock()
        clock.advance(minutes: 9)
        #expect(store.state == .configured)

        clock.advance(minutes: 2)
        #expect(store.state == .locked)
    }

    // MARK: - Remembering at import time

    @Test("importing without remember leaves the vault untouched")
    func importDoesNotRememberByDefault() throws {
        let vault = InMemoryAgeKeyVault()
        let store = SessionKeyStore(vault: vault)

        try store.importKey(vaultKey)

        #expect(store.state == .configured)
        #expect(vault.hasStoredKey() == false)
        // And so the fallback after a sleep is `.empty`, exactly as it was
        // before this ticket — opting out has to mean opting out.
        store.forget()
        #expect(store.state == .empty)
    }

    @Test("importing with remember puts the key in the vault")
    func importRemembers() throws {
        let vault = InMemoryAgeKeyVault()
        let store = SessionKeyStore(vault: vault)

        try store.importKey(vaultKey, remember: true)

        #expect(vault.storedKeyForTesting == vaultKey)
        store.forget()
        #expect(store.state == .locked)
    }

    @Test("remembering a second key replaces the first")
    func importReplacesStoredKey() throws {
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        let store = SessionKeyStore(vault: vault)

        try store.importKey(otherKey, remember: true)

        #expect(vault.storedKeyForTesting == otherKey)
    }

    /// A vault that refuses to save must not cost the user the import they
    /// just made: the key is valid and in memory, only its persistence
    /// failed. `importKey` reports that as a returned warning rather than by
    /// throwing, because throwing would roll back an import that in fact
    /// succeeded.
    @Test("a failing vault does not fail the import")
    func storeFailureDoesNotFailImport() throws {
        let vault = InMemoryAgeKeyVault()
        vault.failStore(with: .unavailable(reason: "no entitlement"))
        let store = SessionKeyStore(vault: vault)

        let warning = try store.importKey(vaultKey, remember: true)

        #expect(store.state == .configured)
        #expect(store.withKey { $0 } == vaultKey)
        #expect(warning == .unavailable(reason: "no entitlement"))
    }

    @Test("a successful import reports no warning")
    func successfulImportHasNoWarning() throws {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault())

        #expect(try store.importKey(vaultKey, remember: true) == nil)
    }

    // MARK: - Unlock failures

    @Test("a cancelled unlock leaves the store locked and re-unlockable")
    func cancelledUnlockStaysLocked() async throws {
        let vault = InMemoryAgeKeyVault(storedKey: vaultKey)
        vault.failNextLoad(with: .authenticationCancelled)
        let store = SessionKeyStore(vault: vault)

        await #expect(throws: AgeKeyVaultError.authenticationCancelled) {
            try await store.unlock()
        }
        #expect(store.state == .locked)

        try await store.unlock()

        #expect(store.state == .configured)
    }

    /// A vault holding something that is not an age key must fail the same
    /// way a bad paste does — with this store's own error, not a vault error
    /// the import UI has no message for. The key stays in the vault: deleting
    /// a user's stored item because this app could not parse it is a
    /// mutation nobody asked for.
    @Test("a vault holding a non-key fails with the store's own error")
    func vaultHoldingGarbageIsRefused() async throws {
        let vault = InMemoryAgeKeyVault(storedKey: "hunter2")
        let store = SessionKeyStore(vault: vault)

        await #expect(throws: SessionKeyStore.Error.notAnAgeKey) {
            try await store.unlock()
        }
        #expect(store.state == .locked)
        #expect(vault.hasStoredKey() == true)
    }

    @Test("unlocking an empty vault reports no stored key")
    func unlockingEmptyVaultFails() async {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault())

        await #expect(throws: AgeKeyVaultError.noStoredKey) {
            try await store.unlock()
        }
        #expect(store.state == .empty)
    }

    // MARK: - Public key

    /// `sessionPublicKey` is what the file list uses to tell read-only
    /// ciphertext from a file this key can open. It has to be derived on the
    /// unlock path too, not only on import — otherwise every file looks
    /// read-only after a relaunch.
    @Test("unlocking derives the session public key, like importing does")
    func unlockDerivesPublicKey() async throws {
        let real = try SopsBridge.generateAgeKey()
        let vault = InMemoryAgeKeyVault(storedKey: real.privateKey)
        let store = SessionKeyStore(vault: vault)

        try await store.unlock()

        #expect(store.sessionPublicKey == real.publicKey)
    }
}
