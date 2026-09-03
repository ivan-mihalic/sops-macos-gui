import Foundation
import Testing

/// SOPS-46 / ADR 0006. A guard on the one combination that ships an app which
/// **does not launch**.
///
/// `keychain-access-groups` is a restricted entitlement. A binary carrying it
/// without an embedded provisioning profile that authorises it is killed by
/// AMFI before `main` runs — SIGKILL, no message, no crash log worth reading.
/// This was measured on 2026-09-03 with a Developer ID-signed, hardened-runtime
/// probe carrying exactly that entitlement and a real team prefix: exit 137.
///
/// So `App/SopsGUI.entitlements` sits in the repo unwired. The day someone adds
/// `CODE_SIGN_ENTITLEMENTS` to `project.yml` — which is the obvious thing to do
/// when the profile finally arrives, and the obvious thing to do *too early* —
/// this test asks whether the profile came with it.
///
/// It is a text check over two files rather than anything clever, because the
/// failure it prevents costs a release: the app would install, sign, notarize,
/// pass every other test here, and then refuse to open on the user's Mac.
@Suite("Entitlements are wired only alongside a provisioning profile")
struct EntitlementsWiringTests {

    /// Walks up from this file to the repository root. `#filePath` rather than
    /// a bundle resource: the two files under test are build configuration,
    /// not resources, and nothing copies them into a test bundle.
    private static func repositoryRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }
        return nil
    }

    private static func read(_ relative: String) throws -> String? {
        guard let root = repositoryRoot() else { return nil }
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `project.yml` with every `#` comment emptied out.
    ///
    /// Without this the whole suite is theatre, and it was: the first version
    /// of this test passed its own ablation. `project.yml` carries a comment
    /// **explaining** that `CODE_SIGN_ENTITLEMENTS` is deliberately not set and
    /// why the provisioning profile matters — so a substring search found both
    /// "CODE_SIGN_ENTITLEMENTS" and "provisioning" in the prose that exists to
    /// warn about them, and reported a correctly wired build no matter what the
    /// file actually configured. A guard that reads the documentation instead
    /// of the configuration cannot fail.
    ///
    /// Deliberately naive about `#` inside a quoted string: nothing in this
    /// file has one, and a parser here would be a second thing to get wrong.
    private static func configurationOnly(_ yaml: String) -> String {
        yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let hash = line.firstIndex(of: "#") else { return line }
                return line[line.startIndex..<hash]
            }
            .joined(separator: "\n")
    }

    /// The check that can fail. Its own test rather than a `guard` inside the
    /// real one: a missing `project.yml` (a bundle-only build, a moved file)
    /// would otherwise make the guard below silently vacuous, which is the
    /// exact failure mode this repo's own conventions warn about.
    @Test("the guard can actually see project.yml")
    func projectFileIsReachable() throws {
        let project = try Self.read("project.yml")

        #expect(project != nil, "project.yml was not found from #filePath — the wiring guard below is asserting nothing")
        #expect(project?.contains("ENABLE_HARDENED_RUNTIME") == true)
    }

    /// The canary for the comment-stripping above: today's `project.yml`
    /// mentions both terms **only** in prose, so the stripped text must
    /// contain neither. If someone wires the entitlements in for real this
    /// flips, and that is the moment the real guard below starts having
    /// something to say — so this test failing is a signal to read that one,
    /// not to loosen this one.
    @Test("comment stripping actually removes the prose that mentions the entitlement")
    func commentStrippingWorks() throws {
        let project = try #require(try Self.read("project.yml"))

        #expect(project.contains("CODE_SIGN_ENTITLEMENTS"),
                "the comment explaining why entitlements are unwired is gone; this canary no longer proves anything")
        #expect(Self.configurationOnly(project).contains("CODE_SIGN_ENTITLEMENTS") == false)
    }

    @Test("entitlements are not wired in without a provisioning profile step")
    func entitlementsRequireAProfile() throws {
        guard let raw = try Self.read("project.yml") else { return }
        let project = Self.configurationOnly(raw)

        let entitlementsWired = project.contains("CODE_SIGN_ENTITLEMENTS")
        guard entitlementsWired else { return }

        // Whatever shape the profile arrives in — a `postbuildScripts` entry
        // that copies it, a `PROVISIONING_PROFILE_SPECIFIER`, an
        // `embedded.provisionprofile` committed next to the app — it has to be
        // named somewhere in the same file. This deliberately does not
        // prescribe which.
        let mentionsProfile = project.contains("provisionprofile")
            || project.contains("PROVISIONING_PROFILE")
            || project.contains("provisioning")

        #expect(mentionsProfile, Comment(rawValue: """
            project.yml sets CODE_SIGN_ENTITLEMENTS but names no provisioning profile. \
            App/SopsGUI.entitlements asks for keychain-access-groups, which is restricted: \
            AMFI kills a binary carrying it without an embedded profile, before main runs \
            (measured 2026-09-03, exit 137). This build would sign, notarize, and then fail \
            to launch. See ADR 0006.
            """))
    }

    /// The other half: the entitlements file must keep asking for the group the
    /// vault addresses. A rename on one side and not the other produces
    /// -34018 at runtime with everything looking correctly configured.
    @Test("the entitlements file names the app's own keychain group")
    func entitlementsNameTheGroup() throws {
        guard let entitlements = try Self.read("App/SopsGUI.entitlements") else {
            Issue.record("App/SopsGUI.entitlements is missing — SOPS-46's Keychain storage cannot work without it")
            return
        }

        #expect(entitlements.contains("keychain-access-groups"))
        #expect(entitlements.contains("cz.mihalic.SopsGUI"))
        // The Xcode build-time substitution, not a hardcoded team id: the
        // repo must not carry one, and `codesign` alone does not expand this
        // (measured — the unexpanded literal reaches the signature and the
        // binary is killed just the same).
        #expect(entitlements.contains("$(AppIdentifierPrefix)"))
    }
}
