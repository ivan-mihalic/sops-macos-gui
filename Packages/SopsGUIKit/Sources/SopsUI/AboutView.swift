import SopsEngine
import SwiftUI

/// What this app can truthfully say about itself.
///
/// It exists because the About row in the sidebar showed nothing at all — the
/// detail pane fell through to the same "nothing selected" placeholder the app
/// shows when the user has selected nothing, so one of the two rows PROPOSAL §4
/// pins to the bottom of the sidebar was decoration in the shipped build.
///
/// Every field is read, never assumed. A version pane that guesses is worse
/// than one that says it does not know: its whole job is telling a user which
/// build is in front of them when something goes wrong, and a plausible-looking
/// "1.0" invented by a missing-key fallback would send a bug report to the
/// wrong commit.
public struct AboutFacts: Equatable, Sendable {
    /// What is printed when a key is not in the bundle. Not an empty string —
    /// blank space next to a label reads as "there is no version", which is a
    /// different and untrue statement.
    public static let unknownValue = "unknown"

    public let version: String
    public let build: String
    /// Baked in by `Scripts/bake-build-number.sh`. Absent in a development
    /// build run straight from Xcode without that phase, hence optional.
    public let commit: String?
    public let sops: String
    public let age: String

    public init(version: String, build: String, commit: String?, sops: String, age: String) {
        self.version = version
        self.build = build
        self.commit = commit
        self.sops = sops
        self.age = age
    }

    public static func read(from bundle: Bundle = .main,
                            sops: String = EngineVersion.sops,
                            age: String = EngineVersion.age) -> AboutFacts {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        return AboutFacts(
            version: string("CFBundleShortVersionString") ?? unknownValue,
            build: string("CFBundleVersion") ?? unknownValue,
            commit: string("SopsGUICommit"),
            sops: sops,
            age: age)
    }

    /// `0.1.0 (123) · d85cae8` — one line a user can paste into a bug report.
    /// The commit half is dropped entirely when absent rather than printed as
    /// "unknown", which would leave a separator pointing at nothing.
    public var versionLine: String {
        let head = "\(version) (\(build))"
        guard let commit else { return head }
        return "\(head) · \(commit)"
    }
}

/// The About pane, shown in the detail column for the sidebar's About row.
public struct AboutView: View {
    private let facts: AboutFacts

    public init(facts: AboutFacts = .read()) {
        self.facts = facts
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(.aboutAppName).font(.title2).bold()
                Text(facts.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().frame(maxWidth: 320)

            // Named because they are what actually does the encrypting: the
            // engine is compiled into this app, so "which sops do I have" is
            // answered here and not by whatever is on the user's PATH. The
            // health check says the same thing about the same two versions.
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(LocalizedKey.aboutEngineSops.text, value: facts.sops)
                LabeledContent(LocalizedKey.aboutEngineAge.text, value: facts.age)
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: 320)

            Link(LocalizedKey.aboutReleasesLink.text,
                 destination: URL(string: "https://github.com/ivan-mihalic/sops-macos-gui-releases")!)
                .font(.callout)

            Text(.aboutPrivacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
