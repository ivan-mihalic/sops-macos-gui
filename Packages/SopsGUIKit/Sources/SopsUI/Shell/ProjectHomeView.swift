import SopsHealth
import SopsProjects
import SwiftUI

/// The detail pane for a project row — everything the deleted `FileListView`
/// showed *except* the list of files, which is now the sidebar's job
/// (SOPS-39 task 6).
///
/// ## Why these states needed a home at all
/// The file list was never only a list. It also carried five things that say
/// something about the *scan* rather than about any one file:
///
/// - the incomplete-scan banner (`incompleteScanReason`),
/// - "this project's directory is missing" / "…could not be read",
/// - the first-scan spinner,
/// - the narrowed empty state for a walk that could not cover the tree,
/// - and the standing footnotes: files in formats this build cannot open,
///   directories the walk never enters, and each unfollowed directory
///   symlink with its "Add as Project" action.
///
/// A tree row has nowhere to put any of that, and dropping it would mean
/// this app once again claiming "no encrypted files" over a directory it
/// never got into — the one thing PROPOSAL §6 D says it must never do. So
/// they moved here, unchanged, and `ProjectHomeViewWiringTests` is
/// `FileListViewWiringTests` pointed at this view.
///
/// ⚠️ Known consequence, recorded rather than hidden: the banner is now one
/// click away (select the project row) instead of sitting above the file
/// list. A user reading a file whose project scan was incomplete is not told
/// so on that screen. That is a real narrowing of where the warning appears,
/// accepted for this task because the alternative — a banner in a 220 pt
/// sidebar column — is where the old design put it precisely because the
/// sidebar was 320 pt wide and had nothing else to show.
public struct ProjectHomeView: View {
    @Bindable private var model: FileListModel
    private let onNewFile: () -> Void
    private let onAddProjectAtPath: (String) -> Void

    public init(model: FileListModel,
                onNewFile: @escaping () -> Void,
                onAddProjectAtPath: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onNewFile = onNewFile
        self.onAddProjectAtPath = onAddProjectAtPath
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let reason = model.incompleteScanReason {
                incompleteScanBanner(reason)
            }
            content
        }
    }

    /// Whether the walk found nothing to show *and* completed cleanly enough
    /// that saying more than "nothing here" is honest — the exact branch
    /// `ProjectStartHereView` owns. `rootMissing`, `rootUnreadable` and a
    /// non-nil `incompleteScanReason` all fail this on purpose: none of them
    /// is a real "this project is empty".
    private var showsStartHere: Bool {
        model.files.isEmpty && model.incompleteScanReason == nil
    }

    @ViewBuilder
    private var content: some View {
        if model.rootMissing {
            statusPlaceholder(systemImage: "questionmark.folder", title: .filesProjectMissingTitle)
        } else if model.rootUnreadable {
            statusPlaceholder(systemImage: "lock.folder", title: .filesProjectUnreadableTitle)
        } else if model.isScanning && !model.hasScanned {
            VStack(spacing: 8) {
                ProgressView()
                Text(.filesScanning).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if showsStartHere {
                // A complete scan that genuinely found nothing — the one
                // case where this app can say more than "empty" and mean it.
                ProjectStartHereView(
                    configState: model.configState, otherFormatCount: model.otherFormatCount,
                    projectRoot: model.projectRoot, onNewFile: onNewFile)
            } else if model.files.isEmpty {
                // Reachable only over an incomplete walk (`showsStartHere` is
                // false whenever `incompleteScanReason` is non-nil). "No
                // encrypted files found in this project." is a claim about
                // the whole project; over a walk that could not cover it,
                // that claim is not one this app is entitled to make.
                statusPlaceholder(systemImage: "doc.text.magnifyingglass", title: .filesEmptyPartialTitle)
            } else {
                projectSummary
            }

            footnotes
        }
    }

    /// What the pane says when the sidebar is already listing this project's
    /// files: how many there are, and the way to add one. Deliberately not a
    /// second copy of the list — two lists of the same files, one of them not
    /// the one that drives the selection, is the disagreement this task
    /// collapsed the columns to end.
    private var projectSummary: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(format: LocalizedKey.filesCountSummary.text, model.files.count))
                .foregroundStyle(.secondary)
            Button(action: onNewFile) {
                Label(.filesNewFileButton, systemImage: "plus")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Standing facts about what this project is, as opposed to the banner's
    /// "something went wrong on this particular walk".
    @ViewBuilder
    private var footnotes: some View {
        // `ProjectStartHereView` already carries this exact sentence itself
        // when it is the one on screen, so showing it again here would
        // repeat the same note twice.
        if model.otherFormatCount > 0 && !showsStartHere {
            footnote(String(format: LocalizedKey.filesOtherFormatNote.text, model.otherFormatCount))
        }
        if !model.skippedDirectoryNames.isEmpty {
            footnote(String(format: LocalizedKey.filesSkippedDirectoriesNote.text,
                            model.skippedDirectoryNames.joined(separator: ", ")))
        }
        ForEach(model.unfollowedDirectorySymlinks, id: \.path) { link in
            unfollowedSymlinkFootnote(link)
        }
    }

    /// One row per unfollowed directory symlink, naming what it points at and
    /// offering to add that target as its own project — ticket #25 claim 2.
    private func unfollowedSymlinkFootnote(_ link: ScannedTree.UnfollowedSymlink) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(String(format: LocalizedKey.filesUnfollowedSymlinkNote.text,
                            model.relativePath(for: URL(fileURLWithPath: link.path)), link.target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(LocalizedKey.filesAddSymlinkTargetButton.text) {
                    onAddProjectAtPath(link.target)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .padding(8)
        }
    }

    private func footnote(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusPlaceholder(systemImage: String, title: LocalizedKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `reason` comes from `SopsHealth` already written as a sentence for a
    /// user (`ProjectScopeAccountant.blockedVerdictReason`) — the same text
    /// the health check shows for the same condition, so the two views of one
    /// scan cannot drift into saying different things about it.
    private func incompleteScanBanner(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(.filesScanIncompleteTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}
