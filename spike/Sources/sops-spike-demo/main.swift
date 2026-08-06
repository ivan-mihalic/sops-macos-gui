import Foundation
import SopsBridge

// Proof-of-life executable. Run it with `env -i` — no PATH, no sops binary
// reachable — to demonstrate the engine really is in-process, and to give the
// linker something realistic to measure for binary size.

let recipient = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !recipient.isEmpty else {
    FileHandle.standardError.write(Data("usage: sops-spike-demo <age-public-key>\n".utf8))
    exit(2)
}

let plain = """
    db:
        host: localhost
        password: hunter2

    """

do {
    let encrypted = try SopsBridge.encryptYAML(plain, recipients: [recipient])
    print("encrypted \(plain.utf8.count) bytes -> \(encrypted.utf8.count) bytes")
    print(encrypted.contains("hunter2") ? "FAIL: plaintext leaked" : "OK: no plaintext in output")
} catch {
    FileHandle.standardError.write(Data("bridge error: \(error)\n".utf8))
    exit(1)
}
