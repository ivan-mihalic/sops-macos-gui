import Foundation
import SopsEngine

/// A proposed `.sops.yaml` for a project that has none yet — text a caller
/// may write, and only ever a caller's decision to write it.
///
/// The shape deliberately mirrors `ConfigRecipientUpdate`
/// (`SopsBridge.swift:43-89`): `verified`/`reason`/`text` plays the same role
/// `writable`/`reason`/`config` plays there — a refusal never hands back
/// something a caller could write. `text` is empty exactly when `verified`
/// is `false`; `reason` is empty exactly when `verified` is `true`. Two
/// different shapes for the identical problem — "here is a proposal, or here
/// is why not" — would drift from each other over time, so this type does
/// not invent a second one.
public struct ProposedConfig: Equatable, Sendable {
    /// The complete proposed `.sops.yaml` text.
    public let text: String
    /// Whether sops's own config parser, asked about this exact text, agrees
    /// it governs the target file and resolves to exactly the requested
    /// recipients. See `SopsConfigGenerator`'s doc comment, "Why `verified`
    /// is proven, not asserted", for how this is established.
    public let verified: Bool
    /// A whole sentence for a user: what went wrong. Never carries a
    /// recipient value or any document content — only sops's own diagnostic
    /// text or a fixed sentence naming the mismatch.
    public let reason: String

    public init(text: String, verified: Bool, reason: String) {
        self.text = text
        self.verified = verified
        self.reason = reason
    }
}

