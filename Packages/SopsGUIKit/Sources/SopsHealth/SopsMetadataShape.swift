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
    /// none of them. Recognising *which* is what lets a caller (`EncryptedFile
    /// Metadata`, `ProjectScanner.classify`) give each its own `SopsFileFormat`
    /// without a second structural pass: `isYAMLMetadata`/the old boolean
    /// `isNonYAMLMetadata` only ever answered "is this a sops document",
    /// never "which store wrote it". As of SOPS-38 phase F2 task 3, this
    /// build reads recipients out of all three — dotenv, JSON and INI.
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

    /// JSON: a top-level `sops` key whose value is an object carrying `mac`
    /// and `version` fields *of its own* — nested inside that object, not
    /// merely present somewhere in the document. Checked with a real
    /// `JSONSerialization` parse, not a substring scan.
    ///
    /// The substring version this replaced — "does `\"mac\":` appear
    /// anywhere, does `\"version\":` appear anywhere, does `\"sops\":`
    /// appear anywhere followed by `{`" — checked three things independently
    /// and had no way to tell an object's *own* `mac`/`version` apart from
    /// sibling top-level fields of the same name. SOPS-38 phase F2 task 3
    /// review: an entirely ordinary device-inventory-shaped record —
    /// `{"mac": "00:11:22:33:44:55", "version": "1.0", "sops": {"foo":
    /// "bar"}}`, a MAC address and a schema version next to an unrelated
    /// `sops` object — satisfied all three independently and was classified
    /// as an encrypted file, the exact class of bug this type's own doc
    /// comment already names for a Swift dictionary literal and a Go map
    /// literal, just not yet closed for this one field pairing. See
    /// `SopsMetadataShapeTests.deviceInventoryJSONIsNotEncrypted` for the
    /// fixture.
    ///
    /// A parse failure — most often a truncated tail that starts mid-
    /// document and so never opens the top-level object at all — is
    /// honestly treated as "not this shape", never guessed at from whichever
    /// substrings happen to survive the cut: a document is one JSON value,
    /// and half of one does not parse. That is a real, accepted
    /// false-negative direction on its own (a huge encrypted JSON file whose
    /// metadata block sits past the tail-read budget could briefly go
    /// undetected) — mitigated the same way YAML's identical oversized case
    /// already is, not left as a silent gap:
    /// `ProjectScanner.looksLikeTruncatedSopsBlock` recognises JSON's own
    /// near-tail shape too, so `ProjectScanner.classify` re-reads a wider
    /// tail before giving up, and a still-too-large document becomes
    /// `.metadataBlockTooLarge` rather than silence. See
    /// `SopsMetadataShapeTests.truncatedJSONTailIsNotMetadata` for the
    /// decision pinned directly, and
    /// `ProjectScanUndisclosedScopeTests.oversizedJSONMetadataBlockIsNotInvisible`
    /// for the case that exercises the mitigation end to end.
    private static func isJSONMetadata(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sops = object["sops"] as? [String: Any]
        else { return false }
        return sops["mac"] != nil && sops["version"] != nil
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
