import AppKit
import SopsProjects
import SwiftUI

/// The new-secret-file wizard: pick a source, name the file, watch the
/// `ⓘ` line explain live what `.sops.yaml` decides for the name as it is
/// typed, preview what the chosen source would produce, then create it.
///
/// ## The view decides nothing
///
/// Every branch below renders what `NewSecretFileModel` already computed.
/// "Create" is enabled for exactly `Readiness.ready` — see `canCreate(
/// readiness:isCreating:)`, the one pure decision this file makes and the
/// one thing about it a test can check without rendering anything.
/// `.needsAcknowledgement` renders the checkbox bound straight to `model
/// .acknowledgedUnreadable`; `.blocked(message)` renders `message.title`/
/// `.detail`/`.recovery` verbatim through `failureBanner(_:)` — this view
/// never composes a failure sentence of its own, matching
/// `CreationFailurePresenter`'s own discipline. The one narrow exception is
/// `newFileFileUnreadable`: `Data(contentsOf:)` failing on a file the user
/// just picked via `NSOpenPanel` is not one of the four vocabularies
/// `CreationFailurePresenter` unifies (`CreationPlanResolver.Error`,
/// `SecretFileCreator.Failure`, `SopsConfigGenerator.Error`,
/// `DotEnvParseFailure`), so it gets one fixed, non-interpolated sentence
/// here rather than a new presenter overload for a single call site.
///
/// ## The debounce, and why it checks `resolvedName` before firing
///
/// `NewSecretFileModel.resolvePlan()` walks `.sops.yaml` and crosses into
/// the Go bridge — real cost that has no business running on every
/// keystroke, so a change to `relativeName` debounces 200ms
/// (`resolveDebounced()`) before calling it, cancelling whatever resolve
/// was still in flight (`resolveTask`).
///
/// But `resolvePlan()` also resets `acknowledgedUnreadable` on **every**
/// call, even one that resolves to the exact same rule again — see that
/// property's own doc comment on `NewSecretFileModel`. A debounce that
/// fires unconditionally in the window between the user ticking the
/// checkbox and clicking Create would silently discard the tick:
/// `readiness` recomputes to the optimistic `.ready`, nothing on screen
/// says anything changed, and Create then hits `wouldBeUnreadable` again
/// with no visible cause — a loop the user cannot see their way out of.
/// `shouldResolve(relativeName:resolvedName:)` is the guard against
/// exactly that, checked right after the sleep and before `resolvePlan()`
/// is ever called: a resolve is skipped whenever the name it would resolve
/// for is already the one `model.resolvedName` reports. It is a free
/// function precisely so a test can drive it directly, with no `Task.sleep`
/// anywhere in the test — see `NewSecretFileSheetTests`.
///
/// Choosing a different source has no such bridge cost — `sourceChoice`
/// has no property observer of its own on the model (see that property's
/// doc comment) — but still needs `readiness` recomputed, so
/// `resolveNow()` calls `resolvePlan()` immediately, unguarded, whenever
/// `sourceChoice` changes.
///
/// ## Only "Empty" can actually be created here
///
/// `NewSecretFileModel.create()` only ever builds a document for
/// `sourceChoice == .empty` — every other choice reports `.needsSource`
/// regardless of what has been picked or previewed (see that type's own
/// doc comment: "Only `.empty` is implemented by this task"). Plain YAML
/// and `.env` are still fully offered and previewed here, honestly, with
/// Create correctly disabled for them — nothing in this file works around
/// that guard, and nothing pretends the preview means Create would
/// succeed.
///
/// ## Encrypted YAML stays disabled in this task
///
/// Its preview needs unlocking the file and diffing who would gain or lose
/// access, which Task 6 adds. Offering the option before this app can
/// finish it would walk the user into a dead end, so the radio option is
/// disabled and the reason is a permanently visible sentence, not a
/// tooltip nobody has a reason to hover — a disabled option's own reason
/// has to be readable without interacting with it.
public struct NewSecretFileSheet: View {
    @Bindable private var model: NewSecretFileModel
    private let onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var registryRecords: [RecipientRecord] = []
    @State private var resolveTask: Task<Void, Never>?
    @State private var isCreating = false