/// Proposes a `.sops.yaml` that would govern one not-yet-existing target
/// file, for exactly the age recipients a caller names.
///
/// **Never writes.** A project with no `.sops.yaml` cannot say who its
/// secrets should be encrypted to, so nothing in this app may create a
/// secret file there until someone decides what the config should say — and
/// deciding is not the same act as writing it down, nor the same act as
/// creating a file under it. `SecretFileCreator`, `CreationPlanResolver` and
/// `ProjectRecipientApplier` each already keep exactly one of those three
/// acts to itself; this type keeps the first. Phase 2's wizard shows
/// `ProposedConfig.text` to the user and, only on their explicit
/// confirmation, writes it with `AtomicFileWriter.write(_:to:expecting:
/// .absent)` — a separate call this type never makes and does not import
/// the ability to make.
///
/// ## Why `verified` is proven, not asserted
///
/// A generator that hands back YAML it believes is correct, on the strength
/// of its own string-building, is worth little — the one thing worth
/// promising here is that the proposal *works*, and the only honest way to
/// know that is to ask the same parser sops itself uses, not to re-derive
/// the answer in Swift (ADR 0002's rule against reimplementing what sops's
/// own code already does correctly applies here exactly as it does to YAML
/// or config parsing elsewhere in this app).
///
/// So before any `ProposedConfig` is returned, its `text` is staged as a
/// real file — `.sops.yaml.<UUID>.tmp`, in `projectRoot` itself — and handed
/// to `SopsBridge.lookupCreationRule(configPath:targetFilePath:)`, the exact
/// bridge call every other consumer of `.sops.yaml` in this app goes
/// through. `verified` is `true` only when that call reports `matched ==
/// true` *and* the resolved `ageRecipients` equal the requested set — a
/// rule that matches the wrong file, or matches the right file but resolves
/// to different keys because of a typo this generator itself introduced,
/// both fail this check.
///
/// The staging directory is not incidental: `lookupCreationRule` matches a
/// rule's `path_regex` against the target *relative to the config's own
/// directory*, by stripping that directory as a literal prefix (see that
/// call's own doc comment). Staging anywhere else would make sops check the
/// proposal against a directory this generator did not derive `path_regex`
/// from, which would either falsely fail a good proposal or — worse —
/// falsely pass a bad one against an unrelated coincidence of paths.
///
/// The temp file is removed on every exit from the verification step —
/// success, a mismatch, or the bridge throwing — so a caller that retries
/// this repeatedly (a wizard where a user is still typing a target path)
/// never leaves a stray probe file behind for a later, real `.sops.yaml`
/// write to trip over. `ProjectHealthCheck.swift`'s
/// `.sops-health-check-probe` establishes the identical technique for the
/// identical reason: neither type ever intends the target path to exist, so
/// there is no I/O risk in choosing a synthetic name inside a directory that
/// does have to be real.
///
/// Anything that keeps the proposal from being proven — the bridge refusing
/// to parse the staged text, a mismatched rule, a mismatched recipient set —
/// comes back as `ProposedConfig(text: "", verified: false, reason: …)`,
/// never a thrown error: see `ProposedConfig`'s own doc comment for why a
/// second failure shape here would drift from `ConfigRecipientUpdate`'s.
/// `propose(forTarget:in:recipients:)` still `throws`, but only for the
/// `Error` cases below, which are caller mistakes rather than proposals
/// that failed to verify — the same split `CreationPlanResolver.Error` and
/// `SecretFileCreator.Failure` already make for the identical shapes of
/// mistake.
///
/// ## `path_regex` is escaped, not interpolated
///
/// The target's path relative to `projectRoot` is turned into `path_regex`
/// through `NSRegularExpression.escapedPattern(for:)`, anchored with `^`/`$`,
/// never spliced in as a literal string. A literal `.` — present in almost
/// every real target, `secrets/prod.yaml` among them — is a regex
/// metacharacter meaning "any character": an unescaped rule for
/// `secrets/prod.yaml` would also govern `secrets/prodXyaml` or any other
/// same-length sibling, silently widening which files this app hands a
/// given set of recipients to. Which files a rule governs is who can read
/// them, so this is not a cosmetic detail.
///
/// ## Containment is enforced here, independently of `SecretFileCreator`
///
/// `SecretFileCreator.refuseIfOutsideProject` already refuses a `..`
/// component and requires `projectRoot` to exist as a real directory before
/// it ever writes a secret file — the obvious question is why this type
/// repeats that rather than leaning on it. The answer is that this type's
/// output is not a file `SecretFileCreator` — or anything else in this
/// app — ever opens again. It is a **`.sops.yaml` written into the user's
/// own repository**, where it outlives this app's control entirely: the real
/// `sops` CLI, CI, and a colleague's editor all read it later, and none of
/// them inherit `SecretFileCreator`'s guard. A `path_regex` built from a
/// target path containing a literal `..` component is a rule whose meaning
/// depends on where it happens to be evaluated from — not a hazard this type
/// gets to bound by pointing at what a sibling type in this same process
/// would have refused. So `target` is checked for a literal `..` component,
/// and `projectRoot` is required to exist and be a directory, before
/// anything is staged — the same two guards `refuseIfOutsideProject`
/// applies, in the same order, before its own write.
///
/// One thing is deliberately *not* copied from `refuseIfOutsideProject`:
/// symlink-aware canonicalization (`CanonicalPath.of` plus
/// `canonicalizedForContainment`'s walk-upward-to-an-existing-ancestor
/// trick). `relativePath(of:in:)` below strips `projectRoot` as a literal
/// string prefix, never resolving symlinks — because that is exactly what
/// `SopsBridge.lookupCreationRule` itself does when it later strips
/// `configPath`'s directory to match `path_regex` (see that call's own doc
/// comment). Resolving symlinks here would make this type check `target`
/// against a *different* string than the one the bridge verifies it
/// against a moment later — the literal `..` refusal closes the one escape
/// that distinction would otherwise leave open, without introducing a
/// second, disagreeing notion of "inside".
public enum SopsConfigGenerator {

