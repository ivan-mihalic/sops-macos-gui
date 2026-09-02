import AppKit
import SopsEngine
import SopsProjects
import SwiftUI

/// One `creation_rules` entry, as the Access page shows it: the `path_regex`
/// it matches on, who it declares, which files it governs, and whether those
/// files still agree with it.
///
/// Its own file rather than three more methods on `ProjectAccessPage`, which
/// had grown past 500 lines — the split CLAUDE.md's code-organisation note
/// asks for. The split is along a real seam: this card renders a rule and
/// reports intent back through closures, and knows nothing about staging,
/// plans, sheets or the model that owns them.
///
/// ## Read-only is a property of the rule, not of the app's mood
/// A rule declared through YAML anchors or `key_groups` is one this app reads
/// and refuses to rewrite (`SopsBridge.updateConfigRecipients`). Its chips
/// therefore carry no `×`, and the reason is stated next to a button that
/// opens the file the user would have to edit instead — said before the
/// attempt rather than as a failure after it.
struct AccessRuleCard: View {
    let rule: ConfigRules.Rule
    let inventory: AccessInventory
    /// Whether the selected file falls under this rule.
    let isSelected: Bool
    /// Whether this is the rule the page's staged recipient set belongs to,
    /// and that set is one this app can write. See `ProjectAccessPage`.
    let isEditable: Bool
    /// What an edit would write — shown instead of the rule's current list on
    /// an editable rule, so pressing `×` visibly does something before the
    /// config is saved.
    let stagedRecipients: [String]
    let configURL: URL
    let displayName: (String) -> String
    let onRemove: (String) -> Void
    @Binding var newRecipientText: String
    let onAdd: () -> Void
    /// Adds one of the config's existing named keys to *this* rule as an
    /// alias. Offered on a read-only rule, which is the only place it makes
    /// sense: an editable rule already has the text field above.
    let onAddNamedKey: (String) -> Void

    @State private var choosingNamedKey = false

    private var governed: [AccessInventory.FileAccess] {
        inventory.files(governedBy: rule.index)
    }

    private var drifted: [AccessInventory.FileAccess] {
        governed.filter {
            if case .ruleDiffers = $0.status { return true }
            return false
        }
    }

    private var readOnly: Bool { rule.usesAnchors || rule.usesKeyGroups }

    /// The config's named keys this rule does not already name. The list the
    /// sheet offers — empty is a sentence, not an empty sheet.
    private var addableKeys: [ConfigRules.NamedKey] {
        inventory.keys.filter { key in
            !key.name.isEmpty && !rule.recipients.contains { $0.recipient == key.recipient }
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                header
                AccessLabelledRow(.accessRulesRecipients) { recipients }
                AccessLabelledRow(.accessRulesGoverns) { governedFiles }
                if !rule.comment.isEmpty {
                    AccessLabelledRow(.accessRulesComment) {
                        Text(verbatim: rule.comment).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
        .sheet(isPresented: $choosingNamedKey) {
            AddNamedKeySheet(
                keys: addableKeys,
                onPick: { anchor in
                    choosingNamedKey = false
                    onAddNamedKey(anchor)
                },
                onCancel: { choosingNamedKey = false })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: rule.pathRegex)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            if drifted.isEmpty {
                AccessPill(text: LocalizedKey.accessRulesAllInSync.text, tint: .green)
            } else {
                AccessPill(
                    text: String(
                        format: LocalizedKey.accessRulesNeedsRewrap.text, drifted.count),
                    tint: .orange)
            }
        }
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 6) {
            chips
            if readOnly {
                Text(.accessRulesAnchoredReadOnly)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(LocalizedKey.accessRulesRevealConfig.text) {
                        // Reveals in Finder. It does not activate this app, so
                        // it cannot take focus from whatever the machine owner
                        // is doing — the distinction CLAUDE.md draws about
                        // launching and raising windows.
                        NSWorkspace.shared.activateFileViewerSelecting([configURL])
                    }
                    .controlSize(.small)
                    // Appending an alias of a key the config already declares
                    // is the one edit an anchored rule supports: nothing is
                    // removed and nothing is resolved, so none of the
                    // questions that make a full rewrite a guess arise. See
                    // `SopsBridge.addAliasRecipient`.
                    if !addableKeys.isEmpty {
                        Button(LocalizedKey.accessRulesAddNamed.text) { choosingNamedKey = true }
                            .controlSize(.small)
                    }
                }
            } else if isEditable {
                addRow
            }
            if !rule.nonAgeBackends.isEmpty {
                // Rendered as the identifiers sops itself uses ("pgp",
                // "kms"): this module has no backend-label dictionary, and
                // inventing display names here would put a second vocabulary
                // next to the config file the user is reading.
                HStack(spacing: 6) {
                    ForEach(rule.nonAgeBackends, id: \.self) { backend in
                        AccessPill(text: backend, tint: .secondary)
                    }
                }
            }
        }
    }