    @State private var plainYAMLFileName: String?
    @State private var dotEnvParsed: ParsedDotEnv?
    @State private var dotEnvParseError: CreationFailureMessage?

    private static let debounceDuration: Duration = .milliseconds(200)

    public init(model: NewSecretFileModel, onCreated: @escaping (URL) -> Void) {
        self.model = model
        self.onCreated = onCreated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.newFileTitle).font(.headline)

            sourceSection

            nameSection

            Divider()

            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            buttonRow
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 440, idealHeight: 560)
        .task {
            // Registry labels only — deliberately no initial `resolvePlan()`
            // call here. A freshly constructed `NewSecretFileModel` always
            // starts with `relativeName == ""`, so `readiness` is already
            // the correct `.needsName` with no resolve needed; and
            // `resolvePlan()` resets `discoveredUnreadable`/
            // `acknowledgedUnreadable` on every call (see those properties'
            // own doc comments), so calling it here would silently clobber
            // a model handed in already past that point — exactly the
            // fixtures `NewSecretFileSheetTests` builds to exercise
            // `.needsAcknowledgement` without a live user session. Matches
            // `SecretEditorView`'s own contract: a caller establishes a
            // model's state before handing it to a view; the view never
            // re-derives it on appearance.
            registryRecords = (try? RecipientRegistry.load(in: model.projectRoot)) ?? []
        }
        .onChange(of: model.relativeName) { _, _ in resolveDebounced() }
        .onChange(of: model.sourceChoice) { _, _ in resolveNow() }
    }

    // MARK: - Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text(.newFileSourceLabel)
                ForEach(NewSecretFileModel.SourceChoice.allCases, id: \.self) { choice in
                    sourceOption(choice)
                }
            }
            Text(.newFileSourceEncryptedYAMLDisabledReason)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceOption(_ choice: NewSecretFileModel.SourceChoice) -> some View {
        let isSelected = model.sourceChoice == choice
        let isDisabled = choice == .encryptedYAML
        return Button {
            model.sourceChoice = choice
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                Text(sourceLabel(choice))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
        .accessibilityLabel(sourceLabel(choice))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func sourceLabel(_ choice: NewSecretFileModel.SourceChoice) -> String {
        switch choice {
        case .empty: LocalizedKey.newFileSourceEmpty.text
        case .plainYAML: LocalizedKey.newFileSourcePlainYAML.text
        case .encryptedYAML: LocalizedKey.newFileSourceEncryptedYAML.text
        case .dotEnv: LocalizedKey.newFileSourceDotEnv.text
        }
    }

    // MARK: - Name + ⓘ line + acknowledgement + failure banner

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(.newFileNameLabel)
                TextField(LocalizedKey.newFileNamePlaceholder.text, text: $model.relativeName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(LocalizedKey.newFileNameLabel.text)
            }

            if let infoLineText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(infoLineText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .needsAcknowledgement = model.readiness {
                Toggle(LocalizedKey.newFileAcknowledgeUnreadableCheckbox.text, isOn: $model.acknowledgedUnreadable)
                    .toggleStyle(.checkbox)
            }

            if case .blocked(let message) = model.readiness {
                failureBanner(message)
            }
        }
    }

    /// The `ⓘ` line's text: five shapes matching `CreationPlan`'s cases, plus
    /// a sixth for "still resolving". `nil` — nothing shown — before any
    /// name has produced a plan at all (`model.plan == nil` and not
    /// resolving), which covers both `.needsName` and a thrown
    /// `CreationPlanResolver.Error`; the latter already has its own sentence
    /// in `model.planError`, rendered through `failureBanner(_:)` above via
    /// `readiness == .blocked`, so this line has nothing useful to add for
    /// it.
    ///
    /// No `default` in the switch — a case added to `CreationPlan` later
    /// must fail this file's build, the same discipline
    /// `CreationFailurePresenter` documents for its own switches.
    private var infoLineText: String? {
        if model.isResolving { return LocalizedKey.newFileInfoResolving.text }
        guard let plan = model.plan else { return nil }
        switch plan {
        case .governedByRule(let recipients, _):
            return String(format: LocalizedKey.newFileInfoGovernedByRule.text, recipientNames(recipients))
        case .noConfig:
            return LocalizedKey.newFileInfoNoConfig.text
        case .noRuleMatched:
            return LocalizedKey.newFileInfoNoRuleMatched.text
        case .unsupportedRule, .configUnreadable:
            // Reuses `CreationFailurePresenter`'s own already-composed
            // sentence for these two blocking cases — see this file's own
            // doc comment, "The view decides nothing": this line never
            // words a failure itself, even a brief one.
            return CreationFailurePresenter.message(forBlocking: plan)?.detail
        }
    }

    /// `recipient`'s registry label when one exists, otherwise the public
    /// key itself, shortened for a comma-joined sentence — never an invented
    /// name. Mirrors the fallback `ProjectAccessModel.makeEntry(_:status:)`
    /// and `RecipientAccessModel.makeEntry(_:status:)` already use
    /// (`record?.label ?? ageRecipient`, rendered with `.truncationMode(
    /// .middle)` in a `List` row); this line is a joined sentence rather
    /// than a row, so an unlabeled key is shortened here directly instead of
    /// relying on `SwiftUI` to truncate the whole sentence around it.
    private func recipientNames(_ recipients: [String]) -> String {
        recipients.map { recipient in
            registryRecords.first { $0.ageRecipient == recipient }?.label ?? Self.shortenedKey(recipient)
        }.joined(separator: ", ")
    }

    /// `age1qy…8x`-shaped: the first six and last four characters, joined by
    /// an ellipsis. Left whole when it is already short enough that
    /// shortening it would not save anything.
    static func shortenedKey(_ ageRecipient: String) -> String {
        guard ageRecipient.count > 12 else { return ageRecipient }
        return "\(ageRecipient.prefix(6))…\(ageRecipient.suffix(4))"
    }

    private func failureBanner(_ message: CreationFailureMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.title).font(.headline)
            // Plain-`String` overload, not `LocalizedStringKey` — `detail`
            // may carry a path or the bridge's own diagnostic and must never
            // be looked up in the catalog. See `CreationFailureMessage
            // .detail`'s own doc comment.
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

    // MARK: - Preview, by source

    /// No `default` — a case added to `SourceChoice` later must fail this
    /// file's build rather than silently show nothing.
    @ViewBuilder
    private var previewArea: some View {
        switch model.sourceChoice {
        case .empty:
            Text(.newFileEmptyPreviewNote).foregroundStyle(.secondary)
        case .plainYAML:
            plainYAMLPreview
        case .dotEnv:
            dotEnvPreviewArea
        case .encryptedYAML:
            // Unreachable through this view's own radio row (disabled), but
            // `sourceChoice` is a plain, externally-settable property — a
            // caller that sets it directly must still see the same honest
            // explanation, not a blank preview.
            Text(.newFileSourceEncryptedYAMLDisabledReason).foregroundStyle(.secondary)
        }
    }

    private var plainYAMLPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: choosePlainYAMLFile)
            if let plainYAMLFileName {
                Text(String(format: LocalizedKey.newFileFileChosen.text, plainYAMLFileName))
                    .font(.callout)
            } else {
                Text(.newFileNoFileChosen).foregroundStyle(.secondary)
            }
        }
    }

    private var dotEnvPreviewArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: chooseDotEnvFile)
            if let dotEnvParseError {
                failureBanner(dotEnvParseError)
            } else if let dotEnvParsed {
                DotEnvPreviewTable(parsed: dotEnvParsed)
            } else {
                Text(.newFileNoFileChosen).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - File pickers (NSOpenPanel — established pattern, ProjectSidebar.swift)

    private func choosePlainYAMLFile() {
        guard let url = runOpenPanel() else { return }
        plainYAMLFileName = url.lastPathComponent
    }

    private func chooseDotEnvFile() {
        guard let url = runOpenPanel() else { return }
        do {
            // `DotEnvParser` owns the UTF-8 decode — the raw bytes go
            // straight in, never a `String(contentsOf:)` read first. See
            // that type's own doc comment, "Why `Data`, not `String`".
            let data = try Data(contentsOf: url)
            dotEnvParsed = try DotEnvParser.parse(data)
            dotEnvParseError = nil
        } catch let failure as DotEnvParseFailure {
            dotEnvParsed = nil
            dotEnvParseError = CreationFailurePresenter.message(for: failure)
        } catch {
            // `Data(contentsOf:)` itself failing (permissions, the file
            // vanished between picking and reading) — not a
            // `DotEnvParseFailure`, and not one of the four vocabularies
            // `CreationFailurePresenter` unifies. See this file's own doc
            // comment, "The view decides nothing", for why this is the one
            // sentence composed directly here rather than through that type.
            dotEnvParsed = nil
            dotEnvParseError = CreationFailureMessage(
                title: .creationFailureDotEnvTitle, detail: LocalizedKey.newFileFileUnreadable.text,
                recovery: nil)
        }
    }

    private func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = LocalizedKey.newFileChooseFileButton.text
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack {
            Spacer()
            Button(LocalizedKey.actionCancel.text) { dismiss() }
            Button(LocalizedKey.newFileCreateButton.text) {
                Task { await performCreate() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!Self.canCreate(readiness: model.readiness, isCreating: isCreating))
        }
    }

    private func performCreate() async {
        isCreating = true
        defer { isCreating = false }
        guard let url = await model.create() else { return }
        onCreated(url)
        dismiss()
    }

    /// Whether "Create" may be pressed right now. The one decision this view
    /// makes — and it makes it by reading `readiness`, never by
    /// re-deriving what `readiness` already means. Pure and `static` so a
    /// test can check every `Readiness` case without rendering anything —
    /// see `NewSecretFileSheetTests`.
    static func canCreate(readiness: NewSecretFileModel.Readiness, isCreating: Bool) -> Bool {
        guard case .ready = readiness else { return false }
        return !isCreating
    }

    // MARK: - Debounce

    /// Recomputes `readiness` immediately — no delay, no bridge-call cost to
    /// justify one. Used whenever `sourceChoice` changes, per this file's
    /// own doc comment.
    private func resolveNow() {
        resolveTask?.cancel()
        resolveTask = Task { await model.resolvePlan() }
    }

    /// Recomputes `readiness` 200ms after the last call, cancelling
    /// whatever resolve was still in flight — and skips the call entirely
    /// when nothing has actually changed since the last successful resolve.
    /// See this file's own doc comment, "The debounce, and why it checks
    /// `resolvedName` before firing".
    private func resolveDebounced() {
        resolveTask?.cancel()
        resolveTask = Task {
            try? await Task.sleep(for: Self.debounceDuration)
            guard !Task.isCancelled else { return }
            guard Self.shouldResolve(relativeName: model.relativeName, resolvedName: model.resolvedName) else {
                return
            }
            await model.resolvePlan()
        }
    }

    /// Whether a resolve should actually run for `relativeName`, given what
    /// the model last resolved (`resolvedName`, `nil` before any resolve has
    /// happened at all). `false` exactly when the name has not changed since
    /// the last successful resolve — the guard against the reflexive reset
    /// this file's own doc comment describes. A free, pure function so a
    /// test can drive it directly with plain strings, without `Task.sleep`
    /// or a rendered view anywhere in the test.
    static func shouldResolve(relativeName: String, resolvedName: String?) -> Bool {
        relativeName != resolvedName
    }
}
