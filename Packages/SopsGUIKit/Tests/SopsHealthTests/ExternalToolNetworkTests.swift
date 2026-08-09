import Foundation
import Testing
@testable import SopsHealth

/// Records the arguments the check actually asks each tool for, and finds
/// nothing — the argument list is the whole subject here.
private actor RecordingLocator: ToolLocating {
    private(set) var calls: [String: [String]] = [:]

    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? {
        calls[name] = versionArguments
        return nil
    }
}

/// Returns one named tool whose version output is whatever the test supplies,
/// parsed by the *real* `ToolLocator.parseVersion` so the parser's own
/// behaviour is part of what is under test.
private struct FixedOutputLocator: ToolLocating {
    let name: String
    let path: String
    let output: String

    func locate(_ requested: String, versionArguments: [String]) async -> LocatedTool? {
        guard requested == name else { return nil }
        return LocatedTool(name: name, path: path,
                           version: ToolLocator.parseVersion(from: output),
                           rawVersionOutput: output)
    }
}

/// The five probed tools, paired with whether this machine actually has them.
/// Resolved through the same search paths the shipping app uses, synchronously,
/// so it can gate `.enabled(if:)` — a real-binary test that silently returns
/// when the binary is absent is a test that asserts nothing.
private let installedTools: [String: String] = {
    let paths = ToolLocator.loginShellSearchPaths()
    var found: [String: String] = [:]
    for name in ["sops", "age", "git", "yq", "docker"] {
        if let path = paths
            .map({ ($0 as NSString).appendingPathComponent(name) })
            .first(where: ToolLocator.isRunnableExecutable(atPath:)) {
            found[name] = path
        }
    }
    return found
}()

/// The non-sops tools this machine can actually prove anything about. Absent
/// tools are dropped rather than asserted away, so the suite never reports a
/// pass it did not earn.
private let probableNonSopsTools = ["age", "git", "yq", "docker"].filter { installedTools[$0] != nil }

/// Substrings a CLI prints when it tried to reach the network and could not.
/// Under `Scripts/test-network-denied.sh` every one of these is a positive
/// signal that the probe caused a request; with networking available, the
/// `[warning]`/`[info]` markers catch a *successful* upstream check just as
/// well, because sops narrates that too.
private let networkChatterMarkers = [
    "no such host", "dial tcp", "connection refused", "network is unreachable",
    "could not resolve host", "operation not permitted", "failed to retrieve",
    "i/o timeout", "context deadline exceeded",
]

/// PROPOSAL.md §6 B and the app's own copy: the GitHub release lookup is the
/// only network request the app makes on its own, and it is off until the user
/// turns it on.
///
/// `sops --version` broke that promise. Since sops 3.8 the command contacts
/// `api.github.com` to compare against the latest release, and sops 3.11
/// deprecated the behaviour while keeping it as the default. `ExternalToolCheck`
/// runs on first launch, before the user has consented to anything, so the
/// health check itself caused an unconsented request while the wizard's own
/// copy said "Nothing was sent anywhere".
///
/// The existing `ExternalToolCheckTests` could not catch this: every test there
/// uses a `FakeLocator`, so no argument list and no real binary is ever
/// involved. These tests close both halves — the constructed arguments, and the
/// output of the real binary on this machine.
@Suite("ExternalToolCheck network hygiene")
struct ExternalToolNetworkTests {
    private let embedded = SemanticVersion(3, 13, 3)

