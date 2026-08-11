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
            List(model.entries) { entry in
                RecipientAccessRow(entry: entry, onToggle: { toggleRemoval(for: entry) })
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
/// the public key beneath a label when one exists, the registry's kind, a
/// staged-change badge, and the add/remove toggle.
private struct RecipientAccessRow: View {
    let entry: RecipientAccessModel.AccessEntry
    let onToggle: () -> Void

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
            }

            RecipientKindBadge(kind: entry.kind)

            Spacer()

            if let badge {
                Text(badge.0)
                    .font(.caption2)
                    .foregroundStyle(badge.1)
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
