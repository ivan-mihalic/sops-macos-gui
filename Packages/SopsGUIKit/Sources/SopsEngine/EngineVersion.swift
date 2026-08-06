import CSopsBridge
import Foundation

/// The sops and age versions compiled into the bridge. Read once at first use —
/// they cannot change while the process is running.
public enum EngineVersion {
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
            sopsPtr.map { String(cString: $0) } ?? "0.0.0",
            agePtr.map { String(cString: $0) } ?? "0.0.0"
        )
    }()
}
