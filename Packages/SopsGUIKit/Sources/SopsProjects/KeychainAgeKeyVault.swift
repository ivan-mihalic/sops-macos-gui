import Foundation
import LocalAuthentication
import Security

/// The shipped `AgeKeyVault`: one generic-password item in the data-protection
/// keychain, guarded by a `SecAccessControl` requiring user presence.
///
/// ## Why the data-protection keychain
/// `kSecAttrAccessControl` — the attribute that makes the item cost a Touch ID
/// — is only honoured there. The older file-based keychain has no equivalent:
/// an item in it is readable by this app the moment the login keychain is
/// unlocked, which is most of the time, and that is not a meaningfully
/// different guarantee from the plaintext `keys.txt` this app's own health
/// check warns about.
///
/// ## The entitlement, which is not optional and is not present yet
/// The data-protection keychain gates access by *keychain access group*, which
/// the system derives from the `application-identifier` and
/// `keychain-access-groups` entitlements. A Developer ID app with neither —
/// which is what this app ships as today (`project.yml` sets hardened runtime
/// and nothing else) — has no group to write into, so `SecItemAdd` returns
/// `errSecMissingEntitlement` (-34018) and nothing works. Adding the
/// entitlement means an App ID and an embedded Developer ID provisioning
/// profile, which is release-pipeline work, not app work. Until that lands,
/// `store(_:)` fails with `.unavailable(reason:)` — which `SessionKeyStore`
/// deliberately treats as "your key is ready, it just was not saved", so the
/// app is fully usable in the meantime and simply does not remember anything.
///
/// ## `.userPresence`, not `.biometryCurrentSet`
/// `.biometryCurrentSet` invalidates the item whenever the enrolled
/// fingerprint set changes — add a finger in System Settings and the stored
/// key is gone for good, with no way to get it back and no warning that it
/// happened. That is a data-loss mode in exchange for a threat model
/// (someone enrolls their own fingerprint on your unlocked Mac) that already
/// implies a total compromise. `.userPresence` also allows the password
/// fallback, so a Mac whose Touch ID sensor stops working does not lock its
/// owner out of their own key.
public struct KeychainAgeKeyVault: AgeKeyVault {

    /// Service and account together identify the one item this app owns.
    /// Fixed strings, not derived from the bundle id: a rename of the app
    /// must not orphan a key the user is relying on.
    private static let service = "cz.mihalic.SopsGUI.age-identity"
    private static let account = "primary"

    /// Shown in the Touch ID sheet, so it says what is being unlocked rather
    /// than naming this app twice (macOS already prefixes it with the app
    /// name).
    private static let prompt = "unlock your age key"

    public init() {}

    // MARK: - Reading

    public func hasStoredKey() -> Bool {
        // Attributes, never data. The access control guards the *value*; the
        // metadata saying an item exists is not behind it, so this question
        // can be asked without putting a Touch ID sheet in front of somebody
        // who merely opened the window.
        //
        // `interactionNotAllowed` is belt and braces: if some future OS
        // decides otherwise, this comes back as a status rather than as an
        // unexplained prompt. What that status *means* is the subtle part —
        // see `existsVerdict(for:)`.
        let context = LAContext()
        context.interactionNotAllowed = true

        var query = Self.baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        return Self.existsVerdict(for: SecItemCopyMatching(query as CFDictionary, &item))
    }

    /// Whether `status`, from the existence query above, means "there is a key
    /// stored".
    ///
    /// ## The bug this exists to name
    /// This used to be `status == errSecSuccess`, and that shipped a
    /// **user-visible lie**: import a key with "Remember" ticked, relaunch,
    /// and Settings › Key said *"No key is imported."* while the key sat in
    /// the Keychain the whole time. The import itself had succeeded and
    /// reported nothing wrong, so there was no error anywhere to follow — the
    /// app simply could not see its own stored key.
    ///
    /// `errSecInteractionNotAllowed` is not "no". It is the keychain saying
    /// *"the item is here and I will not hand it over without asking the
    /// user"* — a sentence that presupposes the item. An absent item produces
    /// `errSecItemNotFound`, which is the "no" this function actually needs to
    /// recognise. Reading the first as the second turns a key that is present
    /// and merely locked into a key that does not exist, which is precisely
    /// backwards from what the caller (`SessionKeyStore.state`) then reports.
    ///
    /// Erring towards `true` is also the right way to be wrong. A false
    /// `true` shows an Unlock button that fails once and explains itself; a
    /// false `false` tells the user their key is gone and asks them to import
    /// it again.
    static func existsVerdict(for status: OSStatus) -> Bool {
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        default:
            return false
        }
    }

    public func loadKey() throws -> String {
        let context = LAContext()
        context.localizedReason = Self.prompt

        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw Self.error(for: status) }
        guard let data = item as? Data else { throw AgeKeyVaultError.unreadableStoredKey }
        // The one place the key becomes a `String`. Everything below this
        // line is `Data`, which is at least storage this app allocated and
        // can drop, unlike a `String`'s shared buffer — see
        // `SessionKeyStore`'s "What this does *not* protect against".
        guard let key = String(data: data, encoding: .utf8) else {
            throw AgeKeyVaultError.unreadableStoredKey
        }
        return key
    }

    // MARK: - Writing

    public func store(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw AgeKeyVaultError.unreadableStoredKey
        }

        var accessControlError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            accessControlError?.release()
            throw AgeKeyVaultError.unavailable(
                reason: "This Mac cannot protect a stored key with Touch ID or a password.")
        }

        // Replace rather than update: `SecItemUpdate` cannot change an
        // access-control attribute, so an item written by an older build with
        // different flags would keep them forever. Deleting first is also the
        // only way to avoid `errSecDuplicateItem` without first reading the
        // existing item — which would prompt for Touch ID in the middle of an
        // import.
        try? removeStoredKey()

        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessControl as String] = access
        // Nothing about this item should ever leave the machine: it is a
        // private key, and iCloud Keychain sync would put a copy on every
        // other device signed into the same account.
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func removeStoredKey() throws {
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        // Deleting what is not there is the outcome the caller wanted, not a
        // failure worth surfacing.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    // MARK: - Query and error shapes

    /// The attributes that identify this app's one item, shared by every
    /// operation so a copy-paste divergence cannot make `store` and `loadKey`
    /// address different items.
    ///
    /// The access control is deliberately **not** here: `SecItemAdd` takes it
    /// as an attribute to set, while a query must not carry it at all —
    /// including it in a lookup filters on it and matches nothing.
    static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Without this the call goes to the file-based keychain, where
            // the access control above is silently ignored — the exact shape
            // of failure this whole type exists to avoid, and one that would
            // look like success.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Maps the `OSStatus` values this app can actually provoke onto
    /// sentences the UI has something to do with. Everything else keeps its
    /// number and nothing more — a status code is a bug report, not a message.
    static func error(for status: OSStatus) -> AgeKeyVaultError {
        switch status {
        case errSecItemNotFound:
            return .noStoredKey
        case errSecUserCanceled, errSecAuthFailed:
            return .authenticationCancelled
        case errSecMissingEntitlement:
            // The one that will be hit first, and the one whose default
            // message ("A required entitlement isn't present") tells the user
            // nothing they can act on. See the type's doc comment.
            return .unavailable(
                reason: "This build cannot use the Keychain yet, so your key is kept for this session only.")
        case errSecInteractionNotAllowed:
            return .unavailable(
                reason: "The Keychain could not be reached without unlocking this Mac first.")
        default:
            return .failed(status: status)
        }
    }
}
