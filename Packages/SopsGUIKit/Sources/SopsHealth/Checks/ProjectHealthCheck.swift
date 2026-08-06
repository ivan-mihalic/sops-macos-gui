import Foundation

public struct InspectedProject: Equatable, Sendable {
    public let name: String
    public let rootPath: String

    public init(name: String, rootPath: String) {
        self.name = name
        self.rootPath = rootPath
    }
}

public protocol ProjectSourceProviding: Sendable {
    var projects: [InspectedProject] { get }
}

/// PROPOSAL.md §6 D.
///
/// Honesty constraint: this app holds only public keys. It can confirm that a
/// public key *appears in a file's recipient list* — that is a fact it can
/// read straight from the file. It cannot confirm that the holder of that key
/// can actually decrypt the file, because that would need their private key,
/// which this app never has. Every user-facing string this check produces
/// must preserve that distinction: "is encrypted to" / "is not in the key
/// list", never "can decrypt" / "cannot decrypt".
///
/// Never-log constraint: the plaintext-leak finding below reports that a file
/// such as `.env` exists and is not gitignored. It names the file so the user
/// knows what to fix. It must never read or quote the file's contents — not a
/// value, not a fragment, not a preview line — because a finding is exactly
/// the kind of text that gets screenshotted or captured in a log.
public struct ProjectHealthCheck: HealthCheck {
    public let id = "project-health"
    public let category = HealthCategory.projects

    /// Plaintext files that commonly hold secrets and must not be committed.
    private static let plaintextSecretNames = [".env", ".env.local", ".env.production"]

    private let source: any ProjectSourceProviding

    public init(source: any ProjectSourceProviding) {
        self.source = source
    }

    public func run() async -> [HealthFinding] {
        let projects = source.projects
        guard !projects.isEmpty else {
            return [HealthFinding(
                id: "project.none", title: "Projects",
                status: .skipped(reason: "No projects have been added yet."),
                detail: "Add a project to have its .sops.yaml and encrypted files checked.")]
        }

        // Finding ids are derived from the project name (`project.<name>.*`).
        // Two projects sharing a display name would otherwise collide and
        // silently overwrite each other's findings in the report, so later
        // duplicates get a numeric suffix baked into the *id* only — the
        // title the user sees still shows their own name unchanged.
        var seenNames: [String: Int] = [:]
        return projects.flatMap { project -> [HealthFinding] in
            let occurrence = seenNames[project.name, default: 0]
            seenNames[project.name] = occurrence + 1
            let slug = occurrence == 0 ? project.name : "\(project.name)-\(occurrence + 1)"
            return findings(for: project, idSlug: slug)
        }
    }

    private func findings(for project: InspectedProject, idSlug: String) -> [HealthFinding] {
        let root = URL(fileURLWithPath: project.rootPath)
        let configURL = root.appendingPathComponent(".sops.yaml")

        guard let configText = try? String(contentsOf: configURL, encoding: .utf8) else {
            return [HealthFinding(
                id: "project.\(idSlug).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .warning,
                detail: "No .sops.yaml in \(project.rootPath). Without it, sops has no rules for which keys to encrypt new files to.",
                remediation: Remediation(
                    explanation: "Create one from the .sops.yaml wizard in this app."))]
        }

        guard let config = SopsConfig(parsing: configText) else {
            return [HealthFinding(
                id: "project.\(idSlug).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .problem,
                detail: "The .sops.yaml in \(project.rootPath) could not be parsed, so neither this app nor the sops CLI can apply its rules.",
                remediation: Remediation(
                    explanation: "Fix the YAML syntax, then re-run this check."))]
        }

        return [
            HealthFinding(id: "project.\(idSlug).sops-yaml",
                          title: "\(project.name): .sops.yaml", status: .ok,
                          detail: "\(config.creationRules.count) creation rule(s) found and understood."),
            recipientFinding(for: project, idSlug: idSlug, root: root, config: config),
            gitignoreFinding(for: project, idSlug: idSlug, root: root),
        ]
    }

