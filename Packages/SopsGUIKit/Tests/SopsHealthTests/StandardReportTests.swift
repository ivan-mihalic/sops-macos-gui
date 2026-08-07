import Testing
@testable import SopsHealth

@Suite("standard report")
struct StandardReportTests {

    @Test("covers all four categories from PROPOSAL §6")
    func coversEveryCategory() async {
        let findings = await HealthReport.standard(updateChecksEnabled: false).run()
        let prefixes = Set(findings.map { $0.id.split(separator: ".").first.map(String.init) ?? "" })
        #expect(prefixes.isSuperset(of: ["tool", "engine", "security", "project"]))
    }

    @Test("runs offline without producing a single error state")
    func worksOffline() async {
        for finding in await HealthReport.standard(updateChecksEnabled: false).run() {
            if case .problem = finding.status {
                // Problems are legitimate findings, but none may be caused by the
                // network being unavailable.
                #expect(!finding.detail.lowercased().contains("github"))
            }
        }
    }

    @Test("every finding has a non-empty title and a stable id")
    func findingsAreWellFormed() async {
        let findings = await HealthReport.standard(updateChecksEnabled: false).run()
        #expect(!findings.isEmpty)
        #expect(Set(findings.map(\.id)).count == findings.count, "ids must be unique")
        for finding in findings {
            #expect(!finding.title.isEmpty)
            #expect(!finding.id.isEmpty)
        }
    }
}
