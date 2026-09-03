import AppKit
import SopsEngine
import SopsProjects
import SwiftUI

/// The Access page: who can read this project's secrets, said in the
/// project's own vocabulary.
///
/// SOPS-39 task 8. This is a **destination** — the pane the sidebar's Access
/// row navigates to — not a sheet. It replaces the inline `ProjectAccessView`
/// the shell used to render there, and it answers three questions that panel
/// could not:
///
/// 1. **What are the keys called?** A `.sops.yaml` that declares its keys
///    under a top-level `keys:` list gives each one a YAML anchor, and that
///    anchor is the name the team already uses ("studio", "vps"). Rendering
///    three `age1…` strings instead throws that away. The anchor is not a
///    secret by construction: it sits in a file everyone reading the repo
///    sees, next to the public key it names.
/// 2. **Which rule governs what?** The old panel described exactly one rule —
///    the one governing the selected file — so a project with a production
///    rule and a catch-all rule looked like a project with one rule.
/// 3. **Has anything drifted?** A creation rule says who *new* files are
///    encrypted for. It says nothing about the files already on disk, and
///    those two answers diverge the moment someone edits the config. The
///    per-rule pill and the rewrap banner are that divergence, named.
///
/// ## The model comes from the store
/// Never constructed in this body: a model built here is replaced by a fresh,
/// unloaded one on any re-render while the view's identity — and therefore
/// its `.task` — stays put. `ProjectTreeStore.accessModel(for:targetFile:)`
/// owns it. The one deliberate exception in this feature is
/// `RewrapCoordinator`, which builds one model per drifted rule; see its doc
/// comment for why a project-wide rewrap is the operation that genuinely
/// spans rules, and why that makes it the only place `targetFile` is used for
/// more than one rule.
///
/// ## Editing is scoped to the rule the model is about
/// `ProjectAccessModel` holds a single staged recipient set, and it belongs
/// to the rule governing `targetFile`. So the `×` and add controls appear on
/// that rule only, and only when the rule is a flat `age:` list this app can
/// rewrite. Every other rule renders read-only rather than offering an edit
/// that would silently be applied to a different rule's key list.
///
/// No `SnapshotTool` entry is missing here — `Catalog.projectAccessPage()`
/// renders it against a momentak-shaped fixture with one drifted file.
public struct ProjectAccessPage: View {
    @Bindable private var model: ProjectAccessModel
    private let selectedFile: URL?
    private let onFilesApplied: () -> Void
    /// Opens the new-file wizard. `nil` where there is nothing to open it
    /// with — the snapshot catalog and the tests that only read this page —
    /// and the empty state then explains without offering the button.
    private let onNewFile: (() -> Void)?

    @State private var labelEdit: RecipientLabelEditRequest?
    @State private var newRecipientText = ""
    @State private var rewrap: RewrapCoordinator?
    @State private var showingRewrap = false
    @State private var errorMessage: String?
    @State private var confirmingConfigUpdate = false
    /// The Named-keys section's own sheet — SOPS-44. Separate from the one
    /// each rule card owns: this one declares a key under `keys:` and joins
    /// no rule, so it offers no Existing tab and writes with `ruleIndex ==
    /// -1`.
    @State private var declaringProjectKey = false

