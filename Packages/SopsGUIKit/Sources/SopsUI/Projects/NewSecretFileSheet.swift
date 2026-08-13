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
/// `CreationFailurePresenter`'s own discipline. Even a Plain YAML/`.env`
/// file that could not be read (`NSOpenPanel` returned a URL, but
/// `Data(contentsOf:)` then failed) is worded by that presenter —
/// `CreationFailurePresenter.message(forUnreadableSourceFile:)` — not by
/// this file; this view only ever picks the URL and hands it to
/// `model.loadPlainYAML(from:)`/`.loadDotEnv(from:)`, which do the actual
/// read and own the resulting error text.
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
/// Choosing a different source fires no resolve at all. An earlier version
/// called `resolvePlan()` on every `sourceChoice` change "to recompute
/// `readiness`" — `NewSecretFileModel.readiness` is now derived on every
/// read, so there is nothing to recompute, and the plan cannot have changed
/// anyway: `CreationPlanResolver.plan(forTarget:in:)` is a function of the
/// name and the project root, not of the source. All that call did was cross
/// the Go bridge for an unchanged answer and discard the user's
/// acknowledgement on the way.
///
/// ## What Plain YAML and `.env` actually create
///
/// `model.loadPlainYAML(from:)`/`.loadDotEnv(from:)` read the file the
/// moment it is picked and store what they read on the model —
/// `plainYAMLText`/`dotEnvParsed` — not the `URL`. `create()` then uses
/// exactly that stored value, never re-reading the file: what the user
/// previewed (this view renders `dotEnvParsed` through
/// `DotEnvPreviewTable`) is what gets encrypted, even if the file on disk
/// changes or disappears in between. Plain YAML goes through verbatim as
/// `SecretFileCreator.Source.verbatimYAML(_:)` — no reserialisation; `.env`
/// goes through as `.dotEnv(dotEnvParsed.entries)`, the identical entries
/// the preview already showed.
///
/// ## Encrypted YAML
///
/// The one source that needs an extra step before it can be used at all:
/// the file arrives already encrypted, for a recipient set that routinely
/// differs from whatever governs the destination, so unlocking it and
/// disclosing exactly who would gain and lose access has to happen before
/// `create()` has anything to encrypt. `EncryptedImportPreview` (Task 6)
/// owns all of that — this view only ever renders it, the same way it
/// renders `DotEnvPreviewTable` for `.dotEnv`.
public struct NewSecretFileSheet: View {
    @Bindable private var model: NewSecretFileModel
    private let onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var registryRecords: [RecipientRecord] = []
    @State private var resolveTask: Task<Void, Never>?
    @State private var isCreating = false