    /// Human-readable label for a `.sops.yaml`/file-metadata backend key
    /// name. Both spellings exist because the config key and the file's own
    /// metadata key don't always match (`azure_keyvault` in `.sops.yaml` vs.
    /// `azure_kv` in the file; `hc_vault_transit_uri` vs. `hc_vault`) — see
    /// the doc comments on `CreationRule.nonAgeBackends` and
    /// `SopsConfig.nonAgeBackends(inEncryptedFile:)`.
    private static func backendLabel(_ key: String) -> String {
        switch key {
        case "pgp": return "PGP"
        case "kms": return "AWS KMS"
        case "gcp_kms": return "GCP KMS"
        case "hckms": return "HC Vault KMS"
        case "azure_keyvault", "azure_kv": return "Azure Key Vault"
        case "hc_vault_transit_uri", "hc_vault": return "HashiCorp Vault"
        case "key_groups": return "a key group"
        default: return key
        }
    }

    /// Compares each encrypted file's actual key list against the rule that
    /// governs it. This is a comparison of two lists of public keys read from
    /// disk — see the type-level doc comment for what it does and does not
    /// prove about decryption.
    ///
    /// Age is not the only backend sops supports. A rule can declare `pgp`,
    /// `kms`, and the rest alongside or instead of `age`, and a file's own
    /// metadata is the ground truth for what actually protects it, which can
    /// drift from what the rule declares. This app only ever holds age keys,
    /// so neither signal can be turned into a recipient comparison — surfacing
    /// them as a silent `.ok` (matching two empty sets, as if nothing were
    /// there to check) would be confidently telling the user this is fine
    /// when it was never evaluated. Both signals are tracked separately and
    /// downgrade the result to `.unknown` — never left to fall through to
    /// `.ok` — unless a genuine age-recipient mismatch is also found, which
    /// remains `.problem` regardless.
    private func recipientFinding(for project: InspectedProject, idSlug: String, root: URL,
                                  config: SopsConfig) -> HealthFinding {
        var mismatches: [String] = []
        var sawStaleRecipient = false
        var unverifiable: [String] = []

        // A rule can declare a non-age backend without any file currently
        // using it (e.g. added for future use). Surface that up front, per
        // rule, independent of which files happen to exist right now.
        for rule in config.creationRules where !rule.nonAgeBackends.isEmpty {
            let pattern = rule.pathRegex.map { "\"\($0)\"" } ?? "every file (it has no path_regex)"
            let backends = rule.nonAgeBackends.map(Self.backendLabel).joined(separator: ", ")
            unverifiable.append("The rule matching \(pattern) also allows \(backends), which this app cannot read — it only understands age recipients.")
        }

        for sniffed in encryptedFiles(under: root) {
            let relative = sniffed.url.path.hasPrefix(root.path + "/")
                ? String(sniffed.url.path.dropFirst(root.path.count + 1))
                : sniffed.url.path
            guard let rule = config.rule(matching: relative) else { continue }
            let text = sniffed.tail

            // Ground truth from the file itself: what actually protects it
            // right now, regardless of what the rule declares.
            let fileBackends = SopsConfig.nonAgeBackends(inEncryptedFile: text)
            if !fileBackends.isEmpty {
                let backends = fileBackends.map(Self.backendLabel).joined(separator: ", ")
                unverifiable.append("\(relative) is protected, at least in part, by \(backends), which this app cannot read — it only understands age recipients.")
            }

            let actual = Set(SopsConfig.recipients(inEncryptedFile: text))
            let expected = Set(rule.ageRecipients)

            for extra in actual.subtracting(expected).sorted() {
                mismatches.append("\(relative) is encrypted to \(extra), which is not in the key list .sops.yaml declares for it.")
                sawStaleRecipient = true
            }
            for missing in expected.subtracting(actual).sorted() {
                mismatches.append("\(relative) does not list \(missing) among its recipients, but .sops.yaml declares it for this file.")
            }
        }

        if !mismatches.isEmpty {
            // A key that was removed from .sops.yaml but still appears in a
            // file's recipient list already saw the plaintext once; removing
            // the entry from the config does not retract that. The
            // remediation says so explicitly, using "rotate" rather than
            // implying re-encryption alone fixes it.
            let rotateNote = sawStaleRecipient
                ? " If a recipient was removed on purpose, also rotate the secret values themselves — that key's holder already had a chance to see the old plaintext, and re-wrapping the file does not undo that."
                : ""
            var detail = mismatches.joined(separator: "\n")
            if !unverifiable.isEmpty {
                detail += "\n\nThis app also could not fully check:\n" + unverifiable.joined(separator: "\n")
            }
            return HealthFinding(
                id: "project.\(idSlug).stale-recipients",
                title: "\(project.name): recipients", status: .problem,
                detail: detail,
                remediation: Remediation(
                    explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares." + rotateNote,
                    command: "sops updatekeys <file>"))
        }

        guard unverifiable.isEmpty else {
            return HealthFinding(
                id: "project.\(idSlug).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: "Some rules or files use a key backend other than age, which this app cannot read."),
                detail: "This app checked every age recipient it could read and found no mismatch there, but could not fully verify:\n"
                    + unverifiable.joined(separator: "\n"),
                remediation: Remediation(
                    explanation: "Verify these recipients with the tooling for that backend — for example `gpg --list-keys` for PGP, or your cloud provider's console for KMS/Key Vault/Vault. This app only manages age keys."))
        }

        return HealthFinding(
            id: "project.\(idSlug).stale-recipients",
            title: "\(project.name): recipients", status: .ok,
            detail: "Checked every encrypted file's recipient key list against the rule that governs it — every file's key list matches.")
    }

