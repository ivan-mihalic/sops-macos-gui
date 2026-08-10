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
        try SopsBridge.encryptYAML(plain, recipients: recipients)
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

