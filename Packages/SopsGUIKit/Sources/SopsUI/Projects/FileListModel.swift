import Observation
import SopsEngine
import SopsHealth
import SopsProjects
import SwiftUI

/// One openable row in `FileListModel.files`: an encrypted document this
/// build can actually open, alongside the format it must be opened, edited
/// and saved as.
///
/// Carrying `format` here — not just the `url` — is what lets
/// `AppShell`'s detail pane hand
/// `SecretDocumentViewModel` the right one without re-deriving it from the
/// file's extension. The scanner is the one place that already knows it for
/// certain (`SniffedFile.format`, Task 5's `ProjectScanner.classify`), and
/// `SecretDocumentViewModel.format`'s own doc comment is explicit that the
/// format used to save a document must always be the one used to load it —
/// re-guessing from a filename downstream of that is exactly the kind of
/// second answer that could disagree with the first.
public struct ListedFile: Identifiable, Equatable, Sendable {
    public let url: URL
    public let format: SopsFileFormat
    /// Whether this file's own recipient metadata is known and does **not**
    /// include the session's own public key — SOPS-38 phase F3.
    ///
    /// This is a cheap, metadata-only signal (`SniffedFile.recipients`
    /// compared against `SessionKeyStore.sessionPublicKey`), computed once
    /// per `FileListModel.refresh()` and deliberately conservative:
    /// `false` whenever the session's public key is not known, or the
    /// file's own recipients could not be read, or came back empty — the
    /// list is never entitled to claim read-only over metadata it could not
    /// actually parse. See `FileListModel.refresh()`'s own comment for the
    /// exact rule.
    ///
    /// **This never blocks opening the file**, and no view may treat it as
    /// though it did — `false` here is not "this file is definitely
    /// writable", only "this app did not detect otherwise from metadata
    /// alone". The only true answer is what `SecretDocumentViewModel.load()`
    /// finds when it actually tries: `LoadState.readOnlyCiphertext` is
    /// ground truth, this badge is a hint that can be conservatively wrong
    /// in the "not flagged" direction and must never be wrong in the other.
    public let isReadOnly: Bool
    public var id: URL { url }

    public init(url: URL, format: SopsFileFormat, isReadOnly: Bool = false) {
        self.url = url
        self.format = format
        self.isReadOnly = isReadOnly
    }
}

/// Drives the file list for one project: runs `ProjectScanner.scan(root:)`
/// and exposes the result the view needs, plus the relative-path formatting
/// every row displays.
///
/// One instance per project, owned by `ProjectTreeStore` and created the
/// first time that project's rows are asked for, so this type never has to
/// notice its own `projectRoot` changing underneath it.
@MainActor
@Observable
public final class FileListModel {

    public let projectRoot: URL
    /// Where `ListedFile.isReadOnly` reads the session's own public key from
    /// — SOPS-38 phase F3. `nil` (the default) keeps every existing call
    /// site — snapshots, tests that predate this feature — compiling and
    /// behaving exactly as before: with no key store, `isReadOnly` is
    /// `false` for every file, which is the conservative default this
    /// property's own doc comment requires anyway when the session's public
    /// key is not known.
    private let keyStore: SessionKeyStore?
    public private(set) var files: [ListedFile] = []
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
    /// Directory symlinks this walk found and declined to follow, each
    /// paired with where it actually points — ticket #25 claim 2.
    /// `ProjectHomeView` offers "Add as Project" per entry rather than
    /// following the link itself: `ProjectScanner.walk`'s own comment names
    /// the real hazard a followed link can cause (escaping the project
    /// entirely on the strength of one `ln -s /`), so not following stays
    /// correct and this is what makes the consequence actionable instead of
    /// only named in prose.
    public private(set) var unfollowedDirectorySymlinks: [ScannedTree.UnfollowedSymlink] = []
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
    /// The scan `refresh()` last completed, kept so a second consumer never
    /// has to walk the project again to learn the same thing.
    ///
    /// `ProjectTreeStore` builds its `AccessInventory` from exactly this
    /// tree (SOPS-39 task 6). Re-scanning for it would not merely be slow —
    /// it would be a *second* observation of a directory that can change
    /// between the two, so the sidebar's per-file status dots could describe
    /// a set of files the row list never showed. `nil` until the first
    /// `refresh()` completes.
    public private(set) var lastTree: ScannedTree?

    /// The probe filename `configState` resolves against — never created,
    /// never written to disk. Named for this call site rather than reusing
    /// `ProjectHealthCheck`'s `.sops-health-check-probe` literally, so a
    /// reader who finds one on disk (e.g. after a crash somewhere that does
    /// write its probe) can tell which subsystem it came from; the technique
    /// is shared, the name does not need to be.
    private static let configProbeName = ".sops-file-list-config-probe"