    private var chips: some View {
        let shown = isEditable && !readOnly ? stagedRecipients : rule.recipients.map(\.recipient)
        return HStack(spacing: 6) {
            // Identified positionally, not by value: a creation rule may name
            // the same key twice (`ProjectAccessModel.duplicatedRecipients`),
            // and `id: \.self` over that is the duplicate-identity defect the
            // old recipient rows already had once. A rule that lists a key
            // twice is one this page draws twice, honestly, rather than
            // tidying the second one away.
            ForEach(Array(shown.enumerated()), id: \.offset) { _, recipient in
                HStack(spacing: 4) {
                    Circle()
                        .fill(ProjectAccessPage.colour(for: recipient))
                        .frame(width: 7, height: 7)
                    Text(verbatim: displayName(recipient))
                        .font(.caption)
                        .help(recipient)
                    if isEditable && !readOnly {
                        Button { onRemove(recipient) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizedKey.accessRemoveRecipient.text)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
            }
        }
    }

    private var addRow: some View {
        HStack {
            TextField(LocalizedKey.accessAddRecipientField.text, text: $newRecipientText)
                .font(.system(.body, design: .monospaced))
                .onSubmit(onAdd)
            Button(LocalizedKey.actionAdd.text, action: onAdd)
                .disabled(!RecipientRowContent.canAdd(newRecipientText))
        }
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private var governedFiles: some View {
        if governed.isEmpty {
            Text(.accessRulesGovernsNone).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(governed) { file in
                    HStack(spacing: 6) {
                        // A path is not translatable, and resolved through the
                        // catalog it would vanish under whichever build system
                        // copies `.xcstrings` uncompiled — see
                        // `ProjectAccessView.filesPreview`.
                        Text(verbatim: file.relativePath)
                            .font(.system(.caption, design: .monospaced))
                        if case .ruleDiffers(let has, let wants) = file.status {
                            AccessPill(
                                text: String(
                                    format: LocalizedKey.accessRulesEncryptedForOf.text,
                                    has.count, wants.count),
                                tint: .orange)
                        }
                    }
                }
            }
        }
    }
}

/// A short, tinted status word. Colour is never the message here — the word
/// is (`ColourIndependenceTests`); the tint only repeats what it says.
struct AccessPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// A fixed-width caption label with content beside it — the shape every row
/// inside a rule card uses, so the three rows line up down the card.
struct AccessLabelledRow<Content: View>: View {
    private let key: LocalizedKey
    private let content: Content

    init(_ key: LocalizedKey, @ViewBuilder content: () -> Content) {
        self.key = key
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// Picks one of the config's own named keys to append to an anchored rule.
///
/// Only keys the rule does not already name are offered — adding one twice is
/// something the bridge refuses anyway (`SopsBridge.addAliasRecipient`), and
/// an option whose only outcome is a refusal is not an option — so the empty
/// case is not dead text either: a reload while this sheet is open (the page
/// reloads after every add) recomputes the list under it. The note under the
/// list says the part users get wrong: a config edit decides who *new*
/// files are encrypted for and re-encrypts nothing that already exists.
struct AddNamedKeySheet: View {
    let keys: [ConfigRules.NamedKey]
    let onPick: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.accessRulesAddNamed).font(.headline)

            if keys.isEmpty {
                Text(.accessRulesAddNamedNone).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keys) { key in
                        Button { onPick(key.name) } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(ProjectAccessPage.colour(for: key.recipient))
                                    .frame(width: 8, height: 8)
                                // The anchor is the name the team already
                                // uses, and it is what lands in the file —
                                // so it is what the choice is labelled by.
                                Text(verbatim: key.name)
                                    .font(.system(.body, design: .monospaced))
                                Text(verbatim: ProjectAccessPage.short(key.recipient))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(key.recipient)
                    }
                }
            }

            Text(.accessRulesAddNamedNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(LocalizedKey.actionCancel.text, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