    /// Reports only that a plaintext secret file exists and is not
    /// gitignored — never its contents. See the type-level doc comment.
    private func gitignoreFinding(for project: InspectedProject, idSlug: String,
                                  root: URL) -> HealthFinding {
        let ignored = (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8))
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []

        let exposed = Self.plaintextSecretNames.filter { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
                && !ignored.contains(name)
        }

        guard !exposed.isEmpty else {
            return HealthFinding(
                id: "project.\(idSlug).gitignore",
                title: "\(project.name): plaintext files", status: .ok,
                detail: "No unignored plaintext secret files found.")
        }

        return HealthFinding(
            id: "project.\(idSlug).gitignore",
            title: "\(project.name): plaintext files", status: .problem,
            detail: "These plaintext files exist in \(project.rootPath) and are not gitignored: \(exposed.joined(separator: ", ")). Committing one publishes its contents to everyone with access to the repository's history, permanently.",
            remediation: Remediation(
                explanation: "Add them to .gitignore, then move their secrets into a file this app encrypts. If one has already been committed, rotating the values is the only real fix — removing the file from a future commit does not remove it from history.",
                command: exposed.map { "echo '\($0)' >> .gitignore" }.joined(separator: "\n")))
    }

    /// The number of bytes read from the *end* of every candidate file, via
    /// `FileHandle` seek — never more, regardless of the file's total size.
    ///
    /// This works because sops always appends its `sops:` metadata block as
    /// the file's *last* top-level key. Verified directly against the pinned
    /// getsops/sops v3.13.3 source this app embeds: `SerializeMetadata` in
    /// `stores/metadata.go` builds the metadata `TreeItem`s (`md`) and then,
    /// for every branch, appends the branch's *existing* items first and
    /// `md` after —
    /// ```go
    /// for _, item := range branch { newBranch = append(newBranch, item) }
    /// for _, item := range md     { newBranch = append(newBranch, item) }
    /// ```
    /// — so `sops:` is unconditionally last. A bounded tail read therefore
    /// finds it regardless of how large the file's own plaintext-derived
    /// `ENC[...]` values are before it, at a *constant* cost per file: a
    /// 300 MB file and an 8 KB one cost the same. (An earlier version of
    /// this check skipped files above this size entirely instead of tail
    /// reading them, which silently excluded any legitimately oversized sops
    /// file from the recipient check — closed by reading the tail instead of
    /// documenting the gap.)
    ///
    /// 8 MiB is generous for what actually needs to fit in the tail: a real
    /// sops metadata block is a handful of small per-key entries (~200-400
    /// bytes each for age/pgp/kms), so even hundreds of recipients stay well
    /// under 1 MiB. The one residual edge case — a `sops:` block itself
    /// exceeding 8 MiB, which would need many thousands of recipients on a
    /// single file — falls back to being invisible to this check the same
    /// way the old whole-file cap did, just at a threshold that should never
    /// occur in practice.
    static let maxSniffedFileBytes = 8 * 1024 * 1024

    /// A candidate file paired with the tail bytes already read from it, so
    /// callers that need the content (`recipientFinding`) don't re-open and
    /// re-read the file a second time after `encryptedFiles(under:)` already
    /// paid that cost once.
    private struct SniffedFile {
        let url: URL
        let tail: String
    }

    /// Files carrying sops metadata, found by sniffing content rather than by
    /// extension — a project can encrypt .json, .env, or plain .yaml alike.
    /// Every file's *tail* is read (see `maxSniffedFileBytes`), never its
    /// full contents, so this scales with file count, not file size.
    private func encryptedFiles(under root: URL) -> [SniffedFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        return enumerator.compactMap { $0 as? URL }.compactMap { url -> SniffedFile? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            guard let tail = Self.tailText(of: url, maxBytes: Self.maxSniffedFileBytes) else { return nil }
            guard tail.contains("\nsops:") || tail.hasPrefix("sops:") else { return nil }
            return SniffedFile(url: url, tail: tail)
        }
    }

    /// Reads at most the last `maxBytes` bytes of `url` via `FileHandle`
    /// seek — see `maxSniffedFileBytes` for why the tail is always where
    /// the `sops:` block lives, regardless of the file's total size.
    private static func tailText(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let readSize = min(UInt64(maxBytes), size)
        guard (try? handle.seek(toOffset: size - readSize)) != nil,
              var bytes = try? handle.read(upToCount: Int(readSize))
        else { return nil }

        // A byte-offset tail slice can start mid-UTF-8-codepoint. Drop
        // leading continuation bytes (0b10xxxxxx) rather than fail the
        // whole decode over a boundary nowhere near the sops: block this
        // exists to find, which sits well inside the tail, not at its very
        // first byte.
        while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 {
            bytes.removeFirst()
        }
        return String(data: bytes, encoding: .utf8)
    }
}