    /// The picked file's display name only — cosmetic, never what gets
    /// encrypted. `model.plainYAMLText` (set by `loadPlainYAML(from:)`) is
    /// the actual content; this exists purely so the preview can say
    /// "Selected: <name>" without the model needing to carry a filename
    /// alongside the text it will encrypt.
    @State private var plainYAMLFileName: String?

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
            // `resolvePlan()` resets the unreadability discovery and
            // `acknowledgedUnreadable` on every call (see that method's own
            // doc comment), so calling it here would silently clobber
            // a model handed in already past that point — exactly the
            // fixtures `NewSecretFileSheetTests` builds to exercise
            // `.needsAcknowledgement` without a live user session. Matches
            // `SecretEditorView`'s own contract: a caller establishes a
            // model's state before handing it to a view; the view never
            // re-derives it on appearance.
            registryRecords = (try? RecipientRegistry.load(in: model.projectRoot)) ?? []
        }
        .onChange(of: model.relativeName) { _, _ in resolveDebounced() }
    }

    // MARK: - Source

    private var sourceSection: some View {
        HStack(spacing: 16) {
            Text(.newFileSourceLabel)
            ForEach(NewSecretFileModel.SourceChoice.allCases, id: \.self) { choice in
                sourceOption(choice)
            }
        }
    }

    private func sourceOption(_ choice: NewSecretFileModel.SourceChoice) -> some View {
        let isSelected = model.sourceChoice == choice
        return Button {
            model.sourceChoice = choice
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                Text(sourceLabel(choice))
            }
        }
        .buttonStyle(.plain)
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

            // `.noConfig`/`.noRuleMatched` are not failures — see
            // `CreationFailurePresenter.message(forBlocking:)`'s own doc
            // comment — so nothing above renders a banner for them.
            // `RecipientPicker` is what this view shows instead, gated on
            // `model.plan` directly rather than on `readiness`: it must stay
            // visible once a recipient has been chosen and `readiness`
            // moves on to `.ready`/`.needsAcknowledgement`/`.blocked`, not
            // only while `readiness == .needsRecipients`.
            //
            // One consequence worth stating rather than fixing: gating on
            // `model.plan` alone means the picker's propose/write controls
            // render *alongside* a `.blocked` failure banner above — an
            // empty key store, say. That is deliberate, not an oversight:
            // proposing and writing a `.sops.yaml` needs no session
            // identity at all (`SopsConfigGenerator`/`AtomicFileWriter`
            // don't touch `keyStore`), only *creating the file itself*
            // does, which is exactly what the banner above is about. A
            // user with no key configured genuinely can set up a project's
            // config in advance of importing one.
            if model.plan == .noConfig || model.plan == .noRuleMatched {
                RecipientPicker(model: model)
            }
        }
    }

    /// `nil` — nothing shown — before any name has produced a plan at all
    /// (`model.plan == nil` and not resolving), which covers both
    /// `.needsName` and a thrown `CreationPlanResolver.Error`; the latter
    /// already has its own sentence in `model.readiness`, rendered through
    /// `failureBanner(_:)` above via `readiness == .blocked`, so this line
    /// has nothing useful to add for it.
    ///
    /// That used to name `model.planError` as the source of the rendered
    /// sentence, which was false: the banner renders `readiness`'s message,
    /// and the two only coincide for this one case — they disagree about
    /// precedence in general (see `NewSecretFileModel.planError`'s own doc
    /// comment). Nothing in this file reads `planError` at all, and nothing
    /// may.
    private var infoLineText: String? {
        // `.resolving` counts as resolving here, not only `model.isResolving`:
        // between a keystroke and the debounce firing, `model.plan` is still
        // the *previous* name's plan, and rendering its rule under the name
        // now in the field would say something true about a file the user is
        // no longer describing. `Readiness.resolving` is exactly that window.
        Self.infoLineText(
            isResolving: model.isResolving || model.readiness == .resolving,
            plan: model.plan, recipientNames: recipientNames)
    }

    /// The `ⓘ` line's text: five shapes matching `CreationPlan`'s cases, plus
    /// a sixth for "still resolving" — and, for a `.governedByRule` whose
    /// rule sets `encrypted_regex`, a second sentence appended to the first
    /// disclosing that the rule scopes which values get encrypted at all.
    /// See that branch's own comment for why that belongs on this line
    /// rather than in any one source's preview. Pure and `static` — `isResolving` is a
    /// plain `Bool` argument here rather than read live off `model
    /// .isResolving`, precisely so a test can check every shape (including
    /// "still resolving") without racing a real async resolve: this app's
    /// `CreationPlanResolver.plan(forTarget:in:)` is itself synchronous, so
    /// there is no `await` point inside `resolvePlan()` a test could
    /// reliably interleave with to catch `isResolving` genuinely `true` —
    /// see `NewSecretFileSheetTests.InfoLineTextTests`.
    ///
    /// No `default` in the switch — a case added to `CreationPlan` later
    /// must fail this file's build, the same discipline
    /// `CreationFailurePresenter` documents for its own switches.
    static func infoLineText(
        isResolving: Bool, plan: CreationPlan?, recipientNames: ([String]) -> String
    ) -> String? {
        if isResolving { return LocalizedKey.newFileInfoResolving.text }
        guard let plan else { return nil }
        switch plan {
        case .governedByRule(let recipients, let encryptedRegex):
            // An empty recipient list is not a governed target — see
            // `NewSecretFileModel.currentGovernedPlan()`'s own doc comment,
            // "An empty recipient list is not a target", for the review
            // finding this guard exists to close one screen over: sops
            // itself admits a creation rule with a matching `path_regex`
            // and no key group at all
            // (`CreationPlanResolverTests
            // .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients`), and
            // this was the one `.governedByRule` reader that never went
            // through `currentGovernedPlan()`'s choke point — reading
            // `plan`'s recipients straight from `model.plan` instead. Left
            // alone, `recipientNames([])` renders `""`, and this line
            // would claim "it will be encrypted for: " — asserting an
            // encryption that will not happen, directly above
            // `readiness`'s own `.blocked` banner saying so. Reusing
            // `messageForRuleWithNoRecipients()`'s own `detail` here is the
            // same duplication this file already accepts for
            // `.unsupportedRule`/`.configUnreadable` below — both cases
            // still hit `.blocked` and still render the same sentence a
            // second time via the failure banner — not a new pattern
            // invented for this one case.
            guard !recipients.isEmpty else {
                return CreationFailurePresenter.messageForRuleWithNoRecipients().detail
            }
            let governed = String(format: LocalizedKey.newFileInfoGovernedByRule.text, recipientNames(recipients))
            // `encrypted_regex` is the one scoping field `CreationPlanResolver`
            // passes through as supported rather than refusing (see its own
            // doc comment, decision order step 5), so a rule that sets it
            // produces a file whose every *non*-matching value is written in
            // plaintext. Naming only who can read the file, and saying
            // nothing about how much of it is encrypted, is the silent half
            // of an access change — spec §4.1 decision 4. Appended here
            // rather than shown per source because this line is the one
            // disclosure every source passes through: `nameSection` renders
            // it for `.empty`, `.plainYAML`, `.dotEnv` and `.encryptedYAML`
            // alike. `EncryptedImportPreview` repeats the identical sentence
            // beside its access diff, which is the other screen making an
            // access claim about the file this creates.
            guard !encryptedRegex.isEmpty else { return governed }
            return governed + " "
                + String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, encryptedRegex)
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
            EncryptedImportPreview(model: model)
        }
    }

    /// Gated on `model.plainYAMLText`, not on the view-local
    /// `plainYAMLFileName` — a model handed in already loaded (every
    /// `CreateFromSourceTests` fixture does exactly this, and Tasks 6/7
    /// will too, presenting a sheet built around a model whose source was
    /// set up before the view ever existed) must not render "No file
    /// chosen yet." beside an enabled Create button. `plainYAMLFileName`
    /// only decorates *which* file, when this view happens to know — the
    /// model deliberately never carries a path (see this file's own doc
    /// comment, "What Plain YAML and `.env` actually create"), so there is
    /// no filename to recover for a model loaded before this view existed.
    private var plainYAMLPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: choosePlainYAMLFile)
            if let plainYAMLLoadError = model.plainYAMLLoadError {
                failureBanner(plainYAMLLoadError)
            } else if model.plainYAMLText != nil {
                if let plainYAMLFileName {
                    Text(String(format: LocalizedKey.newFileFileChosen.text, plainYAMLFileName))
                        .font(.callout)
                } else {
                    Text(.newFileFileChosenNoName).font(.callout)
                }
            } else {
                Text(.newFileNoFileChosen).foregroundStyle(.secondary)
            }
        }
    }

    private var dotEnvPreviewArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocalizedKey.newFileChooseFileButton.text, action: chooseDotEnvFile)
            if let dotEnvLoadError = model.dotEnvLoadError {
                failureBanner(dotEnvLoadError)
            } else if let dotEnvParsed = model.dotEnvParsed {
                DotEnvPreviewTable(parsed: dotEnvParsed)
            } else {
                Text(.newFileNoFileChosen).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - File pickers (NSOpenPanel — established pattern, ProjectSidebar.swift)
    //
    // Both pickers only ever choose a `URL` and hand it straight to the
    // model — `model.loadPlainYAML(from:)`/`.loadDotEnv(from:)` do the
    // actual read, own the resulting content or error, and recompute
    // `readiness` themselves (no bridge call there to justify routing
    // through `resolveDebounced()`). See this file's own doc comment, "What
    // Plain YAML and `.env` actually create".

    private func choosePlainYAMLFile() {
        guard let url = runOpenPanel() else { return }
        plainYAMLFileName = url.lastPathComponent
        model.loadPlainYAML(from: url)
    }

    private func chooseDotEnvFile() {
        guard let url = runOpenPanel() else { return }
        model.loadDotEnv(from: url)
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

    /// Re-resolves the plan 200ms after the last call, cancelling
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