    /// Thrown before `.sops.yaml` is ever staged: when `target` or
    /// `projectRoot` is not an absolute path, when `projectRoot` does not
    /// exist as a real directory, or when `target` does not lie inside
    /// `projectRoot` — including via a literal `..` path component, which is
    /// refused outright rather than resolved, for the identical reason
    /// `SecretFileCreator.Failure.destinationOutsideProject`'s doc comment
    /// gives ("Why `..` is refused rather than resolved"): there is no safe
    /// way to resolve a `..` that might follow a symlink without
    /// re-deriving the kernel's own path-walking order in Swift, which ADR
    /// 0002 already rules out doing by hand.
    ///
    /// This is not optional defensive coding — it is the same discipline
    /// `CreationPlanResolver.Error` and `SecretFileCreator.Failure` already
    /// established for the identical shapes of mistake, and for the same
    /// reason: `SopsBridge.lookupCreationRule` matches `path_regex` against
    /// the target *relative to the config's own directory*, computed by
    /// stripping that directory as a literal prefix. A relative or
    /// differently-rooted path does not error there, it silently fails to
    /// strip and produces a confident, wrong verification result instead —
    /// so the check has to live here, before any text is even built,
    /// because a `path_regex` derived from a target outside `projectRoot`
    /// is not a proposal this type can honestly make in the first place.
    /// See this type's own doc comment, "Containment is enforced here,
    /// independently of `SecretFileCreator`", for why a `..` in `target`
    /// is not merely a caller mistake this app happens to guard against
    /// elsewhere: the config this type proposes outlives this app and is
    /// read by tools that have no such guard of their own.
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case targetNotAbsolute(String)
        case projectRootNotAbsolute(String)
        case projectRootDoesNotExist(String)
        case targetOutsideProjectRoot(String)

