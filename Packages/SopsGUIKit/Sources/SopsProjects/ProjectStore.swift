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
    @discardableResult
    public func add(path: String) throws -> StoredProject {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw Error.notADirectory
        }

        if let existing = projects.first(where: { $0.rootPath == path }) {
            throw Error.alreadyAdded(existing: existing)
        }

        let name = (path as NSString).lastPathComponent
        let project = StoredProject(displayName: name, rootPath: path)
        projects.append(project)
        try persist()
        return project
    }

    /// Forgets the project with the given id. Never deletes anything on disk.
    public func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        try? persist()
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

    private func persist() throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(projects)
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
