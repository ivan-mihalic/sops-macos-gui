import AppKit
import SwiftUI
import SopsProjects

/// Gives the app a decryption key for the session: a paste field, and a
/// separate, explicit "Import from `~/.config/sops/age/keys.txt`" action.
///
/// The legacy-file import is a button, never something this view does on
/// its own `onAppear` or similar — `SecurityPostureCheck`'s
/// `security.legacy-key-file` finding exists specifically to warn the user
/// that file sits on disk unprotected, and silently reading it the moment
/// this view opens would contradict that warning with the app's own
/// behavior. The user has to ask for it.
public struct KeyImportView: View {
    @Bindable private var store: SessionKeyStore
    @State private var pastedText: String = ""
    @State private var errorMessage: String?
    @State private var justImportedFromLegacyFile = false
    @State private var didCopyChmodCommand = false

    /// Not user-configurable — this is the one well-known path §2/§6 of
    /// PROPOSAL.md and `SecurityPostureCheck.legacyKeyFilePath` both name.
    /// A picker here would suggest the app can import *any* file, which
    /// would need a very different — and much larger — conversation about
    /// what "import" does with an arbitrary path.
    private static let legacyKeyFilePath = NSHomeDirectory() + "/.config/sops/age/keys.txt"

    public init(store: SessionKeyStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                statusRow
            }

            Section {
                TextEditor(text: $pastedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .accessibilityLabel(LocalizedKey.keyPasteHeader.text)

                HStack {
                    Button(LocalizedKey.keyImportPasteButton.text) {
                        importPastedText()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    if store.state == .configured {
                        Button(LocalizedKey.keyForgetButton.text, role: .destructive) {
                            store.forget()
                            justImportedFromLegacyFile = false
                        }
                    }
                }
            } header: {
                Text(.keyPasteHeader)
            } footer: {
                Text(.keyPasteFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button(LocalizedKey.keyImportLegacyButton.text) {
                    importFromLegacyFile()
                }

                if justImportedFromLegacyFile {
                    legacyFileImportedCallout
                }
            } footer: {
                Text(.keyImportLegacyFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            LocalizedKey.keyImportErrorTitle.text,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.state == .configured ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(store.state == .configured ? .green : .secondary)
            Text(store.state == .configured ? LocalizedKey.keyStatusConfigured.text : LocalizedKey.keyStatusEmpty.text)
        }
    }

    /// Shown once, right after a successful import from the legacy file.
    /// This app has been telling the user that file is a risk
    /// (`security.legacy-key-file`); this is the moment it can point at the
    /// next step — and it repeats that finding's own `chmod 600` advice
    /// rather than inventing a different fix for the same problem.
    private var legacyFileImportedCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.keyImportLegacySuccess)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Self.chmodCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                // The app shows the command; the user runs it — this app
                // never mutates the system (CLAUDE.md).
                Button(didCopyChmodCommand ? LocalizedKey.actionCopied.text : LocalizedKey.actionCopy.text) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.chmodCommand, forType: .string)
                    didCopyChmodCommand = true
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private static var chmodCommand: String { "chmod 600 \(legacyKeyFilePath)" }

    private func importPastedText() {
        do {
            try store.importKey(pastedText)
            pastedText = ""
            justImportedFromLegacyFile = false
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func importFromLegacyFile() {
        do {
            try store.importFromLegacyKeyFile(at: Self.legacyKeyFilePath)
            justImportedFromLegacyFile = true
            didCopyChmodCommand = false
            errorMessage = nil
        } catch {
            justImportedFromLegacyFile = false
            errorMessage = message(for: error)
        }
    }

    /// Every case here maps to fixed, pre-written English text — never the
    /// error's own `String(describing:)` or the input the user typed. That
    /// is deliberate, not incidental: an import error is the single most
    /// tempting place in this app to echo the input back "so the user can
    /// see what they pasted", and the standing rule (CLAUDE.md) is that no
    /// secret value reaches a log, an error, or a crash report. See
    /// `SessionKeyStoreTests.noErrorMessageLeaksTheSuppliedKey` for the
    /// property this upholds.
    private func message(for error: Swift.Error) -> String {
        switch error {
        case SessionKeyStore.Error.empty:
            LocalizedKey.keyErrorEmpty.text
        case SessionKeyStore.Error.notAnAgeKey:
            LocalizedKey.keyErrorNotAnAgeKey.text
        case SessionKeyStore.Error.multipleKeysInFile(let count):
            String(format: LocalizedKey.keyErrorMultipleKeys.text, count)
        default:
            // `importFromLegacyKeyFile(at:)` also throws whatever
            // `String(contentsOfFile:encoding:)` throws (file missing,
            // unreadable, wrong encoding) — none of those carry key
            // material, but they're Foundation/POSIX errors, not this
            // store's own cases, so they get one generic, honest message
            // rather than a leaked system error string.
            LocalizedKey.keyErrorReadFailed.text
        }
    }
}
