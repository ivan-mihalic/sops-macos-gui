import Foundation

/// Decides whether a decoded file tail carries metadata sops itself *wrote*,
/// as opposed to merely containing the characters a sops metadata block is
/// made of.
///
/// `ProjectScanner` finds candidates with byte-level substring searches
/// (`"\nsops:"`, `"sops_mac="`, `"\"sops\":"`, `"\n[sops]"`) because that is
/// the only thing cheap enough to run against every file in a project tree.
/// A substring is not an answer, though, and the gap between the two was
/// visible in this app's own repository:
///
/// - Two Markdown task reports quoting a `sops:` block inside a fenced code
///   example were classified as *encrypted YAML* — offered in the file list as
///   openable, decryptable secrets files. That is a wrong answer the user can
///   see and click on.
/// - Nine more files — three review diffs, four Swift/Go sources, two briefs —
///   were counted as "sops-encrypted in a format this app does not read". All
///   nine matched on ordinary code: a Swift dictionary literal
///   `["sops": tool(…)]` contains `"sops":`, and `ProjectScanner`'s own
///   `Data("sops_mac=".utf8)` contains `sops_mac=`. The sniffer was flagging
///   its own source.
///
/// Both were inherent to substring sniffing, not to any particular marker, so
/// the fix is to require *structure*. Each check below is anchored to what the
/// pinned getsops/sops v3.13.3 stores actually emit, verified by encrypting a
/// document in each format with the real `sops` binary and reading the output,
/// not by reasoning about what it probably looks like. Described in prose
/// rather than pasted in as four literal examples, because the first draft of
/// this comment did paste them — and made this file the twelfth false
/// positive on this repository, reported as sops-encrypted in a format the app
/// cannot read. Reproduced, then rewritten; the fixtures that pin the real
/// shapes live in `SopsMetadataShapeTests`, where the app does not read them:
///
/// - **YAML** — a `sops:` key at column 0, the last top-level key in the
///   document, with `lastmodified`, `mac` and `version` indented under it.
/// - **dotenv** — one `sops_`-prefixed `KEY=value` line per metadata field, at
///   column 0, `sops_mac` and `sops_version` among them.
/// - **JSON** — a `sops` key whose value is an object, carrying `mac` and
///   `version` keys of its own.
/// - **INI** — a `[sops]` section header on a line of its own, with `mac` and
///   `version` entries padded out to a common column beneath it.
///
/// The direction of the risk is deliberate and worth stating: a false
/// *negative* here is worse than a false positive, because a sops-encrypted
/// `.env` that stops being recognised becomes a plaintext-leak alarm about a
/// file that is not leaking anything. Every requirement below is therefore
/// something sops writes unconditionally — `mac` and `version` are emitted for
/// every file in every store, and the YAML `sops:` key is unconditionally the
/// document's last top-level key (the same property
/// `ProjectScanner.maxSniffedFileBytes` already relies on for the tail read to
/// work at all). Nothing here requires a field that a legitimate option, an
/// older sops, or an unusual key backend could omit.
enum SopsMetadataShape {

    /// A YAML document whose *last* top-level key is `sops:` and whose block
    /// under it carries both `mac` and `version`.
    ///
    /// "Last top-level key" is the load-bearing half. A document that merely
    /// quotes a sops block — a Markdown report, a test fixture inside a
    /// heredoc, a diff — continues at column 0 afterwards (a closing fence,
    /// the next paragraph, the next hunk). A file sops wrote does not: its
    /// serializer appends the metadata after every existing top-level item, so
    /// nothing unindented can follow it. Both Markdown false positives above
    /// fail on this alone; requiring `mac` and `version` as well means a
    /// document that ends *exactly* on a quoted partial block does not slip
    /// through either.
    static func isYAMLMetadata(_ text: String) -> Bool {
        let lines = Self.lines(of: text)
        guard let blockStart = lines.lastIndex(where: { $0 == "sops:" }) else { return false }

        var sawMAC = false
        var sawVersion = false
        for line in lines[lines.index(after: blockStart)...] {
            if line.isEmpty { continue }
            // Anything at column 0 after the block means this is not a
            // sops-written document; see the doc comment above.
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { return false }
            switch Self.yamlKey(of: line) {
            case "mac": sawMAC = true
            case "version": sawVersion = true
            default: break
            }
        }
        return sawMAC && sawVersion
    }

    /// Which non-YAML sops store, if any, wrote `text`'s metadata — `nil` for
    /// neither. Recognising *which* is what lets a caller route dotenv (this
    /// build reads its recipients — see `EncryptedFileMetadata`) differently
    /// from JSON/INI (still reported honestly as unverifiable) without a
    /// second structural pass: `isYAMLMetadata`/the old boolean
    /// `isNonYAMLMetadata` only ever answered "is this a sops document",
    /// never "which store wrote it".
    enum Kind {
        case dotenv, json, ini
    }

    /// Which non-YAML sops store, if any, wrote `text`'s metadata.
    static func nonYAMLKind(_ text: String) -> Kind? {
        let lines = Self.lines(of: text)
        if isDotenvMetadata(lines) { return .dotenv }
        if isJSONMetadata(text) { return .json }
        if isINIMetadata(lines) { return .ini }
        return nil
    }