    @Test("the sops probe disables sops's own upstream version check")
    func sopsProbeDisablesTheUpstreamVersionCheck() async {
        let locator = RecordingLocator()
        _ = await ExternalToolCheck(locator: locator, embeddedSopsVersion: embedded).run()

        let sopsArguments = await locator.calls["sops"]
        #expect(sopsArguments == ["--disable-version-check", "--version"],
                "sops was probed with \(sopsArguments ?? []); plain --version contacts api.github.com")
    }

    @Test("every probed tool is asked only for its version")
    func everyProbeIsVersionOnly() async {
        let locator = RecordingLocator()
        _ = await ExternalToolCheck(locator: locator, embeddedSopsVersion: embedded).run()

        let calls = await locator.calls
        #expect(Set(calls.keys) == ["sops", "age", "git", "yq", "docker"])
        for (name, arguments) in calls {
            #expect(arguments.last == "--version", "\(name) was probed with \(arguments)")
            // Nothing but --version and flags that *suppress* behaviour. A
            // probe that names a file, a key or a network endpoint does not
            // belong in a check that runs unattended on first launch.
            for argument in arguments {
                #expect(argument.hasPrefix("--"), "\(name) was probed with a non-flag argument: \(argument)")
            }
        }
    }

    /// The real binary, with the real argument list the check builds. This is
    /// the test that fails under `Scripts/test-network-denied.sh` against the
    /// pre-fix code: without `--disable-version-check`, sops prints
    /// `[warning] failed to retrieve latest version from upstream: … dial tcp:
    /// lookup api.github.com: no such host`.
    @Test("the real sops probe says nothing about upstream, online or off",
          .enabled(if: installedTools["sops"] != nil))
    func realSopsProbeIsSilentAboutUpstream() async throws {
        let check = ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: embedded)
        let sops = try #require(check.requirements.first { $0.name == "sops" })
        let located = try #require(await ToolLocator().locate("sops", versionArguments: sops.versionArguments))

        let output = located.rawVersionOutput
        for marker in networkChatterMarkers {
            #expect(!output.lowercased().contains(marker), "sops --version output mentions \(marker): \(output)")
        }
        #expect(!output.contains("[warning]"), "sops narrated something: \(output)")
        #expect(!output.contains("[info]"), "sops narrated something: \(output)")
        #expect(!output.contains("(latest)"), "sops compared itself against upstream: \(output)")

        // One line, `sops <version>`, and it still parses. Removing the
        // upstream check removes lines from the output, so the parser's
        // "first digit-leading token" anchor has to survive the new shape.
        //
        // `LineEndings.lines`, not `split(separator: "\n")`. This is real
        // stdout from a real binary, and `"\r\n"` is a single Swift
        // `Character`: an LF-anchored split returns the whole output as one
        // "line" for a CRLF-printing tool however many lines it really has,
        // so `count == 1` held no matter what sops said. Empty subsequences
        // are filtered at the call site, per `LineEndings`' doc comment —
        // the trailing newline is a terminator here, not a blank line.
        let lines = LineEndings.lines(of: output).filter { !$0.isEmpty }
        #expect(lines.count == 1, "expected a single line, got \(lines.count): \(output)")
        #expect(output.hasPrefix("sops "))
        #expect(located.version != nil, "version no longer parses out of \(output)")
    }

    /// The cost of the fix, paid honestly. `--disable-version-check` arrived in
    /// sops 3.8.0; an older sops rejects it and prints its usage screen. That
    /// screen is not version-free text — it contains a PGP fingerprint example
    /// beginning `85D…`, and `ToolLocator.parseVersion` anchors on the first
    /// digit-leading token, so the naive outcome is a confident `sops 85.0.0
    /// … [OK]` for a sops that is in fact ancient.
    @Test("a sops that rejects the flag is reported as old, never as version 85")
    func aSopsTooOldForTheFlagIsNotBelieved() async {
        // The first line is sops's, verbatim; the fingerprint line is the one
        // that makes the parser invent a version.
        let usage = """
            Incorrect Usage. flag provided but not defined: -disable-version-check

            NAME:
               sops - sops - encrypted file editor with AWS KMS, GCP KMS, Azure Key Vault, age, and GPG support

            USAGE:
               $ sops --pgp 85D77543B3D624B63CEA9E6DBC17301B491B3F21 file.yaml
            """

        // Precondition, not decoration: if the parser stopped inventing a
        // version from this text the guard below would be vacuous.
        #expect(ToolLocator.parseVersion(from: usage) == SemanticVersion(85, 0, 0),
                "the usage screen no longer yields a bogus version; this test's premise has moved")

        let check = ExternalToolCheck(
            locator: FixedOutputLocator(name: "sops", path: "/opt/homebrew/bin/sops", output: usage),
            embeddedSopsVersion: embedded)
        let sops = try! #require(await check.run().first { $0.id == "tool.sops" })

        #expect(sops.status == .warning, "got \(sops.status)")
        #expect(!sops.detail.contains("85"), "\(sops.detail)")
        #expect(sops.detail.contains("3.8.0"))
        #expect(sops.remediation?.command == "brew upgrade sops")
    }

    /// The same guard for a tool with no known flag-introduction version: no
    /// invented number, and no claim about how old it is either.
    @Test("a tool that rejects its arguments is unknown, never a version out of the usage text")
    func rejectedArgumentsWithoutAKnownFloorAreUnknown() async {
        let usage = "Incorrect Usage. flag provided but not defined: -version\n\nUSAGE: 12.4 foo"
        let check = ExternalToolCheck(
            locator: FixedOutputLocator(name: "git", path: "/usr/bin/git", output: usage),
            embeddedSopsVersion: embedded)
        let git = try! #require(await check.run().first { $0.id == "tool.git" })

        guard case .unknown = git.status else {
            Issue.record("expected .unknown, got \(git.status)")
            return
        }
        #expect(!git.detail.contains("12.4"))
    }

    /// The other four tools, checked the same way rather than assumed innocent.
    @Test("no probed tool's real version output shows a network attempt",
          .enabled(if: !probableNonSopsTools.isEmpty),
          arguments: probableNonSopsTools)
    func realProbesShowNoNetworkAttempt(name: String) async throws {
        let check = ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: embedded)
        let requirement = try #require(check.requirements.first { $0.name == name })
        let located = try #require(await ToolLocator().locate(name, versionArguments: requirement.versionArguments))

        for marker in networkChatterMarkers {
            #expect(!located.rawVersionOutput.lowercased().contains(marker),
                    "\(name) --version output mentions \(marker): \(located.rawVersionOutput)")
        }
    }
}
