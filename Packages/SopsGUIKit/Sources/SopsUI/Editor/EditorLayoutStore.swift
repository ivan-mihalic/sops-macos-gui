import Foundation
import SopsEngine
import SopsHealth
import SwiftUI

/// The secret table's column layout — widths and order — remembered per
/// file, so a layout the user dragged into shape survives a relaunch
/// (SOPS-40).
///
/// ## Why per file and not per project
/// A file lives in exactly one project, so keying by the file's canonical
/// path already distinguishes `momentak/secrets/prod.sops.env` from
/// `invoi/secrets/prod.sops.env`. Two projects that contain the same file
/// through a symlink resolve to one key, which is the right answer: it is
/// one file.
///
/// ## What is stored
/// SwiftUI's own `TableColumnCustomization`, which is `Codable` and carries
/// visibility, order and width for every column that has a
/// `customizationID`. Only visibility is readable back through its public
/// API, so `EditorLayoutStoreTests` pins the round trip through that field
/// and a source scan pins that every column takes part.
///
/// One `[String: Data]` dictionary under a single key rather than a key per
/// file, so `forget(_:)` and a future "reset layouts" have one place to
/// look, and `defaults read` shows the whole set at once.
public enum EditorLayoutStore {
    public static let defaultsKey = "editor.columnLayouts"

    public static func columns(
        for fileURL: URL, in defaults: UserDefaults = .standard
    ) -> TableColumnCustomization<SecretRow> {
        guard let data = table(in: defaults)[key(for: fileURL)],
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<SecretRow>.self, from: data)
        else { return TableColumnCustomization() }
        return decoded
    }

    public static func setColumns(
        _ columns: TableColumnCustomization<SecretRow>, for fileURL: URL, in defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(columns) else { return }
        var all = table(in: defaults)
        all[key(for: fileURL)] = data
        defaults.set(all, forKey: defaultsKey)
    }

    public static func forget(_ fileURL: URL, in defaults: UserDefaults = .standard) {
        var all = table(in: defaults)
        all.removeValue(forKey: key(for: fileURL))
        defaults.set(all, forKey: defaultsKey)
    }

    private static func key(for fileURL: URL) -> String {
        CanonicalPath.of(fileURL.path)
    }

    private static func table(in defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
