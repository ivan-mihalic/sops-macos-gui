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
    public private(set) var wasTruncated = false
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
    /// half-updated combination (e.g. `wasTruncated` from the new scan next
    /// to `files` from the old one).
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
        wasTruncated = tree.wasTruncated
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
/// A `wasTruncated` scan says so directly in this list — Task 9's brief is
/// explicit that this is exactly where a user would otherwise assume they
/// are seeing every file, since `ProjectScanner` already knows and reports
/// it (Task 1/1b) but nothing downstream of the health check has shown it
/// to a user yet.
public struct FileListView: View {
    @Bindable private var model: FileListModel
    @Binding private var selection: URL?

    public init(model: FileListModel, selection: Binding<URL?>) {
        self.model = model
        self._selection = selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.wasTruncated {
                truncationBanner
            }

            content
        }
        .task(id: model.projectRoot) {
            await model.refresh()
        }
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
        } else if model.files.isEmpty {
            statusPlaceholder(systemImage: "doc.text.magnifyingglass", title: .filesEmptyTitle)
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

            if model.otherFormatCount > 0 {
                Divider()
                Text(String(format: LocalizedKey.filesOtherFormatNote.text, model.otherFormatCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var truncationBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(.filesTruncatedTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if !model.skippedDirectoryNames.isEmpty {
                Text(String(format: LocalizedKey.filesTruncatedDetail.text,
                            model.skippedDirectoryNames.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}
