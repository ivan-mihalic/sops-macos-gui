import CSopsBridge
import Foundation

public struct SopsBridgeError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

/// In-process SOPS engine. Every call crosses into the Go runtime linked from
/// the static bridge; no `sops` binary is ever spawned.
public enum SopsBridge {

    public static func encryptYAML(
        _ plain: String,
        recipients: [String],
        encryptedRegex: String = ""
    ) throws -> String {
        try call { out in
            plain.withGoString { plainPtr in
                recipients.joined(separator: ",").withGoString { recipientsPtr in
                    encryptedRegex.withGoString { regexPtr in
                        sops_encrypt_yaml(plainPtr, recipientsPtr, regexPtr, out)
                    }
                }
            }
        }
    }

    public static func decryptYAML(_ encrypted: String, agePrivateKey: String) throws -> String {
        try call { out in
            encrypted.withGoString { encryptedPtr in
                agePrivateKey.withGoString { keyPtr in
                    sops_decrypt_yaml(encryptedPtr, keyPtr, out)
                }
            }
        }
    }

    /// Shared calling convention: 0 means *out holds the result, anything else
    /// means *out holds an error message. Either way the buffer is Go-allocated
    /// and must go back through sops_free.
    private static func call(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        let status = body(&out)

        guard let out else {
            throw SopsBridgeError(description: "bridge returned no result (status \(status))")
        }
        defer { sops_free(out) }

        let message = String(cString: out)
        guard status == 0 else {
            throw SopsBridgeError(description: message)
        }
        return message
    }
}

extension String {
    /// The generated header takes non-const `char*`, so hand it a mutable copy.
    /// The pointer is valid only for the duration of `body`.
    fileprivate func withGoString<R>(_ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
        var bytes = Array(utf8CString)
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
