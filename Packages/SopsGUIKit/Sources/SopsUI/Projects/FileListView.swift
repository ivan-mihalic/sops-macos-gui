import Observation
import SopsHealth
import SopsProjects
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
    /// What `.sops.yaml` at the project root says would govern a **typical**
    /// new file. `nil` until the first `refresh()` completes.
    ///
    /// `CreationPlanResolver.plan(forTarget:in:)` answers "what governs
    /// *this specific file*" — it needs a target, and an empty project has
    /// no file to hand it one. `refresh()` asks about a **probe** instead:
    /// `Self.configProbeName` in the project root, a name this app never
    /// creates or writes, exactly the technique
    /// `ProjectHealthCheck.swift`'s own `.sops-health-check-probe` uses and
    /// for the identical reason.
    ///
    /// Because of that substitution, **the result describes the probe path,
    /// not the project as a whole.** A `.sops.yaml` whose only rule reads
    /// `path_regex: ^secrets/` does not match a probe sitting at the project
    /// root, so this comes back `.noRuleMatched` — the honest answer for a
    /// file at *that* location, not evidence that the project has no usable
    /// config. Anything that renders this value (Task 2's empty-state
    /// wording, in particular) must keep that distinction: collapsing
    /// `.noRuleMatched` into "this project has no config" would be exactly
    /// the confident-but-wrong claim `ProjectScanner` and
    /// `ProjectScopeAccountant` exist elsewhere in this app to prevent.
    public private(set) var configState: CreationPlan?

    /// The probe filename `configState` resolves against — never created,
    /// never written to disk. Named for this call site rather than reusing
    /// `ProjectHealthCheck`'s `.sops-health-check-probe` literally, so a
    /// reader who finds one on disk (e.g. after a crash somewhere that does
    /// write its probe) can tell which subsystem it came from; the technique
    /// is shared, the name does not need to be.
    private static let configProbeName = ".sops-file-list-config-probe"

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Walks the project tree and replaces every published property from the
    /// result in one pass, so a view observing this model never sees a
    /// half-updated combination (e.g. `incompleteScanReason` from the new
    /// scan next to `files` from the old one). `configState` is included in
    /// that same pass even though it is not derived from `tree` — it is
    /// still one observation about the project as of this `refresh()`, and a
    /// view must never see it paired with `files` from a different scan.
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
        configState = Self.resolveConfigState(projectRoot: projectRoot)
        isScanning = false
        hasScanned = true
    }

    /// Resolves `configState` against `Self.configProbeName`, swallowing a
    /// thrown `CreationPlanResolver.Error` into `nil` rather than letting it
    /// escape `refresh()` — which is `async` without `throws`, called from
    /// `.task`, and has nowhere to put a thrown error anyway.
    ///
    /// This is deliberately not the same thing as "the config is bad": every
    /// case `CreationPlanResolver.Error` can throw is *this call's own
    /// setup* being wrong — `projectRoot` not absolute, or gone missing
    /// between project selection and this scan — not a problem with
    /// `.sops.yaml` itself. A genuinely bad config already has its own
    /// answer, `.configUnreadable`, which this call reaches normally. Mapping
    /// a setup failure to `.noConfig` or `.configUnreadable` would tell the
    /// user something false about a file they never even have a config
    /// question about; `nil` — "no answer available" — is the only claim
    /// this situation actually supports.
    private static func resolveConfigState(projectRoot: URL) -> CreationPlan? {
        let probe = projectRoot.appendingPathComponent(Self.configProbeName)
        do {
            return try CreationPlanResolver.plan(forTarget: probe, in: projectRoot)
        } catch {
            return nil
        }
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

    /// Whether the walk found nothing to show *and* completed cleanly enough
    /// that saying more than "nothing here" is honest — the exact branch
    /// `ProjectStartHereView` (Task 2) owns. `rootMissing`, `rootUnreadable`
    /// and a non-nil `incompleteScanReason` all fail this on purpose: none
    /// of them is a real "this project is empty" — see `content`'s own doc
    /// comment, "The three states below are about the *root*", and
    /// `ProjectStartHereView`'s own doc comment for why collapsing
    /// `.noRuleMatched` (or any of the other four `configState` values)
    /// into that claim would be dishonest. `footnotes` reads this too, so
    /// the two cannot disagree about which branch is showing.
    ///
    /// This condition says nothing about `model.configState` itself, on
    /// purpose: `showsStartHere == true` picks the branch, but
    /// `ProjectStartHereView` can still render its own `nil`-`configState`
    /// paragraph blank. The ordinary way that happens: `FileListModel`
    /// starts every instance with `configState = nil`, and this view's own
    /// `.task(id:)` above (`FileListView.swift:189`) runs `refresh()` only
    /// *after* the first body evaluation — so every project selection
    /// renders `showsStartHere`'s branch over a `nil` `configState` for one
    /// frame before `refresh()` resolves anything. Rarer, and separate: a
    /// real (if rare) TOCTOU race in `FileListModel.resolveConfigState`.
    /// See that view's own doc comment, "What each of the five configState
    /// values shows", the `nil` paragraph, for the full account of why both
    /// are an accepted gap rather than a regression.
    private var showsStartHere: Bool {
        model.files.isEmpty && model.incompleteScanReason == nil
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
            if showsStartHere {
                // A complete scan that genuinely found nothing — the one
                // case where this app can say more than "empty" and mean
                // it. See `ProjectStartHereView`'s own doc comment for what
                // each of `model.configState`'s five values shows here.
                ProjectStartHereView(
                    configState: model.configState, otherFormatCount: model.otherFormatCount,
                    projectRoot: model.projectRoot, onNewFile: onNewFile)
            } else if model.files.isEmpty {
                // Reachable only over an incomplete walk now (`showsStartHere`
                // above is false whenever `incompleteScanReason` is non-nil).
                // "No encrypted files found in this project." is a claim
                // about the whole project; over a walk that could not cover
                // it, that claim is not one this app is entitled to make, so
                // the wording narrows to what was actually covered and the
                // banner above says why.
                statusPlaceholder(systemImage: "doc.text.magnifyingglass", title: .filesEmptyPartialTitle)
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
        // `ProjectStartHereView` (Task 2) already carries this exact
        // sentence itself when it is the one on screen — see its own
        // `body`, the `otherFormatCount > 0` branch — so showing it again
        // here would repeat the same note twice on one screen. Every other
        // branch (the file `List`, and the incomplete-scan empty
        // placeholder) still gets it from here, unchanged.
        if model.otherFormatCount > 0 && !showsStartHere {
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
