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
/// fact, and why `.unlockedAwaitingPlan` exists as its own state rather than
/// a diff computed against an invented empty target.
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
/// ## What "this file" means, and why the filename stays on screen
///
/// Every sentence below is about the **new** file this import would create
/// — never the source file the user picked, which this app never modifies.
/// A recipient in `losing` still reads the source exactly as before; what
/// they lose is the ability to read the *new* copy. Losing that distinction
/// in the wording is exactly the mistake `ProjectAccessView`'s own
/// `project-access.update-config-confirm.loses` sentence was written to
/// avoid for the identical shape of confusion one screen over — this task
/// borrowed that sentence's vocabulary without the clarifying half, and an
/// earlier version of this file both dropped that clause and stopped
/// showing which file was even selected once unlocked (`.unlocked` used to
/// carry no path at all), which made "this file" ambiguous in exactly the
/// place where ambiguity is dangerous. Both are fixed together here: the
/// chosen file's name is shown unconditionally, from `model
/// .chosenEncryptedFileURL` (never through `EncryptedImportState` — that
/// model property already exists for `.locked(path:)` and there is no
/// reason to duplicate it into every other case), and `newFileEncryptedImportLoses`
/// says explicitly that the source file is untouched.
///
/// ## What this view never touches
///
/// The decrypted plaintext itself. `NewSecretFileModel.encryptedImport`
/// structurally cannot expose it — neither `EncryptedImportState` case
/// carries anything but recipient keys, never the bytes
/// `unlockChosenEncryptedFile()` decrypted — so there is no plaintext for
/// this view to leak into a sentence, a log, or the accessibility tree even
/// by mistake. The one reader of that plaintext is `NewSecretFileModel
/// .currentSource()`, and it hands it straight to `SecretFileCreator
/// .Source.verbatimYAML(_:)`.
public struct EncryptedImportPreview: View {
    @Bindable private var model: NewSecretFileModel

    @State private var registryRecords: [RecipientRecord] = []

    public init(model: NewSecretFileModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: chooseFile)
            selectedFileLabel
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

    /// Shown in every state once a file has been picked, not only
    /// `.locked` — see this file's own doc comment, "What 'this file'
    /// means, and why the filename stays on screen". Reads
    /// `model.chosenEncryptedFileURL` directly rather than the path
    /// `.locked(path:)` carries, so it does not go blank the moment
    /// `unlockChosenEncryptedFile()` finishes.
    @ViewBuilder
    private var selectedFileLabel: some View {
        if let chosenEncryptedFileURL = model.chosenEncryptedFileURL {
            Text(
                String(
                    format: LocalizedKey.newFileFileChosen.text,
                    chosenEncryptedFileURL.lastPathComponent)
            )
            .font(.callout)
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
        case .locked:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(.newFileEncryptedImportUnlockingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unlockFailed(let message):
            failureBanner(message)
        case .unlockedAwaitingPlan:
            // The file decrypted, but there is nothing yet to diff it
            // against — see `NewSecretFileModel.encryptedImport`'s own doc
            // comment, "The diff needs a known target, not just a decrypted
            // file", for the finding this state exists to close. Rendered
            // as a plain, neutral *fact*, deliberately not an instruction —
            // a second review round's finding, closed by removing the
            // instruction rather than trying to word one that fits every
            // cause this state merges. An earlier version said "Choose a
            // name (and, if needed, recipients)…", presuming the fix is
            // always choosing something — wrong for causes where the name
            // is already typed and the rule already matched
            // (`.unsupportedRule`, `.configUnreadable`, a matched rule
            // naming no recipients at all). `NewSecretFileSheet` already
            // renders the real explanation for every cause — the resolving
            // spinner, or the `.blocked` banner — directly above this view
            // (`nameSection` sits before `previewArea`), so the fix lives in
            // not duplicating that judgment here, not in trying to make one
            // sentence correct for every cause. Splitting the sentence per
            // cause was the alternative and was rejected: it would mean this
            // view inspecting `model.plan`/`readiness` to decide *why*
            // there is no target, which is exactly the plan-reading
            // judgment `EncryptedImportPreview`'s own doc comment ("The view
            // decides nothing") says belongs to the model, not here.
            //
            // A third review round caught the sentence itself still naming
            // the wrong noun even after the instruction was removed: "no
            // destination decided yet" is false whenever the name is typed
            // and the rule matched, which is three of the six causes this
            // state now merges. `currentGovernedPlan()` returning `nil`
            // always and only means one thing, though, regardless of cause
            // — no usable *recipient set* — so the catalog text now says
            // that instead, true for all six without this view needing to
            // know which one it is.
            Text(.newFileEncryptedImportAwaitingPlanLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unlocked(let gaining, let losing, let keeping):
            diff(gaining: gaining, losing: losing, keeping: keeping)
        }
    }

    /// The disclosure itself — spec §4.1, decision 4. Every non-empty
    /// section is shown; an empty one (no recipients gained, say) is simply
    /// omitted rather than rendered as an empty sentence, the same
    /// conditional-parts pattern `ProjectAccessView
    /// .configUpdateConfirmationMessage` uses for its own gains/loses.
    ///
    /// The title itself is conditional too — `gaining`/`losing` both empty
    /// (every source recipient survives into the target unchanged) is the
    /// single most common case for an import into a project whose rule
    /// already matches the source, and it is the one case the "will
    /// change" title contradicted outright: a headline claiming a change
    /// directly above a body that names only who *keeps* access.
    @ViewBuilder
    private func diff(gaining: [String], losing: [String], keeping: [String]) -> some View {
        let changes = !gaining.isEmpty || !losing.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            Text(changes ? LocalizedKey.newFileEncryptedImportDiffTitle : .newFileEncryptedImportNoChangeTitle)
                .font(.caption.weight(.semibold))
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
