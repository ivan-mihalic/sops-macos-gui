import AppKit
import SwiftUI
import SopsHealth

struct HealthFindingRow: View {
    let finding: HealthFinding
    @State private var didCopy = false

    // Explicit, non-private init: the compiler-synthesized memberwise init
    // is private here because `_didCopy` (the `@State` property wrapper's
    // backing storage) is private, which makes the whole synthesized init
    // private too — unusable from any other file in this module, including
    // `HealthPanel` and `OnboardingWizard`, which construct this view.
    init(finding: HealthFinding) {
        self.finding = finding
    }

    var body: some View {
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
                        Button(didCopy ? LocalizedKey.actionCopied.text : LocalizedKey.actionCopy.text) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            didCopy = true
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