    /// sops metadata in one of the stores this build cannot *edit* yet
    /// (JSON, INI) or could not read recipients out of before this build
    /// added dotenv support. Kept for callers that only need the boolean —
    /// `nonYAMLKind(_:) != nil` — rather than which store it was.
    static func isNonYAMLMetadata(_ text: String) -> Bool {
        Self.nonYAMLKind(text) != nil
    }

    /// dotenv: sops flattens its metadata into `sops_`-prefixed keys, each its
    /// own `KEY=value` line at column 0. Requiring column 0 — rather than the
    /// bare substring — is what stops `Data("sops_mac=".utf8)` in an indented
    /// line of Swift from matching, and requiring both keys rather than either
    /// costs nothing, because the store writes both for every file.
    private static func isDotenvMetadata(_ lines: [Substring]) -> Bool {
        var sawMAC = false
        var sawVersion = false
        for line in lines {
            if line.hasPrefix("sops_mac=") { sawMAC = true }
            if line.hasPrefix("sops_version=") { sawVersion = true }
        }
        return sawMAC && sawVersion
    }

    /// JSON: `"sops"` names an *object*, so the token after the colon is `{`.
    /// Every false positive in this repository was a dictionary or map literal
    /// in some other language — `["sops": tool(…)]` in Swift,
    /// `{"sops": sopsVersion}` in Go — where the value is an identifier or a
    /// call, never a brace. The `mac`/`version` requirement is the same
    /// belt-and-braces as the YAML case.
    ///
    /// The whitespace skipped between the colon and the brace is
    /// `Character.isWhitespace`, not an explicit `" "`/`"\t"`/`"\n"`/`"\r"`
    /// list. The explicit list had the CRLF blind spot this file's `lines(of:)`
    /// was already written to avoid: `"\r\n"` is one `Character` equal to
    /// neither `"\n"` nor `"\r"`, so a CRLF-converted JSON file with the brace
    /// on the next line stopped the skip dead and the store went unrecognised
    /// — a false *negative*, the direction this type's doc comment names as
    /// the worse one, because an unrecognised encrypted `.env`/`.json` becomes
    /// a plaintext-leak alarm about a file that is not leaking anything.
    private static func isJSONMetadata(_ text: String) -> Bool {
        guard text.contains("\"mac\":"), text.contains("\"version\":") else { return false }
        var remainder = text[...]
        while let match = remainder.range(of: "\"sops\":") {
            let afterColon = remainder[match.upperBound...].drop(while: \.isWhitespace)
            if afterColon.first == "{" { return true }
            remainder = remainder[match.upperBound...]
        }
        return false
    }

    /// INI: a `[sops]` section header on a line of its own, with `mac` and
    /// `version` entries under it. The store pads its keys out to a common
    /// column (`mac                        = ENC[…]`), so the key has to be
    /// read up to the `=` and trimmed rather than matched as `mac=`.
    private static func isINIMetadata(_ lines: [Substring]) -> Bool {
        guard let headerIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[sops]"
        }) else { return false }

        var sawMAC = false
        var sawVersion = false
        for line in lines[lines.index(after: headerIndex)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The next section header ends the sops section.
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { break }
            switch Self.iniKey(of: line) {
            case "mac": sawMAC = true
            case "version": sawVersion = true
            default: break
            }
        }
        return sawMAC && sawVersion
    }

    // MARK: - Line handling

    /// Splits on any line ending, so a document that happens to use CRLF is
    /// read the same way as one that does not. sops writes `\n`, but an editor
    /// round-trip is enough to change that, and the byte-level substring
    /// matching this confirms was insensitive to it — silently narrowing that
    /// tolerance while adding structure would be a false negative introduced
    /// by the fix rather than found by it.
    ///
    /// `whereSeparator`, not `split(separator: "\n")`: Swift treats `\r\n` as
    /// a *single* `Character` (a CRLF grapheme cluster), so splitting on the
    /// `Character` `"\n"` does not split a CRLF document at all — the whole
    /// file comes back as one line and every structural check silently fails.
    /// Caught by `SopsMetadataShapeTests.crlfIsTolerated`, which failed
    /// against the first version of this function for exactly that reason.
    ///
    /// The three-way `$0 == "\n" || $0 == "\r\n" || $0 == "\r"` predicate this
    /// replaced was correct; it is now `LineEndings.lines(of:)` so that this
    /// package has exactly one answer to "what is a line", and so the
    /// `Sources/`-wide guard against the `"\n"`-as-a-Character habit
    /// (`CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms`) has no
    /// correct-but-indistinguishable exception to carve out.
    private static func lines(of text: String) -> [Substring] {
        LineEndings.lines(of: text)
    }

    /// The key of a `key: value` YAML line, trimmed of its indentation.
    /// Returns `""` for a line with no colon, which matches nothing.
    private static func yamlKey(of line: Substring) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
    }

    /// The key of a `key = value` INI line, trimmed of its padding.
    private static func iniKey(of line: Substring) -> String {
        guard let equals = line.firstIndex(of: "=") else { return "" }
        return line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
    }
}
