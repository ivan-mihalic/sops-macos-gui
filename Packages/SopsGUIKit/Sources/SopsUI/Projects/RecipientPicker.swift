import Foundation
import SopsProjects
import SwiftUI

/// The way out of the two states phase 1 deliberately left open rather than
/// inventing an answer for: a project with no `.sops.yaml` at all
/// (`CreationPlan.noConfig`), or one whose rules simply do not cover the
/// path the user typed (`.noRuleMatched`). Neither is a failure —
/// `CreationPlanResolver.plan`'s own doc comment says a caller such as this
/// wizard "is expected to fall back to a manual recipient picker rather
/// than invent one here" — and this is that picker.
///
/// ## Two different jobs behind one control
///
/// Choosing recipients here always feeds `NewSecretFileModel
/// .manuallyChosenRecipients`, which is enough on its own: the moment at
/// least one is chosen, `NewSecretFileModel.readiness` treats the set
/// exactly like a resolved rule's own recipients (the same round-trip
/// discovery, the same `create()` failures), and the file this wizard is
/// about to create can be written for exactly them — without ever touching
/// `.sops.yaml`. That is the whole answer for `.noRuleMatched`: some other
/// rule already governs the rest of the project, and this type has no
/// business proposing a replacement config that would silently drop it.
///
/// `.noConfig` gets one thing more: a project with *no* config at all has
/// nothing to lose by gaining one, so this view also offers to propose and
/// write a brand-new `.sops.yaml` whose sole rule governs the target —
/// `NewSecretFileModel.proposeConfig()`/`.writeProposedConfig(_:)`, which
/// wrap `SopsConfigGenerator`/`AtomicFileWriter` exactly the way `create()`
/// already wraps `SecretFileCreator`. Writing it is a fully separate,
/// explicitly confirmed action from choosing recipients for the file
/// itself — see `SopsConfigGenerator`'s own doc comment, "Never writes the
/// config" — and once it succeeds, `NewSecretFileModel.resolvePlan()` is
/// what actually notices the new file: this view calls it, but only after
/// the write has already happened, never before.
///
/// ## The view decides nothing about who to trust
///
/// Every recipient shown here is either something the user typed or pasted,
/// or an entry `RecipientRegistry.load(in:)` already knows about. Nothing
/// here invents a name for an unlabeled key — `displayName(for:)` falls
/// back to `NewSecretFileSheet.shortenedKey(_:)`, the identical fallback
/// that view's own `ⓘ` line uses, so an unlabeled recipient reads the same
/// way everywhere in this wizard.
public struct RecipientPicker: View {
    @Bindable private var model: NewSecretFileModel

    @State private var registryRecords: [RecipientRecord] = []
    @State private var newRecipientText = ""
    @State private var addRefusal: AddRefusal?

    @State private var isProposing = false
    @State private var proposedConfig: ProposedConfig?
    @State private var isWriting = false
    @State private var writeOutcome: NewSecretFileModel.ConfigWriteOutcome?

