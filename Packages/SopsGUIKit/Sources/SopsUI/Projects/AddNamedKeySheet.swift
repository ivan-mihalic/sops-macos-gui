import AppKit
import SopsEngine
import SopsProjects
import SwiftUI

/// Declaring a named key: pick one the config already has, paste a public key
/// someone sent you, or make a brand-new key here and now.
///
/// Its own file rather than a fourth structure inside `AccessRuleCard`, which
/// this sheet outgrew the moment it acquired a third mode (SOPS-44).
///
/// ## The tabs are decided by where the sheet was opened from
/// Opened from a **creation rule**, all three modes make sense: the rule can
/// be handed a key the config already declares (Existing key), or a new
/// declaration can be added and aliased into the rule in one write.
///
/// Opened from the **Named keys** section, "Existing key" would mean "add a
/// key this config already declares to the list of keys this config
/// declares", which is nothing at all — so that tab is not offered. A key
/// declared from there lands under `keys:` and joins no rule: it is a key the
/// project knows by name, ready to be added to whichever rule wants it. That
/// is `ruleIndex == -1` on the way down to `gobridge.AddNamedKey`, which has
/// supported exactly this since SOPS-42 with no caller.
///
/// ## Generating is not installing
/// The Generate tab mints a real age identity through the engine and shows
/// both halves once. It writes nothing on its own: the private key exists in
/// this sheet's memory and in whatever the user copies or saves from it. The
/// app still installs no keys and touches no key store (CLAUDE.md), and the
/// screen says so rather than leaving the user to assume either way.
struct AddNamedKeySheet: View {
    /// Existing named keys the rule does not name yet — the Existing tab.
    let keys: [ConfigRules.NamedKey]
    /// Every key the config declares — what a new name and key are checked
    /// against before the bridge is asked.
    let existingKeys: [ConfigRules.NamedKey]
    /// Whether this sheet was opened from a creation rule (which can be
    /// handed an existing key) rather than from the Named keys section.
    let offersExisting: Bool
    let onPick: (String) -> Void
    let onCreate: (_ name: String, _ recipient: String, _ label: String?) -> Void
    let onCancel: () -> Void
    /// Generates a key. Injected so a test can drive the tab without the
    /// engine, and so the snapshot catalog can show a fixed pair rather than
    /// a different one in every rendering.
    var generate: () throws -> GeneratedAgeKey = { try SopsBridge.generateAgeKey() }

    enum Mode: Hashable { case existing, add, generate }

    @State private var mode: Mode
    @State private var name = ""
    @State private var recipient = ""
    @State private var label = ""
    @State private var generated: GeneratedAgeKey?
    @State private var revealPrivateKey = false
    @State private var generationError: String?
    @State private var copyFeedback = CopyFeedback()

    init(
        keys: [ConfigRules.NamedKey], existingKeys: [ConfigRules.NamedKey],
        offersExisting: Bool = true,
        onPick: @escaping (String) -> Void,
        onCreate: @escaping (_ name: String, _ recipient: String, _ label: String?) -> Void,
        onCancel: @escaping () -> Void,
        generate: @escaping () throws -> GeneratedAgeKey = { try SopsBridge.generateAgeKey() }
    ) {
        self.keys = keys
        self.existingKeys = existingKeys
        self.offersExisting = offersExisting
        self.onPick = onPick
        self.onCreate = onCreate
        self.onCancel = onCancel
        self.generate = generate
        // Nothing left to pick from → straight to the Add form.
        self._mode = State(initialValue: offersExisting && !keys.isEmpty ? .existing : .add)
    }

    /// Why a new key cannot be created as typed, or `nil` when it can.
    enum NewKeyRefusal: Equatable {
        case emptyName, invalidAnchor, nameTaken, invalidRecipient, privateIdentity, recipientDeclared
    }

