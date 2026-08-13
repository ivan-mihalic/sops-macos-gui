import SopsProjects
import SwiftUI

/// What a `.env` import would actually produce — every key and value it
/// would create, and every line it could not read — shown before anything
/// is written.
///
/// ## Why this exists at all
///
/// The app's whole claim, for a `.env`-sourced file, is that the encrypted
/// document can replace the `.env` the user's runtime reads today. The user
/// is entitled to see exactly which keys and values that means before
/// confirming it, and just as importantly, which lines `DotEnvParser` could
/// not read and why a silent import would be the app asking to be trusted
/// with a file full of secrets. Neither half is optional: showing only the
/// entries would hide the fact that `KEY = "unterminated` never becomes
/// anything, and a user who never sees that line has no way to notice a
/// secret went missing.
///
/// ## This is the first new plaintext surface since the editor
///
/// `AccessibilityTreeTests` exists because a masked value once leaked into
/// the accessibility tree from `SecretEditorView`, and this view is the same
/// shape of hazard one screen over. Three rules follow from that, and this
/// type keeps all three:
///
/// - **Masked by default, with per-row reveal** — the identical mechanism
///   `SecretEditorView` uses, not an invented variant: masking goes through
///   `SecretRowViewLogic.maskedValue(for:)`, the same fixed-width mask (see
///   that function's own doc comment for why a `SecureField`-style
///   per-character mask would leak a secret's length through the
///   accessibility tree even while hiding its content), and the reveal
///   control reuses `LocalizedKey.editorRevealValue`/`.editorHideValue`
///   rather than wording its own.
/// - **A skipped line is masked too.** `DotEnvSkippedLine.text` is the raw
///   line, unmasked, by that type's own design — its doc comment states
///   plainly that masking is the UI's job, precisely because a line the
///   parser could not read (`KEY = "value` with an unterminated quote, most
///   commonly) is exactly as likely to hold a secret as one it could. This
///   view is that UI, and it masks skipped text through the same function as
///   an accepted entry's value.
/// - **A suspicion is a sentence, not an icon.** Every `DotEnvSuspicion`
///   parsed without error but worth a second look — see
///   `dotEnvSuspicionSentence(for:entryLine:)` for what each of the five
///   kinds actually says. None of them changes what is in `parsed.entries`;
///   see `ParsedDotEnv`'s own doc comment. Rendering only a warning triangle
///   would say nothing actionable, and `.emptyValue` in particular is not a
///   parse problem at all — it means sops will leave that value readable —
///   which a bare icon could not convey.
///
/// ## What this view does not do
///
/// No parsing, and no file I/O. It renders a `ParsedDotEnv` it is handed —
/// building one is `DotEnvParser`'s job, and choosing a file is a later
/// task's. Suspicions are annotations only: this view never filters,
/// reorders, or otherwise treats `parsed.entries` differently because of
/// them.
public struct DotEnvPreviewTable: View {
    private let parsed: ParsedDotEnv

    @State private var revealed: Set<RowID>

    /// One row whose value can be revealed: an accepted entry, keyed by its
    /// key (unique in `parsed.entries` — `DotEnvParser` already resolved any
    /// duplicate before this view ever sees it), or a skipped line, keyed by
    /// its 1-based line number (unique per physical line).
    public enum RowID: Hashable, Sendable {
        case entry(key: String)
        case skipped(line: Int)
    }

    /// - Parameters:
    ///   - parsed: what a `.env` import would produce, already parsed. This
    ///     view neither parses nor re-parses anything.
    ///   - initiallyRevealedRowIDs: which rows start revealed. The app
    ///     leaves this empty; it exists for the same reason
    ///     `SecretEditorView.initiallyRevealedRowIDs` does — the headless
    ///     snapshot tool and this module's accessibility-tree tests cannot
    ///     click a row to reveal it, so without a seam there would be no way
    ///     to render, or test, a revealed row at all.
    public init(parsed: ParsedDotEnv, initiallyRevealedRowIDs: Set<RowID> = []) {
        self.parsed = parsed
        self._revealed = State(initialValue: initiallyRevealedRowIDs)
    }

