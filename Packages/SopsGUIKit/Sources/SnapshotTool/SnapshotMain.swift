import AppKit
import Foundation

// snapshots — renders the view catalog to PNG.
//
//   swift run snapshots [output-directory] [name-filter]
//
// With no arguments, writes to `.snapshots/` at the package root. `filter`
// is a substring of a snapshot's name, e.g. `swift run snapshots .snapshots
// wizard`.
//
// Exits 1 if any snapshot failed to render, or if building the catalog
// itself threw (a fixture's `git` call failing, say) — so both a CI check
// and a human running the script see a nonzero exit rather than a silently
// incomplete output directory.
@main
struct SnapshotMain {
    @MainActor
    static func main() async {
        // AppKit needs an initialized `NSApplication`, even though no window
        // is ever opened — without it, `ImageRenderer` can crash on an
        // uninitialized font/appearance stack for some views, and
        // `SnapshotRenderer` needs `NSApplication.shared.appearance` to
        // force native chrome into the right light/dark look (see
        // `Snapshot.swift`'s header comment).
        _ = NSApplication.shared

        let arguments = CommandLine.arguments.dropFirst()
        let outputDirectory = URL(fileURLWithPath: arguments.first ?? ".snapshots", isDirectory: true)
        let filter = arguments.dropFirst().first

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let all: [Snapshot]
        do {
            all = try await Catalog.all()
        } catch {
            FileHandle.standardError.write(Data("could not build the snapshot catalog: \(error)\n".utf8))
            exit(1)
        }

        let snapshots = all.filter { snapshot in
            guard let filter else { return true }
            return snapshot.name.contains(filter)
        }
        guard !snapshots.isEmpty else {
            FileHandle.standardError.write(Data("no snapshot matches filter \(filter ?? "")\n".utf8))
            exit(1)
        }

        var failures: [String] = []
        for snapshot in snapshots {
            guard let data = SnapshotRenderer.png(for: snapshot) else {
                failures.append(snapshot.name)
                continue
            }
            let url = outputDirectory.appendingPathComponent("\(snapshot.name).png")
            do {
                try data.write(to: url)
                let w = Int(snapshot.size.width)
                let h = Int(snapshot.size.height)
                print("\u{2713} \(snapshot.name).png  (\(w)\u{00D7}\(h) pt, \(data.count / 1024) kB)")
            } catch {
                failures.append(snapshot.name)
            }
        }

        print("\n\(snapshots.count - failures.count)/\(snapshots.count) snapshots written to \(outputDirectory.path)")
        if !failures.isEmpty {
            FileHandle.standardError.write(Data("FAILED: \(failures.joined(separator: ", "))\n".utf8))
            exit(1)
        }
    }
}
