import Foundation
import Observation
import SopsProjects

/// Re-wraps every drifted file in a project for the recipients **its own**
/// creation rule declares — across as many rules as the project has.
///
/// ## Why this builds models, when nothing else may
/// `ProjectAccessModel` is about one rule: the one governing its `targetFile`.
/// That is the right shape for the panel it was written for, and it is why
/// every other call site takes its model from `ProjectTreeStore` rather than
/// constructing one (a model built in a view body is replaced, unloaded, on
/// the next re-render — see `ProjectTreeStore.accessModel(for:targetFile:)`).
///
/// A project-wide rewrap is the one operation that genuinely spans rules:
/// `secrets/prod.sops.env` may want three keys while everything else wants
/// two, and re-wrapping both sets for one recipient list is precisely the
/// silent access change this app refuses to make. So this builds one model
/// per drifted rule, each targeted at a file that rule governs, and applies
/// each rule's own declared recipients. It is deliberately **not** a view: it
/// owns no rendering, and the page holds one instance across re-renders.
///
/// Nothing here writes `.sops.yaml`. The rules are read as truth and the
/// files are brought to them — the same direction `sops updatekeys` moves in.
@MainActor
@Observable
public final class RewrapCoordinator {

    public private(set) var isRunning = false
    /// Every file result of the run in progress or the last completed one,
    /// concatenated across rules in rule order.
    public private(set) var results: [ProjectRecipientApplier.FileResult] = []
    /// Why a rule was skipped, in this app's own words — never a key, never a
    /// document value. Empty for a run in which every rule ran.
    public private(set) var skipped: [String] = []

    public var updatedCount: Int { results.filter { $0.outcome == .updated }.count }
    public var failedCount: Int {
        results.filter { if case .failed = $0.outcome { true } else { false } }.count
    }

    private let projectRoot: URL
    private let keyStore: SessionKeyStore

    public init(projectRoot: URL, keyStore: SessionKeyStore) {
        self.projectRoot = projectRoot
        self.keyStore = keyStore
    }

    /// Brings every `.ruleDiffers` file in `inventory` to the recipient set
    /// its governing rule declares.
    ///
    /// One pass per rule that has at least one drifted file. A rule whose
    /// model refuses the apply is skipped with its refusal recorded rather
    /// than aborting the run: the other rules' files are a separate promise,
    /// and stopping at the first refusal would leave a project half-rewrapped
    /// with nothing on screen saying which half.
    public func rewrap(_ inventory: AccessInventory) async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        skipped = []
        defer { isRunning = false }

        let driftedRules = Set(inventory.filesNeedingRewrap.compactMap(\.ruleIndex)).sorted()
        for index in driftedRules {
            guard let rule = inventory.rules.first(where: { $0.index == index }),
                let anchor = inventory.files(governedBy: index).first
            else { continue }

            let model = ProjectAccessModel(
                projectRoot: projectRoot, keyStore: keyStore, targetFile: anchor.url)
            await model.load()

            // The rule is the authority here, so the staged set is made to
            // equal it exactly — dropping anything a previous load seeded
            // that the rule does not name, as well as adding what it does.
            let wanted = rule.recipients.map(\.recipient)
            model.discardStagedChanges()
            for recipient in model.stagedRecipients where !wanted.contains(recipient) {
                model.stageRemove(recipient)
            }
            var stagingRefused = false
            for recipient in wanted where !model.stagedRecipients.contains(recipient) {
                if model.stageAdd(recipient) != nil { stagingRefused = true }
            }

            // Never apply a partial set. Every recipient the rule names is
            // one this rewrap is claiming to restore, so a staged set that
            // does not equal the rule's is not "close enough" — applying it
            // would re-wrap files for fewer keys than the config declares and
            // report the result as a success. Compared as sets, for the same
            // reason `ProjectAccessModel.isDirty` is: order is not membership.
            guard !stagingRefused, Set(model.stagedRecipients) == Set(wanted) else {
                skipped.append(LocalizedKey.accessRewrapRuleNotStaged.text)
                continue
            }

            if let refusal = await model.applyToFiles() {
                skipped.append(refusal.explanation)
                continue
            }
            results += model.fileResults
        }
    }
}
