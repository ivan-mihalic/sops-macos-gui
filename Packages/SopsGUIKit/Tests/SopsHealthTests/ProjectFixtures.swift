import Foundation
import ScratchCleanup
import SopsEngine

/// Fixture builders shared by the project-health test suites.
///
/// Everything here is built with the *real* tools — `git init` and a real
/// `git` binary for the ignore rules, `age-keygen` for keys, and the real
/// in-process `SopsBridge` for encrypted files. Two of the three Critical
/// findings in the final review survived five review rounds precisely because
/// the fixtures were hand-written approximations of what the implementer
/// believed those tools produce. A hand-written `.gitignore` matcher and a
/// hand-written "encrypted file" cannot disagree with the implementation that
/// shares their author's assumptions; `git check-ignore` and `sops` can.
enum ProjectFixture {

    /// A throwaway directory. Not a git repository unless `gitInit` is called.
    static func makeDirectory(_ label: String = "project") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        // Deleted when this process exits — see `ScratchDirectoryRegistry`.
        ScratchDirectoryRegistry.shared.register(root)
        return root
    }

    static func write(_ contents: String, to root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Turns `root` into a real git repository. Configured with a local
    /// identity so `git add` works on a machine with no global git config,
    /// and with `core.excludesFile` pointed at an empty file so the
    /// developer's own global gitignore cannot influence a test's result.
    @discardableResult
    static func gitInit(_ root: URL) throws -> String {
        let git = try gitPath()
        let emptyGlobalExcludes = root.appendingPathComponent(".git-empty-global-excludes")
        try run(git, ["init", "-q", root.path])
        try "".write(to: emptyGlobalExcludes, atomically: true, encoding: .utf8)
        try run(git, ["-C", root.path, "config", "core.excludesFile", emptyGlobalExcludes.path])
        try run(git, ["-C", root.path, "config", "user.email", "test@example.invalid"])
        try run(git, ["-C", root.path, "config", "user.name", "Test"])
        return git
    }

    /// Stages `relativePath`, so the file is genuinely tracked by git.
    static func gitAdd(_ root: URL, _ relativePath: String) throws {
        try run(try gitPath(), ["-C", root.path, "add", "-f", "--", relativePath])
    }

    /// A real age key pair from `age-keygen`, never a hand-typed string.
    static func ageKeyPair() throws -> (private: String, public: String) {
        let output = try run(try toolPath("age-keygen"), [])
        var secret = "", recipient = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# public key: ") {
                recipient = String(line.dropFirst("# public key: ".count))
            } else if line.hasPrefix("AGE-SECRET-KEY-") {
                secret = String(line)
            }
        }
        guard !secret.isEmpty, !recipient.isEmpty else {
            throw FixtureError("age-keygen produced no usable key pair")
        }
        return (secret, recipient)
    }

    /// A genuinely sops-encrypted YAML document, produced by the same
    /// in-process bridge the shipping app uses.
    static func encrypted(_ plain: String, to recipients: [String]) throws -> String {
        try SopsBridge.encrypt(plain, format: .yaml, recipients: recipients)
    }

    /// A genuinely sops-encrypted dotenv document, produced by the same
    /// in-process bridge the shipping app uses — never a hand-typed
    /// `sops_age__list_0__map_recipient=` string. `plain` must already be
    /// `KEY=value\n` lines; the dotenv store has no other shape.
    static func encryptedDotenv(_ plain: String, to recipients: [String]) throws -> String {
        try SopsBridge.encrypt(plain, format: .dotenv, recipients: recipients)
    }

    /// A genuinely sops-encrypted JSON document, produced by the same
    /// in-process bridge the shipping app uses (SOPS-38 phase F2 task 2) —
    /// never a hand-typed `"sops": {...}` object. `plain` must already be a
    /// valid JSON document.
    static func encryptedJSON(_ plain: String, to recipients: [String]) throws -> String {
        try SopsBridge.encrypt(plain, format: .json, recipients: recipients)
    }

    /// A genuinely sops-encrypted INI document, produced by the same
    /// in-process bridge the shipping app uses (SOPS-38 phase F2 task 2) —
    /// never a hand-typed `[sops]` section. `plain` must already be a valid
    /// INI document (the INI store's root must stay sections, so a bare
    /// top-level key without a `[section]` above it is not something this
    /// store can round-trip).
    static func encryptedINI(_ plain: String, to recipients: [String]) throws -> String {
        try SopsBridge.encrypt(plain, format: .ini, recipients: recipients)
    }

    /// A genuinely sops-encrypted YAML document produced by the real `sops`
    /// binary, not the in-process bridge — the compatibility oracle for the
    /// cases where the two are expected to disagree (ticket #5: this app's
    /// own save path refuses an `encryptedRegex` that cannot compile;
    /// nothing stops the real CLI from writing one).
    static func sopsCLIEncrypted(
        _ plain: String, age publicKey: String, agePrivateKey: String,
        encryptedRegex: String? = nil, unencryptedSuffix: String? = nil
    ) throws -> String {
        let dir = try makeDirectory("sops-cli-encrypt")
        let plainURL = dir.appendingPathComponent("plain.yaml")
        try plain.write(to: plainURL, atomically: true, encoding: .utf8)
        let keyFile = dir.appendingPathComponent("key.txt")
        try (agePrivateKey + "\n").write(to: keyFile, atomically: true, encoding: .utf8)

        var arguments = ["--encrypt", "--age", publicKey]
        if let encryptedRegex {
            arguments += ["--encrypted-regex", encryptedRegex]
        }
        if let unencryptedSuffix {
            arguments += ["--unencrypted-suffix", unencryptedSuffix]
        }
        arguments.append(plainURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try toolPath("sops"))
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["SOPS_AGE_KEY_FILE": keyFile.path]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError("sops \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(output)")
        }
        return output
    }

    // MARK: - Process plumbing

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func gitPath() throws -> String { try toolPath("git") }

    private static func toolPath(_ name: String) throws -> String {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent(name) }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FixtureError("\(name) not found in \(candidates)")
        }
        return found
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError("\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(output)")
        }
        return output
    }
}

