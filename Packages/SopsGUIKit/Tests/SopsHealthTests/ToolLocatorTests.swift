import Foundation
import Testing
@testable import SopsHealth

@Suite("ToolLocator")
struct ToolLocatorTests {

    // Real output captured on macOS 26.5 from the tools this app cares about.
    @Test("parses the version out of each tool's real output", arguments: [
        ("sops 3.13.2\n[info] a new version of sops (v3.13.3) is available", SemanticVersion(3, 13, 2)),
        ("v1.3.1", SemanticVersion(1, 3, 1)),
        ("git version 2.54.0 (Apple Git-157)", SemanticVersion(2, 54, 0)),
        ("yq (https://github.com/mikefarah/yq/) version v4.44.3", SemanticVersion(4, 44, 3)),
        ("Docker version 29.4.0, build 9d7ad9f", SemanticVersion(29, 4, 0)),
    ])
    func parsesRealOutput(output: String, expected: SemanticVersion) {
        #expect(ToolLocator.parseVersion(from: output) == expected)
    }

    @Test("returns nil rather than a wrong version for unparseable output")
    func refusesToGuess() {
        #expect(ToolLocator.parseVersion(from: "") == nil)
        #expect(ToolLocator.parseVersion(from: "command not found") == nil)
    }

    @Test("finds a tool that exists only in a non-default search path")
    func findsToolOutsideProcessPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("faketool")
        try "#!/bin/sh\necho 'faketool version 9.8.7'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let locator = ToolLocator(searchPaths: [dir.path])
        let found = await locator.locate("faketool", versionArguments: ["--version"])

        #expect(found?.path == script.path)
        #expect(found?.version == SemanticVersion(9, 8, 7))
    }

    @Test("reports nil for a tool that is genuinely absent")
    func absentToolIsNil() async {
        let locator = ToolLocator(searchPaths: ["/nonexistent"])
        #expect(await locator.locate("definitely-not-a-tool", versionArguments: ["--version"]) == nil)
    }

    @Test("discovery still works when the process PATH is absent or minimal")
    func loginShellPathIsRicherThanProcessPath() {
        // The whole point of this component: a GUI app launched from Finder gets
        // a minimal process PATH (no /opt/homebrew/bin). Simulate that by wiping
        // PATH from the environment the login-shell probe inherits, and confirm
        // discovery still finds a real, richer PATH via the login shell / fallbacks.
        let originalPath = getenv("PATH").map { String(cString: $0) }
        unsetenv("PATH")
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            }
        }

        let paths = ToolLocator.loginShellSearchPaths()

        #expect(!paths.isEmpty)
        #expect(paths.contains("/usr/bin"))
        // The component exists specifically to recover Homebrew's location,
        // which a minimal process PATH would not contain.
        #expect(paths.contains("/opt/homebrew/bin") || paths.contains("/usr/local/bin"))
    }
}
