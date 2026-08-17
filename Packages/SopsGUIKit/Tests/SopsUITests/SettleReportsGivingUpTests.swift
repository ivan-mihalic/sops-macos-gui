import Foundation
import SwiftUI
import Testing
@testable import SopsUI

/// `GatingHost.settle(until:)` has to say when it gave up waiting.
///
/// It polls a condition until a timeout and then returns — **either way**.
/// A caller whose condition never became true carries on and fails at the next
/// assertion, which then reports something else entirely.
///
/// That is not hypothetical. On 2026-08-15 a full-suite run failed with
/// `(model.plan?.governingRuleIdentified → nil) == false` in
/// `ProjectAccessTests`, which reads as "the panel computed the wrong thing".
/// The panel had computed nothing: the wait had timed out on a loaded machine
/// and said so to nobody. The same shape hit
/// `SecretDocumentViewModelTests` on 2026-08-17.
///
/// One definition serves about thirty call sites across seven files, so the
/// silence was thirty chances to misdiagnose a slow machine as a broken view.
/// A helper that gives up must report giving up — otherwise it hands back
/// success-shaped output for a thing that did not happen.
@Suite("settle reports a timeout instead of returning quietly")
@MainActor
struct SettleReportsGivingUpTests {

    private func host() -> GatingHost {
        GatingHost(size: CGSize(width: 200, height: 120)) { AnyView(Color.clear) }
    }

    @Test("a condition that never holds records an issue naming the wait")
    func timingOutIsReported() async {
        let host = host()
        defer { host.finish() }

        await withKnownIssue("settle must record an issue when it gives up") {
            await host.settle(until: { false }, timeout: .milliseconds(60))
        }
    }

    /// The ordinary path stays silent. A helper that complained on every
    /// successful wait would be noise, and noise is how a real report gets
    /// skimmed past.
    @Test("a condition that holds immediately reports nothing")
    func satisfiedWaitIsSilent() async {
        let host = host()
        defer { host.finish() }

        await host.settle(until: { true }, timeout: .milliseconds(60))
    }
}
