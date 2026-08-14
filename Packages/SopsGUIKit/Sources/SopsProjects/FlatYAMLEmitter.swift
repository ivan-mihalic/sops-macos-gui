import Foundation

/// Serialises `.env` entries into a flat YAML map that sops can encrypt.
///
/// This is the only place in the whole "create a secret file" feature where a
/// secret value is hand-serialised into text rather than passed through
/// sops's own store (see ADR 0002's rule, applied here to the one seam that
/// has to exist because a `.env` file has no YAML reader of its own to
/// borrow). Every other path in this feature moves a value byte-for-byte.
/// Here, a mistake in the escape table below does not crash and does not fail
/// a test that only looks at "does it run" — it writes a corrupted secret
/// that decrypts to the *wrong* value, silently, and nothing downstream
/// notices. That is why `FlatYAMLEmitterTests` proves correctness with a
/// round trip through the real sops bridge (`encryptYAML` → `decryptToRows`)
/// rather than a comparison against expected YAML text: a text comparison
/// only proves this file agrees with itself, not that sops reads the result
/// back the way it was written.
///
/// ## Why values are always double-quoted, never conditionally
///
/// The emitted YAML is not a document a human will ever read or maintain —
/// sops re-emits it in its own style (four-space indent, its own quoting
/// decisions) the moment it encrypts it. "Quote only when the value needs
/// it" would save nothing a reader benefits from and would add a second path
/// through this code — a plain-scalar path — that has to independently get
/// every YAML plain-scalar trap right (leading `-`, a value that parses as a
/// bool or number, a leading `?`, and more). One quoting rule, always taken,
/// is the smaller surface for a bug to hide in.
///
/// ## Why keys are the opposite: an allowlist, not "quote when needed"
///
/// `DotEnvParser` (Task 3) accepts a wider key charset than YAML's plain
/// scalar grammar tolerates — `a.b-c`, `9KEY`, `MY-KEY`, even `-X` are all
/// valid `.env` keys. `-X` as a bare YAML plain scalar is a real trap: a
/// leading `-` followed by a space would open a block sequence, and even
/// without the space it is exactly the shape a "does this look safe" heuristic
/// would wave through. So the rule here is inverted from the value rule: a
/// key is only ever left unquoted when it matches the narrow, safe pattern
/// `[A-Za-z_][A-Za-z0-9_]*`; everything else — including every shape above —
/// gets the same double-quoting and escaping as a value.
public enum FlatYAMLEmitter {

    /// A flat YAML map of `entries`, one `key: "value"` pair per line, in
    /// entry order. Never a nested structure, never a comment: `.env` has no
    /// concept of either, so nothing here would ever have content to put in
    /// one.
    ///
    /// `entries` is normally `ParsedDotEnv.entries` (Task 3), already
    /// deduplicated (last value wins) and in first-occurrence order — this
    /// function does not deduplicate again and trusts its input.
    ///
    /// An empty list still has to produce a valid YAML document — an empty
    /// map, `"{}\n"` — because Task 6 hands this straight to
    /// `SopsBridge.encryptYAML`, which expects a document, not an empty
    /// string.
    public static func emit(_ entries: [DotEnvEntry]) -> String {
        guard !entries.isEmpty else { return "{}\n" }
        // Each line carries its own trailing newline and the pieces are
        // concatenated with no separator, rather than joining with `"\n"`
        // and appending a final one — a bare `"\n"` separator literal is the
        // one shape `NewlineBlindnessScanner` (`CRLFToleranceTests`) cannot
        // tell apart from a newline-blind *read*, even though this is a
        // write. `joined(separator:)` itself is sanctioned there; a second,
        // standalone `"\n"` literal next to it is not.
        return entries.map { "\(quotedKey($0.key)): \(quotedValue($0.value))\n" }
            .joined()
    }

    // MARK: - Keys

    /// A key stays a plain scalar only when it matches
    /// `[A-Za-z_][A-Za-z0-9_]*` — the one shape that is always safe as a bare
    /// YAML map key regardless of what a YAML parser does with leading `-`,
    /// digits, or `.`. Anything else is quoted and escaped exactly like a
    /// value.
    static func quotedKey(_ key: String) -> String {
        isPlainScalarSafe(key) ? key : quotedValue(key)
    }

    private static func isPlainScalarSafe(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first == "_" else {
            return false
        }
        for c in key.dropFirst() {
            guard c.isASCII, c.isLetter || c.isNumber || c == "_" else { return false }
        }
        return true
    }

    // MARK: - Values

    /// Wraps `value` in double quotes, escaping every character a
    /// double-quoted YAML scalar requires escaping. Meant to be the complete
    /// table:
    ///
    /// | Character | Escape |
    /// |---|---|
    /// | `\` | `\\` |
    /// | `"` | `\"` |
    /// | LF | `\n` |
    /// | CR | `\r` |
    /// | TAB | `\t` |
    /// | other C0 (`U+0000`–`U+001F`), `U+007F`, and `U+0085` (NEL) | `\xNN` |
    /// | everything else, including emoji | written literally |
    ///
    /// `U+0085` (NEL) used to fall through to the `default:` arm below and be
    /// written literally — but sops's YAML layer reads a literal NEL back
    /// differently than it was written, so a value containing it did not
    /// round-trip intact. It was caught, not silent —
    /// `SecretFileCreator.verifyRoundTrip` refused the write rather than
    /// producing a corrupted file — but a value containing NEL simply
    /// couldn't be created at all. Fixed by adding `U+0085` to this table;
    /// proved by `FlatYAMLEmitterTests.lineBreakLookalikesSurviveRoundTrip`.
    ///
    /// `U+2028` (LINE SEPARATOR) and `U+2029` (PARAGRAPH SEPARATOR) were
    /// probed alongside NEL — same test — and round-trip fine unescaped, so
    /// they are deliberately *not* in this table; the defect was specific to
    /// NEL, not "any Unicode line-break character". The same table governs
    /// `quotedKey` too (via `quotedValue` for any key that is not
    /// plain-scalar-safe), so a key containing NEL is escaped the same way a
    /// value is.
    static func quotedValue(_ value: String) -> String {
        var result = "\""
        result.reserveCapacity(value.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\u{0A}":
                result += "\\n"
            case "\u{0D}":
                result += "\\r"
            case "\u{09}":
                result += "\\t"
            case "\u{00}"..."\u{1F}", "\u{7F}", "\u{85}":
                result += String(format: "\\x%02X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
