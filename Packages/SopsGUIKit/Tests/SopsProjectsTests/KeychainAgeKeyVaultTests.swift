import Foundation
import Security
import Testing
@testable import SopsProjects

/// SOPS-46. What can honestly be tested about the real vault in a test
/// process, which is less than it looks and is stated here rather than hidden
/// behind a suite name that implies more.
///
/// **Not covered here, and not coverable:** every actual `SecItem*` call.
/// Reading the item requires a user-presence check, and a test process has no
/// user — in this repo's headless `Background` launchd session it does not
/// even have a window server to draw the sheet on. A test that "verified"
/// round-tripping would either hang forever or be measuring a mocked-out
/// Keychain, which certifies nothing. The round trip is on the ticket's manual
/// acceptance list instead, where the fact that a human has to do it is
/// visible.
///
/// What is covered: the two pieces of pure logic that decide what the user is
/// told and which item is addressed. Both were worth getting wrong.
@Suite("KeychainAgeKeyVault")
struct KeychainAgeKeyVaultTests {

    // MARK: - Status mapping

    @Test("a missing item is 'nothing stored', not a failure")
    func itemNotFoundMapsToNoStoredKey() {
        #expect(KeychainAgeKeyVault.error(for: errSecItemNotFound) == .noStoredKey)
    }

    /// Cancelling and failing authentication are the same thing to every
    /// caller — the key is still there and the offer is still "unlock" —
    /// which is why they collapse into one case rather than two the UI would
    /// word identically.
    @Test("a cancelled or failed Touch ID prompt maps to cancellation")
    func authenticationFailuresMapToCancelled() {
        #expect(KeychainAgeKeyVault.error(for: errSecUserCanceled) == .authenticationCancelled)
        #expect(KeychainAgeKeyVault.error(for: errSecAuthFailed) == .authenticationCancelled)
    }

    /// The status this app will hit on every single save until the
    /// entitlement work lands. Its own message, because the system's ("A
    /// required entitlement isn't present") describes a build problem to
    /// somebody who is trying to save a key.
    @Test("a missing entitlement is reported as unavailable, in the user's terms")
    func missingEntitlementIsUnavailable() {
        let error = KeychainAgeKeyVault.error(for: errSecMissingEntitlement)

        guard case .unavailable(let reason) = error else {
            Issue.record("expected .unavailable, got \(error)")
            return
        }
        #expect(reason.contains("session only"))
        // Whatever this says, it must not be an API noun.
        #expect(reason.lowercased().contains("entitlement") == false)
    }

    @Test("an unrecognised status keeps its number and nothing else")
    func unknownStatusCarriesTheCode() {
        #expect(KeychainAgeKeyVault.error(for: -12345) == .failed(status: -12345))
    }

    // MARK: - Query shape

    /// The single most consequential line in this type: without
    /// `kSecUseDataProtectionKeychain`, the call lands in the file-based
    /// keychain, which **silently ignores** `kSecAttrAccessControl`. The key
    /// would be stored, everything would appear to work, and the Touch ID
    /// gate this whole ticket is about would not exist. A test for one
    /// dictionary key looks trivial; this is the failure it stands guard on.
    @Test("every operation targets the data-protection keychain")
    func queryUsesDataProtectionKeychain() {
        let query = KeychainAgeKeyVault.baseQuery()

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test("every operation addresses one generic-password item")
    func queryAddressesOneItem() {
        let query = KeychainAgeKeyVault.baseQuery()

        #expect((query[kSecClass as String] as! CFString) == kSecClassGenericPassword)
        #expect(query[kSecAttrService as String] as? String != nil)
        #expect(query[kSecAttrAccount as String] as? String != nil)
    }

    /// A query carrying an access-control attribute filters *on* it and
    /// matches nothing — a lookup that always says "no key stored" while a
    /// key sits right there. See `baseQuery`'s doc comment.
    @Test("a lookup query carries no access control")
    func queryHasNoAccessControl() {
        #expect(KeychainAgeKeyVault.baseQuery()[kSecAttrAccessControl as String] == nil)
    }
}
