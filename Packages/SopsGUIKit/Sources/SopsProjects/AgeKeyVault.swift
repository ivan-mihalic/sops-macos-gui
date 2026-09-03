import Foundation

/// Durable storage for the one age identity this app decrypts with, behind
/// whatever the platform offers as a user-presence gate.
///
/// This exists so `SessionKeyStore` can gain "the key survives a relaunch"
/// without gaining a single line of `SecItem`. Everything above this protocol
/// deals in four verbs and an error; the Keychain, `SecAccessControl`,
/// `LAContext` and their `OSStatus` vocabulary live entirely in
/// `KeychainAgeKeyVault` on the other side of it.
///
/// ## Why `hasStoredKey()` is separate from `loadKey()`
/// The app has to be able to say "there is a key here, unlock it" on launch
/// **without** putting a Touch ID prompt in front of someone who opened the
/// window to read a filename. Those are two different questions — *is there
/// one* and *give it to me* — and only the second one is allowed to
/// authenticate. Fusing them into a single `loadKey() -> String?` would mean
/// every `state` read triggers biometry, which is precisely the shape this
/// app decided against (see the ticket: unlock once per launch, not once per
/// use).
///
/// ## Why this is not `async`
/// `loadKey()` blocks on a Touch ID prompt, which is exactly the kind of call
/// that should be `async` — and `SecItemCopyMatching` is nonetheless
/// synchronous and has no async twin. Making the protocol `async` would be
/// dressing a blocking call in a suit; the caller (`SessionKeyStore.unlock()`)
/// is `async` and hops off the main actor around this, which is where the
/// concurrency actually belongs.
public protocol AgeKeyVault: Sendable {

    /// Whether a key is stored, asked in a way that must **never**
    /// authenticate the user.
    ///
    /// Returns `false` — never throws — when the answer cannot be obtained.
    /// A vault that cannot be reached is indistinguishable, from every
    /// caller's point of view, from a vault with nothing in it: both mean
    /// "there is nothing here to unlock", and an error case would only give
    /// the UI a third thing to render that it cannot act on differently.
    func hasStoredKey() -> Bool

    /// Returns the stored identity, authenticating the user first.
    ///
    /// This is the call that shows the Touch ID prompt. Throws
    /// `AgeKeyVaultError` for every outcome that is not "here is the key",
    /// including the user cancelling — see that type for why cancellation is
    /// an error case rather than an optional return.
    func loadKey() throws -> String

    /// Stores `key`, replacing whatever was there.
    ///
    /// Only ever called with a key `SessionKeyStore.importKey` has already
    /// accepted the shape of, so this does no validation of its own.
    func store(_ key: String) throws

    /// Removes the stored identity. Not an error when there was none.
    func removeStoredKey() throws
}

/// What a vault is allowed to fail with.
///
/// A closed set rather than a passthrough of `OSStatus`, for the same reason
/// `SecurityPostureCheck`'s providers report facts rather than verdicts: the
/// UI has to say something specific and useful for each of these, and a raw
/// status code is neither. `KeychainAgeKeyVault` maps the codes it actually
/// sees onto these and carries the rest in `.failed(status:)` — which is a
/// number in a log line, not a sentence shown to anyone.
public enum AgeKeyVaultError: Swift.Error, Equatable, Sendable {

    /// The user dismissed the Touch ID prompt, or authentication failed.
    ///
    /// Its own case, and deliberately not folded into "no key": the key is
    /// still there and the right thing for the UI to offer is the unlock
    /// button again, not an import form. Returning `nil` from `loadKey()`
    /// would have erased exactly that distinction.
    case authenticationCancelled

    /// There is nothing stored. Distinct from `.authenticationCancelled`:
    /// nothing was asked of the user, and nothing will be until a key is
    /// imported with "remember" turned on.
    case noStoredKey

    /// The stored bytes are not a UTF-8 string — a vault item written by
    /// something other than this app, or corrupted in place. Never carries
    /// the bytes.
    case unreadableStoredKey

    /// This machine cannot store a key behind user presence at all: no
    /// biometry and no password fallback available to `SecAccessControl`,
    /// or — the case that will bite first — the app is missing the
    /// `keychain-access-groups` entitlement the data-protection keychain
    /// requires (`errSecMissingEntitlement`, -34018).
    ///
    /// `reason` is shown to the user, so it says what to do rather than
    /// naming an API.
    case unavailable(reason: String)

    /// Anything else the platform reported. `status` is for a log line and a
    /// bug report; it is never the whole of what the user is shown.
    case failed(status: Int32)
}