        public var description: String {
            switch self {
            case .targetNotAbsolute(let path):
                return "the target path \(path) is not absolute, so no .sops.yaml could be proposed for it"
            case .projectRootNotAbsolute(let path):
                return "the project root \(path) is not absolute, so no .sops.yaml could be proposed for it"
            case .projectRootDoesNotExist(let path):
                return "the project root \(path) does not exist or is not a directory, so no .sops.yaml "
                    + "could be proposed for it"
            case .targetOutsideProjectRoot(let path):
                return "the target path \(path) does not lie inside the project root, so no project-relative "
                    + "path_regex could be derived for it"
            }
        }
    }

    /// The filename every staged probe uses while it is verified, sharing
    /// its `.sops.yaml.` prefix and `.tmp` suffix so a caller can recognize
    /// — and a cleanup pass could recognize — what these are, if one ever
    /// survives a crash between the write and the `defer` below.
    private static func probeFilename() -> String {
        ".sops.yaml.\(UUID().uuidString).tmp"
    }

    /// Proposes a `.sops.yaml` whose sole creation rule would govern
    /// `target`, encrypting it to exactly `recipients`. See this type's doc
    /// comment for the full account of why the result is proven against
    /// sops's own parser rather than trusted, and why this never writes
    /// anything a caller did not ask it to.
    ///
    /// `target` and `projectRoot` must both be absolute paths, `projectRoot`
    /// must exist as a real directory, and `target` must lie inside
    /// `projectRoot` with no literal `..` component anywhere in it — throws
    /// `Error` otherwise, before `.sops.yaml` is ever staged. `target` itself
    /// need not exist: this proposes a config for a file that is not there
    /// yet. See this type's doc comment, "Containment is enforced here,
    /// independently of `SecretFileCreator`", for why these checks are not
    /// borrowed from that sibling type instead.
    public static func propose(
        forTarget target: URL,
        in projectRoot: URL,
        recipients: [String]
    ) throws -> ProposedConfig {
        guard target.path.hasPrefix("/") else {
            throw Error.targetNotAbsolute(target.path)
        }
        guard projectRoot.path.hasPrefix("/") else {
            throw Error.projectRootNotAbsolute(projectRoot.path)
        }
        try Self.requireProjectRootExists(projectRoot)
        try Self.refuseDotDotComponent(in: target)

        let relativeTargetPath = try Self.relativePath(of: target, in: projectRoot)
        let pathRegex = "^" + NSRegularExpression.escapedPattern(for: relativeTargetPath) + "$"
        let text = Self.configText(pathRegex: pathRegex, recipients: recipients)

        return Self.verify(text, forTarget: target, in: projectRoot, recipients: recipients)
    }

    // MARK: - Containment

    /// `projectRoot` has to be a real, present directory, or "inside
    /// `projectRoot`" is not a claim the prefix check in `relativePath(of:
    /// in:)` can honestly make — a project root that does not exist yet
    /// makes that check vacuously true against any literal path sharing its
    /// spelling. The identical guard `SecretFileCreator
    /// .refuseIfOutsideProject` applies before its own write, for the
    /// identical reason.
    private static func requireProjectRootExists(_ projectRoot: URL) throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Error.projectRootDoesNotExist(projectRoot.path)
        }
    }

    /// Refuses any literal `..` path component in `target`, before anything
    /// tries to treat `target` as being inside `projectRoot` at all. See
    /// this type's doc comment, "Containment is enforced here, independently
    /// of `SecretFileCreator`", and `SecretFileCreator.Failure
    /// .destinationOutsideProject`'s own doc comment ("Why `..` is refused
    /// rather than resolved") for the full account of why resolving it
    /// instead is not a safe option.
    private static func refuseDotDotComponent(in target: URL) throws {
        guard !target.path.split(separator: "/").contains("..") else {
            throw Error.targetOutsideProjectRoot(target.path)
        }
    }

    // MARK: - path_regex derivation

    /// `target`'s path relative to `projectRoot`, computed the same way
    /// `SopsBridge.lookupCreationRule` computes it — stripping `projectRoot`
    /// as a literal string prefix, never resolving symlinks first, so the
    /// `path_regex` this builds is checked against the identical string the
    /// bridge will strip when it verifies this exact proposal a moment
    /// later. Throws `Error.targetOutsideProjectRoot` when `target` does not
    /// share that literal prefix at all. Only ever called after
    /// `refuseDotDotComponent` has already refused any `..` component, so
    /// there is nothing left here for the literal-prefix check to
    /// mishandle.
    private static func relativePath(of target: URL, in projectRoot: URL) throws -> String {
        let rootPath = projectRoot.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.path.hasPrefix(prefix) else {
            throw Error.targetOutsideProjectRoot(target.path)
        }
        return String(target.path.dropFirst(prefix.count))
    }

    // MARK: - Text

    private static func configText(pathRegex: String, recipients: [String]) -> String {
        """
        creation_rules:
          - path_regex: \(pathRegex)
            age: \(recipients.joined(separator: ","))

        """
    }

    // MARK: - Verification

    /// Proves `text` actually works before it is ever handed back. See this
    /// type's doc comment, "Why `verified` is proven, not asserted", for the
    /// full account; this is that account's implementation.
    ///
    /// The staged probe file is removed on every exit — the `defer` runs
    /// whether `lookupCreationRule` succeeds, reports a mismatch, or throws,
    /// and covers the write itself failing too, so nothing about how this
    /// call ends leaves a `.sops.yaml.*.tmp` behind in a real project's
    /// root.
    private static func verify(
        _ text: String,
        forTarget target: URL,
        in projectRoot: URL,
        recipients: [String]
    ) -> ProposedConfig {
        let probeURL = projectRoot.appendingPathComponent(Self.probeFilename())
        defer { try? FileManager.default.removeItem(at: probeURL) }

        do {
            try text.write(to: probeURL, atomically: true, encoding: .utf8)
            let lookup = try SopsBridge.lookupCreationRule(
                configPath: probeURL.path, targetFilePath: target.path)

            guard lookup.matched else {
                return ProposedConfig(
                    text: "", verified: false,
                    reason: "The proposed creation rule does not match \(target.lastPathComponent) when "
                        + "sops itself checks it.")
            }
            guard Set(lookup.ageRecipients) == Set(recipients) else {
                return ProposedConfig(
                    text: "", verified: false,
                    reason: "The proposed creation rule resolves to a different recipient set than "
                        + "requested when sops itself checks it.")
            }
            return ProposedConfig(text: text, verified: true, reason: "")
        } catch let error as SopsBridgeError {
            return ProposedConfig(text: "", verified: false, reason: error.description)
        } catch {
            // Not expected in practice — staging a file this type just built
            // the text for should not fail to write — but a caller must
            // never see this function fail silently for a type it did not
            // anticipate; see the identical discipline in
            // `CreationPlanResolver.plan(forTarget:in:)`'s own catch-all.
            return ProposedConfig(
                text: "", verified: false,
                reason: "The proposed .sops.yaml could not be staged for verification.")
        }
    }
}
