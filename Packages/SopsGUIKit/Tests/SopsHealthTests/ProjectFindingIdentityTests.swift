import Foundation
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// I4: `HealthFinding` is `Identifiable` and every surface renders findings in
/// a `ForEach`, so duplicate ids make row identity undefined — SwiftUI is free
/// to reuse, drop or mis-animate rows, and a `.problem` can end up rendered as
/// its `.ok` namesake.
///
/// The old scheme derived the id from the project's *display name* and
/// disambiguated duplicates by appending "-2", "-3". That construction creates
/// the collision it exists to prevent: `[acme, acme, acme-2]` produces
/// `project.acme.*`, `project.acme-2.*` (the disambiguated second "acme") and
/// `project.acme-2.*` again (the project genuinely named "acme-2").
///
/// These tests assert the property, not the scheme: whatever the ids look like,
/// they must be unique for any list of project names a user can type. The only
/// way to pass them reliably is to stop deriving identity from a value the user
/// controls.
@Suite("project finding identity")
struct ProjectFindingIdentityTests {

    /// The exact list from the review, originally nine findings (three
    /// projects × sops-yaml/recipients/gitignore) before the fix produced
    /// only six distinct ids. Now eighteen: three tickets landing in the
    /// same week each added a finding per project — `file-permissions`
    /// (#19 item 5), `rotation-debt` (#3), `encryption` (#5). None of them
    /// changes what this test is about — id uniqueness — only the count.
    @Test("names that collide after disambiguation still produce unique ids")
    func disambiguationDoesNotCreateCollisions() async throws {
        let roots = try (0..<3).map { _ -> String in
            let root = try ProjectFixture.makeDirectory()
            try ProjectFixture.gitInit(root)
            try ProjectFixture.write(
                "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                to: root, at: ".sops.yaml")
            return root.path
        }
        let names = ["acme", "acme", "acme-2"]

        let findings = await ProjectHealthCheck(source: Projects(
            projects: zip(names, roots).map { InspectedProject(name: $0, rootPath: $1) })).run()

        #expect(findings.count == 18)
        #expect(Set(findings.map(\.id)).count == findings.count,
                "ids collide: \(findings.map(\.id).sorted())")
    }

    /// Adversarial names: dots (which are the id's own separator), the empty
    /// string, whitespace, path separators, and the disambiguation suffix
    /// spelled out by hand.
    @Test("adversarial project names still produce unique ids")
    func adversarialNamesProduceUniqueIDs() async throws {
        let names = [
            "acme", "acme", "acme-2", "acme-2", "acme-3",
            "a.b", "a", "b", "a.b.stale-recipients",
            "", "   ", "../../etc", "project.acme.sops-yaml",
            "acme", "ACME", "acme ",
        ]
        let projects = try names.map { name -> InspectedProject in
            let root = try ProjectFixture.makeDirectory()
            try ProjectFixture.gitInit(root)
            try ProjectFixture.write(
                "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                to: root, at: ".sops.yaml")
            return InspectedProject(name: name, rootPath: root.path)
        }

        let findings = await ProjectHealthCheck(source: Projects(projects: projects)).run()

        #expect(Set(findings.map(\.id)).count == findings.count,
                "ids collide: \(duplicates(in: findings.map(\.id)))")
        // The user's own name still reaches them, unchanged, in the title.
        for name in names where !name.isEmpty {
            #expect(findings.contains { $0.title.hasPrefix(name + ":") },
                    "no finding titled for project \(name.debugDescription)")
        }
    }

    /// Every id must still land in the projects category, or the finding
    /// vanishes from the panel (`HealthViewModel.findings(in:)` groups by the
    /// `project.` prefix).
    @Test("every project finding id stays inside the projects namespace")
    func idsKeepTheCategoryPrefix() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")

        let findings = await ProjectHealthCheck(source: Projects(
            projects: [InspectedProject(name: "a.b", rootPath: root.path)])).run()

        #expect(findings.allSatisfy { $0.id.hasPrefix("project.") })
    }

    /// Ids must be stable across runs of the same project list, or the panel
    /// re-creates every row on each refresh.
    @Test("ids are stable across repeated runs of the same project list")
    func idsAreStableAcrossRuns() async throws {
        let projects = try ["acme", "acme"].map { name -> InspectedProject in
            let root = try ProjectFixture.makeDirectory()
            try ProjectFixture.gitInit(root)
            try ProjectFixture.write(
                "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                to: root, at: ".sops.yaml")
            return InspectedProject(name: name, rootPath: root.path)
        }
        let check = ProjectHealthCheck(source: Projects(projects: projects))
        let first = await check.run().map(\.id)
        let second = await check.run().map(\.id)

        #expect(first == second)
    }
}

private func duplicates(in ids: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for id in ids { counts[id, default: 0] += 1 }
    return counts.filter { $0.value > 1 }.keys.sorted()
}
