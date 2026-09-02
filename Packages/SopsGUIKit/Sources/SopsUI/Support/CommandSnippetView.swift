import SwiftUI

/// A shell command (or any pasteable text) with a copy button that says
/// "Copied" for a moment.
///
/// Lifted out of `HealthFindingRow` and `KeyImportView`, which each carried
/// the same ten lines, and now also the building block of `SetupGuideView`.
/// The command is always `Text(verbatim:)` — commands are not catalog
/// entries, exactly as the health remediations and
/// `AgeKeyFileLocations.protectCommand` never were.
///
/// `copyWithoutAutoClear`, not `copy`: this is text the user is about to
/// paste at their own pace, not a secret, and wiping their clipboard 30 s
/// later would take away what they asked for. It still gets the concealed/
/// transient markers and host-only scoping every other pasteboard write in
/// this app gets — a `chmod 600` command names the absolute path to a
/// private key file. See `ClipboardClearing.copyWithoutAutoClear`.
///
/// The app shows the command; the user runs it. This app never mutates the
/// system (CLAUDE.md, PROPOSAL.md §6).
public struct CommandSnippetView: View {
    let command: String
    /// What identifies this snippet to the shared `CopyFeedback` — one
    /// confirmation at a time across every snippet that shares the object.
    let feedbackID: String
    let copyFeedback: CopyFeedback
    /// `true` for a block that runs to several lines (a config file, a
    /// prompt): the text wraps and the button sits at the top.
    let multiline: Bool

    public init(command: String, feedbackID: String, copyFeedback: CopyFeedback, multiline: Bool = false) {
        self.command = command
        self.feedbackID = feedbackID
        self.copyFeedback = copyFeedback
        self.multiline = multiline
    }

    public var body: some View {
        HStack(alignment: multiline ? .top : .center) {
            Text(verbatim: command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: multiline ? .infinity : nil, alignment: .leading)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button(copyFeedback.label(for: feedbackID).text) {
                ClipboardClearing.copyWithoutAutoClear(command)
                copyFeedback.confirmCopy(of: feedbackID)
            }
        }
    }
}