/// The subset of `.sops.yaml` this check understands. Deliberately narrow —
/// the app is not a YAML editor, it only needs the age recipients declared
/// per creation rule.
///
/// This is a hand-rolled, indentation-aware line scanner, not a general YAML
/// parser. It was checked against inputs a real user is likely to produce:
/// full-line and trailing comments, `age:` written as a block YAML list, a
/// single-line flow sequence (`age: [k1, k2]`), *or* a flow sequence split
/// across lines (`age: [k1,\n      k2]` — a real shape once a recipient
/// list gets long) rather than only a comma-joined string, multiple
/// creation rules where an earlier one does not match and a later one does,
/// quoted scalar values, and CRLF line endings — all of those parse
/// correctly. What it does *not* attempt is full YAML (flow mappings,
/// anchors, multi-document files). Rather than silently mis-parse those and
/// report confident nonsense about a project's recipients, `init?` returns
/// `nil` — surfaced by the caller as "could not be parsed" — whenever the
/// input contains unbalanced `[]`/`{}` (a sign of flow-YAML syntax this
/// parser does not follow, and the same signal that catches an unclosed
/// `age: [k1, k2`, single-line or split across lines) or no usable creation
/// rule at all. A parser that admits it could not read a file is safer than
/// one that guesses.
///
/// A rule's `age:` list is not the only way sops can protect a file: `pgp`,
/// `kms`, `gcp_kms`, `hckms`, `azure_keyvault`, `hc_vault_transit_uri`, and
/// `key_groups` are all real, supported backends this parser recognises by
/// name (`CreationRule.nonAgeBackends`) without attempting to read their
/// contents — this app only ever holds age keys, so it could not verify a
/// PGP fingerprint or a KMS ARN even if it parsed one. See
/// `ProjectHealthCheck.recipientFinding` for how that shows up to the user:
/// never as a silent `.ok`.
struct SopsConfig {
    struct CreationRule {
        let pathRegex: String?
        let ageRecipients: [String]
        /// Non-age key backends this rule declares (`pgp`, `kms`, `gcp_kms`,
        /// `hckms`, `azure_keyvault`, `hc_vault_transit_uri`, `key_groups` —
        /// the exact `.sops.yaml` key names, per getsops/sops v3.13.3's
        /// `config.creationRule` struct). A rule can legally mix `age:` with
        /// any of these. This app only ever holds age keys, so it cannot
        /// evaluate a file protected (even partly) by one of these — see
        /// `ProjectHealthCheck.recipientFinding`.
        let nonAgeBackends: [String]
    }

