import SopsHealth
import SopsProjects
import SwiftUI

/// The sheet behind the editor toolbar's Access button: who can currently
/// decrypt the open file, staged add/remove changes, and Apply/Cancel.
///
/// Public rather than private so a test in `SopsUITests` can render it through
/// `GatingHost` and read the result off the accessibility tree — the same
/// reason `ProjectAccessView` is, and how `RecipientAccessGatingTests` checks
/// that a gate is really wired into a rendered view rather than only correct in
/// isolation.
///
/// It has deliberately **no** `SnapshotTool/Catalog.swift` entry, despite what
/// this comment claimed until the final review: the panel runs a live load from
/// its own `.task`, which the single-shot headless renderer would race — it
/// draws once and exits, so it would capture whichever half-loaded state the
/// timing produced. Accepted as carried-forward debt rather than papered over
/// with a fixture that renders a state the real panel never holds. Nothing in
/// the app constructs this except `SecretEditorView`.
///
/// ## Staged, not live
/// Every add/remove tap only calls `RecipientAccessModel.stageAdd`/
/// `stageRemove` — never `apply()`. Nothing reaches disk until the user
/// presses Apply, and a pending removal is confirmed first: see
/// `requestApply()`.
public struct RecipientAccessView: View {
    @Bindable private var model: RecipientAccessModel
    private let onClose: () -> Void
    private let onApplied: () -> Void

    @State private var newRecipientText = ""
    @State private var addRefusal: RecipientAccessModel.StageAddRefusal?
    @State private var confirmingRemoval = false
    @State private var applyErrorMessage: String?
    @State private var labelEdit: RecipientLabelEditRequest?

    public init(
        model: RecipientAccessModel,
        onClose: @escaping () -> Void,
        onApplied: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        self.onApplied = onApplied
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.accessTitle).font(.headline)

            content

