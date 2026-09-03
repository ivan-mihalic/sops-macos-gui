import Testing
@testable import SopsUI
import SopsProjects
import SopsHealth

/// SOPS-46. What Settings › Key is allowed to promise now that a key can be
/// written to the Keychain, and what each of the three key states says.
///
/// The first suite here is the one that matters. Until this ticket the app
/// told the user, in three separate places, that it **never** writes their key
/// down — which was true, and which storing a key durably makes false. A
/// feature that quietly turns existing copy into a lie about where a private
/// key lives is worse than the feature is good, and nothing about adding a
/// `SecItemAdd` call fails a build when it happens.
@Suite("Key storage copy tells the truth")
struct KeychainKeyStorageCopyTests {

    /// Every string this app shows about where a key lives. Adding one and
    /// forgetting it here is the way this guard goes quiet, so it lists the
    /// pane's own text wholesale rather than the two lines that happened to
    /// be wrong.
    private static let keyStorageCopy: [(String, String)] = [
        ("key.paste.footer", LocalizedKey.keyPasteFooter.text),
        ("key.paste.no-key-yet", LocalizedKey.keyPasteNoKeyYet.text),
        ("key.ttl.footer", LocalizedKey.keyTTLFooter.text),
        ("key.remember.footer", LocalizedKey.keyRememberFooter.text),
        ("key.unlock-footer", LocalizedKey.keyUnlockFooter.text),
        ("key.status.locked", LocalizedKey.keyStatusLocked.text),
    ]

    /// The three claims that were true before SOPS-46 and are not any more.
    /// Matched case-insensitively on the *claim*, not on the old sentence, so
    /// a reworded relapse ("this app will never write it to disk") is caught
    /// too.
    @Test("no key copy claims the app never writes a key down")
    func noNeverWrittenClaim() {
        let forbidden = ["never written to disk",
                         "never writes it down",
                         "never write it down",
                         "never written down",
                         "memory only",
                         "never on disk"]

        for (id, text) in Self.keyStorageCopy {
            let lowered = text.lowercased()
            for claim in forbidden {
                #expect(lowered.contains(claim) == false, Comment(rawValue: """
                    \(id) still claims "\(claim)". The app can now write the key into the \
                    Keychain when the user asks it to, so this promise is false. Text was: \(text)
                    """))
            }
        }
    }

    /// The other half of honesty: the footer that offers the storage has to
    /// say what storing means. A checkbox reading "Remember this key" with no
    /// statement of where it goes is a consent nobody gave.
    @Test("the remember footer says where the key goes and what guards it")
    func rememberFooterNamesKeychainAndGuard() {
        let footer = LocalizedKey.keyRememberFooter.text.lowercased()

        #expect(footer.contains("keychain"))
        #expect(footer.contains("touch id") || footer.contains("password"))
        // The one property a user is most likely to assume wrongly, and the
        // one that would matter most if it were wrong.
        #expect(footer.contains("icloud") || footer.contains("this mac"))
    }

    @Test("the paste footer still says the key is held for the session")
    func pasteFooterStillNamesTheSession() {
        #expect(LocalizedKey.keyPasteFooter.text.lowercased().contains("session"))
    }

    @Test("the locked status names the Keychain rather than saying no key")
    func lockedStatusIsNotEmptyStatus() {
        let locked = LocalizedKey.keyStatusLocked.text
        #expect(locked != LocalizedKey.keyStatusEmpty.text)
        #expect(locked.lowercased().contains("keychain"))
    }
}

/// The vault-error sentences the pane shows. Each has to be actionable
/// English; `AgeKeyVaultError.failed` is the one with nothing to say and must
/// not paper over that with a status code the reader cannot use.
@Suite("Vault error wording")
struct VaultErrorWordingTests {

    @Test("the missing-entitlement case explains the consequence, not the API")
    func unavailableReasonIsPassedThrough() {
        let reason = KeyImportView.reason(for: .unavailable(reason: "Keychain is off in this build."))

        #expect(reason == "Keychain is off in this build.")
    }

    @Test("no wording quotes an OSStatus number at the user")
    func noStatusCodeInWording() {
        let wording = KeyImportView.reason(for: .failed(status: -34018))

        #expect(wording.contains("34018") == false)
        #expect(wording.isEmpty == false)
    }

    @Test("every vault error produces a non-empty sentence")
    func everyCaseIsWorded() {
        let cases: [AgeKeyVaultError] = [
            .authenticationCancelled,
            .noStoredKey,
            .unreadableStoredKey,
            .unavailable(reason: "because"),
            .failed(status: -1),
        ]

        for error in cases {
            #expect(KeyImportView.reason(for: error).isEmpty == false)
        }
    }
}

/// The wizard's refusal messages, which SOPS-46 gave a third case.
@Suite("Creation refusal for a locked key")
struct LockedKeyCreationMessageTests {

    @Test("a locked key blocks creation with its own sentence")
    func lockedHasItsOwnMessage() throws {
        let locked = try #require(CreationFailurePresenter.message(forEmptyKeyStore: .locked))
        let empty = try #require(CreationFailurePresenter.message(forEmptyKeyStore: .empty))

        #expect(locked.detail != empty.detail)
        // The whole point of the distinction: do not tell somebody holding a
        // key to go and get one.
        #expect(locked.detail.lowercased().contains("unlock"))
        #expect(locked.detail.lowercased().contains("import") == false)
    }

    @Test("a configured key blocks nothing")
    func configuredIsNotBlocked() {
        #expect(CreationFailurePresenter.message(forEmptyKeyStore: .configured) == nil)
    }
}