    let creationRules: [CreationRule]

    init?(parsing text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // An unclosed [ or { means this file uses flow-YAML syntax this line
        // scanner cannot follow with any confidence. Bail out rather than
        // guess at what the unparsed region contained.
        guard Self.bracketsAreBalanced(normalized) else { return nil }

        let strippedLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.stripComment(from: String($0)) }

        // A flow sequence a user splits across lines when it gets long
        // (`age: [k1,\n      k2]`) must be one logical line before the
        // per-line parser ever sees it — otherwise the first physical line
        // parses as `age: [k1` with a stray `[` and the rest is dropped
        // silently. `bracketsAreBalanced` only proves the *document* is
        // balanced overall, not that any single line is; this rejoins
        // exactly the spans that need it.
        let lines = Self.joinMultiLineFlowSequences(strippedLines)

        guard let rules = Self.parseCreationRules(lines), !rules.isEmpty else { return nil }
        self.creationRules = rules
    }

    /// The first rule whose path_regex matches, mirroring sops's own
    /// first-match-wins evaluation order. A rule with no path_regex matches
    /// everything.
    func rule(matching relativePath: String) -> CreationRule? {
        creationRules.first { rule in
            guard let pattern = rule.pathRegex else { return true }
            return relativePath.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Public keys a sops-encrypted file is wrapped for, read from its
    /// `sops.age[].recipient` metadata.
    static func recipients(inEncryptedFile text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- recipient:") || trimmed.hasPrefix("recipient:") else { return nil }
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let value = unquote(String(trimmed[trimmed.index(after: colon)...]))
            return value.isEmpty ? nil : value
        }
    }

    /// Non-age key backends actually present in an encrypted file's own
    /// `sops:` metadata block, read from the field names getsops/sops v3.13.3
    /// itself writes (`stores.metadata` in `stores/stores.go`): `pgp`, `kms`,
    /// `gcp_kms`, `hckms`, `azure_kv`, `hc_vault`, `key_groups`. This is
    /// ground truth about how the *file itself* is protected right now —
    /// independent of what its governing `.sops.yaml` rule declares, which
    /// can drift out of sync with what was actually run. A file whose own
    /// metadata shows one of these cannot have its recipients fully verified
    /// by this app: it only ever holds age keys, never a PGP private key, a
    /// cloud IAM credential, or a Vault token.
    ///
    /// Scoped to the `sops:` block specifically (started by a line that is
    /// exactly `sops:` at column 0, ended by the next column-0 line or EOF)
    /// rather than scanning the whole file, so that a plaintext field the
    /// user happens to have named `kms:` or `pgp:` in their own data is never
    /// mistaken for sops metadata.
    static func nonAgeBackends(inEncryptedFile text: String) -> [String] {
        let backendKeys: Set<String> = ["pgp", "kms", "gcp_kms", "hckms", "azure_kv", "hc_vault", "key_groups"]
        var found: [String] = []
        var inSopsBlock = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "sops:" { inSopsBlock = true; continue }
            guard inSopsBlock else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Back at column 0: the sops: block ended (a sibling top-level
            // key follows — in practice sops always emits `sops:` last, but
            // this stays correct if that ever changes).
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }

            let (key, value) = split(trimmed)
            guard backendKeys.contains(key) else { continue }
            let v = value.trimmingCharacters(in: .whitespaces)
            if v != "[]", v != "{}", !found.contains(key) {
                found.append(key)
            }
        }
        return found
    }

    // MARK: - Parsing

    private static func bracketsAreBalanced(_ text: String) -> Bool {
        var square = 0, curly = 0
        for ch in text {
            switch ch {
            case "[": square += 1
            case "]": square -= 1
            case "{": curly += 1
            case "}": curly -= 1
            default: break
            }
            if square < 0 || curly < 0 { return false }
        }
        return square == 0 && curly == 0
    }

    /// Merges any run of physical lines that together form one YAML flow
    /// sequence (`[...]`) split across line breaks into a single logical
    /// line, so the rest of the parser — which is line-oriented — sees one
    /// coherent `key: [a, b, c]` instead of a truncated first fragment.
    ///
    /// Tracks only `[`/`]` depth (not `{`/`}`  — this parser never reads
    /// flow *mappings*). A line is joined to the next whenever it ends with
    /// unclosed square-bracket depth; continuation lines are trimmed before
    /// joining with a single space, since YAML flow syntax treats line
    /// breaks inside `[...]` as ordinary whitespace. Because
    /// `bracketsAreBalanced` (called first, in `init?`) already guarantees
    /// the document's square-bracket depth never goes negative and ends at
    /// exactly 0, every span opened here is guaranteed to close by EOF —
    /// there is no unterminated case left to handle.
    private static func joinMultiLineFlowSequences(_ lines: [String]) -> [String] {
        var result: [String] = []
        var buffer: String?
        var depth = 0

        for line in lines {
            if let current = buffer {
                buffer = current + " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                buffer = line
            }
            for ch in line {
                if ch == "[" { depth += 1 }
                if ch == "]" { depth -= 1 }
            }
            if depth <= 0 {
                result.append(buffer!)
                buffer = nil
                depth = 0
            }
        }
        // Reached only if bracketsAreBalanced's guarantee were somehow
        // violated; flush whatever was pending rather than drop it.
        if let buffer { result.append(buffer) }
        return result
    }

    /// Strips a trailing `# comment`. Only a `#` preceded by whitespace (or
    /// at the very start of the line) starts a comment, and one inside a
    /// quoted string does not — matching plain YAML's own rule, so a literal
    /// `#` inside a path_regex value survives.
    private static func stripComment(from line: String) -> String {
        var result = ""
        var previousWasSpace = true
        var inSingleQuote = false
        var inDoubleQuote = false
        for ch in line {
            if ch == "'" && !inDoubleQuote { inSingleQuote.toggle() }
            if ch == "\"" && !inSingleQuote { inDoubleQuote.toggle() }
            if ch == "#" && previousWasSpace && !inSingleQuote && !inDoubleQuote { break }
            result.append(ch)
            previousWasSpace = (ch == " " || ch == "\t")
        }
        return result
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func split(_ entry: String) -> (key: String, value: String) {
        guard let colon = entry.firstIndex(of: ":") else { return (entry, "") }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// `.sops.yaml` creation-rule keys for non-age backends, per
    /// getsops/sops v3.13.3's `config.creationRule` struct
    /// (`config/config.go`). `key_groups` is included because a key group
    /// can itself contain any of the others, including a second, disjoint
    /// age list this check does not know how to combine with the rule's own
    /// top-level `age:` — safer to flag it than to guess.
    private static let nonAgeBackendKeys: Set<String> =
        ["pgp", "kms", "gcp_kms", "hckms", "azure_keyvault", "hc_vault_transit_uri", "key_groups"]

    private static func apply(key: String, value: String, pathRegex: inout String?,
                              age: inout [String], backends: inout [String]) {
        switch key {
        case "path_regex":
            pathRegex = unquote(value)
        case "age":
            age = parseAgeList(value)
        case _ where nonAgeBackendKeys.contains(key):
            let v = value.trimmingCharacters(in: .whitespaces)
            // "[]"/"{}" is the user explicitly saying "none of these" —
            // anything else (inline value or nothing, meaning a block list
            // follows) means the backend is actually in play.
            if v != "[]", v != "{}", !backends.contains(key) {
                backends.append(key)
            }
        default:
            break
        }
    }

    /// Parses an `age:` value as either a comma-joined string
    /// (`age: k1,k2`) or a single-line YAML flow sequence
    /// (`age: [k1, k2]`, `age: [ k1 , k2 ]`, `age: []`). Both are valid YAML
    /// a real user will write. An unclosed flow sequence never reaches this
    /// function — `bracketsAreBalanced` rejects the whole document first —
    /// so there is no unbalanced case to half-parse here.
    private static func parseAgeList(_ rawValue: String) -> [String] {
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Scans the lines following `creation_rules:`, tracking indentation to
    /// tell a new rule marker (`- ` at the rule's own indent) apart from a
    /// block-style list nested under a key (`- ` indented deeper than the
    /// key that introduced it, e.g. `age:` followed by `- age1...` lines).
    private static func parseCreationRules(_ lines: [String]) -> [CreationRule]? {
        guard let startIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "creation_rules:"
        }) else { return nil }

        var rules: [CreationRule] = []
        var pathRegex: String?
        var age: [String] = []
        var backends: [String] = []
        var ruleIndent: Int?
        var inRule = false
        var pendingListKey: String?
        var pendingListIndent = 0

        func flush() {
            if inRule {
                rules.append(CreationRule(pathRegex: pathRegex, ageRecipients: age, nonAgeBackends: backends))
            }
            pathRegex = nil
            age = []
            backends = []
            inRule = false
            pendingListKey = nil
        }

        for rawLine in lines[(startIndex + 1)...] {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = indentation(of: rawLine)

            // Indentation back at the document root: creation_rules is over
            // (a sibling top-level key, e.g. `stores:`, follows).
            if indent == 0 { break }

            // A block-list item nested under the pending key, e.g. an
            // `age:` line followed by `- age1foo`.
            if let key = pendingListKey, indent > pendingListIndent, trimmed.hasPrefix("- ") {
                let value = unquote(String(trimmed.dropFirst(2)))
                if key == "age", !value.isEmpty { age.append(value) }
                continue
            }
            pendingListKey = nil

            let isNewRuleMarker = trimmed.hasPrefix("- ") && (ruleIndent == nil || indent == ruleIndent)
            if isNewRuleMarker {
                flush()
                inRule = true
                ruleIndent = indent
                let (key, value) = split(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                apply(key: key, value: value, pathRegex: &pathRegex, age: &age, backends: &backends)
                if key == "age", value.isEmpty { pendingListKey = "age"; pendingListIndent = indent }
                continue
            }

            guard inRule, let ruleIndent, indent > ruleIndent else { continue }
            let (key, value) = split(trimmed)
            apply(key: key, value: value, pathRegex: &pathRegex, age: &age, backends: &backends)
            if key == "age", value.isEmpty { pendingListKey = "age"; pendingListIndent = indent }
        }
        flush()
        return rules
    }
}
