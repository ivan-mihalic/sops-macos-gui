import Foundation
import Testing
@testable import SopsHealth

/// CRLF as a *single* `Character`, for the third time.
///
/// Swift's `Character` is an extended grapheme cluster, and `"\r\n"` is one
/// such cluster — not two. Every idiom that reaches for the `Character`
/// `"\n"` therefore does nothing at all on a CRLF document: a
/// `split(separator: "\n")` returns the whole file as one "line", a
/// `contains("\nsops:")` never matches, a `$0 == "\n"` predicate never fires.
///
/// The project's history with this:
///
/// 1. **Task 1b** — `String.contains("\nsops:")` versus `"\r\nsops:"`.
/// 2. **Task 6** — `keys.txt` split on `"\n"`
///    (`SessionKeyStore.importFromKeysFileContents`).
/// 3. **Task 14** — caught in its own first draft, guarded by
///    `SopsMetadataShapeTests.crlfIsTolerated`.
/// 4. **This task** — `EncryptedFileMetadata.sopsBlockLines`, the one call
///    site the earlier fixes did not reach, with the worst consequence yet:
///    no recipients parsed means every key the rule declares looks *missing*,
///    so the health report accuses a perfectly healthy file of not listing
///    the user's own key, and offers `sops updatekeys` for a problem that
///    does not exist. A confident false accusation about a secret is worse
///    than silence.
///
/// The fixtures below are encrypted with the **real `sops` binary** and then
/// converted to CRLF byte-for-byte, so nothing here depends on this project's
/// own idea of what sops output looks like.
@Suite("CRLF line endings are tolerated wherever a file's own bytes are read")
struct CRLFToleranceTests {

    // MARK: - Fixtures built from the real CLI

