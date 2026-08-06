import Foundation

/// A throwaway age identity, generated per test via `age-keygen`.
/// Nothing here is ever written into the repository.
struct AgeKeyPair {
    let `private`: String  // AGE-SECRET-KEY-1...
    let `public`: String  // age1...

    static func generate() throws -> AgeKeyPair {
        let output = try Process.capture("/opt/homebrew/bin/age-keygen", [])
        var priv = "", pub = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw TestError("age-keygen produced no usable key pair")
        }
        return AgeKeyPair(private: priv, public: pub)
    }
}

/// Drives the real `sops` binary — the compatibility oracle.
enum SopsCLI {
    static func run(_ args: [String], identity: AgeKeyPair) throws -> String {
        let keyFile = try TempFile(named: "keys.txt", contents: identity.private + "\n")
        // SOPS_AGE_KEY_FILE keeps the developer's own ~/.config/sops keys out of the test.
        return try Process.capture(
            "/opt/homebrew/bin/sops", args,
            environment: ["SOPS_AGE_KEY_FILE": keyFile.path])
    }
}

/// A file in a per-instance temp directory, removed when the test process exits.
struct TempFile {
    let path: String

    init(named name: String, contents: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sops-spike-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        path = url.path
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Process {
    static func capture(
        _ launchPath: String, _ args: [String], environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
            new
        }

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TestError(
                "\(launchPath) \(args.joined(separator: " ")) exited \(process.terminationStatus): "
                    + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