    public init(projectRoot: URL, keyStore: SessionKeyStore? = nil) {
        self.projectRoot = projectRoot
        self.keyStore = keyStore
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
        // `ScanBudgetSetting.current()` is read fresh on every refresh, not
        // captured once, for the same reason `ProjectHealthCheck`'s own
        // `scanBudget` closure is: a value raised in Settings › Scanning
        // must take effect on the next refresh, not only after a relaunch.
        let tree = await ProjectScanner.scan(root: projectRoot, maxScannedFiles: ScanBudgetSetting.current())

        // Every verified encrypted file this build can actually open is
        // listed. That used to mean YAML only — a TEMPORARY filter here
        // (Task 5, SOPS-38) kept a dotenv file out of `files` and folded it
        // into `otherFormatCount` instead, because the editor
        // (`SecretDocumentViewModel`) had no way to open one. Task 6 taught
        // it a document's `format` (threaded through to the bridge from
        // `ListedFile.format`, via `ProjectWorkspaceView.activateFile` in
        // `AppShell.swift`), so that is no longer true and the filter is
        // gone. SOPS-38 phase F2 task 3 did the same for JSON and INI on the
        // scanner side (`ProjectScanner.classify` now routes all four
        // formats into `tree.encrypted`), so `otherFormatCount` — still
        // `tree.encryptedInOtherFormats.count` below — is now expected to be
        // 0 for every project this build can classify at all. It stays a
        // real field rather than being removed: see
        // `ScannedTree.encryptedInOtherFormats`'s own doc comment for why.
        // Read once per refresh, not once per file — `sessionPublicKey`
        // already re-checks TTL expiry on every access, and there is no
        // reason for that check to run once per encrypted file in the
        // project when the answer cannot change between them.
        let sessionPublicKey = keyStore?.sessionPublicKey
        files = tree.encrypted
            .map { sniffed in
                ListedFile(
                    url: sniffed.url, format: sniffed.format,
                    isReadOnly: Self.isReadOnly(sniffed, sessionPublicKey: sessionPublicKey))
            }
            .sorted { relativePath(for: $0.url) < relativePath(for: $1.url) }
        otherFormatCount = tree.encryptedInOtherFormats.count
        incompleteScanReason = tree.incompleteScanReason
        skippedDirectoryNames = tree.skippedDirectoryNames.sorted()
        unfollowedDirectorySymlinks = tree.unfollowedDirectorySymlinks.sorted { $0.path < $1.path }
        rootMissing = tree.rootMissing
        rootUnreadable = tree.rootUnreadable
        configState = Self.resolveConfigState(projectRoot: projectRoot)
        lastTree = tree
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

    /// Whether `sniffed` counts as read-only ciphertext for the list badge —
    /// SOPS-38 phase F3. Deliberately conservative in both directions this
    /// app must never claim more than it knows about:
    ///
    /// - `sessionPublicKey == nil` (no key imported, the key expired, or —
    ///   see `SessionKeyStore.publicKey`'s own doc comment — real derivation
    ///   failed for a shape-valid key): **not** read-only. This app has no
    ///   public key to compare against, so it says nothing rather than
    ///   guess.
    /// - `sniffed.recipients.isEmpty`: **not** read-only either. An empty
    ///   list here means "this app could not read this file's own recipient
    ///   metadata" (an unrecognised shape, a non-age-only file, a read that
    ///   failed) at least as often as it could mean "this file genuinely
    ///   lists no age recipients" — either way, claiming read-only over
    ///   metadata this app could not actually establish is exactly the
    ///   vacuous verdict `ProjectHealthCheck.recipientFinding`'s own doc
    ///   comment exists to prevent, applied here to a UI badge instead of a
    ///   health finding.
    /// - Otherwise: read-only exactly when the session's public key is
    ///   genuinely absent from the file's own recipient list — a real,
    ///   positive fact read straight from the file, never inferred.
    ///
    /// This is a hint only. The list badge must never block opening a file
    /// it flags — see `ListedFile.isReadOnly`'s own doc comment — and the
    /// only true answer is whatever `SecretDocumentViewModel.load()` finds
    /// when it actually tries.
    private static func isReadOnly(_ sniffed: SniffedFile, sessionPublicKey: String?) -> Bool {
        guard let sessionPublicKey else { return false }
        let recipients = sniffed.recipients
        guard !recipients.isEmpty else { return false }
        return !recipients.contains(sessionPublicKey)
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