            if model.loadState == .loaded, !model.keyConfigured {
                Label(.accessNeedsKeyBody, systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(LocalizedKey.actionCancel.text) {
                    model.discardStagedChanges()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isApplying)

                if model.isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(LocalizedKey.accessApplyingLabel.text)
                } else {
                    Button(LocalizedKey.accessApplyButton.text) {
                        requestApply()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .task { await model.load() }
        .confirmationDialog(
            LocalizedKey.accessRemoveConfirmTitle.text,
            isPresented: $confirmingRemoval
        ) {
            Button(LocalizedKey.accessRemoveConfirmButton.text, role: .destructive) {
                Task { await apply() }
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(removalConfirmationMessage)
        }
        .alert(
            LocalizedKey.accessApplyErrorTitle.text,
            isPresented: Binding(
                get: { applyErrorMessage != nil },
                set: { isPresented in if !isPresented { applyErrorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { applyErrorMessage = nil }
        } message: {
            Text(applyErrorMessage ?? "")
        }
        // Naming a recipient writes the registry and nothing else, so what
        // follows a save is `reloadRegistry()` — never `load()`, which would
        // discard the staged access edits this sheet is holding.
        .sheet(item: $labelEdit) { request in
            RecipientLabelEditorView(
                model: request.model,
                onClose: { labelEdit = nil },
                onChanged: { model.reloadRegistry() })
        }
    }

    private func editLabel(for entry: RecipientAccessModel.AccessEntry) {
        guard let projectURL = model.projectURL else { return }
        labelEdit = RecipientLabelEditRequest(
            model: RecipientLabelEditorModel(
                projectURL: projectURL,
                ageRecipient: entry.ageRecipient,
                existing: model.registryRecords.first { $0.ageRecipient == entry.ageRecipient }))
    }

    private var canApply: Bool {
        Self.canApply(
            loadState: model.loadState, isDirty: model.isDirty,
            keyConfigured: model.keyConfigured, isApplying: model.isApplying)
    }

    /// Whether the Apply button may be pressed right now. Pulled out as a
    /// pure function — mirroring `SecretEditorView.canOpenAccessPanel` and
    /// this module's `WorkspaceSwitchDecision`/`QuitRequest` — so it is
    /// directly testable without rendering this view.
    static func canApply(
        loadState: RecipientAccessModel.LoadState, isDirty: Bool, keyConfigured: Bool, isApplying: Bool
    ) -> Bool {
        loadState == .loaded && isDirty && keyConfigured && !isApplying
    }

    // MARK: - Content per load state

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(.accessLoadFailedTitle).font(.headline)
                // Engine-produced or fixed diagnostic text, verbatim — never
                // a document value or a key. See
                // `RecipientAccessModel.LoadState.failed`'s doc comment.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.registryQuarantineNotice {
                RegistryQuarantineBanner(notice: notice)
            }

            List(model.entries) { entry in
                RecipientAccessRow(
                    entry: entry, onToggle: { toggleRemoval(for: entry) },
                    onEditLabel: model.projectURL == nil ? nil : { editLabel(for: entry) })
            }
            .frame(minHeight: 160, maxHeight: 260)
            .listStyle(.inset)
            .disabled(model.isApplying)

            HStack {
                TextField(LocalizedKey.accessAddRecipientField.text, text: $newRecipientText)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addStagedRecipient)
                Button(LocalizedKey.actionAdd.text, action: addStagedRecipient)
                    .disabled(!RecipientRowContent.canAdd(newRecipientText))
            }
            .disabled(model.isApplying)

            if let addRefusal, let explanation = Self.explanation(for: addRefusal) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // A key this file's metadata names twice is collapsed into one row
            // — multiplicity is not access — but never without saying so. See
            // `RecipientAccessModel.duplicatedRecipients`.
            if !model.duplicatedRecipients.isEmpty {
                Text(
                    String(
                        format: LocalizedKey.accessDuplicateRecipients.text,
                        model.duplicatedRecipients.count)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !model.rotationDebtEntries.isEmpty {
                rotationDebtSection
            }
        }
    }

    /// Ticket #3: what this app already recorded about a rotation this file
    /// still owes — see `RecipientAccessModel.rotationDebtEntries`. Shown
    /// even when the condition that first found it (a stale recipient) has
    /// long since cleared, which is the entire point of recording it at
    /// all. The only control here is acknowledging it, never "verify" —
    /// this app cannot see whether a value was actually rotated.
    private var rotationDebtSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.accessRotationDebtHeading)
                .font(.caption.bold())
                .foregroundStyle(.orange)
            ForEach(model.rotationDebtEntries) { entry in
                HStack(alignment: .top) {
                    Text(verbatim: RotationDebtDescription.sentence(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(LocalizedKey.accessRotationDebtAcknowledgeButton.text) {
                        model.acknowledgeRotationDebt(entry.id)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func addStagedRecipient() {
        addRefusal = model.stageAdd(newRecipientText)
        if addRefusal == nil {
            newRecipientText = ""
        }
    }

    private func toggleRemoval(for entry: RecipientAccessModel.AccessEntry) {
        if entry.status == .pendingRemoval {
            model.stageAdd(entry.ageRecipient)
        } else {
            model.stageRemove(entry.ageRecipient)
        }
    }

    // MARK: - Apply

    /// Removing access is destructive, so a pending removal is confirmed
    /// first — CLAUDE.md and PROPOSAL.md both require naming what will be
    /// lost before it happens. A change with no removals (additions only)
    /// applies directly.
    private func requestApply() {
        if model.pendingRemovals.isEmpty {
            Task { await apply() }
        } else {
            confirmingRemoval = true
        }
    }

    private func apply() async {
        let outcome = await model.apply()
        switch outcome {
        case .applied:
            onApplied()
            onClose()
        case .refusedEmptyRecipients:
            applyErrorMessage = LocalizedKey.accessErrorEmptyRecipients.text
        case .refusedNoKey:
            applyErrorMessage = LocalizedKey.accessNeedsKeyBody.text
        case .failed(let message):
            applyErrorMessage = message
        }
    }

    private var removalConfirmationMessage: String {
        let names = model.pendingRemovals.map { $0.label ?? $0.ageRecipient }
        return String(format: LocalizedKey.accessRemoveConfirmMessage.text, names.joined(separator: ", "))
    }

    private static func explanation(for refusal: RecipientAccessModel.StageAddRefusal) -> LocalizedKey? {
        switch refusal {
        case .duplicate: .accessAddDuplicate
        case .empty, .notLoaded: nil
        }
    }
}

/// The parts of a recipient row both Access panels share.
///
/// One place rather than two, because the two panels had already drifted apart
/// once in exactly this seam: the per-file panel enabled its Add button on
/// `.whitespaces` while the model that answers it trimmed
/// `.whitespacesAndNewlines`, so a pasted lone newline enabled Add and then
/// returned `.empty` — whose `explanation(for:)` is `nil`. A live button, a
/// press, and nothing at all in response.
enum RecipientRowContent {

    /// Whether the Add button may be pressed for what is typed right now.
    ///
    /// The set trimmed here has to be the one `RecipientAccessModel.stageAdd`
    /// and `ProjectAccessModel.stageAdd` trim, or the button offers something
    /// the model then refuses without a sentence to show for it. Pulled out as
    /// a pure function — like `canApply` and `canUpdateConfig` — so that
    /// agreement is testable without rendering either panel.
    static func canAdd(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a registry `kind` reads as on screen. The design spec asks for the
    /// human name, the *type* and the public key; this is the type.
    static func label(for kind: RecipientKind) -> LocalizedKey {
        switch kind {
        case .device: .recipientKindDevice
        case .server: .recipientKindServer
        case .person: .recipientKindPerson
        }
    }

    /// The registry's optional note for a recipient, where one exists.
    ///
    /// Drawn since the label editor started collecting it: a field a user can
    /// type into and never see again is a field that quietly stops being kept
    /// up to date. Shown verbatim — it is user-written prose, not a translatable
    /// string — and never a place a secret belongs, which is why
    /// `RecipientRegistry` refuses anything private-key-shaped here as firmly as
    /// it does in the recipient itself.
    @ViewBuilder
    static func note(_ note: String?) -> some View {
        if let note, !note.isEmpty {
            Text(verbatim: note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The banner both Access panels show when `registryQuarantineNotice` is
/// set — `RecipientAccessModel`/`ProjectAccessModel`, set by `RecipientRegistry
/// .loadOrQuarantine(in:)` exactly when `recipients.json` existed but could
/// not be decoded and was moved aside (SOPS-33). Before this existed, both
/// panels quarantined the corrupt file correctly but told the user nothing —
/// `RegistryQuarantineWiringTests` pins that every screen at least reads the
/// notice; this is what makes it visible.
///
/// `notice` is engine-authored diagnostic text carrying the registry's real
/// path (see `RecipientRegistry.quarantine(in:)`), shown verbatim — the same
/// treatment `ProjectAccessView.explanation(_:_:tint:)` gives a config
/// error, and for the same reason: a path is not translatable, and resolved
/// through the catalog it would vanish under whichever build system copies
/// `.xcstrings` uncompiled (see `LocalizationTests`' own header). Only the
/// title above it is a catalog string, and that string names no path, so
/// `LocalizationTests.noCatalogStringNamesAKeyFilePath` has nothing to say
/// about it.
///
/// Shared rather than duplicated in both files, the same way
/// `RecipientKindBadge`/`RecipientRowContent` already are: the two panels'
/// wording must not drift, and it already drifted once in this exact seam.
///
/// Deliberately **not** shown by the three wizard steps that also read
/// `registryQuarantineNotice` (`EncryptedImportPreview`, `RecipientPicker`,
/// `NewSecretFileSheet`): each is a single, transient flow for creating one
/// new file, already carrying its own loading/proposal/failure states, and a
/// registry that cannot supply *labels* does not block or even slow that
/// flow — the picker falls back to showing raw public keys, which is a
/// complete and correct (if less friendly) way to choose a recipient. A
/// banner there would be about the project's backend housekeeping, not about
/// anything the wizard is doing. The two dedicated access panels are where
/// this is on-topic and actionable: a user can leave one, fix the file, and
/// come back to labels again.
struct RegistryQuarantineBanner: View {
    let notice: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(.accessRegistryQuarantineTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

/// The control that opens the label editor for one row, in its two states.
///
/// Shared by both panels for the reason `RecipientKindBadge` is: the two row
/// views are near-identical and have already drifted apart once in exactly this
/// seam.
struct RecipientNamingButton: View {
    let hasLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: hasLabel ? "pencil" : "tag")
        }
        .buttonStyle(.plain)
        .accessibilityLabel((hasLabel ? LocalizedKey.recipientEditLabel : .recipientNameThis).text)
    }
}

/// The registry's descriptive role for a recipient — device, server or person.
///
/// Descriptive only, and drawn as such: SOPS metadata and `.sops.yaml` remain
/// the access authority (see `RecipientKind`), so this never changes what a row
/// *means*, only what it tells you about who is behind the key. Absent for a
/// recipient the registry has no record of, which is never a reason to hide the
/// row itself.
struct RecipientKindBadge: View {
    let kind: RecipientKind?

    var body: some View {
        if let kind {
            Text(RecipientRowContent.label(for: kind))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }
}

/// One row: label (or raw public key, if the registry has no record for it),
/// the public key beneath a label when one exists, the registry's note and
/// kind, a staged-change badge, the naming control and the add/remove toggle.
private struct RecipientAccessRow: View {
    let entry: RecipientAccessModel.AccessEntry
    let onToggle: () -> Void
    /// `nil` when there is no project to write a name into — a file opened
    /// outside one. Offered-and-then-failing would be worse than absent.
    let onEditLabel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label ?? entry.ageRecipient)
                    .font(entry.label == nil ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(entry.status == .pendingRemoval)
                if entry.label != nil {
                    Text(entry.ageRecipient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                RecipientRowContent.note(entry.note)
            }

            RecipientKindBadge(kind: entry.kind)

            Spacer()

            if let badge {
                Text(badge.0)
                    .font(.caption2)
                    .foregroundStyle(badge.1)
            }

            if let onEditLabel {
                RecipientNamingButton(hasLabel: entry.label != nil, action: onEditLabel)
            }

            Button(action: onToggle) {
                Image(systemName: entry.status == .pendingRemoval ? "arrow.uturn.backward.circle" : "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                (entry.status == .pendingRemoval
                    ? LocalizedKey.accessUndoRemoval : LocalizedKey.accessRemoveRecipient
                ).text)
        }
        .padding(.vertical, 2)
    }

    private var badge: (LocalizedKey, Color)? {
        switch entry.status {
        case .unchanged: nil
        case .pendingRemoval: (.accessPendingRemovalBadge, .red)
        case .pendingAddition: (.accessPendingAdditionBadge, .green)
        }
    }
}
