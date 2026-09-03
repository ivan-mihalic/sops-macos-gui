import Foundation
import Testing
@testable import SopsUI
import SopsEngine
import SopsProjects

/// SOPS-46 / SOPS-48. The editor's answer to "I cannot read this file yet" has
/// to match *why*.
///
/// The bug this closes was in SOPS-46's own first cut: `withKey` returns `nil`
/// both when nothing is imported and when a stored key is locked, and the
/// editor collapsed both into `.needsKey` — *"No decryption key configured —
/// Add your age private key in Settings › Key"*. Told to somebody whose key is
/// sitting in their Keychain, that is the app failing to know its own state and
/// sending them off to redo work they have already done.
@Suite("The editor tells a locked key apart from a missing one")
@MainActor
struct LockedKeyEditorStateTests {

    /// 74 characters, Bech32 body — the shape `importKey` requires. Never
    /// decrypts anything, and is not asked to: every test here stops before a
    /// bridge call, which is the whole point of both states under test.
    private static let storedKey =
        "AGE-SECRET-KEY-1QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"

    private func model(keyStore: SessionKeyStore) -> SecretDocumentViewModel {
        SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/locked.yaml"),
            format: .yaml,
            keyStore: keyStore,
            readFile: { _ in "sops:\n  version: 3.9.0\n" })
    }

    @Test("an empty key store still reports needsKey")
    func emptyStoreNeedsKey() async {
        let model = model(keyStore: SessionKeyStore())

        await model.load()

        #expect(model.loadState == .needsKey)
    }

    @Test("a locked key store reports needsUnlock, not needsKey")
    func lockedStoreNeedsUnlock() async {
        let store = SessionKeyStore(vault: InMemoryAgeKeyVault(storedKey: Self.storedKey))
        let model = model(keyStore: store)

        await model.load()

        #expect(model.loadState == .needsUnlock)
    }

    /// The recovery this state exists to offer: one press, and the document
    /// gets as far as it would have with the key imported by hand. It cannot
    /// reach `.loaded` here — the fixture's key decrypts nothing — but it must
    /// leave `.needsUnlock`, which is what proves the unlock happened and the
    /// load was retried rather than skipped.
    @Test("unlocking from the editor retries the load")
    func unlockingRetriesTheLoad() async {
        let vault = InMemoryAgeKeyVault(storedKey: Self.storedKey)
        let store = SessionKeyStore(vault: vault)
        let model = model(keyStore: store)
        await model.load()
        #expect(model.loadState == .needsUnlock)

        await model.unlockAndReload()

        #expect(store.state == .configured)
        #expect(model.loadState != .needsUnlock)
        #expect(model.loadState != .needsKey)
        #expect(vault.loadCount == 1)
    }

    /// Cancelling has to be a no-op, not an error. The user changed their mind;
    /// nothing failed, nothing was lost, and the button is still there.
    @Test("cancelling the prompt leaves the editor exactly where it was")
    func cancellingChangesNothing() async {
        let vault = InMemoryAgeKeyVault(storedKey: Self.storedKey)
        vault.failNextLoad(with: .authenticationCancelled)
        let store = SessionKeyStore(vault: vault)
        let model = model(keyStore: store)
        await model.load()

        await model.unlockAndReload()

        #expect(model.loadState == .needsUnlock)
        #expect(store.state == .locked)
    }

    /// The two states must not share their wording, or the distinction exists
    /// only in the type system and never reaches the person reading the screen.
    @Test("the two states say different things, and only one mentions importing")
    func theCopyIsActuallyDifferent() {
        let needsKey = LocalizedKey.editorNeedsKeyBody.text
        let needsUnlock = LocalizedKey.editorNeedsUnlockBody.text

        #expect(needsKey != needsUnlock)
        #expect(needsUnlock.lowercased().contains("unlock"))
        #expect(needsUnlock.lowercased().contains("keychain"))
        // The exact instruction that was wrong for a locked key.
        #expect(needsUnlock.contains("Settings › Key") == false)
    }
}
