import SwiftUI

/// The sheet behind the editor toolbar's Access button: who can currently
/// decrypt the open file, staged add/remove changes, and Apply/Cancel.
///
/// Public rather than private only so the headless snapshot catalog can
/// render it — same reasoning as `EditorAddRowSheet`'s doc comment. Nothing
/// in the app constructs it except `SecretEditorView`.
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
                    .disabled(newRecipientText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(model.isApplying)

            if let addRefusal, let explanation = Self.explanation(for: addRefusal) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.red)
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

/// One row: label (or raw public key, if the registry has no record for it),
/// the public key beneath a label when one exists, a staged-change badge, and
/// the add/remove toggle.
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
