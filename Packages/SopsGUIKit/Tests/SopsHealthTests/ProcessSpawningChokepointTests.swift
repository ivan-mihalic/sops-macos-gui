import Foundation
import Testing
@testable import SopsHealth

/// `GitIgnoreOracleSafetyTests.gitHasASingleGuardedChokepoint` proves that
/// `GitIgnoreOracle.swift` itself runs git from exactly one guarded place.
/// That is a per-file check: it reads only `GitIgnoreOracle.swift`'s own
/// source, so it says nothing about a **second** file that starts a `git`
/// (or any other) subprocess of its own, with no `-c core.fsmonitor=` in
/// front of it. Ticket #9 names this gap directly — three planned features
/// (diff view, git awareness, a pre-commit hook) all add new git call sites,
/// and none of them would be caught by a test that only ever reads one file.
///
/// This is the codebase-wide half. Its claim is narrower than "git can only
/// be invoked correctly" — it is "a subprocess can only be *started* from one
/// place at all, anywhere in the shipped app": `Process()` is constructed in
/// exactly one file, `CommandRunner.swift`, and every caller — today
/// `GitIgnoreOracle` (git, always with `safeArguments`) and `ToolLocator`
/// (version probes for git/sops/age/the login shell, never scoped to a
/// repository a user might have cloned) — goes through
/// `CommandRunner.run(_:arguments:...)`. A new file that shells out to git
/// directly via its own `Process()`, bypassing `CommandRunner` entirely, is
/// exactly the "brand-new file elsewhere" ticket #9 says the per-file test
/// cannot see, and it fails this one.
///
/// This does **not** prove every `CommandRunner.run` caller applies the
/// `core.fsmonitor` mitigation — that is `GitIgnoreOracleSafetyTests`'s job,
/// and it is a per-call-site concern (`ToolLocator`'s `git --version` probe
/// never takes a `-C <repository>`, so the hazard `safeArguments` closes does
/// not apply to it). What this test forecloses is a *second, ungoverned*
/// way into a subprocess at all — the shape a future git feature (diff view,
/// git awareness, a pre-commit hook) would take if it reached for `Process()`
/// directly instead of `CommandRunner.run`.
///
/// ## Scope
///
/// Scans `Sources/SopsUI`, `Sources/SopsEngine`, `Sources/SopsHealth`,
/// `Sources/SopsProjects` — the four library targets `Package.swift` exposes
/// as products, which is exactly what `App/`/`SopsGUI.xcodeproj` link and
/// what a notarized build ships.
///
/// Deliberately **not** scanned: `Sources/SnapshotTool` (an
/// `.executableTarget`; `Package.swift`'s own comment on it says plainly
/// "nothing in `App/` or `SopsGUI.xcodeproj` depends on this, so it never
/// reaches the shipped app" — and it does construct `Process()` directly,
/// in `Fixtures.swift`, to build git fixtures for its own snapshots) and
/// `Sources/ScratchCleanup` (test-only). A hostile repository cannot make
/// either of those run anything on a user's machine, because neither of
/// them ships.
///
/// ## Why source text and not `go/ast`-style parsing
///
/// This package has no Swift AST facility the way `Engine/cshim/exports_test.go`
/// has `go/ast` in the standard library — adding a swift-syntax dependency
/// for one test was judged not worth it. So this reuses the technique
/// already established in this test target for the identical class of
/// problem: read the real source, strip comments with
/// `GitIgnoreOracleSafetyTests.strippingComments` (defined in this target,
/// visible here without an import), and count a literal. That helper's own
/// doc comment records two ways a naive string match was defeated before
/// (moving the guarded token into a comment, then into a `/* */` block) —
/// this inherits the fix for both, for the same reason.
@Suite("A subprocess can only be started from one place in the shipped app")
struct ProcessSpawningChokepointTests {

    private static let shippedTargets = ["SopsUI", "SopsEngine", "SopsHealth", "SopsProjects"]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // this file
            .deletingLastPathComponent() // SopsHealthTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources")
    }

    @Test("Process() is constructed in exactly one file across the shipped app, CommandRunner.swift")
    func processIsConstructedInExactlyOneShippedFile() throws {
        var sitesByFile: [String: Int] = [:]

        for target in Self.shippedTargets {
            let dir = Self.sourcesRoot.appendingPathComponent(target)
            for path in try Self.swiftFiles(under: dir) {
                let source = try String(contentsOf: path, encoding: .utf8)
                let stripped = GitIgnoreOracleSafetyTests.strippingComments(source)
                let count = stripped.components(separatedBy: "Process()").count - 1
                guard count > 0 else { continue }
                sitesByFile[path.lastPathComponent, default: 0] += count
            }
        }

        let expected = ["CommandRunner.swift": 1]
        let message = "Process() is constructed at \(sitesByFile) across the shipped app, expected "
            + "exactly one construction in CommandRunner.swift — a subprocess (git or anything "
            + "else) started any other way bypasses the -c core.fsmonitor= mitigation entirely"
        #expect(sitesByFile == expected, "\(message)")
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
