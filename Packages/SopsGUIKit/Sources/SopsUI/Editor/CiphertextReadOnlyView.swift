import SopsProjects
import SwiftUI

/// What `SecretEditorView` shows for `LoadState.readOnlyCiphertext` — SOPS-38
/// phase F3. Reached whenever the bridge's own decrypt attempt classified the
/// failure as "someone else's key", never for a genuinely damaged file (that
/// stays `.failed`; see `LoadState.readOnlyCiphertext`'s own doc comment).
///
/// ## What this view must never do
/// There is no path from here back to `SecretDocumentViewModel.decrypt`,
/// `.save()`, `.addRow`, `.removeRow` or `.updateRecipients` — the document
/// was never decrypted, so there is nothing to edit and nothing this view
/// could apply. Every value shown is either the raw on-disk bytes
/// (`rawCiphertext`) or metadata read without an identity
/// (`recipients`, via `SopsBridge.recipients(in:format:)` — see
/// `SecretDocumentViewModel.load()`). Regaining the ability to edit this file
/// means importing a different key and reopening it, not anything this view
/// offers.
///
/// ## Why the raw ciphertext is shown at all
/// `rawCiphertext` is exactly what is on disk — never decrypted, never
/// re-derived. Showing it (monospace, selectable, scrollable) lets a user
/// copy the file's contents to send to someone who *can* decrypt it, or to
/// paste into a support request, without this app pretending the file cannot
/// be read at all. There is nothing secret in it: `sops` encrypts every
/// value, so the on-disk text is ciphertext plus structural metadata, the
/// same thing a `cat` of the file on disk would show.
///
/// ## Recipients: labelled where the registry knows them
/// `recipients` names age public keys straight from the file's own metadata
/// — never a claim this app decrypted anything to learn who they are.
/// `RecipientRegistry` is consulted (via `projectURL`, when this file belongs
/// to one) purely for the human-friendly label a project may have recorded
/// for a key; a recipient the registry has no record for is shown as its raw
/// `age1…` string, the same "label, or raw key" idiom `RecipientAccessRow`
/// already uses. `recipients == []` is `LoadState.readOnlyCiphertext`'s own
/// "unknown, not a claim" contract (an unreadable or unparseable metadata
/// block) — shown as a stated fact, never as an empty list that could be
/// misread as "no recipients at all".
struct CiphertextReadOnlyView: View {
    let reason: String
    let rawCiphertext: String
    let recipients: [String]
    /// The project this file belongs to, purely for `RecipientRegistry`
    /// labels. `nil` — a file opened outside a project, or an editor host
    /// that supplies no `RecipientAccessContext` at all (most of the
    /// snapshot catalog, the older editor tests) — falls back to every
    /// recipient's raw public key, exactly as `RecipientAccessRow` does for
    /// an unregistered key.
    let projectURL: URL?

    init(reason: String, rawCiphertext: String, recipients: [String], projectURL: URL? = nil) {
        self.reason = reason
        self.rawCiphertext = rawCiphertext
        self.recipients = recipients
        self.projectURL = projectURL
    }

    /// Read fresh on every render rather than cached: this is a cheap local
    /// JSON read (`RecipientRegistry.loadOrQuarantine`, no bridge call, no
    /// cryptography), and the same up-to-date-over-cached tradeoff
    /// `FileListModel.resolveConfigState` already makes for its own
    /// per-render probe read.
    private var registryRecords: [RecipientRecord] {
        guard let projectURL else { return [] }
        return RecipientRegistry.loadOrQuarantine(in: projectURL).records
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                recipientsSection
                Divider()
                ciphertextSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollOverflowFade()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(.editorReadOnlyCiphertextTitle, systemImage: "lock.doc.fill")
                .font(.headline)
            // The engine's own diagnostic text, verbatim — the exact same
            // wrong-key sentence `.failed` used to carry
            // (`editorLoadFailedWrongKey`), just under a different `LoadState`
            // case. Never a `LocalizedKey`: see `SecretEditorView`'s `.failed`
            // branch for why dynamic, bridge-produced text is rendered as
            // plain secondary text rather than resolved through the catalog.
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var recipientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.editorReadOnlyCiphertextRecipientsHeading)
                .font(.subheadline.weight(.semibold))
            if recipients.isEmpty {
                Text(.editorReadOnlyCiphertextRecipientsUnknown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let records = registryRecords
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recipients, id: \.self) { recipient in
                        CiphertextRecipientRow(
                            ageRecipient: recipient,
                            record: records.first { $0.ageRecipient == recipient })
                    }
                }
            }
        }
    }

    private var ciphertextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.editorReadOnlyCiphertextContentsHeading)
                .font(.subheadline.weight(.semibold))
            // Raw, on-disk bytes. Selectable so they can be copied — that is
            // the only affordance this view offers over the text — but never
            // editable: this is a `Text`, not a `TextEditor`, and there is no
            // control anywhere in this view that writes anything back.
            Text(rawCiphertext)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One recipient row: label (or raw public key, when the registry has no
/// record for it), the public key beneath a label when one exists, the
/// registry's note and kind — the read-only counterpart of
/// `RecipientAccessRow` (`RecipientAccessView.swift`), with no toggle, no
/// naming control and no staged-change badge, because this view offers no
/// action on any of it. Shares `RecipientRowContent`/`RecipientKindBadge`
/// with that row rather than duplicating them, for the reason those types'
/// own doc comments give: the two panels' (now three panels') wording must
/// not drift, and it already drifted once in this exact seam.
private struct CiphertextRecipientRow: View {
    let ageRecipient: String
    let record: RecipientRecord?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record?.label ?? ageRecipient)
                    .font(record?.label == nil ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if record?.label != nil {
                    Text(ageRecipient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                RecipientRowContent.note(record?.note)
            }

            RecipientKindBadge(kind: record?.kind)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
