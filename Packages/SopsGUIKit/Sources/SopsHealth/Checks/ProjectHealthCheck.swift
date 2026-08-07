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

    private let source: any ProjectSourceProviding
    /// Used for one thing: finding `git`, which answers the gitignore
    /// question. Injected rather than hardcoded to `/usr/bin/git` for the same
    /// reason `ExternalToolCheck` uses it — a GUI app launched from Finder has
    /// no useful process `PATH`.
    private let locator: any ToolLocating

    public init(source: any ProjectSourceProviding, locator: any ToolLocating = ToolLocator()) {
        self.source = source
        self.locator = locator
    }

    public func run() async -> [HealthFinding] {
        let projects = source.projects
        guard !projects.isEmpty else {
            return [HealthFinding(
                id: "project.none", title: "Projects",
                status: .skipped(reason: "No projects have been added yet."),
                detail: "Add a project to have its .sops.yaml and encrypted files checked.")]
        }

        // Located once for the whole run, not once per project.
        let gitPath = await locator.locate("git", versionArguments: ["--version"])?.path

        // Finding ids are scoped by the project's *position*, never by its
        // display name.
        //
        // The previous scheme built ids from the name and disambiguated
        // duplicates by appending "-2", "-3" — which manufactures exactly the
        // collision it was written to prevent: `[acme, acme, acme-2]` yields
        // `project.acme-2.…` twice, once for the disambiguated second "acme"
        // and once for the project actually named "acme-2". `HealthFinding` is
        // `Identifiable` and every surface renders findings in a `ForEach`, so
        // that makes row identity undefined. Names containing dots break it
        // further, the id's own separator being part of the value.
        //
        // An index cannot collide with another index. Deriving identity from
        // anything the user types is the bug; the fix is to stop. The user's
        // own name is unaffected — it is shown in `title`, verbatim.
        return projects.enumerated().flatMap { index, project in
            findings(for: project, idScope: String(index), gitPath: gitPath)
        }
    }

    private func findings(for project: InspectedProject, idScope: String,
                          gitPath: String?) -> [HealthFinding] {
        let root = URL(fileURLWithPath: project.rootPath)
        let configURL = root.appendingPathComponent(".sops.yaml")

        // One walk of the tree feeds both findings below.
        let tree = Self.scanTree(under: root)
        let leak = gitignoreFinding(for: project, idScope: idScope, root: root,
                                    candidates: tree.plaintextCandidates, gitPath: gitPath)

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // The plaintext-leak finding is emitted even here. A project with
            // no .sops.yaml is the *most* likely one to have secrets sitting
            // in plaintext, so suppressing that finding until a config exists
            // would hide it exactly when it matters most.
            return [HealthFinding(
                id: "project.\(idScope).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .warning,
                detail: "No .sops.yaml in \(project.rootPath). Without it, sops has no rules for which keys to encrypt new files to.",
                remediation: Remediation(
                    explanation: "Create one from the .sops.yaml wizard in this app.")), leak]
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
                id: "project.\(idScope).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .problem,
                detail: "The .sops.yaml in \(project.rootPath) could not be parsed: \(error).",
                remediation: Remediation(
                    explanation: "Fix the YAML syntax, then re-run this check.")), leak]
        }

        return [
            HealthFinding(id: "project.\(idScope).sops-yaml",
                          title: "\(project.name): .sops.yaml", status: .ok,
                          detail: "The .sops.yaml in \(project.rootPath) parses successfully."),
            recipientFinding(for: project, idScope: idScope, root: root,
                             configPath: configURL.path, tree: tree),
            leak,
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
        case "key_groups": return "key groups"
        default: return key
        }
    }

    /// Backend identifiers as a sentence fragment: "PGP", "AWS KMS and
    /// HashiCorp Vault", "AWS KMS, PGP and HashiCorp Vault". Sorted by the
    /// label a reader sees, not by the identifier behind it — sorting by
    /// identifier puts "HashiCorp Vault" (hc_vault) before "AWS KMS" (kms),
    /// which reads like a mistake.
    private static func backendList(_ keys: some Collection<String>) -> String {
        let labels = keys.map(backendLabel).sorted()
        guard let last = labels.last else { return "" }
        guard labels.count > 1 else { return last }
        return labels.dropLast().joined(separator: ", ") + " and " + last
    }

    /// One spelling for a path, so a file found by directory enumeration can
    /// be reported relative to the project root the user gave us.
    ///
    /// Two things get in the way. Symlinked roots: a root under `/var` (a
    /// symlink to `/private/var`) enumerates its contents as `/private/var/…`,
    /// so stripping the root's own spelling as a prefix fails and the whole
    /// absolute path lands in the finding. And Foundation's own asymmetry:
    /// `resolvingSymlinksInPath()` *removes* a leading `/private`, it does not
    /// add one, so it alone does not reconcile the two. Normalizing both sides
    /// the same way — resolve, then drop a leading `/private` — does.
    private static func canonicalPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : resolved
    }

    /// Compares each encrypted file's actual key list against the rule that
    /// governs it. This is a comparison of two lists of public keys read from
    /// disk — see the type-level doc comment for what it does and does not
    /// prove about decryption.
    ///
    /// Age is not the only backend sops supports, and this app only ever holds
    /// age keys. Three independent signals say "part of this project is
    /// something this app cannot evaluate", and all three must reach the user
    /// rather than falling through to `.ok`:
    ///
    /// 1. **The config as a whole** (`SopsBridge.inspectConfigBackends`) —
    ///    which backends `.sops.yaml` names anywhere, files or no files. This
    ///    is the only signal that can see a rule declaring pgp/KMS/Vault that
    ///    *no file currently matches*. Without it, such a rule was invisible:
    ///    the per-file lookup below never resolves it, nothing lands in the
    ///    unverifiable bucket, and the finding folded that silence into a
    ///    confident "every file's key list matches" — an OK about a
    ///    configuration this app cannot read at all, which PROPOSAL.md §6 D
    ///    forbids in as many words.
    /// 2. **The rule governing a specific file** (`CreationRuleLookup`).
    /// 3. **The file's own metadata** (`EncryptedFileMetadata`) — ground truth
    ///    for what actually protects it right now, which can drift from what
    ///    its rule declares.
    ///
    /// Status precedence, deliberate: a genuine age-recipient mismatch is
    /// still `.problem` even when something else was unreadable — a real,
    /// actionable finding must never be buried under a caveat. Otherwise any
    /// unreadable signal makes the finding `.unknown`, never `.ok`, and the
    /// detail leads with what *was* verified so a user with one healthy age
    /// rule still learns that part is fine.
    ///
    /// `.unknown` rather than `.skipped`, though PROPOSAL.md §6 D says
    /// "Skipped": in this codebase `.skipped` means the check's subject does
    /// not exist yet (`HealthStatus`'s own doc comment; it is what "no
    /// projects have been added" reports), and `.unknown` means the check ran
    /// but could not reach a verdict. This check did run — it read the config
    /// and every encrypted file, and reached a verdict on the age part. The
    /// proposal's substantive requirement is "must never report OK about a
    /// configuration it cannot read", and `.unknown` satisfies it while
    /// ranking above `.skipped` in `HealthStatus.severity`, so a caveat
    /// cannot be hidden behind an informational status. It also keeps one
    /// vocabulary for all three signals above, which already used `.unknown`.
    private func recipientFinding(for project: InspectedProject, idScope: String, root: URL,
                                  configPath: String, tree: ScannedTree) -> HealthFinding {
        var mismatches: [String] = []
        var sawStaleRecipient = false
        var unverifiable: [String] = []
        var unreadableBackends: Set<String> = []
        var verifiedFileCount = 0

        // Signal 1: the whole config, independent of which files exist.
        do {
            let declared = try SopsBridge.inspectConfigBackends(configPath: configPath).backends
            if !declared.isEmpty {
                unreadableBackends.formUnion(declared)
                unverifiable.append("This project's .sops.yaml declares \(Self.backendList(declared)) somewhere in its creation rules. This app reads age recipients only, so it did not check any rule that uses those keys — including a rule no file matches yet, which nothing else here would mention. That is a limit of this app, not a problem with those keys.")
            }
        } catch {
            unverifiable.append("This project's .sops.yaml could not be read for the list of key backends it declares (\(error)), so this app cannot tell whether every rule in it is one it is able to check.")
        }

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            let path = Self.canonicalPath(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        // Encrypted files this build cannot read at all. The bridge is
        // YAML-only in M1 (`gobridge.Format`), so a sops-encrypted .env, .json
        // or .ini carries metadata in a shape `EncryptedFileMetadata` does not
        // parse. Saying so is the point: silently omitting them from the count
        // and then reporting OK is the same vacuous verdict this whole
        // finding was rewritten to stop producing.
        for url in tree.encryptedInOtherFormats {
            unverifiable.append("\(relativeName(url)) is sops-encrypted in a format this app does not read yet — this build handles YAML only — so its recipient list was not checked.")
        }

        for sniffed in tree.encrypted {
            let relative = relativeName(sniffed.url)

            let lookup: CreationRuleLookup
            do {
                lookup = try SopsBridge.lookupCreationRule(configPath: configPath, targetFilePath: sniffed.url.path)
            } catch {
                unverifiable.append("\(relative): could not determine which rule governs it (\(error)).")
                continue
            }
            // No rule governs this file. Previously a bare `continue`, which
            // dropped the file from the report entirely and let the `.ok`
            // branch below announce that every encrypted file had been
            // checked. An encrypted file with no creation rule is precisely
            // the case where this app has nothing to compare against and must
            // say so.
            guard lookup.matched else {
                unverifiable.append("\(relative) is encrypted, but no creation rule in .sops.yaml governs it, so there is no declared key list to compare its recipients against.")
                continue
            }

            // Ground truth from the file itself: what actually protects it
            // right now, regardless of what the rule declares. The two can
            // disagree — a file encrypted before its rule changed — so both
            // are reported, except when they say exactly the same thing,
            // where two sentences saying it would just be noise.
            let ruleBackends = Set(lookup.nonAgeBackends)
            let fileBackends = Set(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: sniffed.tail))
            unreadableBackends.formUnion(ruleBackends)
            unreadableBackends.formUnion(fileBackends)

            if !ruleBackends.isEmpty, ruleBackends == fileBackends {
                unverifiable.append("\(relative) is protected by \(Self.backendList(ruleBackends)), which the rule governing it also declares. This app reads age recipients only, so its key list was not checked.")
            } else {
                if !ruleBackends.isEmpty {
                    unverifiable.append("The rule governing \(relative) also allows \(Self.backendList(ruleBackends)), which this app cannot read — it only understands age recipients.")
                }
                if !fileBackends.isEmpty {
                    unverifiable.append("\(relative) is protected, at least in part, by \(Self.backendList(fileBackends)), which this app cannot read — it only understands age recipients.")
                }
            }

            let actual = Set(EncryptedFileMetadata.recipients(inEncryptedFile: sniffed.tail))
            let expected = Set(lookup.ageRecipients)

            // Only a comparison with at least one age key on one side is a
            // real comparison. Two empty sets matching is exactly the vacuous
            // "check" that produced the original false OK, so it must never
            // be counted as a file this app verified.
            if !(actual.isEmpty && expected.isEmpty) { verifiedFileCount += 1 }

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
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients", status: .problem,
                detail: detail,
                remediation: Remediation(
                    explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares." + rotateNote,
                    command: "sops updatekeys <file>"))
        }

        guard unverifiable.isEmpty else {
            // Lead with what was actually verified. A user whose age rule is
            // healthy deserves to know that part is fine; they must simply
            // not read it as a verdict on the whole project.
            let verified: String
            switch verifiedFileCount {
            case 0:
                verified = "No encrypted file's age recipient list could be checked here, so this app is not vouching for this project's recipients either way."
            case 1:
                verified = "Checked 1 encrypted file's age recipient list against the rule that governs it — it matches."
            default:
                verified = "Checked \(verifiedFileCount) encrypted files' age recipient lists against the rules that govern them — they all match."
            }
            let reason = unreadableBackends.isEmpty
                ? "Part of this project's recipients could not be checked. This is not a verdict on them."
                : "This project uses \(Self.backendList(unreadableBackends)), which this app cannot read — it only understands age keys."
            return HealthFinding(
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: reason),
                detail: verified + "\n\nDeliberately not checked:\n"
                    + unverifiable.map { "• " + $0 }.joined(separator: "\n"),
                remediation: Remediation(
                    explanation: "Nothing here needs fixing on this app's account — it reports only what it read. To check the rest, use the tooling for that backend: `gpg --list-keys` for PGP, or your cloud provider's console for KMS, Key Vault or Vault. This app only manages age keys."))
        }

        // Nothing was unreadable, and nothing disagreed. That is only an
        // affirmative OK if something was actually compared.
        //
        // `verifiedFileCount` has always been the right number — it is
        // incremented only when at least one age key sits on one side of the
        // comparison, precisely so that "two empty sets are equal" is not
        // mistaken for a verified file. It just was never read here. The old
        // sentence, "Checked every encrypted file's recipient key list against
        // the rule that governs it — every file's key list matches", was
        // printed verbatim over zero files in three separate reproduced
        // situations: a project with no encrypted files at all, a project
        // whose only encrypted files were hidden, and a project whose
        // encrypted file matched no creation rule.
        guard verifiedFileCount > 0 else {
            // The subject does not exist yet: no encrypted file was found
            // anywhere under the project root. `.skipped` per
            // `HealthStatus`'s own vocabulary, and it names the fact rather
            // than implying a verdict.
            guard !tree.encrypted.isEmpty || !tree.encryptedInOtherFormats.isEmpty else {
                return HealthFinding(
                    id: "project.\(idScope).stale-recipients",
                    title: "\(project.name): recipients",
                    status: .skipped(reason: "No sops-encrypted files were found anywhere under \(project.rootPath)."),
                    detail: "The .sops.yaml here parses and uses age keys only, but there are no encrypted files yet, so no recipient list was compared against it. This app is not vouching for this project's recipients either way.")
            }
            // Files exist, every one of them resolved to a rule, and not one
            // comparison had an age key on either side. The check ran and
            // reached no verdict.
            return HealthFinding(
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: "No encrypted file here declares an age recipient, and neither does the rule governing it, so there was nothing to compare."),
                detail: "Encrypted files were found under \(project.rootPath), but none of them — and none of the rules governing them — names a single age recipient. This app reads age recipients, so it has not verified anything about how these files are protected.")
        }

        let checked = verifiedFileCount == 1
            ? "Checked 1 encrypted file's recipient key list against the rule that governs it — it matches."
            : "Checked \(verifiedFileCount) encrypted files' recipient key lists against the rules that govern them — they all match."
        return HealthFinding(
            id: "project.\(idScope).stale-recipients",
            title: "\(project.name): recipients", status: .ok,
            detail: checked + " Every rule in .sops.yaml uses age keys only, so there is nothing here this app could not read.")
    }

    /// Reports only that a plaintext secret file exists and is not
    /// gitignored — never its contents. See the type-level doc comment.
    ///
    /// Two things changed here after the whole-branch review, both because the
    /// old version was verified wrong against `git check-ignore`:
    ///
    /// 1. **Scope.** PROPOSAL.md §6 D says "inside the repo"; the old scan
    ///    looked only at the project root, so `services/api/.env` holding a
    ///    live `sk_live_…` was invisible and the finding said "No unignored
    ///    plaintext secret files found." The scan is now the whole tree.
    /// 2. **The oracle.** Ignore status is decided by `git check-ignore`, not
    ///    by comparing `.gitignore` lines to filenames. See `GitIgnoreOracle`.
    ///
    /// When git cannot answer — no repository, no git binary — the finding is
    /// `.unknown` and still names the files it found. Guessing is what
    /// produced the false OK; a named file with an honest "could not
    /// determine" is strictly more useful than a confident wrong answer.
    private func gitignoreFinding(for project: InspectedProject, idScope: String, root: URL,
                                  candidates: [URL], gitPath: String?) -> HealthFinding {
        let findingID = "project.\(idScope).gitignore"
        let title = "\(project.name): plaintext files"

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            let path = Self.canonicalPath(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        // No candidate file at all is a definite answer that needs no git:
        // it is a fact about the filesystem, not about ignore rules.
        guard !candidates.isEmpty else {
            return HealthFinding(
                id: findingID, title: title, status: .ok,
                detail: "Looked through \(project.rootPath) for plaintext files whose names conventionally hold secrets (.env and its variants) and found none.")
        }

        let names = candidates.map(relativeName).sorted()

        switch GitIgnoreOracle.classify(candidates: candidates, root: root, gitPath: gitPath) {
        case .undetermined(let reason):
            return HealthFinding(
                id: findingID, title: title, status: .unknown(reason: reason),
                detail: "These files under \(project.rootPath) have names that conventionally hold plaintext secrets: \(names.joined(separator: ", ")). Whether they are ignored could not be established, so this app is not telling you either way.",
                remediation: Remediation(
                    explanation: "Check them yourself with the command below, and make sure anything holding a real secret is either ignored or moved into a file this app encrypts.",
                    command: "git check-ignore -v " + names.map { "'\($0)'" }.joined(separator: " ")))

        case .answered(let exposed, let tracked):
            guard !exposed.isEmpty else {
                let count = candidates.count == 1
                    ? "1 plaintext file whose name conventionally holds secrets"
                    : "\(candidates.count) plaintext files whose names conventionally hold secrets"
                return HealthFinding(
                    id: findingID, title: title, status: .ok,
                    detail: "Found \(count) under \(project.rootPath) (\(names.joined(separator: ", "))). git ignores all of them, so none can be committed by accident.")
            }

            let exposedNames = exposed.map(relativeName).sorted()
            let trackedNames = exposed.filter { tracked.contains($0.path) }.map(relativeName).sorted()

            var detail = "These plaintext files under \(project.rootPath) are not gitignored: \(exposedNames.joined(separator: ", ")). Committing one publishes its contents to everyone with access to the repository's history, permanently."
            if !trackedNames.isEmpty {
                detail += "\n\nAlready tracked by git, so they are in the repository now: \(trackedNames.joined(separator: ", ")). Adding a .gitignore line does not remove a file that is already tracked."
            }

            let rotationNote = trackedNames.isEmpty
                ? " If one has already been committed, rotating the values is the only real fix — removing the file from a future commit does not remove it from history."
                : " For the files already tracked, rotating the values is the only real fix: they are in the history, and neither a .gitignore line nor a future deletion removes them from it. `git rm --cached <file>` stops tracking it going forward."
            return HealthFinding(
                id: findingID, title: title, status: .problem,
                detail: detail,
                remediation: Remediation(
                    explanation: "Add them to .gitignore, then move their secrets into a file this app encrypts." + rotationNote,
                    command: exposedNames.map { "echo '\($0)' >> .gitignore" }.joined(separator: "\n")))
        }
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
    struct SniffedFile {
        let url: URL
        let tail: String
    }

    /// What one walk of a project tree found.
    struct ScannedTree {
        /// Files carrying a YAML `sops:` metadata block — the shape this
        /// build can read recipients out of.
        var encrypted: [SniffedFile] = []
        /// Files carrying sops metadata in some other serialization
        /// (dotenv, JSON, INI). Recorded, not ignored: they are reported as
        /// unverifiable rather than quietly left out of the count.
        var encryptedInOtherFormats: [URL] = []
        /// Files whose *names* conventionally hold plaintext secrets and
        /// which carry no sops metadata at all.
        var plaintextCandidates: [URL] = []
    }

    /// Directories that hold a tool's own storage rather than the user's
    /// content. `.git` is the one that matters: it is large, it is walked on
    /// every refresh, and nothing a user would call a secret lives there as a
    /// loose file. Deliberately short — every entry here is a place this app
    /// promises not to look, and the longer that list gets the more likely it
    /// is to hide something real. Build and dependency directories
    /// (`node_modules`, `.build`) are *not* on it: a secret can genuinely end
    /// up in one, and being slow is better than being silent.
    private static let skippedDirectoryNames: Set<String> = [".git", ".hg", ".svn"]

    /// Walks the project tree once, classifying every regular file.
    ///
    /// Hidden files are **not** skipped, which is the change that closes one
    /// of the three reproduced false-OK paths. The previous
    /// `.skipsHiddenFiles` meant a genuinely sops-encrypted `.hidden-secrets.yaml`
    /// or `.config/secrets.yaml` was permanently invisible — including one
    /// encrypted to a key the config no longer declared, i.e. a real
    /// `.problem` the report rendered as "every file's key list matches". A
    /// sops-encrypted `.env` is a completely ordinary thing for a user to
    /// have, and so is a `secrets/` directory under a dotfile path. An
    /// exclusion the user cannot see and the copy does not admit is the same
    /// failure class as the vacuous OK itself, so the exclusion is gone rather
    /// than documented.
    ///
    /// Every file's *tail* is read (see `maxSniffedFileBytes`), never its full
    /// contents, so this scales with file count, not file size. Nothing is
    /// read from a plaintext candidate beyond that tail, and nothing read from
    /// any file ever reaches a finding.
    static func scanTree(under root: URL) -> ScannedTree {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return ScannedTree() }

        var tree = ScannedTree()
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if Self.skippedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let tail = Self.tailText(of: url, maxBytes: Self.maxSniffedFileBytes)
            if let tail, tail.contains("\nsops:") || tail.hasPrefix("sops:") {
                tree.encrypted.append(SniffedFile(url: url, tail: tail))
            } else if let tail, Self.looksSopsEncryptedInAnotherFormat(tail) {
                tree.encryptedInOtherFormats.append(url)
            } else if Self.isPlaintextSecretCandidate(url.lastPathComponent) {
                tree.plaintextCandidates.append(url)
            }
        }
        return tree
    }

    /// sops metadata as written by its non-YAML stores. Only used to keep an
    /// encrypted file from being mistaken for a plaintext one — an encrypted
    /// `.env` reported as a leaking secret is a false alarm, and false alarms
    /// are how a user learns to skip this finding.
    private static func looksSopsEncryptedInAnotherFormat(_ tail: String) -> Bool {
        tail.contains("sops_mac=") || tail.contains("sops_version=")   // dotenv
            || tail.contains("\"sops\":")                              // json
            || tail.contains("\n[sops]")                               // ini
    }

    /// Whether a *filename* is one that conventionally holds plaintext
    /// secrets. Names only — nothing here reads a file.
    ///
    /// The old list was three hardcoded strings (`.env`, `.env.local`,
    /// `.env.production`), so `.env.staging`, `.env.development` and
    /// `production.env` all went unreported. This covers the whole `.env`
    /// family in both spellings instead.
    ///
    /// Deliberately still narrow. Widening it to things like `credentials`,
    /// `id_rsa` or `.npmrc` would produce false alarms on files that are
    /// routinely committed on purpose, and a finding that cries wolf is one
    /// the user stops reading — which costs more than the names it would
    /// catch. The `.env` family is the case PROPOSAL.md §6 D names and the one
    /// with an unambiguous convention behind it.
    static func isPlaintextSecretCandidate(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Placeholders documenting which variables exist. Committing one is
        // the point of it, so flagging it is pure noise.
        let placeholderSuffixes = [".example", ".sample", ".template", ".dist", ".defaults"]
        if placeholderSuffixes.contains(where: { lower.hasSuffix($0) }) { return false }
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        // "production.env", "local.env" — the same convention written the
        // other way round. Excludes ".env" itself, already matched above.
        return lower.hasSuffix(".env") && lower != ".env"
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
