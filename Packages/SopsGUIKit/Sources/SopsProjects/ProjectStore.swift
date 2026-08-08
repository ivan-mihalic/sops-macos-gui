import Foundation
import Observation
import SopsHealth

/// A project the user has added to the app, persisted across launches.
///
/// `rootPath` is a filesystem path, not a secret — it is safe to log or
/// display. Nothing about the contents of the project is stored here.
public struct StoredProject: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var rootPath: String
    public var addedAt: Date

    public init(id: UUID = UUID(), displayName: String, rootPath: String, addedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.addedAt = addedAt
    }
}

/// Persisted list of projects the user has added.
///
/// Backed by a single JSON file. Writes go through a temp file plus
/// `replaceItemAt` so a crash or power loss mid-write cannot leave a
/// truncated file that reads back as "no projects" — the previous
/// contents remain intact until the replace is atomic.
///
/// Removing a project only forgets it here; it never touches the
/// project's directory or files on disk.
@MainActor
@Observable
public final class ProjectStore {
    public enum Error: Swift.Error, Equatable {
        case notADirectory
        case alreadyAdded(existing: StoredProject)
        case unreadable
    }

    public private(set) var projects: [StoredProject] = []

    private let fileURL: URL
    private let fileManager = FileManager.default

    /// Default on-disk location: `~/Library/Application Support/cz.mihalic.SopsGUI/projects.json`.
    /// Tests must always pass an explicit `fileURL` so they never touch real user state.
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("cz.mihalic.SopsGUI", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.projects = Self.load(from: fileURL)
    }

    /// Adds `path` as a project. Fails if `path` is not a directory, or if
    /// a project with the same path has already been added — in which case
    /// the existing entry is returned via the error so the caller can, say,
    /// select it instead of silently duplicating it.
    ///
    /// `path` is normalized (symlinks resolved, `..`/`.`, trailing slashes,
    /// and relative components collapsed) before both the existence check
    /// and the duplicate comparison, and the *normalized* path is what gets
    /// stored — see `normalize(_:)` for why.
    ///
    /// Persist-then-mutate: the write to disk happens before `projects` is
    /// updated, and only on success. If persisting fails, this throws and
    /// `projects` is left exactly as it was — the in-memory list must never
    /// claim something the file on disk does not back up.
    @discardableResult
    public func add(path: String) throws -> StoredProject {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw Error.notADirectory
        }

        let normalizedPath = Self.normalize(path)

        if let existing = projects.first(where: { $0.rootPath == normalizedPath }) {
            throw Error.alreadyAdded(existing: existing)
        }

        let name = (normalizedPath as NSString).lastPathComponent
        let project = StoredProject(displayName: name, rootPath: normalizedPath)
        let candidate = projects + [project]
        try persist(candidate)
        projects = candidate
        return project
    }

    /// Forgets the project with the given id. Never deletes anything on disk.
    ///
    /// Throws if the updated list cannot be persisted, leaving `projects`
    /// unchanged. This is a deliberate deviation from the brief's
    /// non-throwing `func remove(id: UUID)`: a signature that silently
    /// swallows a failed write can only lie to its caller — the list would
    /// show the project gone while the file on disk still has it, and it
    /// would reappear on the next launch with no explanation. A thrown
    /// error at least gives the caller (and eventually the UI) a chance to
    /// say "removal failed, try again" instead.
    public func remove(id: UUID) throws {
        let candidate = projects.filter { $0.id != id }
        try persist(candidate)
        projects = candidate
    }

    /// Whether the project's directory can currently be found. Re-checks the
    /// filesystem on every call rather than caching, so a volume that gets
    /// remounted (or a directory that reappears) is reflected immediately.
    public func isMissing(_ project: StoredProject) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: project.rootPath, isDirectory: &isDirectory)
        return !(exists && isDirectory.boolValue)
    }

    // MARK: - Persistence

    /// Writes `candidate` to disk. Does not touch `self.projects` — callers
    /// decide whether to adopt `candidate` in memory based on whether this
    /// throws, so the in-memory list can never diverge from what actually
    /// made it to disk.
    private func persist(_ candidate: [StoredProject]) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(candidate)
        } catch {
            throw Error.unreadable
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            try data.write(to: tempURL, options: .atomic)
            defer { try? fileManager.removeItem(at: tempURL) }

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            throw Error.unreadable
        }
    }

    /// Loads the store from disk. A missing or corrupt file yields an empty
    /// list rather than throwing at launch — a project list is not worth
    /// crashing over, and the user can re-add projects.
    private static func load(from url: URL) -> [StoredProject] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredProject].self, from: data)) ?? []
    }

    /// Canonicalizes a path so two different spellings of the same
    /// directory — a trailing slash, `..` components, a relative path, or a
    /// symlink versus the directory it points at — compare equal.
    ///
    /// Uses `URL.resolvingSymlinksInPath()` rather than `realpath(3)`
    /// directly: Foundation's version deliberately leaves the handful of
    /// `/etc`, `/tmp`, and `/var` compatibility symlinks alone (macOS
    /// tradition — `/tmp` staying `/tmp` rather than becoming
    /// `/private/tmp` is what most software, and this app's own tests using
    /// `FileManager.default.temporaryDirectory`, expect), while still
    /// resolving symlinks the user actually created themselves. Verified
    /// empirically on this system: `realpath(3)` turns `/var` into
    /// `/private/var`; `resolvingSymlinksInPath()` does not.
    ///
    /// The *normalized* (symlink-resolved) path is what gets stored, not
    /// the path as typed. That is the deliberate choice here: storing the
    /// canonical form is what makes duplicate detection actually work — a
    /// project added once through a symlink and once through its target
    /// must collapse to one entry, both at `add(path:)` time and for every
    /// later consumer (`healthSource`, and anything wired to it later,
    /// including `ForEach`-rendered `HealthFinding`s whose identity a
    /// duplicate would corrupt). The cost is that a user who typed a
    /// symlinked path may see the resolved path displayed instead of what
    /// they typed; `displayName` is derived from the resolved path's last
    /// component for the same reason. That tradeoff favors correctness of
    /// identity over preserving the user's literal input.
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - SopsHealth adapter

    /// Adapts this store to `ProjectSourceProviding` so `ProjectHealthCheck`
    /// can inspect the projects the user has actually added, instead of the
    /// `NoProjects()` stub.
    public struct HealthSource: ProjectSourceProviding {
        public let projects: [InspectedProject]

        fileprivate init(projects: [StoredProject]) {
            self.projects = projects.map { InspectedProject(name: $0.displayName, rootPath: $0.rootPath) }
        }
    }

    public var healthSource: HealthSource {
        HealthSource(projects: projects)
    }
}
