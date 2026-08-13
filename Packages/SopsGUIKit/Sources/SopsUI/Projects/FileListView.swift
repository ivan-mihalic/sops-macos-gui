import Observation
import SopsHealth
import SwiftUI

/// Drives the file list for one project: runs `ProjectScanner.scan(root:)`
/// and exposes the result the view needs, plus the relative-path formatting
/// every row displays.
///
/// One instance per selected project — `ProjectWorkspaceView` (in
/// `AppShell.swift`) creates a fresh one each time the selection changes, so
/// this type never has to notice its own `projectRoot` changing underneath
/// it.
@MainActor
@Observable
public final class FileListModel {

    public let projectRoot: URL
    public private(set) var files: [URL] = []
    public private(set) var otherFormatCount = 0
    public private(set) var isScanning = false
    public private(set) var hasScanned = false
    /// Set when the scan fell short of the whole tree in a way that makes any
    /// affirmative statement about this list dishonest — the budget cap, an
    /// unlistable directory, an unfollowed directory symlink, an unreadable
    /// file, an oversized metadata block. Carries the sentence explaining
    /// which; see `ScannedTree.incompleteScanReason`.
    ///
    /// This replaces a bare `wasTruncated` flag, which covered the budget cap
    /// alone and therefore missed four of the five blocking limitations —
    /// including the common one, a subdirectory the user cannot read.
    public private(set) var incompleteScanReason: String?
    /// Directory names the walk never enters at all (`.git`, `node_modules`,
    /// …). Not a defect and not a warning — a permanent, named, bounded
    /// exclusion, so it is stated quietly rather than in the banner.
    public private(set) var skippedDirectoryNames: [String] = []
    public private(set) var rootMissing = false
    /// The root exists but could not be read — changed permissions, a
    /// detached volume, a revoked sandbox scope.
    ///
    /// `ProjectHealthCheck` has handled this since Task 18; the file list
    /// dropped it on the floor, so an unreadable project rendered as
    /// "No encrypted files found in this project." — a confident statement
    /// about a directory the scan never got into, which is the one thing
    /// PROPOSAL §6 D says this app must never do.
    public private(set) var rootUnreadable = false

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Walks the project tree and replaces every published property from the
    /// result in one pass, so a view observing this model never sees a
    /// half-updated combination (e.g. `incompleteScanReason` from the new
    /// scan next to `files` from the old one).
    public func refresh() async {
        isScanning = true
        let tree = await ProjectScanner.scan(root: projectRoot)

        // Only the YAML-sniffed files are listed as *openable* — the editor
        // (`SopsEngine.SopsDocument`) only reads sops's YAML store; dotenv/
        // JSON/INI sops documents are a hard "no" for v1 (Package.swift,
        // CLAUDE.md: "YAML only for v1. Do not add dotenv or JSON handling
        // anywhere"). Rendering one of those as a clickable row would open a
        // file this app cannot actually decrypt, one click after the user
        // finds it in what looks like an ordinary list of the same kind of
        // thing. `otherFormatCount` is surfaced instead, so a user with a
        // `.env` sops file isn't left wondering why it never appears.
        files = tree.encrypted.map(\.url).sorted { relativePath(for: $0) < relativePath(for: $1) }
        otherFormatCount = tree.encryptedInOtherFormats.count
        incompleteScanReason = tree.incompleteScanReason
        skippedDirectoryNames = tree.skippedDirectoryNames.sorted()
        rootMissing = tree.rootMissing
        rootUnreadable = tree.rootUnreadable
        isScanning = false
        hasScanned = true
    }

    /// `url`'s path relative to `projectRoot`, for display. Falls back to the
    /// full path if `url` is somehow not under `projectRoot` at all — never
    /// reachable through `ProjectScanner`'s own walk, but a display helper
    /// has no business crashing or truncating garbage if that invariant is
    /// ever violated by a future caller.
    public func relativePath(for url: URL) -> String {
        let root = projectRoot.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return path }
        path.removeFirst(root.count)
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }
}

