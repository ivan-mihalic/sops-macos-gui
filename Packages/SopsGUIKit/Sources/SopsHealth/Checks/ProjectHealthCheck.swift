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

    /// Compares each encrypted file's actual key list against the rule that
    /// governs it. This is a comparison of two lists of public keys read from
    /// disk — see the type-level doc comment for what it does and does not
    /// prove about decryption.
    private func recipientFinding(for project: InspectedProject, idSlug: String, root: URL,
                                  config: SopsConfig) -> HealthFinding {
        var mismatches: [String] = []
        var sawStaleRecipient = false

        for file in encryptedFiles(under: root) {
            let relative = file.path.hasPrefix(root.path + "/")
                ? String(file.path.dropFirst(root.path.count + 1))
                : file.path
            guard let rule = config.rule(matching: relative) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

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

        guard !mismatches.isEmpty else {
            return HealthFinding(
                id: "project.\(idSlug).stale-recipients",
                title: "\(project.name): recipients", status: .ok,
                detail: "Checked every encrypted file's recipient key list against the rule that governs it — every file's key list matches.")
        }

        // A key that was removed from .sops.yaml but still appears in a
        // file's recipient list already saw the plaintext once; removing the
        // entry from the config does not retract that. The remediation says
        // so explicitly, using "rotate" rather than implying re-encryption
        // alone fixes it.
        let rotateNote = sawStaleRecipient
            ? " If a recipient was removed on purpose, also rotate the secret values themselves — that key's holder already had a chance to see the old plaintext, and re-wrapping the file does not undo that."
            : ""

        return HealthFinding(
            id: "project.\(idSlug).stale-recipients",
            title: "\(project.name): recipients", status: .problem,
            detail: mismatches.joined(separator: "\n"),
            remediation: Remediation(
                explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares." + rotateNote,
                command: "sops updatekeys <file>"))
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

    /// Files carrying sops metadata, found by sniffing content rather than by
    /// extension — a project can encrypt .json, .env, or plain .yaml alike.
    private func encryptedFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("\nsops:") || text.hasPrefix("sops:")
        }
    }
}

/// The subset of `.sops.yaml` this check understands. Deliberately narrow —
/// the app is not a YAML editor, it only needs the age recipients declared
/// per creation rule.
///
/// This is a hand-rolled, indentation-aware line scanner, not a general YAML
/// parser. It was checked against inputs a real user is likely to produce:
/// full-line and trailing comments, `age:` written as a block YAML list
/// rather than a comma-joined string, multiple creation rules where an
/// earlier one does not match and a later one does, quoted scalar values,
/// and CRLF line endings — all of those parse correctly. What it does *not*
/// attempt is full YAML (flow mappings, anchors, multi-document files,
/// non-age key types). Rather than silently mis-parse those and report
/// confident nonsense about a project's recipients, `init?` returns `nil`
/// — surfaced by the caller as "could not be parsed" — whenever the input
/// contains unbalanced `[]`/`{}` (a sign of flow-YAML syntax this parser does
/// not follow) or no usable creation rule at all. A parser that admits it
/// could not read a file is safer than one that guesses.
struct SopsConfig {
    struct CreationRule {
        let pathRegex: String?
        let ageRecipients: [String]
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

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.stripComment(from: String($0)) }

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

    private static func apply(key: String, value: String, pathRegex: inout String?, age: inout [String]) {
        switch key {
        case "path_regex":
            pathRegex = unquote(value)
        case "age":
            age = value.isEmpty
                ? []
                : value.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
        default:
            break
        }
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
        var ruleIndent: Int?
        var inRule = false
        var pendingListKey: String?
        var pendingListIndent = 0

        func flush() {
            if inRule { rules.append(CreationRule(pathRegex: pathRegex, ageRecipients: age)) }
            pathRegex = nil
            age = []
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
                apply(key: key, value: value, pathRegex: &pathRegex, age: &age)
                if key == "age", value.isEmpty { pendingListKey = "age"; pendingListIndent = indent }
                continue
            }

            guard inRule, let ruleIndent, indent > ruleIndent else { continue }
            let (key, value) = split(trimmed)
            apply(key: key, value: value, pathRegex: &pathRegex, age: &age)
            if key == "age", value.isEmpty { pendingListKey = "age"; pendingListIndent = indent }
        }
        flush()
        return rules
    }
}
