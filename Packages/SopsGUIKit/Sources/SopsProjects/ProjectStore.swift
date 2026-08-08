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
    /// The path as the user chose it — absolute, and with `.`/`..`/trailing
    /// slashes collapsed lexically, but with any symlink component left
    /// exactly as typed. `rootPath` above is the *identity* key (symlink-
    /// resolved, see `ProjectStore.normalize(_:)`); this is the *display*
    /// value. They differ exactly when the chosen path passes through a
    /// symlink — a symlinked home directory (iCloud Desktop/Documents does
    /// this) or a symlinked dev volume being the two real-world cases. See
    /// `ProjectStore.add(path:)` for why the two must not be the same field.
    public var displayPath: String
    public var addedAt: Date

    public init(id: UUID = UUID(), displayName: String, rootPath: String, displayPath: String? = nil,
                addedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        // Tests and any other caller that doesn't care about the distinction
        // can omit `displayPath`; it falls back to `rootPath` rather than
        // forcing every call site in the test suite to spell out a field
        // that's only ever different from `rootPath` when a symlink is
        // involved.
        self.displayPath = displayPath ?? rootPath
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, rootPath, displayPath, addedAt
    }

    /// Migrating decoder. `displayPath` did not exist before this task — a
    /// `projects.json` written by a Task 3 or Task 4 build has `id`,
    /// `displayName`, `rootPath` and `addedAt` only. The compiler-synthesized
    /// `Decodable` this type would otherwise get treats `displayPath` as a
    /// required key like any other non-optional stored property, so decoding
    /// such a file fails outright — and `ProjectStore.load(from:)` used to
    /// swallow that failure into an empty list indistinguishable from a new
    /// user's, silently forgetting every project the file actually named.
    /// Reviewer-verified: fed a literal pre-`displayPath` JSON string and
    /// got `projects.count == 0` back.
    ///
    /// `displayPath` missing from the payload defaults to `rootPath` —
    /// exactly what it was before this task existed, since `rootPath` *was*
    /// the display value then (see `ProjectStore.normalize(_:)`'s doc
    /// comment for that history). A project decoded this way shows exactly
    /// what it always showed; it only gets a *distinct* `displayPath` again
    /// if it's removed and re-added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        displayPath = try container.decodeIfPresent(String.self, forKey: .displayPath) ?? rootPath
        addedAt = try container.decode(Date.self, forKey: .addedAt)
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
    /// Set at `init` when the store file exists but could not be read —
    /// unreadable data, or JSON that doesn't decode as `[StoredProject]` even
    /// after the migration `StoredProject.init(from:)` allows for. `nil` in
    /// every other case, *including* "no file exists yet", which is not an
    /// error — it is what a new user's Application Support directory looks
    /// like before they add a first project. Conflating the two used to mean
    /// an unreadable file and an empty project list were the same fact as
    /// far as anything downstream could tell; they are not, and this app's
    /// standing rule is that it never claims more than it established — an
    /// empty sidebar is a claim ("you have no projects"), and it must not be
    /// shown in place of the true one ("your saved projects could not be
    /// read"). `ProjectSidebarModel` surfaces this through its own
    /// `lastError` at construction time.
    public private(set) var loadError: String?
    /// `true` only in the narrow case where the store file existed, could not
    /// be read, and this app also failed to move it out of the way (see
    /// `quarantine(_:reason:)`). `add`/`remove` refuse to persist anything
    /// while this is `true` — see `persist(_:)`'s first guard.
    ///
    /// This exists to close a specific incident: `add`/`remove` used to
    /// build `candidate` from `self.projects`, which is the *false empty*
    /// list a failed load produces, and persist it through the same
    /// atomic-replace path a normal write uses — silently overwriting a
    /// store file that was unreadable, not empty. A user or a support
    /// conversation could have recovered bytes that started with `{"id":`
    /// by hand; the moment `add` or `remove` ran, they couldn't, because
    /// nothing before this ever asked whether the load had actually
    /// succeeded. `load(from:)` now tries to move the bad file aside first
    /// (see `quarantine(_:reason:)`), which is enough to make normal writes
    /// safe again — this flag only matters in the case where even *that*
    /// failed, and the original bytes are still sitting where the next
    /// write would land.
    private let unsafeToWrite: Bool

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
        let loaded = Self.load(from: fileURL)
        self.projects = loaded.projects
        self.loadError = loaded.error
        self.unsafeToWrite = loaded.unsafeToWrite
    }

    /// Adds `path` as a project. Fails if `path` is not a directory, or if
    /// a project with the same path has already been added — in which case
    /// the existing entry is returned via the error so the caller can, say,
    /// select it instead of silently duplicating it.
    ///
    /// `path` is normalized (symlinks resolved, `..`/`.`, trailing slashes,
    /// and relative components collapsed) before both the existence check
    /// and the duplicate comparison, and that *identity-normalized* path is
    /// what gets stored as `rootPath` — see `normalize(_:)` for why. A
    /// separate, lexically-standardized-but-not-symlink-resolved form of
    /// `path` is stored as `displayPath` — see `standardizeForDisplay(_:)`
    /// and `StoredProject.displayPath`'s doc comment for why identity and
    /// display are kept apart.
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

        let displayPath = Self.standardizeForDisplay(path)
        let name = (displayPath as NSString).lastPathComponent
        let project = StoredProject(displayName: name, rootPath: normalizedPath, displayPath: displayPath)
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
        // Refuse outright rather than risk destroying a store file this
        // process could not read *and* could not move out of the way at
        // load time. See `unsafeToWrite`'s doc comment for the incident this
        // closes. Checked first, before encoding even starts — there is
        // nothing safe to do with `candidate` in this state, encoding it
        // would just be wasted work on the way to the same refusal.
        guard !unsafeToWrite else { throw Error.unreadable }

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

    /// Loads the store from disk. Never throws at launch — a project list is
    /// not worth crashing the app over — but a file that exists and could
    /// not be read is a materially different fact from no file existing at
    /// all, and the two are kept apart in the returned `error`:
    ///
    /// - No file at `url`: brand new user, or every project was removed.
    ///   `error` is `nil` — an empty list is the honest, complete answer.
    /// - A file exists but its bytes can't be read, or its JSON doesn't
    ///   decode as `[StoredProject]` even through the migrating
    ///   `StoredProject.init(from:)` — this is a **recoverable** failure: the
    ///   bytes on disk might still be salvageable by hand (a truncated write,
    ///   a hand-edited file with a typo, anything short of physical media
    ///   failure). `load` tries to move the file out of the way of any
    ///   future write before returning — see `quarantine(_:reason:)` — so
    ///   the *next* thing this app does is never "silently overwrite the one
    ///   copy of data the user might still recover." `error` is set either
    ///   way, and `projects` comes back empty *not because that is true*,
    ///   but because there is nothing else this method can safely return.
    ///   The caller (`ProjectStore`, then `ProjectSidebarModel`) is
    ///   responsible for telling the user `error` rather than rendering the
    ///   empty list as if it were real.
    private static func load(from url: URL) -> (projects: [StoredProject], error: String?, unsafeToWrite: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, false) }

        guard let data = try? Data(contentsOf: url) else {
            return quarantine(url, reason: "could not be read")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let projects = try decoder.decode([StoredProject].self, from: data)
            return (projects, nil, false)
        } catch {
            return quarantine(url, reason: "could not be read: \(error)")
        }
    }

    /// Moves a store file this app could not read out of the way, so the
    /// very next `add`/`remove` — which writes a fresh, correctly-shaped
    /// file to the same `url` — cannot silently overwrite it.
    ///
    /// This is the fix for the incident named in `unsafeToWrite`'s doc
    /// comment, and the "move it aside" choice over "just refuse every write
    /// until the user fixes it by hand" is deliberate: it lets the user keep
    /// using the app immediately — `projects` comes back `[]`, which is now
    /// *actually* true at `url`, not a lie — while the original bytes wait,
    /// untouched, at a sibling path named in the error text, in case they're
    /// worth recovering by hand or over a support conversation. A pure
    /// refuse-until-fixed store is its own trap: it has no way to say "I
    /// accept the loss, start fresh" short of the user finding and deleting
    /// the file outside the app anyway — which this achieves automatically,
    /// with nothing thrown away.
    ///
    /// The one case this can't make safe on its own is the move itself
    /// failing — an immutable flag on the file, or a directory this process
    /// can't write to. `unsafeToWrite` exists for exactly that case: the
    /// original bytes are still sitting at `url`, so every write is refused
    /// (`persist(_:)`'s guard) until the user resolves it — by hand, outside
    /// this app, since this app could not even move the file without the
    /// same permission a write would need. `error`, returned either way,
    /// names the exact path so that resolution is possible.
    private static func quarantine(
        _ url: URL, reason: String
    ) -> (projects: [StoredProject], error: String?, unsafeToWrite: Bool) {
        let backupURL = quarantinedURL(for: url)
        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
            return ([], "Your saved project list at \(url.path) \(reason), so it has been moved aside to \(backupURL.path) in case it can be recovered by hand. Starting fresh from here — nothing was deleted, and nothing was added automatically.", false)
        } catch {
            return ([], "Your saved project list at \(url.path) \(reason), and this app could not move it aside to protect it either (\(error)). To avoid losing it, this app will not save any project changes until the file at that path is moved, renamed, or deleted by hand.", true)
        }
    }

    /// A sibling path for `url`'s quarantined backup:
    /// `projects-corrupt-<timestamp>.json` next to `projects.json`. No
    /// colons in the timestamp — `:` is legal in a raw POSIX filename on
    /// APFS, but Finder still renders it as `/` and some tooling still
    /// balks, and nothing here needs a colon to be unambiguous.
    private static func quarantinedURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let stamp = Self.quarantineTimestampFormatter.string(from: Date())
        let name = ext.isEmpty ? "\(base)-corrupt-\(stamp)" : "\(base)-corrupt-\(stamp).\(ext)"
        return directory.appendingPathComponent(name)
    }

    private static let quarantineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

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
    /// duplicate would corrupt).
    ///
    /// This *used* to also be what got displayed — `displayName` was derived
    /// from this same resolved path — on the theory that the two concerns
    /// were one. They are not: a user who adds `~/work/project` through a
    /// symlinked home (iCloud Desktop/Documents does this, so does a `~/dev`
    /// symlink to a second volume) would see a path they do not recognize in
    /// the sidebar, forever, even though nothing about their input was wrong.
    /// `add(path:)` now keeps this value for identity/dedup only and stores
    /// what the user actually chose, separately, via
    /// `standardizeForDisplay(_:)` — see `StoredProject.displayPath`.
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Lexically standardizes `path` for *display*: makes it absolute and
    /// collapses `.`/`..` components and a trailing slash, exactly like
    /// `normalize(_:)` above — but, unlike `normalize(_:)`, never resolves a
    /// symlink. `URL.standardizedFileURL` is documented to do the lexical
    /// half without touching the filesystem (the same guarantee
    /// `WorktreeResolver` relies on for the same reason), so a symlink
    /// component the user's path passes through survives exactly as typed.
    ///
    /// This is why `add(path:)` needs two functions instead of one: this one
    /// answers "what should the user see", `normalize(_:)` answers "what
    /// identifies this directory regardless of how it was spelled" — and a
    /// symlinked path is the one case where those two questions have
    /// different honest answers.
    private static func standardizeForDisplay(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