/// The encrypted files in one project, shown relative to the project root.
///
/// A scan that fell short of the whole tree says so directly in this list —
/// Task 9's brief is explicit that this is exactly where a user would
/// otherwise assume they are seeing every file, since `ProjectScanner`
/// already knows and reports it (Task 1/1b) but nothing downstream of the
/// health check has shown it to a user yet.
public struct FileListView: View {
    @Bindable private var model: FileListModel
    @Binding private var selection: URL?
    /// What the toolbar "+" (and its ⌘N shortcut) should do. A callback, not
    /// a sheet this view presents itself — matching `NewSecretFileSheet`'s own
    /// "the view decides nothing": building the model a new file would need
    /// requires `SessionKeyStore` and the project root's current
    /// `FileListModel`, both of which belong to `ProjectWorkspaceView`
    /// (`AppShell.swift`), not to this one. This view only ever asks; the
    /// caller decides whether there is a project to ask about at all — see
    /// `AppShell.makeNewFileModel(projectRoot:keyStore:)`.
    private let onNewFile: () -> Void

    public init(model: FileListModel, selection: Binding<URL?>, onNewFile: @escaping () -> Void) {
        self.model = model
        self._selection = selection
        self.onNewFile = onNewFile
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let reason = model.incompleteScanReason {
                incompleteScanBanner(reason)
            }

            content
        }
        .task(id: model.projectRoot) {
            await model.refresh()
        }
    }

    /// The "+" row above the list — this app's toolbar shape, matching
    /// `SecretEditorView.toolbar` and `access.toolbar-button`'s own naming:
    /// a hand-drawn header `HStack`, not `NavigationSplitView`'s own window
    /// toolbar. Icon-only, so `.filesNewFileButton` is never rendered as a
    /// title — it supplies the accessibility label and the tooltip instead.
    ///
    /// Always enabled when this view exists at all: `ProjectWorkspaceView`
    /// never constructs `FileListView` without a project (the `else` branch
    /// of its `fileListPane` renders `.filesNoProjectSelected` instead), so
    /// "inactive without a selected project" holds by construction rather
    /// than by a `.disabled()` this view would otherwise have to fake a
    /// reason for. The row (and with it, ⌘N) is also disabled for free
    /// whenever a save is in flight — `ProjectWorkspaceView` already applies
    /// `.disabled(openDocumentIsSaving)` to the whole pane this view sits in,
    /// the same guard the project sidebar and the file `List` selection get.
    private var toolbar: some View {
        HStack {
            Spacer()
            Button(action: onNewFile) {
                Label(.filesNewFileButton, systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help(LocalizedKey.filesNewFileButton.text)
        }
        .padding(8)
    }

    /// The three states below are about the *root* — nothing ran, so there is
    /// no list and no footnote to qualify. Everything after them is a real
    /// walk's result, and its footnotes belong to it whether or not it found
    /// anything: `otherFormatCount` used to be rendered inside the
    /// has-files branch, so a project holding only dotenv or JSON sops files
    /// hit the empty placeholder and was told nothing was here — the one
    /// group of users the note exists for.
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
            if model.files.isEmpty {
                // "No encrypted files found in this project." is a claim about
                // the whole project. Over an incomplete walk it is not one this
                // app is entitled to make, so the wording narrows to what was
                // actually covered and the banner above says why.
                statusPlaceholder(
                    systemImage: "doc.text.magnifyingglass",
                    title: model.incompleteScanReason == nil ? .filesEmptyTitle : .filesEmptyPartialTitle)
            } else {
                List(selection: $selection) {
                    ForEach(model.files, id: \.self) { url in
                        Text(model.relativePath(for: url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(url)
                    }
                }
                .listStyle(.sidebar)
                .scrollOverflowFade()
            }

            footnotes
        }
    }

    /// Standing facts about what this list is, as opposed to the banner's
    /// "something went wrong on this particular walk".
    @ViewBuilder
    private var footnotes: some View {
        if model.otherFormatCount > 0 {
            footnote(String(format: LocalizedKey.filesOtherFormatNote.text, model.otherFormatCount))
        }
        // Previously rendered only inside the truncation banner, i.e. only on
        // the rare walk that hit the file budget — while `.git` puts an entry
        // in this list on every real repository. The disclosure PROPOSAL §6 D
        // asks for was therefore almost never shown.
        if !model.skippedDirectoryNames.isEmpty {
            footnote(String(format: LocalizedKey.filesSkippedDirectoriesNote.text,
                            model.skippedDirectoryNames.joined(separator: ", ")))
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
    /// scan cannot drift into saying different things about it. It is not a
    /// `LocalizedKey` for the same reason the health findings aren't: the
    /// sentence is assembled from the walk's own data.
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