    public var body: some View {
        List {
            if !parsed.entries.isEmpty {
                Section(LocalizedKey.dotEnvPreviewEntriesTitle.text) {
                    ForEach(parsed.entries, id: \.key) { entry in
                        EntryRow(
                            entry: entry,
                            suspicions: suspicions(forKey: entry.key),
                            isRevealed: revealed.contains(.entry(key: entry.key)),
                            onToggleReveal: { toggle(.entry(key: entry.key)) })
                    }
                }
            }

            if !parsed.skipped.isEmpty {
                Section(LocalizedKey.dotEnvPreviewSkippedTitle.text) {
                    // A row, not the section `header:` — a `List` section
                    // header clips its content to one line with an ellipsis
                    // regardless of `.fixedSize` (measured against an early
                    // draft of `dotenv-preview.png`), and this sentence is
                    // the only place a user is told *why* the lines below
                    // are masked and unreadable, so silently truncating it
                    // would defeat the point of writing it.
                    Text(LocalizedKey.dotEnvPreviewSkippedExplanation.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(parsed.skipped, id: \.line) { line in
                        SkippedLineRow(
                            skipped: line,
                            isRevealed: revealed.contains(.skipped(line: line.line)),
                            onToggleReveal: { toggle(.skipped(line: line.line)) })
                    }
                }
            }

            if parsed.entries.isEmpty, parsed.skipped.isEmpty {
                Text(.dotEnvPreviewEmpty)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollOverflowFade()
    }

    private func suspicions(forKey key: String) -> [DotEnvSuspicion] {
        parsed.suspicions.filter { $0.key == key }
    }

    private func toggle(_ id: RowID) {
        if revealed.contains(id) {
            revealed.remove(id)
        } else {
            revealed.insert(id)
        }
    }
}

// MARK: - Rows

/// One accepted `KEY=value` assignment: the key (never masked — it is not a
/// secret), the value (masked by default), and every suspicion raised
/// against this key, each with its own sentence underneath.
private struct EntryRow: View {
    let entry: DotEnvEntry
    let suspicions: [DotEnvSuspicion]
    let isRevealed: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 12)

                // Deliberately a plain `Text`, never the real value passed
                // to any accessibility API while masked — see
                // `SecretRowViewLogic.maskedValue(for:)`'s own doc comment
                // for why a per-character mask (a `SecureField`) would leak
                // the value's length even while hiding its content. This
                // view has no field to type into, so there is no editing
                // affordance to preserve the way `SecretEditorView`'s
                // `.disabled` `TextField` does — only the same masking rule.
                //
                // Branched, not a `.textSelection(isRevealed ? .enabled :
                // .disabled)` ternary: `.enabled`/`.disabled` are different
                // opaque `TextSelectability` types, and the ternary's two
                // branches cannot unify to one.
                Group {
                    if isRevealed {
                        Text(entry.value).textSelection(.enabled)
                    } else {
                        Text(SecretRowViewLogic.maskedValue(for: entry.value))
                    }
                }
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isRevealed ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

                Button(action: onToggleReveal) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    isRevealed ? LocalizedKey.editorHideValue.text : LocalizedKey.editorRevealValue.text)
            }

            ForEach(Array(suspicions.enumerated()), id: \.offset) { _, suspicion in
                SuspicionSentence(text: dotEnvSuspicionSentence(for: suspicion, entryLine: entry.line))
            }
        }
        .padding(.vertical, 4)
    }
}

/// One line `DotEnvParser` could not read as a `KEY=value` assignment. Its
/// raw text is masked exactly like an accepted entry's value — see this
/// file's header comment, "A skipped line is masked too".
private struct SkippedLineRow: View {
    let skipped: DotEnvSkippedLine
    let isRevealed: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: LocalizedKey.dotEnvPreviewSkippedLineLabel.text, skipped.line))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)

            Group {
                if isRevealed {
                    Text(skipped.text).textSelection(.enabled)
                } else {
                    Text(SecretRowViewLogic.maskedValue(for: skipped.text))
                }
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(isRevealed ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 12)

            Button(action: onToggleReveal) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isRevealed ? LocalizedKey.editorHideValue.text : LocalizedKey.editorRevealValue.text)
        }
        .padding(.vertical, 2)
    }
}

/// One suspicion's explanatory sentence, rendered next to the row it
/// concerns rather than folded into a tooltip a screen reader would have to
/// be hovered to find. The leading glyph is decorative only — the sentence
/// itself carries the whole meaning, so the glyph is hidden from
/// accessibility clients rather than announced as a second, wordless node.
private struct SuspicionSentence: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every user-facing sentence for a `DotEnvSuspicion.Kind` — see this file's
/// header comment, "A suspicion is a sentence, not an icon", and each
/// `LocalizedKey` case's own doc comment for what the sentence has to say.
///
/// `entryLine` is `DotEnvEntry.line` for the entry this suspicion was raised
/// against — needed only by `.duplicateKey`, whose sentence names which
/// line's value actually won. Free rather than a method, so it is directly
/// testable without constructing a view.
func dotEnvSuspicionSentence(for suspicion: DotEnvSuspicion, entryLine: Int) -> String {
    switch suspicion.kind {
    case .strayOpeningQuote:
        return LocalizedKey.dotEnvPreviewSuspicionStrayOpeningQuote.text
    case .notAPosixName:
        return LocalizedKey.dotEnvPreviewSuspicionNotAPosixName.text
    case .looksInterpolated:
        return LocalizedKey.dotEnvPreviewSuspicionLooksInterpolated.text
    case .emptyValue:
        return LocalizedKey.dotEnvPreviewSuspicionEmptyValue.text
    case .duplicateKey(let supersededLines):
        let earlierLines = supersededLines.map(String.init).joined(separator: ", ")
        return String(
            format: LocalizedKey.dotEnvPreviewSuspicionDuplicateKey.text, entryLine, earlierLines)
    }
}
