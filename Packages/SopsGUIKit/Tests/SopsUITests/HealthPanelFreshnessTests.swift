import AppKit
import Foundation
import SopsHealth
import SwiftUI
import Testing
@testable import SopsUI

/// Settings › Health used to render whatever the last run produced, in the
/// present tense and without a timestamp, because its `.task` refreshed only
/// when `findings.isEmpty`. One `HealthViewModel` is shared across the app and
/// the security check reads the same key store the Settings › Key tab writes
/// to, so "No age key is configured" survived the user configuring one.
///
/// This asserts the property rather than the source line: what matters is that
/// arriving at the panel produces a report reflecting the world as it is now.
@Suite("The health panel does not show a stale run")
@MainActor
struct HealthPanelFreshnessTests {

    /// A check whose verdict changes between runs, standing in for the real
    /// `security.keystore` one: it reads a key store the neighbouring Settings
    /// tab can change while this panel is on screen.
    private struct ChangingCheck: HealthCheck {
        let id = "probe.run"
        let category = HealthCategory.security
        let counter: Counter

        func run() async -> [HealthFinding] {
            let run = await counter.next()
            return [HealthFinding(
                id: id,
                title: "run \(run)",
                status: run == 1 ? .problem : .ok,
                detail: "run \(run)")]
        }
    }

    private actor Counter {
        private var value = 0
        func next() -> Int { value += 1; return value }
        func total() -> Int { value }
    }

    /// The one that actually renders `HealthPanel`.
    ///
    /// The model-level test below passes with the buggy `.task { if
    /// model.findings.isEmpty … }` restored verbatim — measured — so on its own
    /// it guards nothing, which is the same shape the previous round fixed for
    /// `FileListView` and reintroduced next door.
    ///
    /// `.task` does fire in the offscreen host `AXProbe` builds, but not
    /// synchronously, so this waits for the run to be observed rather than
    /// assuming it happened by the time `tree` returns.
    @Test("arriving at the panel a second time re-runs the checks")
    func panelRefreshesOnEveryAppearance() async throws {
        let counter = Counter()
        let model = HealthViewModel(reportBuilder: {
            HealthReport(checks: [ChangingCheck(counter: counter)])
        })

        await model.refresh()
        try #require(await counter.total() == 1, "precondition: one run so far")

        _ = AXProbe.tree(size: CGSize(width: 640, height: 520)) {
            HealthPanel(model: model)
        }
        // The `.task` is asynchronous; give it a bounded chance to be seen.
        for _ in 0..<100 where await counter.total() < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(await counter.total() >= 2,
                "rendering the panel again did not re-run the checks, so it shows the previous run's verdicts")
    }

    @Test("a second visit re-runs the checks rather than reusing the first answer")
    func revisitRefreshes() async {
        let counter = Counter()
        let model = HealthViewModel(reportBuilder: {
            HealthReport(checks: [ChangingCheck(counter: counter)])
        })

        // What `.task` does on the first appearance of the panel.
        await model.refresh()
        #expect(await counter.total() == 1)
        #expect(model.findings.first?.status == .problem, "precondition: the first run says problem")

        // And on the second.
        await model.refresh()

        #expect(await counter.total() == 2, "the panel reused the previous run's verdicts")
        #expect(model.findings.first?.status == .ok,
                "the panel is showing a verdict the world has moved past")
    }
}
