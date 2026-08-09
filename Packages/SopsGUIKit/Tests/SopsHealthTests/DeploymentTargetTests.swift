import Foundation
import Testing

/// CLAUDE.md: "Deployment target is one variable — `MACOSX_DEPLOYMENT_TARGET`
/// in `Engine/build-xcframework.sh`, mirrored in `Package.swift` and
/// `project.yml`. A mismatch produces a linker warning on every object file."
///
/// It was a rule with four copies and no enforcement. The stated symptom is
/// also the weakest possible one: a linker warning per object file is exactly
/// the kind of output that scrolls past in a build log, and neither
/// `swift test` nor `swift build` of this package links the Go archive at all,
/// so the fast loop never even emits it. A mismatched `project.yml` would ship
/// an `LSMinimumSystemVersion` that disagrees with what the binary was built
/// against, and the app would refuse to launch — or launch and crash — on the
/// versions in between.
///
/// Whichever value is right is not this test's business. That they are the
/// same value is.
@Suite("The deployment target is one number, in four places")
struct DeploymentTargetTests {

    /// `Tests/SopsHealthTests/…` → package root → repository root.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SopsHealthTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Packages/SopsGUIKit
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repository root

    private static func read(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The first capture of `pattern` in `text`, or `nil`.
    private static func firstMatch(_ pattern: String, in text: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }

    @Test("every declaration of the minimum macOS version agrees")
    func everyDeclarationAgrees() throws {
        let script = try Self.read("Engine/build-xcframework.sh")
        let manifest = try Self.read("Packages/SopsGUIKit/Package.swift")
        let projectSpec = try Self.read("project.yml")

        let sources: [(name: String, value: String?)] = [
            ("Engine/build-xcframework.sh MACOSX_DEPLOYMENT_TARGET default",
             try Self.firstMatch(#"DEPLOYMENT_TARGET="\$\{MACOSX_DEPLOYMENT_TARGET:-([0-9.]+)\}""#, in: script)),
            ("Packages/SopsGUIKit/Package.swift platforms",
             try Self.firstMatch(#"\.macOS\("([0-9.]+)"\)"#, in: manifest)),
            ("project.yml deploymentTarget macOS",
             try Self.firstMatch(#"macOS:\s*"([0-9.]+)""#, in: projectSpec)),
            ("project.yml LSMinimumSystemVersion",
             try Self.firstMatch(#"LSMinimumSystemVersion:\s*"([0-9.]+)""#, in: projectSpec)),
        ]

        // A source whose pattern stopped matching is a failure, not a skip:
        // silently dropping it would leave this test green while enforcing
        // nothing, which is the state it was written to end.
        var found: [String: String] = [:]
        for source in sources {
            let value = try #require(source.value, "could not find the deployment target in \(source.name)")
            found[source.name] = value
        }

        let distinct = Set(found.values)
        #expect(distinct.count == 1,
                "the deployment target disagrees across the repository: \(found.sorted { $0.key < $1.key })")
    }
}
