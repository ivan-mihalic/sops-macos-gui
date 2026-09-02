import Foundation
import SopsEngine
import SopsHealth

/// Everything the Access page needs to show about a project's `.sops.yaml`
/// rules, its named keys, and how each encrypted file's actual recipients
/// compare against the rule that governs it — built from a single scan
/// (`ScannedTree`) and a single bridge call (`SopsBridge.inspectConfigRules`,
/// Task 3), never a second walk of the project.
///
/// This is a pure value, built once by `build(projectRoot:tree:inspect:)` and
/// carried on `ProjectRecipientApplier.Plan.inventory` — `plan()` already
/// walks the tree it is built from, so no caller needs to scan again just to
/// render the sidebar's per-file status dot or the Access page's rule list
/// and drift banner.
public struct AccessInventory: Equatable, Sendable {
    /// How one file's actual recipients compare to the recipients its
    /// governing rule declares.
    public enum FileStatus: Equatable, Sendable {
        /// The file is wrapped for exactly the recipients its rule declares.
        case inSync
        /// The file is wrapped for a different set than its rule declares —
        /// both sides sorted, so two sets differing only in order never
        /// report a spurious drift. `fileHas` is what the file's own
        /// metadata says today; `ruleWants` is what the rule would produce.
        case ruleDiffers(fileHas: [String], ruleWants: [String])
        /// No creation rule governs this file — no `.sops.yaml`, a config
        /// this app could not read, or a file no rule's `path_regex`
        /// matches.
        case ungoverned
    }

    /// One encrypted file paired with its status against the rule
    /// (if any) that governs it.
    public struct FileAccess: Identifiable, Equatable, Sendable {
        public let url: URL
        /// Path relative to the project root — the same form the file list
        /// already sorts by. See `ProjectRecipientApplier.projectRelativePath`.
        public let relativePath: String
        /// The on-disk document shape this file was sniffed as — carried
        /// through from `EncryptedFile.format` so a later caller (a rewrap
        /// action driven off this inventory) never has to guess or assume
        /// `.yaml`.
        public let format: SopsFileFormat
        /// Position of the governing rule in `AccessInventory.rules`, `nil`
        /// when no rule governs this file (including an out-of-range index
        /// the bridge could not have produced but which is treated the same
        /// way defensively — see `build`).
        public let ruleIndex: Int?
        /// The age recipients this file's own metadata says it is wrapped
        /// for today, sorted.
        public let encryptedFor: [String]
        public let status: FileStatus
        public var id: URL { url }

        public init(
            url: URL, relativePath: String, format: SopsFileFormat, ruleIndex: Int?,
            encryptedFor: [String], status: FileStatus
        ) {
            self.url = url
            self.relativePath = relativePath
            self.format = format
            self.ruleIndex = ruleIndex
            self.encryptedFor = encryptedFor
            self.status = status
        }
    }

    /// A file this inventory was built from, format-tagged so `build` never
    /// needs to depend on `SopsHealth.SniffedFile`'s internal `tail` — only
    /// on what any caller (a real scan, or a test) can construct.
    public struct EncryptedFile: Equatable, Sendable {
        public let url: URL
        public let format: SopsFileFormat
        public let recipients: [String]

        public init(url: URL, format: SopsFileFormat, recipients: [String]) {
            self.url = url
            self.format = format
            self.recipients = recipients
        }
    }

    public let keys: [ConfigRules.NamedKey]
    public let rules: [ConfigRules.Rule]
    /// One entry per encrypted file, sorted ascending by `relativePath` — the
    /// order the file list already shows.
    public let files: [FileAccess]
    /// The bridge's own failure text when `.sops.yaml` exists but could not
    /// be inspected — never a key or document value. `nil` both when there
    /// is no config at all (not an error — see `build`) and when inspection
    /// succeeded.
    public let configError: String?

    public init(
        keys: [ConfigRules.NamedKey], rules: [ConfigRules.Rule], files: [FileAccess],
        configError: String?
    ) {
        self.keys = keys
        self.rules = rules
        self.files = files
        self.configError = configError
    }

    /// The inventory for a project with nothing to show — no files, no
    /// rules, no error. What every early-return branch of
    /// `ProjectRecipientApplier.plan()` uses for `Plan.inventory` rather than
    /// scanning again for a plan that already returned nothing.
    public static let empty = AccessInventory(keys: [], rules: [], files: [], configError: nil)

    /// Builds an inventory from a project's own scan result, `tree` — the
    /// same one `plan()` produces — mapping each `SniffedFile` to the
    /// format-tagged `EncryptedFile` the core builder below needs. See that
    /// overload's doc comment for what this actually computes.
    public static func build(
        projectRoot: URL, tree: ScannedTree,
        inspect: (String, [String]) throws -> ConfigRules = SopsBridge.inspectConfigRules
    ) -> AccessInventory {
        let files = tree.encrypted.map {
            EncryptedFile(url: $0.url, format: $0.format, recipients: $0.recipients)
        }
        return build(projectRoot: projectRoot, files: files, inspect: inspect)
    }