    /// The same rules the bridge applies (`gobridge.AddNamedKey`), answered
    /// here so the Create button is dead before a refusal rather than after.
    nonisolated static func validateNewKey(name: String, recipient: String, existing: [ConfigRules.NamedKey]) -> NewKeyRefusal? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .emptyName }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard trimmedName.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return .invalidAnchor }
        guard !existing.contains(where: { $0.name == trimmedName }) else { return .nameTaken }
        let trimmedKey = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .invalidRecipient }
        if trimmedKey.uppercased().hasPrefix("AGE-SECRET-KEY-") { return .privateIdentity }
        guard RecipientRegistry.refusal(forAgeRecipient: trimmedKey) == nil else { return .invalidRecipient }
        guard !existing.contains(where: { $0.recipient == trimmedKey }) else { return .recipientDeclared }
        return nil
    }

    nonisolated static func explanation(for refusal: NewKeyRefusal) -> LocalizedKey? {
        switch refusal {
        case .emptyName: nil
        case .invalidAnchor: .accessAddNamedRefusalInvalidAnchor
        case .nameTaken: .accessAddNamedRefusalNameTaken
        case .invalidRecipient: .accessAddNamedRefusalInvalidKey
        case .privateIdentity: .accessAddNamedRefusalPrivateKey
        case .recipientDeclared: .accessAddNamedRefusalKeyDeclared
        }
    }

    /// The tabs this sheet offers, in the order they are shown. Derived, not
    /// stored: the one thing that decides it is where the sheet was opened
    /// from.
    var modes: [Mode] { offersExisting ? [.existing, .add, .generate] : [.add, .generate] }

    private var refusal: NewKeyRefusal? {
        Self.validateNewKey(name: name, recipient: recipient, existing: existingKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.accessRulesAddNamed).font(.headline)

            Picker("", selection: $mode) {
                ForEach(modes, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .existing: existingList
            case .add: newForm
            case .generate: generateForm
            }

            Text(.accessRulesAddNamedNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(LocalizedKey.actionCancel.text, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if mode == .add {
                    Button(LocalizedKey.accessAddNamedCreate.text) {
                        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                            trimmedLabel.isEmpty ? nil : trimmedLabel)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(refusal != nil)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    static func title(for mode: Mode) -> LocalizedKey {
        switch mode {
        case .existing: .accessAddNamedModeExisting
        case .add: .accessAddNamedModeNew
        case .generate: .accessAddNamedModeGenerate
        }
    }

    @ViewBuilder
    private var existingList: some View {
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
    }

    private var newForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(LocalizedKey.accessAddNamedFieldName.text, text: $name)
                .font(.system(.body, design: .monospaced))
            TextField(LocalizedKey.accessAddNamedFieldKey.text, text: $recipient)
                .font(.system(.body, design: .monospaced))
            TextField(LocalizedKey.accessAddNamedFieldLabel.text, text: $label)
            if let refusal, let explanation = Self.explanation(for: refusal) {
                Text(explanation).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: - Generate

    @ViewBuilder
    private var generateForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let generated {
                generatedKey(generated)
            } else {
                Text(.accessGenerateIntro).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(LocalizedKey.accessGenerateButton.text) { generateKey() }
                    .keyboardShortcut(.defaultAction)
            }
            if let generationError {
                Text(verbatim: generationError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func generatedKey(_ key: GeneratedAgeKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Said before either half is shown, not after: this is the only
            // moment the private key exists anywhere the user can reach it.
            Text(.accessGenerateOnceWarning)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12))
                .fixedSize(horizontal: false, vertical: true)

            keyRow(
                title: .accessGeneratePublicKey,
                shown: key.publicKey,
                value: key.publicKey,
                target: "generated.public",
                isPrivate: false,
                key: key)

            keyRow(
                title: .accessGeneratePrivateKey,
                shown: revealPrivateKey
                    ? key.privateKey
                    : SecretRowViewLogic.maskedValue(for: key.privateKey),
                value: key.privateKey,
                target: "generated.private",
                isPrivate: true,
                key: key)

            // The public key is already in the Add tab's field by now — this
            // just takes the user there, so "generate" and "declare" are one
            // errand rather than two.
            Button(LocalizedKey.accessGenerateContinue.text) { mode = .add }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func keyRow(
        title: LocalizedKey, shown: String, value: String, target: String,
        isPrivate: Bool, key: GeneratedAgeKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(verbatim: shown)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isPrivate {
                    Button {
                        revealPrivateKey.toggle()
                    } label: {
                        Image(systemName: revealPrivateKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        revealPrivateKey
                            ? LocalizedKey.editorHideValue.text
                            : LocalizedKey.editorRevealValue.text)
                }
                // The audited clipboard path, the same one the editor uses:
                // a copied private key clears itself again after the
                // configured interval rather than sitting on the pasteboard.
                RowCopyButton(value: value, target: target, copyFeedback: copyFeedback)
                Button(LocalizedKey.accessGenerateSaveButton.text) {
                    save(value: isPrivate
                        ? GeneratedKeyFiles.privateKeyFile(key)
                        : GeneratedKeyFiles.publicKeyFile(key),
                        isPrivate: isPrivate)
                }
                .controlSize(.small)
            }
        }
    }

    private func generateKey() {
        generationError = nil
        do {
            let key = try generate()
            generated = key
            revealPrivateKey = false
            // Pre-filled straight away: the key the user just made is the one
            // they are about to declare, and retyping an `age1…` line by hand
            // is how a wrong key ends up in a config.
            recipient = key.publicKey
        } catch {
            // The engine's own sentence. It names the operation, never the
            // key — nothing generated has reached this scope on this path.
            generationError = (error as? SopsBridgeError)?.description
                ?? LocalizedKey.accessGenerateFailed.text
        }
    }

    private func save(value: String, isPrivate: Bool) {
        let panel = GeneratedKeyFiles.savePanel(
            suggesting: GeneratedKeyFiles.fileName(for: name, isPrivate: isPrivate))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let failure = GeneratedKeyFiles.write(value, to: url, isPrivate: isPrivate) {
            generationError = failure
        }
    }
}
