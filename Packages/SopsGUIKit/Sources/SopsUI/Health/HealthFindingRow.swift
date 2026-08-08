import AppKit
import SwiftUI
import SopsHealth

// `public`, not merely internal: `SnapshotTool` renders this view directly,
// in isolation, from outside this module — the whole reason it needs its own
// snapshots (see M2's brief) is that `HealthPanel`/`OnboardingWizard` never
// exercised anything past a `.ok` finding, so the four other statuses (and
// the multi-line reason/remediation text they carry) went unverified through
// M1. A cross-module snapshot target is exactly what closes that gap, which
// requires this type — and its init — to be visible outside `SopsUI`.
public struct HealthFindingRow: View {
    let finding: HealthFinding

    /// Shared by every row in a panel, not owned per row.
    ///
    /// Per-row `@State` gave the right answer for the wrong reason: rows did
    /// not interfere because SwiftUI happened to give each one its own flag,
    /// which is a fact about view identity rather than a property anything
    /// could check. One object keyed by `finding.id` makes "only the row you
    /// copied from says Copied" true by construction and reachable from a
    /// test — see `CopyFeedback`.
    private let copyFeedback: CopyFeedback

    // Explicit, non-private init: the compiler-synthesized memberwise init
    // would be private here (it inherits the narrowest access of its stored
    // properties), and is therefore unusable from any other file in this
    // module — including `HealthPanel` and `OnboardingWizard`, which
    // construct this view.
    public init(finding: HealthFinding, copyFeedback: CopyFeedback) {
        self.finding = finding
        self.copyFeedback = copyFeedback
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .foregroundStyle(tint)
                    .accessibilityLabel(statusDescription)
                Text(finding.title).font(.headline)
                Spacer()
            }

            if !finding.detail.isEmpty {
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .skipped(let reason) = finding.status {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if case .unknown(let reason) = finding.status {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }

            if let remediation = finding.remediation {
                Text(remediation.explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = remediation.command {
                    HStack {
                        Text(command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        // The app shows the command; the user runs it. PROPOSAL.md §6.
                        //
                        // Straight to `NSPasteboard`, not through
                        // `ClipboardClearing`: this is a shell command the
                        // user is about to paste into a terminal, not a
                        // secret, and wiping their clipboard 30 seconds later
                        // would be taking away something they asked for.
                        Button(copyFeedback.label(for: finding.id).text) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copyFeedback.confirmCopy(of: finding.id)
                        }
                    }
                }
                if let url = remediation.documentationURL {
                    Link(LocalizedKey.actionLearnMore.text, destination: url).font(.callout)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var glyph: String {
        switch finding.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch finding.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .skipped, .unknown: .secondary
        }
    }

    private var statusDescription: String {
        switch finding.status {
        case .ok: LocalizedKey.statusOK.text
        case .warning: LocalizedKey.statusWarning.text
        case .problem: LocalizedKey.statusProblem.text
        case .skipped: LocalizedKey.statusSkipped.text
        case .unknown: LocalizedKey.statusUnknown.text
        }
    }
}
