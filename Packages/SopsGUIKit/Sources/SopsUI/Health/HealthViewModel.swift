import Foundation
import Observation
import SopsHealth

@MainActor
@Observable
public final class HealthViewModel {
    public private(set) var findings: [HealthFinding] = []
    public private(set) var isRunning = false
    /// Set once `refresh()` has completed at least one full run. Distinct from
    /// `findings.isEmpty`: an empty finding list is a legitimate completed
    /// result (e.g. `HealthReport(checks: [])`), not evidence the scan hasn't
    /// run yet — callers that need "has this ever settled" must read this
    /// flag rather than infer it from `findings` being non-empty.
    public private(set) var hasCompletedRefresh = false

    /// When the currently-shown `findings` finished being produced. `nil`
    /// until the first refresh completes, and updated every time `findings`
    /// is replaced — never captured once and forgotten.
    ///
    /// Ticket #22: findings carried no timestamp at all, so a panel showing
    /// results from minutes or hours ago (this view model is one shared
    /// instance for the whole app — see `HealthPanel`'s `.task` doc comment)
    /// looked identical to one showing what was true right now. `HealthPanel`
    /// reads this to show "Last checked <relative time>" next to the Re-run
    /// button, which is the cheapest honest signal: a report that finished 20
    /// minutes ago visibly says so instead of implying it is current.
    public private(set) var lastRefreshedAt: Date?

    /// Built fresh on every `refresh()` rather than captured once — see
    /// `init(reportBuilder:)`.
    private let reportBuilder: @MainActor @Sendable () -> HealthReport

    /// The currently-running refresh, if any. A caller that arrives while a
    /// refresh is already in flight awaits this same task instead of starting
    /// a second one — see `refresh()`.
    private var inFlightRefresh: Task<Void, Never>?

    public init(report: HealthReport) {
        self.reportBuilder = { report }
    }

    /// Same as `init(report:)`, except the report is (re)built from scratch
    /// on every `refresh()` instead of once at construction time.
    ///
    /// Exists for exactly one reason: `HealthReport.standard(projects:)` is
    /// handed a `ProjectSourceProviding` *value* — `ProjectStore.HealthSource`
    /// is a plain struct snapshot of `ProjectStore.projects` at the moment it
    /// was read. `SopsGUIApp` builds `health` once, in a property initializer,
    /// before the window (and therefore the project sidebar) has ever been
    /// shown — so a `HealthViewModel(report:)` built the old way would freeze
    /// the projects section at "whatever was on disk at launch" for the rest
    /// of the run: add a project through the sidebar, click "Re-run checks",
    /// and the new project would never appear without quitting and relaunching.
    /// That is exactly the class of bug this app's own standing rule forbids
    /// — a stale result standing in for one nobody actually checked. This
    /// mirrors `HealthReport.standard`'s own `updateChecksEnabled` closure,
    /// which exists for the identical reason (its doc comment: "a captured
    /// value would freeze the user's consent... for the rest of the session").
    ///
    /// `@MainActor` because the builder needs to read `ProjectStore`, which is
    /// itself `@MainActor`-isolated; `refresh()` already runs its body on the
    /// main actor (see below), so calling the builder there requires no
    /// additional hop.
    public init(reportBuilder: @escaping @MainActor @Sendable () -> HealthReport) {
        self.reportBuilder = reportBuilder
    }

    public var headlineStatus: HealthStatus {
        HealthReport.worstStatus(in: findings)
    }

    private static func prefix(for category: HealthCategory) -> String {
        switch category {
        case .tools: "tool."
        case .engine: "engine."
        case .security: "security."
        case .projects: "project."
        }
    }

    /// Findings are keyed by an id whose prefix names the category, which keeps
    /// the grouping stable without the view knowing which check produced what.
    public func findings(in category: HealthCategory) -> [HealthFinding] {
        let prefix = Self.prefix(for: category)
        return findings.filter { $0.id.hasPrefix(prefix) }
    }

    /// Findings whose id prefix matches none of `HealthCategory`'s known
    /// prefixes. `HealthPanel` renders these in a fallback section: a naming
    /// mismatch between a check's id and its category must never make a
    /// finding — including a `.problem` that already drives `headlineStatus`
    /// — silently disappear from the UI.
    public var uncategorizedFindings: [HealthFinding] {
        findings.filter { finding in
            !HealthCategory.allCases.contains { finding.id.hasPrefix(Self.prefix(for: $0)) }
        }
    }

    /// Runs every check and replaces `findings` with the result.
    ///
    /// Concurrent callers share one in-flight run rather than each starting
    /// their own. Checks shell out to CLI tools and walk project trees, so two
    /// full scans running at once is wasteful — and, without this guard, a
    /// genuine race: whichever call's `findings` assignment happened to land
    /// last would win (last-completion-wins, not last-call-wins), and the
    /// first call's `isRunning = false` would fire while a second call was
    /// still running, making the spinner and the disabled re-run button lie.
    ///
    /// A caller that arrives mid-refresh awaits the same run and observes its
    /// result; it never starts a second one, and `isRunning` stays true until
    /// that shared run actually finishes.
    /// Set when someone asks for a refresh while one is already running.
    ///
    /// Joining the in-flight run and returning was wrong, and measurably so: a
    /// caller who arrives mid-scan gets a report **built from inputs captured
    /// before they asked**. The sequence that matters is Settings › Health
    /// starting a scan, the user adding a project or importing a key while it
    /// runs, then App menu › "Run setup check" — the wizard would settle on a
    /// verdict about the old inputs and schedule nothing further, because the
    /// sheet's identity does not change and the wizard has no re-run of its
    /// own. Measured: one builder call, `hasCompletedRefresh == true`, one
    /// finding, against two live projects.
    ///
    /// `init(reportBuilder:)` exists to forbid exactly this — "a stale result
    /// standing in for one nobody actually checked".
    private var rerunRequested = false

    public func refresh() async {
        if let inFlightRefresh {
            // Ask the running scan to go around once more, then wait for the
            // whole chain — the task does not finish until it stops looping,
            // so awaiting it is awaiting the fresh answer, not the stale one.
            rerunRequested = true
            await inFlightRefresh.value
            return
        }
        await startRefresh()
    }

    private func startRefresh() async {
        isRunning = true
        let task = Task { @MainActor in
            repeat {
                // Cleared before the run, not after: a request that arrives
                // *during* this iteration has to survive into the next check.
                self.rerunRequested = false
                let results = await self.reportBuilder().run()
                self.findings = results
                self.hasCompletedRefresh = true
                self.lastRefreshedAt = Date()
            } while self.rerunRequested
            self.isRunning = false
            self.inFlightRefresh = nil
        }
        inFlightRefresh = task
        await task.value
    }
}