    private static func sopsCLIPath() throws -> String {
        let candidates = ["/opt/homebrew/bin/sops", "/usr/local/bin/sops", "/usr/bin/sops"]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProjectFixture.FixtureError("no sops binary found in \(candidates)")
        }
        return found
    }

    /// Encrypts `plain` with the real `sops` command-line binary — not the
    /// in-process bridge, and not a hand-written approximation of sops
    /// output. Only public keys cross this boundary: `--age` takes
    /// recipients, so no identity and no environment variable is involved
    /// (CLAUDE.md's key-material constraint).
    private static func encryptedWithRealCLI(_ plain: String, to recipients: [String]) throws -> String {
        let scratch = try ProjectFixture.makeDirectory("crlf-encrypt")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("plain.yaml")
        try plain.write(to: source, atomically: true, encoding: .utf8)
        return try ProjectFixture.run(
            try sopsCLIPath(),
            ["--encrypt", "--age", recipients.joined(separator: ","), source.path])
    }

    /// Rewrites every line ending as CRLF, whatever it was before — the
    /// exact transformation an editor round-trip, a Windows checkout, or
    /// `git config core.autocrlf=true` performs on a file sops wrote with
    /// bare LF.
    static func crlf(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - The reported bug, end to end

    /// The headline case. A genuinely healthy file — encrypted by the real
    /// CLI to exactly the key `.sops.yaml` declares — must not be reported as
    /// missing that key just because its line endings changed.
    @Test("a CRLF sops file encrypted to the declared key is not falsely accused of missing it")
    func crlfFileIsNotFalselyAccused() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory("crlf-project")
        defer { try? FileManager.default.removeItem(at: root) }

        try ProjectFixture.write("""
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(key.public)
            """, to: root, at: ".sops.yaml")

        let encrypted = try Self.encryptedWithRealCLI(
            "password: hunter2\napi_key: sk-live-abc123\n", to: [key.public])
        // Sanity: the fixture is only meaningful if the conversion actually
        // produced CRLF and left no bare LF behind.
        let converted = Self.crlf(encrypted)
        let scalars = Array(converted.unicodeScalars)
        #expect(scalars.contains("\r"), "fixture precondition: the conversion produced no CR at all")
        #expect(!scalars.indices.contains { scalars[$0] == "\n" && ($0 == 0 || scalars[$0 - 1] != "\r") },
                "fixture precondition: every line ending must be CRLF, no bare LF left")
        try ProjectFixture.write(converted, to: root, at: "secrets/prod.yaml")

        let check = ProjectHealthCheck(source: FixedProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let recipients = try #require(findings.first { $0.id.hasSuffix("stale-recipients") })

        #expect(!recipients.detail.contains("does not list"),
                "a CRLF file that lists the declared key was reported as not listing it: \(recipients.detail)")
        #expect(recipients.status == .ok,
                "expected .ok for a healthy CRLF file, got \(recipients.status): \(recipients.detail)")
    }

    /// A real mismatch must still be a mismatch under CRLF — the fix must not
    /// buy its way out of the false accusation by finding nothing at all.
    @Test("a CRLF sops file encrypted to the wrong key is still reported as a mismatch")
    func crlfFileWithWrongKeyIsStillCaught() async throws {
        let declared = try ProjectFixture.ageKeyPair()
        let actual = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory("crlf-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }

        try ProjectFixture.write("""
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(declared.public)
            """, to: root, at: ".sops.yaml")

        let encrypted = try Self.encryptedWithRealCLI("password: hunter2\n", to: [actual.public])
        try ProjectFixture.write(Self.crlf(encrypted), to: root, at: "secrets/prod.yaml")

        let check = ProjectHealthCheck(source: FixedProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let recipients = try #require(findings.first { $0.id.hasSuffix("stale-recipients") })

        #expect(recipients.status == .problem)
        #expect(recipients.detail.contains(actual.public))
        #expect(recipients.detail.contains(declared.public))
    }

    // MARK: - The parser directly

    @Test("EncryptedFileMetadata.recipients reads a CRLF file's recipients")
    func recipientsSurviveCRLF() throws {
        let key = try ProjectFixture.ageKeyPair()
        let encrypted = try Self.encryptedWithRealCLI("password: hunter2\n", to: [key.public])

        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: encrypted) == [key.public])
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: Self.crlf(encrypted)) == [key.public])
    }

    /// The block scoping that `EncryptedFileMetadata`'s doc comment exists to
    /// protect must survive the CRLF fix. Splitting correctly but forgetting
    /// to stop at the end of the `sops:` block would swallow a user's own
    /// plaintext `recipient:` field — the exact bug that scoping was added
    /// for, reintroduced by a careless line-ending fix.
    @Test("the sops: block stays scoped under CRLF — a plaintext recipient field is not a sops recipient")
    func blockScopingSurvivesCRLF() throws {
        let key = try ProjectFixture.ageKeyPair()
        // `recipient` is an ordinary field name; sops encrypts values, never
        // keys, so it survives encryption verbatim as `recipient: ENC[...]`.
        let encrypted = try Self.encryptedWithRealCLI(
            "recipient: alice@example.invalid\npassword: hunter2\n", to: [key.public])
        #expect(encrypted.contains("recipient: ENC["),
                "fixture precondition: sops must leave the plaintext field name in place")

        let found = EncryptedFileMetadata.recipients(inEncryptedFile: Self.crlf(encrypted))
        #expect(found == [key.public])
        #expect(!found.contains { $0.hasPrefix("ENC[") })
    }

    @Test("EncryptedFileMetadata.nonAgeBackends reads a CRLF block")
    func nonAgeBackendsSurviveCRLF() {
        let block = """
            data: ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]
            sops:
                kms:
                    - arn: arn:aws:kms:eu-west-1:000000000000:key/abc
                age: []
                lastmodified: "2026-08-08T00:00:00Z"
                mac: ENC[AES256_GCM,data:m,iv:n,tag:o,type:str]
                version: 3.13.3
            """
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: block) == ["kms"])
        #expect(EncryptedFileMetadata.nonAgeBackends(inEncryptedFile: Self.crlf(block)) == ["kms"])
    }

    // MARK: - The shared helper, and the other newline-blind predicates

    @Test("LineEndings.lines splits LF, CRLF, CR and a mixture the same way")
    func lineEndingsHelperHandlesEveryConvention() {
        #expect(LineEndings.lines(of: "a\nb\nc") == ["a", "b", "c"])
        #expect(LineEndings.lines(of: "a\r\nb\r\nc") == ["a", "b", "c"])
        #expect(LineEndings.lines(of: "a\rb\rc") == ["a", "b", "c"])
        #expect(LineEndings.lines(of: "a\r\nb\nc\rd") == ["a", "b", "c", "d"])
        // Empty lines are kept: the `sops:` block scan depends on seeing them.
        #expect(LineEndings.lines(of: "a\r\n\r\nb") == ["a", "", "b"])
        #expect(LineEndings.lines(of: "a\r\n") == ["a", ""])
        #expect(LineEndings.lines(of: "") == [""])
    }

    /// `ShellQuoting` refuses a filename that spans lines rather than
    /// escaping it. A name broken by CRLF spans lines exactly as one broken
    /// by LF does, and the refusal has to see it: a "single-line" command
    /// that silently contains a line break is precisely the unfollowable
    /// remediation the refusal exists to prevent.
    @Test("ShellQuoting refuses a CRLF-broken filename, not just an LF-broken one")
    func shellQuotingRefusesCRLFNames() {
        #expect(ShellQuoting.singleQuoted("a\nb.env") == nil)
        #expect(ShellQuoting.singleQuoted("a\r\nb.env") == nil)
        #expect(ShellQuoting.singleQuoted("a\rb.env") == nil)
        #expect(ShellQuoting.singleQuotedList(["ok.env", "a\r\nb.env"]) == nil)
        #expect(ShellQuoting.singleQuoted("ordinary.env") == "'ordinary.env'")
    }

    /// The note the plaintext-leak finding attaches when a filename cannot be
    /// named on one line has the same requirement.
    @Test("nameSpansLines sees a CRLF break")
    func nameSpansLinesSeesCRLF() {
        #expect(ProjectHealthCheck.nameSpansLines("a\nb.env"))
        #expect(ProjectHealthCheck.nameSpansLines("a\r\nb.env"))
        #expect(ProjectHealthCheck.nameSpansLines("a\rb.env"))
        #expect(!ProjectHealthCheck.nameSpansLines("ordinary.env"))
    }

    /// `ToolLocator.parseVersion` tokenises a tool's own stdout. A tool that
    /// prints CRLF is unusual on macOS but not impossible (anything shipped
    /// as a cross-platform binary, anything piped through a converter), and
    /// the cost of tolerating it is nil.
    @Test("parseVersion tokenises CRLF output")
    func parseVersionHandlesCRLF() {
        #expect(ToolLocator.parseVersion(from: "sops\r\n3.13.3\r\n") == SemanticVersion(3, 13, 3))
        #expect(ToolLocator.parseVersion(from: "sops 3.13.3\n") == SemanticVersion(3, 13, 3))
    }

    /// JSON metadata detection skips whitespace between `"sops":` and the `{`
    /// that proves it names an object. A CRLF-converted JSON file puts
    /// exactly that whitespace there.
    @Test("JSON sops metadata is recognised across a CRLF break after the colon")
    func jsonMetadataAcrossCRLF() {
        let json = "{\n  \"data\": \"ENC[x]\",\n  \"sops\":\n  {\n    \"mac\": \"ENC[y]\",\n    \"version\": \"3.13.3\"\n  }\n}"
        #expect(SopsMetadataShape.isNonYAMLMetadata(json))
        #expect(SopsMetadataShape.isNonYAMLMetadata(CRLFToleranceTests.crlf(json)))
    }

    // MARK: - The standing guard against a fourth occurrence

    /// Scans this package's own `Sources/` for the idioms that caused all
    /// four occurrences, so the next one fails a test instead of shipping.
    ///
    /// A guard, not a helper, is the anti-recurrence measure that actually
    /// works here. `LineEndings` exists and is used — but every one of the
    /// four bugs was written by someone who reached for `"\n"` out of habit
    /// and never looked for a helper, so a helper alone would have prevented
    /// none of them. What stops the habit is the build going red at the
    /// moment the habit is exercised.
    ///
    /// The scanning itself lives in `NewlineBlindness`, whose header explains
    /// why this is a tokeniser and not the line-oriented grep it used to be:
    /// thirteen ways of writing the same bug were injected into a copy of the
    /// package, and the grep let twelve of them through — including one that
    /// `swift-format` produces on its own, just by breaking a call across two
    /// lines.
    ///
    /// Comments are removed before anything is matched, rather than skipped a
    /// line at a time: `SessionKeyStore`, `SopsMetadataShape` and
    /// `LineEndings` all *describe* the wrong idiom at length in their doc
    /// comments, which is exactly the documentation this guard wants to keep.
    /// That is also why there is no longer any per-file exemption — see
    /// `NewlineBlindness.offences(in:named:)`.
    @Test("no newline-blind idiom survives anywhere in Sources/")
    func sourcesContainNoNewlineBlindIdioms() throws {
        let sources = Self.packageSources
        #expect(FileManager.default.fileExists(atPath: sources.path),
                "sanity: expected this package's Sources at \(sources.path)")

        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey]))
        var offences: [NewlineBlindness.Offence] = []
        var filesScanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            filesScanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            offences += NewlineBlindness.offences(in: text, named: relative)
        }

        #expect(filesScanned > 20, "sanity: the guard scanned only \(filesScanned) source files")
        #expect(offences.isEmpty, """
            Newline-blind idiom(s) found. Swift treats "\\r\\n" as ONE Character, so \
            comparing against the Character "\\n" silently does nothing on a CRLF file. \
            Use LineEndings.lines(of:), \\.isNewline or \\.isWhitespace instead.
            \(offences.map(\.description).joined(separator: "\n"))
            """)
    }

    /// …/Tests/SopsHealthTests/<this file> → …/Sources
    static let packageSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SopsHealthTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // SopsGUIKit
        .appendingPathComponent("Sources")

    /// The guard's own guard.
    ///
    /// Every case here is a way the *previous*, line-oriented guard was
    /// actually evaded when thirteen variants of the bug were injected into a
    /// copy of the package — twelve of which it passed. They are cases in a
    /// test rather than a paragraph in a report, because the whole lesson of
    /// that exercise is that "we checked by hand once" is not a property.
    ///
    /// Case 10 is the file-name evasion: the old guard skipped any file whose
    /// *basename* was `LineEndings.swift`, so adding a second file with that
    /// name anywhere in the tree bought a blanket exemption. It is asserted
    /// here by passing that very name, which must make no difference at all.
    @Test("the guard catches every evasion that got past the grep it replaced",
          arguments: [
            // 1 — the original, which the grep did catch.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.split(separator: "\n") }"#),
            // 2 — a CharacterSet that is not blind but invents a blank line
            //     after every CRLF-terminated one.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.components(separatedBy: .newlines) }"#),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.components(separatedBy: CharacterSet.newlines) }"#),
            // 3 — the same call, reformatted. swift-format defeats a
            //     line-oriented guard on its own.
            (name: "Whatever.swift",
             code: """
                func f(_ text: String) {
                    _ = text.split(
                        separator: "\\n")
                }
                """),
            // 4 — one space short of the banned string.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.components(separatedBy:"\n") }"#),
            // 5 — the literal never appears next to the call.
            (name: "Whatever.swift",
             code: """
                func f(_ text: String) {
                    let sep: Character = "\\n"
                    _ = text.split(separator: sep)
                }
                """),
            // 5b — same trick without the type annotation.
            (name: "Whatever.swift",
             code: """
                func f(_ text: String) {
                    let sep = "\\r\\n"
                    _ = text.components(separatedBy: sep)
                }
                """),
            // 6, 7, 8 — consumers nobody had listed.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.firstIndex(of: "\n") }"#),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.lastIndex(of: "\n") }"#),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.range(of: "\n") }"#),
            // 9 — a predicate rather than a separator.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.filter { $0 != "\n" } }"#),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.split(whereSeparator: { $0 == "\n" }) }"#),
            // 10 — the basename exemption. This name must buy nothing.
            (name: "LineEndings.swift",
             code: #"func f(_ text: String) { _ = text.split(separator: "\n") }"#),
            // 11, 12 — prefix/suffix probes.
            (name: "Whatever.swift",
             code: ##"func f(_ text: String) -> Bool { text.hasSuffix("\r\n") }"##),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) -> Bool { text.contains("\nsops:") }"#),
            // 13 — argument order the grep's fixed string could not survive.
            (name: "Whatever.swift",
             code: #"func f(_ text: String) { _ = text.split(maxSplits: 2, separator: "\n") }"#),
            // Extras: a `case` label, and the bug hidden inside an
            // interpolation, which a text scan of the file never enters.
            (name: "Whatever.swift",
             code: """
                func f(_ c: Character) -> Bool {
                    switch c { case "\\n": return true; default: return false }
                }
                """),
            (name: "Whatever.swift",
             code: #"func f(_ text: String) -> String { "lines: \(text.split(separator: "\n").count)" }"#),
          ])
    func guardCatchesKnownEvasions(evasion: (name: String, code: String)) {
        let offences = NewlineBlindness.offences(in: evasion.code, named: evasion.name)
        #expect(!offences.isEmpty, """
            this evasion was not caught:
            \(evasion.code)
            """)
    }

    /// The other half of a guard worth having: it must not cry wolf, or the
    /// next person to hit it will add an exemption instead of a fix.
    ///
    /// Everything here is an idiom that is genuinely present in `Sources/`
    /// today, or genuinely correct. `Data("\nsops:".utf8)` in particular is
    /// the one this project must keep: over *bytes* `\r\n` really is two of
    /// them, so an LF-anchored byte marker matches a CRLF document correctly.
    @Test("the guard is silent on the writing and byte-level idioms Sources actually uses",
          arguments: [
            #"let detail = mismatches.joined(separator: "\n")"#,
            #"let marker = Data("\nsops:".utf8)"#,
            #"detail += "\n\nAlready tracked by git: \(names.joined(separator: ", "))""#,
            #"print("\n\(count) snapshots written")"#,
            ##"try "# nothing encrypted here yet\n".write(to: url, atomically: true, encoding: .utf8)"##,
            #"let lines = LineEndings.lines(of: text)"#,
            #"let parts = text.split(whereSeparator: \.isNewline)"#,
            #"let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)"#,
            #"let tokens = text.components(separatedBy: .whitespacesAndNewlines)"#,
            // Comments describing the bug are documentation, not the bug.
            #"// text.split(separator: "\n") is the mistake this file exists to prevent"#,
            #"/// - `text.contains("\nsops:")` never matches on a CRLF document"#,
            "/* text.split(separator: \"\\n\") */ let x = 1",
          ])
    func guardIsSilentOnLegitimateIdioms(line: String) {
        let offences = NewlineBlindness.offences(in: line, named: "Whatever.swift")
        #expect(offences.isEmpty, """
            false positive on a legitimate idiom:
            \(line)
            \(offences.map(\.description).joined(separator: "\n"))
            """)
    }

    /// Where the guarantee stops. Not aspirational notes — executable cases,
    /// asserting the *current* behaviour, so that the boundary is visible and
    /// a future change that moves it fails here and gets thought about.
    ///
    /// Both need the newline to be *constructed* rather than written, which is
    /// a step past reaching for `"\n"` out of habit — the failure mode all four
    /// historical occurrences shared and the only one this guard claims.
    /// Closing them needs a real Swift parser with constant folding; see
    /// `NewlineBlindness`'s header for why `swift-syntax` was not taken on.
    ///
    /// A third limit is structural rather than syntactic and has no case here:
    /// the guard scans `Sources/` only. `Tests/` writes `"\n"` legitimately in
    /// almost every fixture, so the same ban there would be all noise — and
    /// that is exactly how two tests in this very suite came to assert nothing
    /// under CRLF (`ExternalToolNetworkTests`' single-line check and
    /// `ProjectScanBOMTests`' `!contains("\nsops:")` precondition). Those are
    /// fixed by hand, at the source, and stay a reviewer's job.
    @Test("known blind spots, stated rather than implied",
          arguments: [
            // A scalar escape spells the same character without spelling the
            // same literal.
            #"func f(_ t: String) { _ = t.split(separator: "\u{0A}") }"#,
            // Built at runtime.
            #"func f(_ t: String) { _ = t.split(separator: Character(UnicodeScalar(10))) }"#,
          ])
    func guardStillMissesTheseAndWeKnowIt(line: String) {
        #expect(NewlineBlindness.offences(in: line, named: "Whatever.swift").isEmpty,
                "this blind spot has been closed — good; delete the case and say so in NewlineBlindness's header")
    }
}

private struct FixedProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}