    /// Builds an inventory from an explicit file list — the seam
    /// `AccessInventoryTests` drives directly, and what the `tree:`
    /// overload above delegates to once it has stripped `SniffedFile` down
    /// to what this needs.
    ///
    /// A missing `.sops.yaml` is not an error: every file is reported
    /// `.ungoverned` and `configError` stays `nil`. A `.sops.yaml` that
    /// exists but the bridge could not inspect *is* an error: every file is
    /// still reported `.ungoverned` (there is no rule to compare against),
    /// but `configError` carries the bridge's own failure text.
    public static func build(
        projectRoot: URL, files: [EncryptedFile],
        inspect: (String, [String]) throws -> ConfigRules = SopsBridge.inspectConfigRules
    ) -> AccessInventory {
        let rel = { (u: URL) in ProjectRecipientApplier.projectRelativePath(u, under: projectRoot) }
        let sorted = files.sorted { rel($0.url) < rel($1.url) }

        let configURL = projectRoot.appendingPathComponent(".sops.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return AccessInventory(
                keys: [], rules: [],
                files: sorted.map { fileAccess($0, ruleIndex: nil, rules: [], rel: rel) },
                configError: nil)
        }

        // Both the config path and every candidate go through
        // `ProjectRecipientApplier.ruleMatchingPath` before crossing into the
        // bridge — the same seam `plan()`'s own `proposeConfig` call already
        // uses (`ProjectRecipientApplier.swift`, `Self.ruleMatchingPath`).
        // sops's Go side matches a creation rule by stripping the config's
        // *own directory* off a file's path as a literal prefix
        // (`parseCreationRuleForFile`), which only works if both paths are
        // spelled the same way. `FileManager.enumerator` (what populated
        // `files` here) hands back entries with symlinks in the directory
        // prefix already resolved (`/var/…` → `/private/var/…` — true of
        // every scratch directory on this machine), while `projectRoot` and
        // therefore `configURL` keep whatever form they were constructed
        // with. Left unresolved, the prefix strip is a no-op, every rule is
        // matched against an absolute path, and an anchored `path_regex`
        // like `^secrets/` matches nothing — every file comes back
        // `.ungoverned` regardless of what the config actually says. Reading
        // `rules.governedBy` back keyed by the identical resolved string
        // keeps the lookup consistent with what was actually sent.
        let resolvedConfigPath = ProjectRecipientApplier.ruleMatchingPath(configURL)
        let resolvedPath = { (u: URL) in ProjectRecipientApplier.ruleMatchingPath(u) }

        let rules: ConfigRules
        do {
            rules = try inspect(resolvedConfigPath, sorted.map { resolvedPath($0.url) })
        } catch {
            return AccessInventory(
                keys: [], rules: [],
                files: sorted.map { fileAccess($0, ruleIndex: nil, rules: [], rel: rel) },
                configError: String(describing: error))
        }

        let fileAccesses = sorted.map {
            fileAccess(
                $0, ruleIndex: rules.governedBy[resolvedPath($0.url)], rules: rules.rules, rel: rel)
        }
        return AccessInventory(
            keys: rules.keys, rules: rules.rules, files: fileAccesses, configError: nil)
    }

    private static func fileAccess(
        _ file: EncryptedFile, ruleIndex: Int?, rules: [ConfigRules.Rule], rel: (URL) -> String
    ) -> FileAccess {
        // `has == wants` below is a sorted-*list* comparison, deliberately
        // not a `Set` one: a rule or a file listing the same age recipient
        // twice is itself a shape worth flagging as drift rather than
        // silently collapsing away, and neither `ConfigRules` (Task 3) nor
        // `SniffedFile.recipients` promises deduplication on this app's
        // behalf. Sorting alone is enough to make the comparison
        // order-insensitive without hiding a duplicate.
        let has = file.recipients.sorted()
        let status: FileStatus
        // `ruleIndex` bounds-checked against `rules.count` rather than
        // trusted outright: `governedBy` comes straight from the bridge, and
        // an index it could never actually produce is treated the same as no
        // rule at all rather than crashing on `rules[i]`.
        if let index = ruleIndex, rules.indices.contains(index) {
            let wants = rules[index].recipients.map(\.recipient).sorted()
            status = has == wants ? .inSync : .ruleDiffers(fileHas: has, ruleWants: wants)
        } else {
            status = .ungoverned
        }
        return FileAccess(
            url: file.url, relativePath: rel(file.url), format: file.format, ruleIndex: ruleIndex,
            encryptedFor: has, status: status)
    }

    /// Every file `ruleIndex` (a position in `rules`) governs, in the same
    /// order as `files`.
    public func files(governedBy ruleIndex: Int) -> [FileAccess] {
        files.filter { $0.ruleIndex == ruleIndex }
    }

    /// The anchor name `keys` recorded for `recipient`, or `nil` for an
    /// unnamed (inline) recipient (`NamedKey.name` is empty for those — see
    /// its own doc comment) or one this inventory does not know about.
    public func name(for recipient: String) -> String? {
        guard let key = keys.first(where: { $0.recipient == recipient }), !key.name.isEmpty else {
            return nil
        }
        return key.name
    }

    /// Every file whose status is `.ruleDiffers` — the set a project-wide
    /// rewrap should touch.
    public var filesNeedingRewrap: [FileAccess] {
        files.filter {
            if case .ruleDiffers = $0.status { return true }
            return false
        }
    }
}