    public init(model: NewSecretFileModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.recipientPickerTitle).font(.subheadline.weight(.semibold))
            explanation
            chosenRecipients
            addRecipientRow
            knownRecipientsSection
            configProposalSection
        }
        .task {
            // Deliberately non-throwing, degrading to "no labels" rather
            // than hiding a recipient the user has already chosen — the
            // same contract `NewSecretFileSheet`'s own registry load and
            // `ProjectAccessModel.loadRegistry` both keep.
            registryRecords = (try? RecipientRegistry.load(in: model.projectRoot)) ?? []
        }
    }

    // MARK: - Explanation

    /// `nil`-rendering for any `plan` other than the two this view exists
    /// for — reachable only if a caller renders this view without checking
    /// `model.plan` first, which `NewSecretFileSheet` always does.
    @ViewBuilder
    private var explanation: some View {
        if model.plan == .noConfig {
            Text(.recipientPickerExplanationNoConfig)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.plan == .noRuleMatched {
            Text(.recipientPickerExplanationNoRuleMatched)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chosen recipients

    @ViewBuilder
    private var chosenRecipients: some View {
        if model.manuallyChosenRecipients.isEmpty {
            Text(.recipientPickerNoneChosen).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.manuallyChosenRecipients, id: \.self) { recipient in
                    recipientRow(recipient)
                }
            }
        }
    }

    private func recipientRow(_ recipient: String) -> some View {
        HStack {
            Text(displayName(for: recipient))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.manuallyChosenRecipients.removeAll { $0 == recipient }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedKey.accessRemoveRecipient.text)
        }
    }

    /// `recipient`'s registry label when one exists, otherwise the public
    /// key itself, shortened — never an invented name. Reuses
    /// `NewSecretFileSheet.shortenedKey(_:)` rather than a second copy of
    /// the same rule, so an unlabeled key reads identically in the ⓘ line
    /// and here.
    private func displayName(for recipient: String) -> String {
        registryRecords.first { $0.ageRecipient == recipient }?.label ?? NewSecretFileSheet.shortenedKey(recipient)
    }

    // MARK: - Adding a recipient by hand

    /// Whether `text` could be added to `existing` right now, and why not
    /// when it can't. A free, pure function — like `NewSecretFileSheet
    /// .canCreate`/`.shouldResolve` — so a test can drive every case
    /// directly, without rendering anything.
    enum AddRefusal: Equatable {
        case empty
        case duplicate
    }

    static func canAdd(_ text: String, existing: [String]) -> AddRefusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if existing.contains(trimmed) { return .duplicate }
        return nil
    }

    private var addRecipientRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField(LocalizedKey.accessAddRecipientField.text, text: $newRecipientText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRecipient)
                Button(LocalizedKey.actionAdd.text, action: addRecipient)
                    .disabled(Self.canAdd(newRecipientText, existing: model.manuallyChosenRecipients) != nil)
            }
            if addRefusal == .duplicate {
                Text(.accessAddDuplicate).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func addRecipient() {
        let refusal = Self.canAdd(newRecipientText, existing: model.manuallyChosenRecipients)
        addRefusal = refusal
        guard refusal == nil else { return }
        model.manuallyChosenRecipients.append(newRecipientText.trimmingCharacters(in: .whitespacesAndNewlines))
        newRecipientText = ""
        proposedConfig = nil
        writeOutcome = nil
    }

    // MARK: - Known recipients — one-tap add, never a source of new names

    /// Registry entries not already chosen. A convenience only:
    /// `RecipientRegistry` is a label directory, not a whitelist (see this
    /// type's own doc comment), so this list is never the only way to add a
    /// recipient — the free-text field above always works for a key the
    /// registry has never heard of.
    private var knownRecipients: [RecipientRecord] {
        registryRecords.filter { !model.manuallyChosenRecipients.contains($0.ageRecipient) }
    }

    @ViewBuilder
    private var knownRecipientsSection: some View {
        if !knownRecipients.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(.recipientPickerKnownRecipientsTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(knownRecipients) { record in
                    HStack {
                        Text(record.label).font(.callout)
                        Spacer()
                        Button(LocalizedKey.actionAdd.text) {
                            model.manuallyChosenRecipients.append(record.ageRecipient)
                            proposedConfig = nil
                            writeOutcome = nil
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - .sops.yaml, .noConfig only

    /// `nil`-rendering for `.noRuleMatched` — some other rule already
    /// governs the rest of this project, and this view has no business
    /// proposing a replacement `.sops.yaml` that would silently drop it.
    /// See this type's own doc comment, "Two different jobs behind one
    /// control".
    @ViewBuilder
    private var configProposalSection: some View {
        if model.plan == .noConfig {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(LocalizedKey.recipientPickerProposeButton.text, action: propose)
                        .disabled(!Self.canPropose(recipients: model.manuallyChosenRecipients) || isProposing)
                    if isProposing {
                        ProgressView().controlSize(.small)
                    }
                }

                if let proposedConfig {
                    if proposedConfig.verified {
                        Text(.recipientPickerProposalHeading).font(.caption.weight(.semibold))
                        // The proposed YAML itself is not translatable and is
                        // shown as itself — the same discipline
                        // `RecipientLabelEditorView` uses for a public key.
                        Text(verbatim: proposedConfig.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        Button(LocalizedKey.recipientPickerWriteButton.text, action: write)
                            .disabled(!Self.canWrite(proposedConfig) || isWriting)
                    } else {
                        Text(proposedConfig.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let writeOutcome {
                    switch writeOutcome {
                    case .written:
                        Text(.recipientPickerWriteSuccess).font(.caption).foregroundStyle(.secondary)
                    case .refused(let message):
                        Text(message.title).font(.caption.weight(.semibold))
                        Text(message.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Whether the propose control may be pressed at all. Mirrors
    /// `NewSecretFileModel.proposeConfig()`'s own guard — see that method's
    /// own doc comment for why this is the picker's *own* guard, not a way
    /// to route around `SopsConfigGenerator.propose`'s refusal of an empty
    /// recipient list: that refusal still runs, unconditionally, whenever
    /// this guard is bypassed by anything other than this view's own
    /// button.
    static func canPropose(recipients: [String]) -> Bool { !recipients.isEmpty }

    /// Whether the write control may be pressed. `verified == false` means
    /// `SopsConfigGenerator.propose` itself would not stand behind `text` —
    /// see `ProposedConfig`'s own doc comment — so there is nothing here to
    /// write, ever, regardless of anything else about `isWriting`.
    static func canWrite(_ proposal: ProposedConfig?) -> Bool { proposal?.verified == true }

    private func propose() {
        isProposing = true
        writeOutcome = nil
        Task {
            proposedConfig = await model.proposeConfig()
            isProposing = false
        }
    }

    private func write() {
        guard let proposedConfig, Self.canWrite(proposedConfig) else { return }
        isWriting = true
        let outcome = model.writeProposedConfig(proposedConfig)
        writeOutcome = outcome
        isWriting = false
        if case .written = outcome {
            // The write just happened; nothing about `readiness` reflects it
            // until a fresh resolve actually looks at the new `.sops.yaml`
            // again. See `NewSecretFileModel.writeProposedConfig(_:)`'s own
            // doc comment for why that call is this view's job, not that
            // method's.
            Task { await model.resolvePlan() }
        }
    }
}
