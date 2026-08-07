import Foundation
import SopsEngine

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
///
/// `.sops.yaml` parsing history, for whoever touches this next: this check
/// used to parse `.sops.yaml` with a hand-rolled Swift YAML scanner. Across
/// three review rounds it shipped three different silent-corruption bugs —
/// a nested block list misread as a new rule, a flow list read as one
/// recipient with a stray bracket, and two unrelated rules glued together by
/// a whole-document bracket-balance check that quoted-value brackets in
/// different rules could cancel out against. The pattern was the parser, not
/// any individual bug in it. `.sops.yaml` parsing is now delegated entirely
/// to `SopsBridge.lookupCreationRule`, which crosses into
/// `github.com/getsops/sops/v3/config` — sops's own config parser, the exact
/// code every other sops command uses to answer the same question. This
/// app's understanding of a `.sops.yaml` can no longer drift from what sops
/// itself does with it. See `EncryptedFileMetadata` below for the one piece
/// of text-scanning that remains Swift-side, and its own doc comment for why
/// that one is a materially different, narrower problem.
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

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return [HealthFinding(
                id: "project.\(idSlug).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .warning,
                detail: "No .sops.yaml in \(project.rootPath). Without it, sops has no rules for which keys to encrypt new files to.",
                remediation: Remediation(
                    explanation: "Create one from the .sops.yaml wizard in this app."))]
        }

        // Probe that the config itself loads under sops's own parser,
        // independent of any specific file. The target path is never used
        // for anything but path_regex matching (sops does no I/O on it), so
        // a synthetic, non-existent name is fine here — only the "did the
        // config load" outcome from this call is used.
        let probeTarget = root.appendingPathComponent(".sops-health-check-probe").path
        do {
            _ = try SopsBridge.lookupCreationRule(configPath: configURL.path, targetFilePath: probeTarget)
        } catch {
            return [HealthFinding(
                id: "project.\(idSlug).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .problem,
                detail: "The .sops.yaml in \(project.rootPath) could not be parsed: \(error).",
                remediation: Remediation(
                    explanation: "Fix the YAML syntax, then re-run this check."))]
        }

        return [
            HealthFinding(id: "project.\(idSlug).sops-yaml",
                          title: "\(project.name): .sops.yaml", status: .ok,
                          detail: "The .sops.yaml in \(project.rootPath) parses successfully."),
            recipientFinding(for: project, idSlug: idSlug, root: root, configPath: configURL.path),
            gitignoreFinding(for: project, idSlug: idSlug, root: root),
        ]
    }

    /// Human-readable label for a sops master-key type identifier
    /// (`keys.MasterKey.TypeToIdentifier()`, e.g. from
    /// `CreationRuleLookup.nonAgeBackends` or
    /// `EncryptedFileMetadata.nonAgeBackends(inEncryptedFile:)`).
    private static func backendLabel(_ key: String) -> String {
        switch key {
        case "pgp": return "PGP"
        case "kms": return "AWS KMS"
        case "gcp_kms": return "GCP KMS"
        case "hckms": return "HC Vault KMS"
        case "azure_kv": return "Azure Key Vault"
        case "hc_vault": return "HashiCorp Vault"
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
                                  configPath: String) -> HealthFinding {
        var mismatches: [String] = []
        var sawStaleRecipient = false
        var unverifiable: [String] = []

        for sniffed in encryptedFiles(under: root) {
            let relative = sniffed.url.path.hasPrefix(root.path + "/")
                ? String(sniffed.url.path.dropFirst(root.path.count + 1))
                : sniffed.url.path

            let lookup: CreationRuleLookup
            do {
                lookup = try SopsBridge.lookupCreationRule(configPath: configPath, targetFilePath: sniffed.url.path)
            } catch {
                unverifiable.append("\(relative): could not determine which rule governs it (\(error)).")
                continue
            }
            guard lookup.matched else { continue }

            if !lookup.nonAgeBackends.isEmpty {
                let backends = lookup.nonAgeBackends.map(Self.backendLabel).joined(separator: ", ")
                unverifiable.append("The rule governing \(relative) also allows \(backends), which this app cannot read — it only understands age recipients.")
            }

            // Ground truth from the file itself: what actually protects it
            // right now, regardless of what the rule declares.
            let fileBackends = EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: sniffed.tail)
            if !fileBackends.isEmpty {
                let backends = fileBackends.map(Self.backendLabel).joined(separator: ", ")
                unverifiable.append("\(relative) is protected, at least in part, by \(backends), which this app cannot read — it only understands age recipients.")
            }

            let actual = Set(EncryptedFileMetadata.recipients(inEncryptedFile: sniffed.tail))
            let expected = Set(lookup.ageRecipients)

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
    /// `ENC[...]` values are before it, at a *constant* cost per file.
    ///
    /// 64 KiB, not the 8 MiB an earlier version of this check used: a real
    /// sops metadata block is a handful of small per-key entries (~200-400
    /// bytes each for age/pgp/kms), so even a file with a few hundred
    /// recipients stays well under 64 KiB. 8 MiB was measured to cost
    /// ~0.5s per matching file — fine for one file, ~7.7s across 15 files
    /// and ~10.3s across 20 in a real-sized repository, i.e. the exact
    /// "large tree is slow" regression this cap exists to prevent, just
    /// re-introduced at the per-file, per-tree-size level instead of the
    /// per-single-large-file level the original version fixed. 64 KiB
    /// removes that scaling: see the fix report for before/after timing
    /// across 15- and 20-file trees. The residual edge case — a `sops:`
    /// block itself exceeding 64 KiB, needing on the order of a hundred-plus
    /// recipients on a single file — falls back to being invisible to this
    /// check, the same direction of limitation as before, at a threshold
    /// closer to what real files actually look like.
    static let maxSniffedFileBytes = 64 * 1024

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

/// Reads metadata out of an *encrypted file's own* `sops:` block — a
/// fundamentally different, narrower problem than parsing a user-authored
/// `.sops.yaml`, which is why it is not covered by the migration to
/// `SopsBridge.lookupCreationRule` described in `ProjectHealthCheck`'s doc
/// comment. Two things make it narrower:
///
/// 1. The input is machine-generated by sops's own serializer
///    (`stores/yaml/store.go`, `stores/metadata.go` in getsops/sops
///    v3.13.3), never hand-typed. It has exactly one shape: fixed 4-space
///    indent, no comments, no flow sequences split or otherwise, no
///    creative formatting choices — the entire "a real user writes YAML in
///    many equally-valid ways" problem that made `.sops.yaml` parsing
///    fragile does not exist here.
/// 2. What this reads is far narrower: a handful of known top-level keys
///    under `sops:`, each with a small, fixed set of sub-fields. There is
///    no indentation-sensitive rule/key state machine, no bracket
///    balancing, no multi-line joining.
///
/// That said, this scanner was reviewed for the *same class* of bug the
/// `.sops.yaml` parser had — scope creep from "read sops's own metadata"
/// into "read anything that looks similar" — and one real instance was
/// found and fixed: `recipients(inEncryptedFile:)` used to scan the *whole*
/// file for any line starting with `recipient:`, not just inside the
/// `sops:` block. Since sops only ever encrypts *values*, never *keys*, a
/// project's own plaintext data can legitimately have a field literally
/// named `recipient` (e.g. an email/payment "recipient" field) — after
/// encryption that becomes `recipient: ENC[...]`, which the old, unscoped
/// scan would have swallowed whole as if `ENC[AES256_GCM,...]` were a real
/// age public key. Both functions are now scoped to the `sops:` block via
/// the shared `sopsBlockLines(in:)` helper, closing that gap. See
/// `EncryptedFileMetadataTests.swift` for the regression test.
enum EncryptedFileMetadata {

    /// Public keys a sops-encrypted file is wrapped for, read from its
    /// `sops.age[].recipient` metadata.
    static func recipients(inEncryptedFile text: String) -> [String] {
        sopsBlockLines(in: text).compactMap { line in
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
    static func nonAgeBackends(inEncryptedFile text: String) -> [String] {
        let backendKeys: Set<String> = ["pgp", "kms", "gcp_kms", "hckms", "azure_kv", "hc_vault", "key_groups"]
        var found: [String] = []
        for line in sopsBlockLines(in: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "sops:" { continue }
            let (key, value) = split(trimmed)
            guard backendKeys.contains(key) else { continue }
            let v = value.trimmingCharacters(in: .whitespaces)
            if v != "[]", v != "{}", !found.contains(key) {
                found.append(key)
            }
        }
        return found
    }

    /// Extracts just the `sops:` metadata block's lines — started by a line
    /// that is exactly `sops:` at column 0, ended by the next column-0 line
    /// or EOF. Scoping every scan to this block, rather than the whole
    /// file, is what stops a user's own plaintext field name (e.g.
    /// `recipient`, `kms`) from being mistaken for sops metadata; see the
    /// type-level doc comment.
    private static func sopsBlockLines(in text: String) -> [String] {
        var lines: [String] = []
        var inBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "sops:" { inBlock = true; lines.append(line); continue }
            guard inBlock else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { lines.append(line); continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            lines.append(line)
        }
        return lines
    }

    private static func split(_ entry: String) -> (key: String, value: String) {
        guard let colon = entry.firstIndex(of: ":") else { return (entry, "") }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
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
}
