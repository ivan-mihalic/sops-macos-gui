import CSopsBridge
import Foundation

/// The sops and age versions compiled into the bridge. Read once at first use —
/// they cannot change while the process is running.
public enum EngineVersion {

    /// What both properties below hold when the bridge could not determine the
    /// linked module's version. Mirrors `gobridge.UnknownVersion` exactly.
    ///
    /// Deliberately not a version number. The previous sentinel on both sides
    /// of the boundary was `"0.0.0"`, which parses cleanly as semver and then
    /// loses every comparison — so an engine version that was never actually
    /// read turned `ExternalToolCheck`'s "warn if the sops CLI is older than
    /// the embedded engine" into a permanent OK (an installed sops 3.0.0
    /// reported `[OK]` against an embedded 0.0.0), and turned
    /// `EngineFreshnessCheck` into a confident warning about a number nobody
    /// established. A value that cannot parse forces every consumer to handle
    /// "unknown" explicitly instead of comparing against a fiction.
    public static let unknown = "unknown"

    public static let sops: String = versions.sops
    public static let age: String = versions.age

    private static let versions: (sops: String, age: String) = {
        var sopsPtr: UnsafeMutablePointer<CChar>?
        var agePtr: UnsafeMutablePointer<CChar>?
        sops_engine_versions(&sopsPtr, &agePtr)
        defer {
            if let sopsPtr { sops_free(sopsPtr) }
            if let agePtr { sops_free(agePtr) }
        }
        return (
            sopsPtr.map { String(cString: $0) } ?? unknown,
            agePtr.map { String(cString: $0) } ?? unknown
        )
    }()
}
