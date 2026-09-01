import Foundation

/// Serialises `.env` entries into the flat `KEY=value` text sops's own dotenv
/// store reads, for a destination whose name says the file itself should be
/// a dotenv document (task SOPS-38) — the sibling of `FlatYAMLEmitter`, which
/// keeps doing the identical job for a `.yaml`-named destination.
///
/// ## Why a second emitter, not one that branches internally
///
/// `FlatYAMLEmitter` builds *YAML* — a quoted `key: "value"` map entry, with
/// its own escaping rules for what makes a YAML double-quoted scalar safe.
/// This type builds *dotenv* — a bare `KEY=value` line, with a different and
/// much narrower escaping need (see below), read back by a different store
/// (`stores/dotenv.Store.LoadPlainFile`, not the YAML store). The two
/// grammars do not share an escaping table, so a single function branching
/// on format would just be this file and `FlatYAMLEmitter` concatenated
/// behind an `if` — no code saved, and a future edit to one escaping rule
/// risks leaking into the other's `case`.
///
/// ## Why the escaping table is exactly one entry
///
/// Measured directly against the pinned getsops/sops v3.13.3 source this app
/// embeds (`stores/dotenv/store.go`):
///
/// - `LoadPlainFile` splits the whole input on literal `"\n"` (a real LF
///   byte) before looking at anything else. A value containing a real LF
///   would therefore split into a second "line" with no `=` in it — either a
///   spurious `invalid dotenv input line` refusal, or worse, content silently
///   reattached to the *next* key. `EmitPlainFile` (sops's own writer for
///   this format) avoids exactly this by writing every value through
///   `strings.ReplaceAll(value, "\n", "\\n")` — a real LF becomes the two
///   literal characters `\` `n` — and `LoadPlainFile` reverses it on the way
///   back in (`strings.Replace(value, "\\n", "\n", -1)`). This type mirrors
///   that one substitution, in that one direction, for the same reason: it
///   is not this app's own escaping invention, it is the format's own
///   defined round trip, and diverging from it would produce a document
///   sops's own store could not read back the way it was written (ADR 0002).
/// - Nothing else in `LoadPlainFile` treats any other byte specially inside
///   a value: `pos := bytes.Index(line, []byte("="))` takes the *first* `=`
///   as the separator and everything after it — quote characters, `#`,
///   another `=`, a raw backslash not followed by `n` — is read back
///   verbatim as part of the value. So nothing else needs escaping, and
///   adding an escape this store's own reader does not expect would corrupt
///   the round trip rather than protect it.
///
/// `\r` (CR) is deliberately not escaped for the identical reason: the store
/// splits only on LF, so a lone CR sitting inside a value is neither a line
/// boundary nor otherwise special to it, and it survives untouched in both
/// directions — verified by `DotEnvEmitterTests`.
///
/// ## Keys are never escaped
///
/// Every `DotEnvEntry.key` this type is ever handed already passed
/// `DotEnvParser`'s own key grammar, `[\w.-]+` (ASCII word characters, `.`,
/// `-`) — see `DotEnvParser.isKeyChar`. That charset cannot contain `=`, a
/// newline, or a leading `#`, so it can never collide with `LoadPlainFile`'s
/// own `=`-splitting or comment detection. Unlike `FlatYAMLEmitter.quotedKey`,
/// which has to defend a much wider dotenv key charset against YAML's own
/// plain-scalar traps, there is no equivalent trap here for this type to
/// guard against.
public enum DotEnvEmitter {

    /// `entries`, one `KEY=value` line per entry, in entry order — the same
    /// contract `FlatYAMLEmitter.emit` keeps for its own callers: this
    /// function does not deduplicate or reorder, and trusts
    /// `ParsedDotEnv.entries` (already deduplicated, last value wins) as its
    /// input.
    ///
    /// An empty list produces `""`, not a sentinel document the way
    /// `FlatYAMLEmitter.emit([])` produces `"{}\n"` for YAML. Dotenv has no
    /// YAML-shaped notion of "empty but valid" to spell — measured directly
    /// against the real bridge (`SopsBridgeDotenvTests
    /// .emptyDotenvDocumentIsCreatedAndReadsBackEmpty`): `LoadPlainFile("")`
    /// splits the empty input into one empty line, which it simply skips,
    /// leaving a tree with no items and no error. `""` is already a
    /// legitimate, minimal, empty dotenv document on its own terms — there is
    /// nothing to invent here the way `{}\n` had to be invented for YAML.
    public static func emit(_ entries: [DotEnvEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        return entries.map { "\($0.key)=\(escapedValue($0.value))\n" }
            .joined()
    }

    /// The one substitution this format's own store round-trips through —
    /// see this type's doc comment for the measured reason it is exactly
    /// this one substitution and no others.
    ///
    /// `"\u{0A}"`, not a bare `"\n"` literal: this package's own
    /// `CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms` bans a bare
    /// line-ending literal anywhere outside `joined(separator:)`, precisely
    /// because Swift's `Character` is a grapheme cluster and `"\r\n"` is one
    /// of them — the identical reason `FlatYAMLEmitter.quotedValue` matches
    /// LF via `case "\u{0A}":` rather than `case "\n":`. This is a
    /// **write**, not a newline-blind read: it is not scanning `value` for
    /// where its lines are, only substituting the one byte the dotenv
    /// store's own `\n` escape stands for, so there is no CRLF hazard to
    /// guard against here either way — the replacement is correct for a
    /// real LF and leaves a real CR (part of a CRLF pair or standing alone)
    /// untouched, exactly as intended (see this type's doc comment).
    static func escapedValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{0A}", with: "\\n")
    }
}
