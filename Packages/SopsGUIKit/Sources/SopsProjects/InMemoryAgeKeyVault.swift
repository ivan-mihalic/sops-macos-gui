import Foundation

/// An `AgeKeyVault` that keeps its one item in memory, for tests, snapshots,
/// and previews.
///
/// Public rather than test-only for the same reason `UnshippedKeyStore` is:
/// three test targets and the snapshot catalog all need to put
/// `SessionKeyStore` into its `.locked` state, and none of them can do that
/// with the real Keychain — `KeychainAgeKeyVault` would prompt for Touch ID
/// in a headless process, which either hangs the run or fails it depending on
/// which session type the process happens to be in.
///
/// Nothing in `App/` constructs one; the shipped app wires
/// `KeychainAgeKeyVault`.
///
/// ## Failure scripting
/// `nextLoadFailure` makes a single `loadKey()` throw and then clears itself,
/// so a test can prove the *recovery* path — cancel the prompt, press unlock
/// again, succeed — rather than only the failure. `loadCount` exists for the
/// one assertion that matters most here: unlocking twice must not authenticate
/// twice.
/// `@unchecked Sendable`: every stored property below is mutable and every
/// access to it goes through `lock`, which is exactly the contract the
/// annotation exists for. Swift 6 cannot see that a lock covers a property, so
/// the alternative is an `actor` — which cannot satisfy `AgeKeyVault`'s
/// synchronous requirements without making the whole protocol `async`, and
/// those requirements are synchronous because `SecItemCopyMatching` is.
public final class InMemoryAgeKeyVault: AgeKeyVault, @unchecked Sendable {

    private let lock = NSLock()
    private var storedKey: String?
    private var scriptedLoadFailure: AgeKeyVaultError?
    private var loads = 0
    private var scriptedStoreFailure: AgeKeyVaultError?

    public init(storedKey: String? = nil) {
        self.storedKey = storedKey
    }

    /// How many times `loadKey()` has been called, successfully or not.
    public var loadCount: Int {
        lock.withLock { loads }
    }

    /// Makes the next `loadKey()` throw `error`, once.
    public func failNextLoad(with error: AgeKeyVaultError) {
        lock.withLock { scriptedLoadFailure = error }
    }

    /// Makes every `store(_:)` throw `error` until cleared with `nil`.
    ///
    /// Unlike `failNextLoad`, this one sticks: the behaviour under test is
    /// "an import whose save failed still leaves a usable in-memory key", and
    /// a one-shot failure would let a retry hide it.
    public func failStore(with error: AgeKeyVaultError?) {
        lock.withLock { scriptedStoreFailure = error }
    }

    /// What is stored right now, without authenticating — for assertions
    /// only. The real vault has no such door; that is the point of it.
    public var storedKeyForTesting: String? {
        lock.withLock { storedKey }
    }

    public func hasStoredKey() -> Bool {
        lock.withLock { storedKey != nil }
    }

    public func loadKey() throws -> String {
        try lock.withLock {
            loads += 1
            if let scriptedLoadFailure {
                self.scriptedLoadFailure = nil
                throw scriptedLoadFailure
            }
            guard let storedKey else { throw AgeKeyVaultError.noStoredKey }
            return storedKey
        }
    }

    public func store(_ key: String) throws {
        try lock.withLock {
            if let scriptedStoreFailure { throw scriptedStoreFailure }
            storedKey = key
        }
    }

    public func removeStoredKey() throws {
        lock.withLock { storedKey = nil }
    }
}
