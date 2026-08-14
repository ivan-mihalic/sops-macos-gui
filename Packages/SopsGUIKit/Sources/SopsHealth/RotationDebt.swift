import Foundation

/// Why a file or a project is owed a rotation of its secret values.
///
/// Lives in `SopsHealth`, not next to `SopsProjects.RotationDebtLedger`
/// (the type that actually persists this), because `ProjectHealthCheck`
/// needs this vocabulary and `SopsHealth` cannot depend on `SopsProjects` —
/// that dependency already runs the other way (`SopsProjects` depends on
/// `SopsHealth`, for `ProjectScanner`/`ScannedTree`). This is the shared
/// model both layers speak; the persistence engine that reads and writes it
/// to `.sops-gui/rotation-debt.json` stays with `RecipientRegistry`, whose
/// symlink-safe file-store technique it reuses — see
/// `RotationDebtLedger`'s own doc comment.
public enum RotationDebtReason: String, Codable, CaseIterable, Sendable {
    /// An age recipient was removed and the removal was applied — re-wrapped
    /// into the file, not merely staged — so the removed holder already had
    /// a chance to see every value the file held before the rewrap. Rotating
    /// a recipient set does not undo that; only changing the values does.
    case recipientRemoved
    /// This file's plaintext contents were found tracked by git and not
    /// gitignored. Anyone with access to the repository's history may
    /// already hold a copy, whether or not the file is tracked *now* —
    /// removing it from the index does not remove it from history.
    case plaintextCommitted
}

/// One outstanding rotation debt: a file, why it is owed, and when this app
/// first learned that.
public struct RotationDebtEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Project-relative path of the file this debt is about. Relative, like
    /// every other user-facing path this app prints, and never absolute —
    /// an absolute path would leak the project's location on disk into a
    /// file `.sops-gui/` documentation already says may be committed and
    /// shared.
    public var path: String
    public var reason: RotationDebtReason
    /// When this app first recorded the debt — the smallest possible
    /// estimate of how long it has been owed, never an authoritative "the
    /// value has been exposed since exactly this instant". This app cannot
    /// see changes made outside it (the CLI, another machine), so the debt
    /// may in fact be older than this date; it is never younger.
    public var recordedAt: Date

    public init(
        id: UUID = UUID(), path: String, reason: RotationDebtReason, recordedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

/// Where `ProjectHealthCheck` reads a project's outstanding rotation debt
/// and records a newly-discovered one — the seam `SopsProjects
/// .RotationDebtLedger` sits behind for callers in this module, which
/// cannot import that type directly (see this file's header).
///
/// `record(path:reason:in:)` must never throw and must never block on
/// anything a health check cannot recover from: a real implementation
/// backed by a file store is expected to fail silently (best-effort),
/// exactly as `SopsProjects.RotationDebtLedger`'s own callers already treat
/// a ledger write — the fact being recorded was already true before the
/// write was attempted, and a health check is in no position to react to a
/// storage failure mid-scan.
public protocol RotationDebtSource: Sendable {
    func rotationDebt(in project: URL) -> [RotationDebtEntry]
    func record(path: String, reason: RotationDebtReason, in project: URL)
}

/// A one-sentence, user-facing description of why an entry is owed — shared
/// between `ProjectHealthCheck`'s rotation-debt finding and any UI (the per-
/// file Access panel) that shows a single entry, so the two can never
/// describe the same fact two different ways.
public enum RotationDebtDescription {
    public static func sentence(for entry: RotationDebtEntry) -> String {
        switch entry.reason {
        case .recipientRemoved:
            return "A recipient was removed from it and the file was re-wrapped — they already had a chance to see its old values."
        case .plaintextCommitted:
            return "It was found tracked by git and not gitignored — its old values may already be in the repository's history."
        }
    }
}

/// The default for every caller that does not wire in a real, persistent
/// rotation-debt store — every test in this package, and `SopsGUIKit`
/// itself until something in `SopsProjects` or above supplies the real one.
/// Same role as `NoProjects` for `ProjectSourceProviding`.
public struct NoRotationDebt: RotationDebtSource {
    public init() {}
    public func rotationDebt(in project: URL) -> [RotationDebtEntry] { [] }
    public func record(path: String, reason: RotationDebtReason, in project: URL) {}
}
