import AppKit
import SopsProjects
import SwiftUI

/// The `.encryptedYAML` source's own preview: choose an already-encrypted
/// file, watch it unlock, and see exactly who gains and loses access before
/// anything is created — the disclosure spec §4.1's decision 4 requires.
///
/// ## Why this source alone needs a gate before it can proceed
///
/// `.empty`, `.plainYAML` and `.dotEnv` are all usable the instant a file is
/// picked (or, for `.empty`, with nothing picked at all). This one is not:
/// the file arrives already encrypted, for a recipient set that routinely
/// differs from whatever governs the destination, and re-encrypting it for
/// a different set is a real access change — the app must not make that
/// change silently. So this source needs an extra step,
/// `NewSecretFileModel.unlockChosenEncryptedFile()`, before `create()` has
/// anything to encrypt at all; see that model's own doc comment on
/// `encryptedImport` for the full account, including why the three-way diff
/// below is computed fresh on every read rather than carried as a stored
/// fact.
///
/// ## The view decides nothing, same as `NewSecretFileSheet`
///
/// Every branch below renders exactly what `model.encryptedImport` reports.
/// `.unlockFailed`'s message is rendered through `failureBanner(_:)` —
/// `message.title`/`.detail`/`.recovery` verbatim, the identical shape
/// `NewSecretFileSheet.failureBanner(_:)` uses (duplicated rather than
/// shared: that method is private to that file, and this is a handful of
/// lines of layout, not a sentence — every sentence still comes from
/// `CreationFailurePresenter`, never composed here). `.unlocked`'s three
/// arrays are age recipients, named through the same registry lookup the ⓘ
/// line and `RecipientPicker` already use — a labeled recipient by its
/// label, an unlabeled one shortened, never an invented name.
///
/// ## What this view never touches
///
/// The decrypted plaintext itself. `NewSecretFileModel.encryptedImport`
/// structurally cannot expose it — `EncryptedImportState.unlocked` carries
/// only the three recipient arrays, never the bytes `unlockChosenEncryptedFile()`
/// decrypted — so there is no plaintext for this view to leak into a
/// sentence, a log, or the accessibility tree even by mistake. The one
/// reader of that plaintext is `NewSecretFileModel.currentSource()`, and it
/// hands it straight to `SecretFileCreator.Source.verbatimYAML(_:)`.
public struct EncryptedImportPreview: View {
    @Bindable private var model: NewSecretFileModel

    @State private var registryRecords: [RecipientRecord] = []

    public init(model: NewSecretFileModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: chooseFile)
            content
        }
        .task {
            // Deliberately non-throwing, degrading to "no labels" rather
            // than hiding a recipient the diff already knows about — the
            // same contract `NewSecretFileSheet`/`RecipientPicker` keep for
            // their own registry loads.
            registryRecords = (try? RecipientRegistry.load(in: model.projectRoot)) ?? []
        }
    }

    // MARK: - Content, by state

    /// No `default` — a case added to `EncryptedImportState` later must fail
    /// this file's build rather than silently show nothing, the same
    /// discipline `NewSecretFileSheet.previewArea`'s own switch keeps.
    @ViewBuilder
    private var content: some View {
        switch model.encryptedImport {
        case .notChosen:
            Text(.newFileNoFileChosen).foregroundStyle(.secondary)
        case .locked(let path):
            lockedState(path: path)
        case .unlockFailed(let message):
            failureBanner(message)
        case .unlocked(let gaining, let losing, let keeping):
            diff(gaining: gaining, losing: losing, keeping: keeping)
        }
    }

    /// Between `chooseFile()` picking a file and `unlockChosenEncryptedFile()`
    /// finishing for it — in practice a brief window, since `chooseFile()`
    /// kicks the unlock off immediately, but a model handed in already at
    /// `.locked` (a fixture, or a caller mid-attempt) must render this
    /// honestly rather than assume the transition is instant.
    private func lockedState(path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: LocalizedKey.newFileFileChosen.text, URL(fileURLWithPath: path).lastPathComponent))
                .font(.callout)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(.newFileEncryptedImportUnlockingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The disclosure itself — spec §4.1, decision 4. Every non-empty
    /// section is shown; an empty one (no recipients gained, say) is simply
    /// omitted rather than rendered as an empty sentence, the same
    /// conditional-parts pattern `ProjectAccessView
    /// .configUpdateConfirmationMessage` uses for its own gains/loses.
    @ViewBuilder
    private func diff(gaining: [String], losing: [String], keeping: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.newFileEncryptedImportDiffTitle).font(.caption.weight(.semibold))
            if !gaining.isEmpty {
                Text(String(format: LocalizedKey.newFileEncryptedImportGains.text, names(gaining)))
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !losing.isEmpty {
                Text(String(format: LocalizedKey.newFileEncryptedImportLoses.text, names(losing)))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !keeping.isEmpty {
                Text(String(format: LocalizedKey.newFileEncryptedImportKeeps.text, names(keeping)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `recipients`' registry labels when they exist, otherwise the public
    /// keys themselves, shortened — never an invented name. Reuses
    /// `NewSecretFileSheet.shortenedKey(_:)` rather than a second copy of the
    /// same rule, so an unlabeled recipient reads identically everywhere in
    /// this wizard.
    private func names(_ recipients: [String]) -> String {
        recipients.map { recipient in
            registryRecords.first { $0.ageRecipient == recipient }?.label ?? NewSecretFileSheet.shortenedKey(recipient)
        }.joined(separator: ", ")
    }

    /// Identical rendering to `NewSecretFileSheet.failureBanner(_:)` — see
    /// this file's own doc comment for why it is duplicated rather than
    /// shared.
    private func failureBanner(_ message: CreationFailureMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.title).font(.headline)
            // Plain-`String` overload, not `LocalizedStringKey` — `detail`
            // may carry the bridge's own diagnostic and must never be
            // looked up in the catalog. See `CreationFailureMessage.detail`'s
            // own doc comment.
            Text(message.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let recovery = message.recovery {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - File picker (NSOpenPanel — established pattern, ProjectSidebar.swift)

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = LocalizedKey.newFileChooseFileButton.text
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseEncryptedFile(at: url)
        Task { await model.unlockChosenEncryptedFile() }
    }
}