    public init(
        model: ProjectAccessModel,
        selectedFile: URL?,
        onFilesApplied: @escaping () -> Void,
        onNewFile: (() -> Void)? = nil
    ) {
        self.model = model
        self.selectedFile = selectedFile
        self.onFilesApplied = onFilesApplied
        self.onNewFile = onNewFile
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                registryQuarantineBanner
                if let inventory = model.inventory {
                    // From the plan first: when `.sops.yaml` exists and could
                    // not be read, `ProjectRecipientApplier.plan()` reports
                    // the reason on the *plan* and hands back
                    // `AccessInventory.empty`, whose own `configError` is
                    // `nil`. Reading only the inventory's therefore showed
                    // nothing at all for exactly the case the box exists for —
                    // the page rendered a title, two notes and no explanation.
                    if let error = model.plan?.configError ?? inventory.configError {
                        configErrorBox(error)
                    } else if inventory.rules.isEmpty, inventory.files.isEmpty {
                        emptyState
                    }
                    rewrapBanner(inventory)
                    namedKeys(inventory)
                    rules(inventory)
                    ungoverned(inventory)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
        .sheet(isPresented: $showingRewrap) {
            // `if let` rather than a fallback coordinator: a coordinator built
            // here would be a second, empty one that never ran, so the sheet
            // would sit at "nothing happened" while the real run reported into
            // an instance nothing is showing.
            if let rewrap {
                RewrapSheet(
                    coordinator: rewrap,
                    onClose: {
                        showingRewrap = false
                        Task {
                            await model.load()
                            onFilesApplied()
                        }
                    })
            }
        }
        .sheet(isPresented: $declaringProjectKey) { declareKeySheet }
        .sheet(item: $labelEdit) { request in
            RecipientLabelEditorView(
                model: request.model,
                onClose: { labelEdit = nil },
                onChanged: { model.reloadRegistry() })
        }
        // The one screen before `.sops.yaml` is rewritten. It carries the two
        // disclosures `ProjectAccessView` made before this page replaced it
        // (SOPS-39 task 10 deleted them with that view, and the final review
        // caught it): the file is re-emitted whole, so blank lines, a leading
        // `---` and the alignment inside `creation_rules` can shift; and
        // dropping a recipient from a *rule* revokes nothing — every file
        // already on disk still decrypts for them until it is re-wrapped.
        // Neither is recoverable by undo, and the second is the one a user
        // can act on wrongly for weeks without noticing.
        .confirmationDialog(
            LocalizedKey.projectAccessUpdateConfigConfirmTitle.text,
            isPresented: $confirmingConfigUpdate
        ) {
            Button(LocalizedKey.projectAccessUpdateConfigConfirmButton.text) {
                Task { await applyConfig() }
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(verbatim: configUpdateConfirmationMessage)
        }
        .alert(
            LocalizedKey.projectAccessErrorTitle.text,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(.accessPageTitle).font(.title2.weight(.semibold))
                Spacer()
                Button(LocalizedKey.projectAccessUpdateConfigButton.text) {
                    confirmingConfigUpdate = true
                }
                // Nothing has been staged, so there is nothing this could
                // write. Disabled rather than hidden: the control is the
                // answer to "where do I save this?", and it has to be visible
                // before there is something to save for that answer to arrive
                // in time.
                .disabled(!model.isDirty)
            }
            // The write landed — and the sentence that says so is also the
            // only thing on this path that asks for a commit. Carried over
            // from the panel this page replaced (SOPS-39 task 10): writing
            // `.sops.yaml` silently would leave the team's copy disagreeing
            // with the repository's, which is the one outcome
            // `CommitRemindersTests` exists to prevent.
            if model.configWritten {
                Text(.projectAccessConfigWritten)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// SOPS-33. The registry was found present but undecodable and moved
    /// aside, so the names on this page are missing for a reason the user is
    /// entitled to know. Rendered through the shared
    /// `RegistryQuarantineBanner`, exactly as the panel this page replaced
    /// did — dropping it with that panel would have silently retired a
    /// disclosure the app already shipped (SOPS-39 task 10).
    @ViewBuilder
    private var registryQuarantineBanner: some View {
        if let notice = model.registryQuarantineNotice {
            RegistryQuarantineBanner(notice: notice)
        }
    }

    private func configErrorBox(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(.projectAccessConfigErrorTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(error).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // Something to do about it: the text is the bridge's own reason
            // and this app never edits `.sops.yaml` by hand, so the only next
            // step it can offer is the file itself. Same control, same
            // wording as the one an anchored rule card shows.
            Button(LocalizedKey.accessRulesRevealConfig.text) {
                NSWorkspace.shared.activateFileViewerSelecting([
                    model.projectRoot.appendingPathComponent(".sops.yaml")
                ])
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10))
    }

    /// What the page says about a project with no rules and no encrypted
    /// files: the two ways that happens, told apart, rather than a pane that
    /// renders a title and nothing else.
    ///
    /// It was a dead end before — the page is built out of rules and files,
    /// so a project with neither drew a heading, two notes and no way
    /// forward, which reads as a failure to load. The wording is
    /// `ProjectStartHereView`'s (`newFileInfoNoConfig` is the identical
    /// sentence `NewSecretFileSheet` shows for `CreationPlan.noConfig`) and
    /// the button is the wizard that screen already offers. No new write
    /// path: this page still writes nothing but `.sops.yaml`, and only
    /// through the confirmation above.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasConfigFile {
                Text(.accessEmptyNoFiles)
            } else {
                Text(.newFileInfoNoConfig)
            }
            if let onNewFile {
                Button(LocalizedKey.startHereCreateFirstFileButton.text, action: onNewFile)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Read from disk rather than inferred from the inventory: an inventory
    /// with no rules is what both a missing `.sops.yaml` and a config with an
    /// empty `creation_rules:` produce, and the two sentences above differ in
    /// exactly that. `configError` — a config that exists and could not be
    /// read — is handled before this is reached.
    private var hasConfigFile: Bool {
        FileManager.default.fileExists(
            atPath: model.projectRoot.appendingPathComponent(".sops.yaml").path)
    }

    /// The sentence the confirmation carries, exposed so a test can read it:
    /// a `.confirmationDialog`'s own body is not reachable from `AXProbe`
    /// (the same limitation `ProjectAccessView`'s deleted tests worked
    /// around), so the string it is handed is the last thing that can be
    /// pinned.
    ///
    /// The removal sentence comes first and names people, because that is the
    /// half a reader can act on wrongly: dropping a key from a creation rule
    /// takes nothing away from anybody until the files are re-wrapped.
    var configUpdateConfirmationMessage: String {
        var parts: [String] = []
        let lost = model.pendingRemovals
        if !lost.isEmpty {
            parts.append(
                String(
                    format: LocalizedKey.projectAccessConfigLoses.text,
                    lost.map { $0.label ?? $0.ageRecipient }.joined(separator: ", ")))
        }
        parts.append(LocalizedKey.projectAccessUpdateConfigConfirmMessage.text)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Rewrap banner

    /// Shown only when at least one file's own recipients differ from what
    /// its rule declares. A config edit changes who *new* files are encrypted
    /// for and nothing else — this is the sentence that stops "I updated
    /// .sops.yaml" from being mistaken for "I rotated access".
    @ViewBuilder
    private func rewrapBanner(_ inventory: AccessInventory) -> some View {
        let drifted = inventory.filesNeedingRewrap
        if !drifted.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(.accessRewrapBanner, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)

                ForEach(drifted) { file in
                    if case .ruleDiffers(let has, let wants) = file.status {
                        Text(
                            String(
                                format: LocalizedKey.accessRewrapDetail.text,
                                file.relativePath, names(has, in: inventory),
                                names(wants, in: inventory))
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button(String(format: LocalizedKey.accessRewrapButton.text, drifted.count)) {
                        let coordinator = makeCoordinator()
                        rewrap = coordinator
                        showingRewrap = true
                        Task { await coordinator.rewrap(inventory) }
                    }
                    .disabled(!model.keyConfigured)
                    Text(.accessRewrapNote).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
        }
    }

    // MARK: - Named keys

    @ViewBuilder
    private func namedKeys(_ inventory: AccessInventory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(.accessKeysTitle).font(.headline)
                Spacer()
                // The section's own call to action. A named key belongs to
                // the *project*, not to a rule — before SOPS-44 the only way
                // to declare one was through a rule card, so a key could not
                // be added until there was a rule willing to take it, and
                // adding it always changed who new files are encrypted for.
                Button(LocalizedKey.accessKeysAddButton.text) { declaringProjectKey = true }
                    .controlSize(.small)
                    // No `.sops.yaml` yet means there is no `keys:` list to
                    // declare into — `gobridge.AddNamedKey` opens the config
                    // it is given and this app never creates one behind the
                    // user's back. The New File flow is what writes the first
                    // one.
                    .disabled(model.plan?.configExists != true)
            }
            Text(.accessKeysNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if inventory.keys.isEmpty {
                Text(.accessKeysNone).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // A `Grid` rather than a `Table`: `Table` is a scroll view,
                // and neither the headless snapshot renderer nor `AXProbe`
                // sees past a scroll view's own laid-out frame (CLAUDE.md,
                // "What it still cannot see"). A key list that cannot be
                // verified is a key list nothing guards.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        columnHeader(.accessKeysColumnName)
                        columnHeader(.accessKeysColumnKey)
                        columnHeader(.accessKeysColumnLabel)
                        columnHeader(.accessKeysColumnUsedIn)
                    }
                    ForEach(inventory.keys) { key in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Self.colour(for: key.recipient))
                                    .frame(width: 8, height: 8)
                                Text(verbatim: key.name.isEmpty ? "—" : key.name)
                                    .font(.system(.body, design: .monospaced))
                            }
                            // Selectable rather than behind a copy button:
                            // this module has no shared copy control, and a
                            // new one here would be a second clipboard path
                            // next to the audited one in `CopyFeedback`. A
                            // public key is not a secret, so selection is
                            // enough — the whole key is in `.help` too.
                            Text(verbatim: Self.short(key.recipient))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .help(key.recipient)
                            // The cell *is* the control, so what it does has
                            // to be said somewhere a reader — and the
                            // accessibility tree — can find it: an unnamed
                            // key's cell reads "—", which announces nothing.
                            // The per-file panel says the same two sentences
                            // through `RecipientNamingButton`; this column
                            // carries them as the cell's help.
                            Button {
                                editLabel(for: key.recipient)
                            } label: {
                                Text(verbatim: label(for: key.recipient) ?? "—")
                                    .foregroundStyle(
                                        label(for: key.recipient) == nil ? .secondary : .primary)
                            }
                            .buttonStyle(.plain)
                            // `.help`, not `.accessibilityLabel`: a label
                            // would *replace* the cell's own text in the
                            // accessibility tree, so the name a user just
                            // gave this key would stop being announced — the
                            // one thing the column exists to show.
                            .help(namingLabel(for: key.recipient).text)
                            Text(verbatim: usedIn(key.recipient, in: inventory))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .help(usedInHelp(key.recipient, in: inventory))
                        }
                    }
                }
            }
        }
    }

    /// The Named-keys sheet: declare a key the project knows by name, with
    /// no rule attached. `ruleIndex: -1` is the bridge's own "declare only"
    /// (`gobridge.AddNamedKey`), so nothing about who can read what changes
    /// until the key is added to a rule.
    @ViewBuilder
    private var declareKeySheet: some View {
        if let inventory = model.inventory {
            AddNamedKeySheet(
                keys: [],
                existingKeys: inventory.keys,
                offersExisting: false,
                onPick: { _ in declaringProjectKey = false },
                onCreate: { name, recipient, label in
                    declaringProjectKey = false
                    Task { await addNewKey(name: name, recipient: recipient, label: label, to: -1) }
                },
                onCancel: { declaringProjectKey = false })
        }
    }

    private func columnHeader(_ key: LocalizedKey) -> some View {
        Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    // MARK: - Creation rules

    @ViewBuilder
    private func rules(_ inventory: AccessInventory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.accessRulesTitle).font(.headline)
            Text(.accessRulesNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.plan?.targetFileWasSubstituted == true {
                Text(.accessTargetSubstituted).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A key the editable rule names twice is drawn once — the staged
            // set is a set, and multiplicity is not access — but never
            // without saying so. Carried over from the panel this page
            // replaced (SOPS-39 task 10): the collapse is otherwise
            // invisible, and the config on disk says something the page
            // would not. See `ProjectAccessModel.duplicatedRecipients`.
            if !model.duplicatedRecipients.isEmpty {
                Text(
                    String(
                        format: LocalizedKey.projectAccessDuplicateRecipients.text,
                        model.duplicatedRecipients.count)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(inventory.rules) { rule in
                AccessRuleCard(
                    rule: rule, inventory: inventory,
                    isSelected: selectedRuleIndex(in: inventory) == rule.index,
                    isEditable: isEditable(rule, in: inventory),
                    stagedRecipients: model.stagedRecipients,
                    configURL: model.projectRoot.appendingPathComponent(".sops.yaml"),
                    displayName: { displayName($0, in: inventory) },
                    onRemove: { recipient in
                        model.stageRemove(recipient)
                        model.startRefreshingPlan()
                    },
                    newRecipientText: $newRecipientText,
                    onAdd: addStagedRecipient,
                    onAddNamedKey: { anchor in
                        Task { await addNamedKey(anchor, to: rule.index) }
                    },
                    onRemoveNamedKey: { anchor in
                        Task { await removeNamedKey(anchor, from: rule.index) }
                    },
                    onAddNewKey: { name, recipient, label in
                        Task { await addNewKey(name: name, recipient: recipient, label: label, to: rule.index) }
                    })
            }
        }
    }

    // MARK: - Derived

    /// Which rule the page is *about*: the one governing the selected file,
    /// or — when no file is selected, or the selected one is no longer in the
    /// project — the one governing whatever file the plan itself fell back to.
    ///
    /// The fallback is not cosmetic. `ProjectAccessModel` stages against the
    /// rule governing `plan.targetFile`, and `plan()` picks the first file in
    /// path order when it was given none. Returning `nil` here for a page
    /// opened before any file was ever selected — the ordinary case, since the
    /// sidebar's Access row is reachable from a project the user has only just
    /// added — left every rule read-only and said nothing about why, while the
    /// model was perfectly willing to stage.
    private func selectedRuleIndex(in inventory: AccessInventory) -> Int? {
        if let selectedFile, let match = inventory.files.first(where: { $0.url == selectedFile }) {
            return match.ruleIndex
        }
        guard let target = model.plan?.targetFile else { return nil }
        return inventory.files.first { $0.url == target }?.ruleIndex
    }

    /// Whether `rule` is the one this model's staged set belongs to — the rule
    /// governing its target file. See the type's doc comment.
    private func isEditable(_ rule: ConfigRules.Rule, in inventory: AccessInventory) -> Bool {
        guard model.plan?.configRefusal == nil else { return false }
        return selectedRuleIndex(in: inventory) == rule.index
    }

    /// "Name this key" or "Edit name", the same pair `RecipientNamingButton`
    /// offers on the per-file panel's rows — so the same action does not read
    /// as two different ones in the two places it appears.
    private func namingLabel(for recipient: String) -> LocalizedKey {
        label(for: recipient) == nil ? .recipientNameThis : .recipientEditLabel
    }

    private func label(for recipient: String) -> String? {
        model.registryRecords.first { $0.ageRecipient == recipient }?.label
    }

    /// What a recipient is called on this page: its anchor name when the
    /// config gave it one, its registry label when the user named it, and its
    /// shortened public key otherwise. Never nothing — a recipient with no
    /// name is still a recipient.
    private func displayName(_ recipient: String, in inventory: AccessInventory) -> String {
        inventory.name(for: recipient) ?? label(for: recipient) ?? Self.short(recipient)
    }

    private func names(_ recipients: [String], in inventory: AccessInventory) -> String {
        recipients.map { displayName($0, in: inventory) }.joined(separator: ", ")
    }

    /// The files every rule that names this key governs — how a reader
    /// answers "what does the vps key actually unlock?" in the names they
    /// know the files by, not in the patterns sops matches on. The patterns
    /// are in `usedInHelp`, one hover away.
    private func usedIn(_ recipient: String, in inventory: AccessInventory) -> String {
        let rules = inventory.rules.filter { $0.recipients.contains { $0.recipient == recipient } }
        guard !rules.isEmpty else { return "—" }
        var seen = Set<String>()
        let files = rules.flatMap { inventory.files(governedBy: $0.index) }
            .map(\.relativePath)
            .filter { seen.insert($0).inserted }
        return files.isEmpty ? LocalizedKey.accessKeysUsedInNoFiles.text : files.joined(separator: ", ")
    }

    private func usedInHelp(_ recipient: String, in inventory: AccessInventory) -> String {
        inventory.rules
            .filter { $0.recipients.contains { $0.recipient == recipient } }
            .map(\.pathRegex)
            .joined(separator: "\n")
    }

    /// First 10 and last 6 characters of an age public key. Public keys are
    /// not secrets, so this is legibility rather than masking — the full key
    /// is in `.help` and one click away in the clipboard.
    static func short(_ recipient: String) -> String {
        guard recipient.count > 18 else { return recipient }
        return recipient.prefix(10) + "…" + recipient.suffix(6)
    }

    /// A stable colour per recipient, so the same key reads as the same key
    /// in the table and in every rule's chips.
    ///
    /// Hashed from the key's own scalars rather than from `hashValue`:
    /// Swift's `Hashable` is seeded per process, so a `hashValue`-derived
    /// colour changes between launches — and a snapshot of it would differ on
    /// every run for reasons that have nothing to do with the change under
    /// review.
    static func colour(for recipient: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in recipient.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.85)
    }

    // MARK: - Files no rule governs

    /// Encrypted files that fall under no creation rule at all — no
    /// `path_regex` matches them, or there is no readable config.
    ///
    /// They were invisible before: the page is organised by rule, and a file
    /// belonging to no rule therefore appeared nowhere, while the sidebar's
    /// own status dot has flagged exactly this condition since task 6
    /// (`sidebar.file-ungoverned`). A file nothing governs is not a tidy
    /// case — it is the one whose recipients no rule will ever correct, so
    /// it is listed with the keys it is actually wrapped for.
    @ViewBuilder
    private func ungoverned(_ inventory: AccessInventory) -> some View {
        let orphans = inventory.files.filter { $0.status == .ungoverned }
        if !orphans.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(.accessUngoverned).font(.headline)
                Text(.accessUngovernedHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(LocalizedKey.accessRulesRevealConfig.text) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.projectRoot.appendingPathComponent(".sops.yaml")])
                }
                .controlSize(.small)
                ForEach(orphans) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Verbatim: a path is not translatable, and resolved
                        // through the catalog it would vanish under a build
                        // system that copies `.xcstrings` uncompiled.
                        Text(verbatim: file.relativePath)
                            .font(.system(.caption, design: .monospaced))
                        HStack(spacing: 6) {
                            ForEach(file.encryptedFor, id: \.self) { recipient in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Self.colour(for: recipient))
                                        .frame(width: 7, height: 7)
                                    Text(verbatim: displayName(recipient, in: inventory))
                                        .font(.caption)
                                        .help(recipient)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func makeCoordinator() -> RewrapCoordinator {
        RewrapCoordinator(projectRoot: model.projectRoot, keyStore: model.keyStore)
    }

    /// Stages a typed recipient, and says so when it will not.
    ///
    /// A refusal used to be dropped on the floor here: pasting a key that is
    /// already in the rule cleared nothing and reported nothing, so the only
    /// reading available to the user was that the app had stopped responding.
    /// The explanation is the same `LocalizedKey` the per-file panel uses
    /// (`RecipientAccessView.explanation(for:)`) — `.empty` and `.notLoaded`
    /// have none, because neither is reachable from a control that is only
    /// enabled for non-empty text on a loaded page.
    private func addStagedRecipient() {
        guard let refusal = model.stageAdd(newRecipientText) else {
            newRecipientText = ""
            model.startRefreshingPlan()
            return
        }
        if let explanation = Self.explanation(for: refusal) {
            errorMessage = explanation.text
        }
    }

    static func explanation(for refusal: RecipientAccessModel.StageAddRefusal) -> LocalizedKey? {
        switch refusal {
        case .duplicate: .accessAddDuplicate
        case .empty, .notLoaded: nil
        }
    }

    /// Removes a named key from a rule — the inverse of `addNamedKey`, with
    /// the same reload and the same sidebar refresh, since every file the
    /// rule governs has just drifted the other way.
    private func removeNamedKey(_ anchor: String, from ruleIndex: Int) async {
        switch await model.removeAliasFromRule(ruleIndex: ruleIndex, anchor: anchor) {
        case .written: onFilesApplied()
        case .nothingToWrite: break
        case .failed(let message): errorMessage = message
        }
    }

    /// Declares a new named key and adds it to the rule in one write.
    private func addNewKey(name: String, recipient: String, label: String?, to ruleIndex: Int) async {
        switch await model.addNamedKey(name: name, recipient: recipient, label: label, ruleIndex: ruleIndex) {
        case .written: onFilesApplied()
        case .nothingToWrite: break
        case .failed(let message): errorMessage = message
        }
    }

    /// Adds one of the config's named keys to a rule as an alias — the one
    /// edit an anchored rule supports. Writes `.sops.yaml` and nothing else:
    /// the files on disk keep the keys they have until they are re-wrapped,
    /// which the banner the reload puts up is for.
    private func addNamedKey(_ anchor: String, to ruleIndex: Int) async {
        switch await model.addAliasToRule(ruleIndex: ruleIndex, anchor: anchor) {
        case .written:
            // The rule now wants a key the files on disk do not have, so
            // every file it governs has just drifted — and the sidebar draws
            // that drift as a status dot it only recomputes when told to. Left
            // out, the dots kept showing the state from before the write until
            // the user happened to collapse and re-expand the project.
            onFilesApplied()
        case .nothingToWrite:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    private func editLabel(for recipient: String) {
        labelEdit = RecipientLabelEditRequest(
            model: RecipientLabelEditorModel(
                projectURL: model.projectRoot,
                ageRecipient: recipient,
                existing: model.registryRecords.first { $0.ageRecipient == recipient }))
    }

    private func applyConfig() async {
        switch await model.applyConfig() {
        case .written:
            // Same reason as `addNamedKey`: a rewritten creation rule is new
            // drift for every file it governs, and the tree's dots are stale
            // until something asks for a rescan.
            onFilesApplied()
        case .nothingToWrite:
            break
        case .refusedEmptyRecipients:
            errorMessage = LocalizedKey.projectAccessErrorEmptyRecipients.text
        case .refusedStalePlan:
            errorMessage = LocalizedKey.projectAccessErrorStalePlan.text
        case .failed(let message):
            errorMessage = message
        }
    }
}

/// What a project-wide rewrap is doing, and what it did.
///
/// A sheet rather than inline content: a rewrap rewrites files, so it holds
/// the user's attention until it is finished or has reported why it is not.
struct RewrapSheet: View {
    @Bindable var coordinator: RewrapCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.projectAccessResultsTitle).font(.headline)

            if coordinator.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(.projectAccessApplyingLabel).foregroundStyle(.secondary)
                }
            }

            ForEach(coordinator.results) { result in
                HStack(spacing: 6) {
                    Text(verbatim: result.url.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(Self.outcomeLabel(result.outcome))
                        .font(.caption2)
                        .foregroundStyle(result.outcome == .updated ? Color.green : .secondary)
                }
            }

            ForEach(coordinator.skipped, id: \.self) { reason in
                Text(verbatim: reason).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !coordinator.isRunning, coordinator.updatedCount > 0 {
                Text(.projectAccessResultsCommitNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(LocalizedKey.actionDone.text, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.isRunning)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private static func outcomeLabel(_ outcome: ProjectRecipientApplier.FileOutcome)
        -> LocalizedKey
    {
        switch outcome {
        case .updated: .projectAccessResultUpdated
        case .unchanged: .projectAccessResultUnchanged
        case .failed: .projectAccessResultFailed
        }
    }
}
