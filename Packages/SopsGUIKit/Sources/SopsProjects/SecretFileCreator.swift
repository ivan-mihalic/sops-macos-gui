import Darwin
import Foundation
import SopsEngine
import SopsHealth

/// The age recipient set, `encrypted_regex` scope, and self-readability
/// acknowledgement a caller has already resolved for a not-yet-existing
/// secret file.
///
/// `SecretFileCreator` never derives this itself — `recipients` and
/// `encryptedRegex` normally come from `CreationPlanResolver`'s
/// `.governedByRule` (Task 5) or from a user's manual picker when no rule
/// matches, but this type takes whatever it is handed and never reads
/// `.sops.yaml` on its own. See `SecretFileCreator`'s own doc comment,
/// "Why this never resolves its own plan", for why that boundary is kept.
public struct ResolvedEncryption: Equatable, Sendable {
    public let recipients: [String]
    public let encryptedRegex: String
    /// Set by a caller who has explicitly chosen to create a file the
    /// current session identity cannot read back. See `Failure
    /// .wouldBeUnreadable` and this type's "Self-readability is the
    /// default" section for what setting this trades away.
    public let acknowledgedUnreadable: Bool

    public init(recipients: [String], encryptedRegex: String, acknowledgedUnreadable: Bool) {
        self.recipients = recipients
        self.encryptedRegex = encryptedRegex
        self.acknowledgedUnreadable = acknowledgedUnreadable
    }
}

/// Creates a brand-new SOPS secret file — from a parsed `.env`, from pasted
/// YAML, or empty — and never lets it exist on disk unless it has already
/// been proven readable.
///
/// ## The order is the whole point (spec §3.5)
///
/// 1. Canonicalize `destination` and refuse anything that resolves outside
///    `projectRoot` — a `..` escape, an absolute path elsewhere entirely, or
///    a symlink (the destination itself, or a directory on the way to it)
///    that leads out of the project.
/// 2. `lstat` the destination; if anything is already there, refuse.
/// 3. If the recipient set cannot be proven to include this session's own
///    identity and the caller has not acknowledged that, refuse. See
///    "Self-readability is the default" below for why this step's *check*
///    physically has to run after step 6 in this implementation, even
///    though it is numbered before the steps that build and encrypt the
///    document.
/// 4. Turn `source` into plaintext YAML.
/// 5. Encrypt it for `plan.recipients`.
/// 6. Round-trip it — decrypt what was just produced and compare against
///    what was meant to be written. See "The round trip is semantic, not
///    byte-for-byte" below.
/// 7. Create any missing intermediate directories, mode `0700`.
/// 8. `AtomicFileWriter.write(_:to:expecting: .absent)` — the one step that
///    touches disk.
///
/// Steps 1–6 never touch disk and never write anything. A file that fails
/// any check above simply never existed — there is no delete-on-failure path
/// anywhere in this type, because there is nothing to delete: nothing was
/// ever there.
///
/// ## Self-readability is the default, and the check happens where the
/// answer actually exists
///
/// A recipient set that does not include this session's own identity means
/// the app cannot verify what it is about to produce, and it is also the
/// cheapest catch there is for a typo in an `age1…` recipient — one that
/// would otherwise surface only when someone actually needs the file.
/// `ResolvedEncryption.acknowledgedUnreadable` is how a caller opts out of
/// this explicitly; `Failure.wouldBeUnreadable` is the refusal when they have
/// not.
///
/// The spec numbers this check as step 3, before the document is even built.
/// This implementation cannot honor that literally: there is no bridge call
/// that derives an age *public* key from a private identity, and this app
/// does not hand-roll X25519/bech32 to invent one — ADR 0002's rule against
/// reimplementing what sops's own code already does correctly applies just
/// as much to a recipient-membership test as it does to YAML or config
/// parsing. The only answer that is actually true to what sops itself would
/// do is the same one step 6 needs anyway: encrypt for `plan.recipients`,
/// then try to decrypt the result with `sessionKey`, and see. So both
/// questions — "can this session read what it is about to create" and "does
/// what comes back match what was meant to be written" — share the one
/// decrypt call in step 6, rather than this type running a second,
/// throwaway encrypt/decrypt against placeholder content purely to answer
/// step 3 a moment earlier. What step 3 actually protects — that nothing
/// below it ever reaches disk before this is resolved — still holds
/// exactly: steps 4 and 5 build and encrypt the document entirely in
/// memory, and the *refusal* itself (`wouldBeUnreadable` or
/// `roundTripMismatch`) is still raised before step 7 ever runs. Only the
/// bookkeeping order of "which in-memory step runs first" differs from the
/// spec's numbering, never what a caller observes.
///
/// When the recipient set cannot be proven readable and the caller has
/// acknowledged that, the round trip's *content* comparison is skipped
/// outright — not attempted and ignored, skipped — because there is no
/// identity here that can decrypt the result to compare against.
///
/// ## The round trip is semantic, not byte-for-byte
///
/// sops normalises its own YAML output — four-space indentation, its own
/// quoting decisions — the moment it re-emits a document, exactly as
/// `ProjectRecipientApplierTests.swift`'s `applierPlainYAML` fixture comment
/// records for the same reason. Comparing `decryptToRows` output against the
/// *input text* would therefore fail for almost any normally-formatted
/// input and report corruption where there is none. Instead, verification
/// goes through `SopsBridge.decryptToRows`, per source:
///
/// | Source | What is checked |
/// |---|---|
/// | `.dotEnv` | Every entry has exactly one row with `path == [key]` and a matching `value`; `rows.count == entries.count`. |
/// | `.verbatimYAML` | `decryptToRows` succeeds and returns a non-empty row list. |
/// | `.empty` | Not compared — there is nothing to compare — but `decryptToRows` still has to succeed for the write to proceed; see step 3/6 above. |
///
/// ## Why this never resolves its own plan
///
/// This type is handed a `ResolvedEncryption`; it never calls
/// `CreationPlanResolver`, never reads `.sops.yaml`, and never derives a
/// recipient list from anything on disk. `ProjectRecipientApplier.swift`'s
/// header states the identical discipline for the identical reason: whoever
/// decides who can read a file has to be an explicit, visible call, never a
/// side effect of creating one.
///
/// ## Containment, including through a symlink that does not exist yet
///
/// `CanonicalPath.of` (Task 6 made it `public` in `SopsHealth` for exactly
/// this — see its own doc comment) resolves symlinks via
/// `resolvingSymlinksInPath()`, which calls `realpath(3)` under the hood.
/// `realpath` requires the *entire* path to exist to resolve anything at
/// all — measured directly: a project containing a real directory symlink
/// `escape -> /outside`, asked to resolve `escape/does-not-exist-yet.yaml`,
/// comes back completely unresolved, `escape` and all, purely because the
/// trailing component is missing. That is exactly backwards for this type,
/// whose entire job is creating files that do not exist yet — a symlinked
/// directory one level below an as-yet-nonexistent leaf, or several levels,
/// would sail past a containment check built on `CanonicalPath.of` alone.
///
/// `canonicalizedForContainment(_:)` below closes that: it walks upward from
/// `destination` until it finds the nearest ancestor that actually exists,
/// resolves *that* through `CanonicalPath.of` — the one place this file ever
/// asks the filesystem to follow a symlink — and reattaches every component
/// below it exactly as spelled, because a path component that does not
/// exist cannot itself be a symlink pointing anywhere. Verified directly
/// against a real symlink in `SecretFileCreatorTests`, for one and for two
/// missing levels below it.
public enum SecretFileCreator {

    public enum Source: Sendable {
        case empty
        case verbatimYAML(String)
        case dotEnv([DotEnvEntry])
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Step 2: something is already at `destination` — a file, a
        /// directory, or a dangling symlink. `path` names the file; nothing
        /// about its contents is ever in reach here, since nothing was ever
        /// read.
        case destinationExists(path: String)
        /// Step 1: `destination` does not resolve to somewhere inside
        /// `projectRoot` — a `..` escape, an absolute path elsewhere, a
        /// symlink out of the project, or a `destination`/`projectRoot` that
        /// was not given as an absolute path in the first place (see
        /// `refuseIfOutsideProject`'s doc comment for why that last case is
        /// folded in here rather than given its own case).
        case destinationOutsideProject(path: String)
        /// Step 6: the recipient set could decrypt what was produced, but
        /// what came back does not match what was meant to be written. No
        /// associated value — see this type's file-level "no secret values"
        /// discipline; a mismatch is a shape a document took, never the
        /// values that made it that shape.
        case roundTripMismatch
        /// Step 3 (see this type's doc comment for why its *check* runs
        /// where step 6 does): the recipient set could not be proven to
        /// include this session's own identity, and the caller has not set
        /// `ResolvedEncryption.acknowledgedUnreadable`.
        case wouldBeUnreadable
        /// Step 5 (or the decrypt in step 3/6, for a bridge failure that is
        /// not simply "this identity cannot read it" — see
        /// `SopsBridgeError`'s own contract): the bridge's own diagnostic.
        /// Fixed, value-free text by the bridge's own construction —
        /// `Engine/gobridge/bridge.go`'s recipient checks name an index,
        /// never the recipient string itself, precisely so a pasted private
        /// key never reaches here.
        case engine(String)
        /// Step 8: `AtomicFileWriter.write` itself refused. Its own
        /// `Error.description` is path- and errno-derived only — see that
        /// type's "Errors never contain the file's contents" section.
        case write(AtomicFileWriter.Error)
    }

    /// The mode intermediate directories are created with in step 7. Owner
    /// only, for the same reason `AtomicFileWriter.modeForNewFiles` is
    /// `0600`: a directory this call creates exists to hold a secrets
    /// document, and a default umask would otherwise make it world-readable
    /// without anything about the call site saying so.
    private static let modeForNewDirectories: Int = 0o700

    /// Creates a new SOPS secret file at `destination` from `source`,
    /// encrypted for `plan.recipients`. See this type's doc comment for the
    /// full account of the step order and why it is the order it is.
    ///
    /// `destination` and `projectRoot` must both be absolute paths — a
    /// relative one is refused as `Failure.destinationOutsideProject` before
    /// anything else runs, the same discipline `CreationPlanResolver`
    /// established for the identical reason (its own doc comment has the
    /// full account): resolving a relative path silently falls back to the
    /// *process's* working directory, which is a confident, wrong answer
    /// about whether a path lies inside a project, not a safe default.
    ///
    /// `sessionKey` must be a native `AGE-SECRET-KEY-1…` identity — the same
    /// contract `SopsBridge.decryptToRows` documents — and is used only for
    /// the duration of this call; nothing here stores, logs, or returns it.
    public static func create(
        _ source: Source,
        plan: ResolvedEncryption,
        at destination: URL,
        in projectRoot: URL,
        sessionKey: String
    ) throws -> AtomicWriteReceipt {
        // 1.
        try refuseIfOutsideProject(destination, projectRoot: projectRoot)

        // 2. A cheap, early duplicate of what `AtomicFileWriter.write(...,
        //    expecting: .absent)` will authoritatively re-check immediately
        //    before the replace (step 8) — see that type's own doc comment
        //    for why the early copy does not make the late one redundant.
        //    Refusing here means a target that already exists never reaches
        //    the encrypt/round-trip work below at all.
        try refuseIfPresent(destination)

        // 4. Never touches disk, never leaves this process.
        let plaintext = Self.plaintext(for: source)

        // 5. For exactly `plan.recipients` — the set a caller resolved,
        //    never one this type derives. See "Why this never resolves its
        //    own plan" above.
        let encrypted: String
        do {
            encrypted = try SopsBridge.encryptYAML(
                plaintext, recipients: plan.recipients, encryptedRegex: plan.encryptedRegex)
        } catch let error as SopsBridgeError {
            throw Failure.engine(error.description)
        }

        // 3 & 6, together — see this type's doc comment, "Self-readability
        // is the default", for why the check that spec §3.5 numbers as step
        // 3 can only be *answered* here, one decrypt call shared with step
        // 6's own verification.
        let rows: [SecretRow]?
        do {
            rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: sessionKey)
        } catch {
            rows = nil
        }

        guard let rows else {
            guard plan.acknowledgedUnreadable else { throw Failure.wouldBeUnreadable }
            // Acknowledged: there is no identity here that can decrypt the
            // result to compare against, so the content comparison is
            // skipped outright rather than attempted and ignored.
            return try finishWriting(encrypted, to: destination)
        }
        try verifyRoundTrip(source, rows: rows)

        return try finishWriting(encrypted, to: destination)
    }

    // MARK: - Step 4: source → plaintext

    private static func plaintext(for source: Source) -> String {
        switch source {
        case .empty:
            return "{}\n"
        case .verbatimYAML(let text):
            return text
        case .dotEnv(let entries):
            return FlatYAMLEmitter.emit(entries)
        }
    }

    // MARK: - Step 6: round-trip verification

    /// Compares decrypted `rows` against what `source` was meant to
    /// produce. See this type's doc comment, "The round trip is semantic,
    /// not byte-for-byte", for the table this implements and why a text
    /// comparison would be the wrong check.
    private static func verifyRoundTrip(_ source: Source, rows: [SecretRow]) throws {
        switch source {
        case .empty:
            return
        case .verbatimYAML:
            guard !rows.isEmpty else { throw Failure.roundTripMismatch }
        case .dotEnv(let entries):
            guard rows.count == entries.count else { throw Failure.roundTripMismatch }
            for entry in entries {
                guard let row = rows.first(where: { $0.path == [entry.key] }),
                    row.value == entry.value
                else {
                    throw Failure.roundTripMismatch
                }
            }
        }
    }

    // MARK: - Steps 7 & 8: the only steps that touch disk

    private static func finishWriting(_ encrypted: String, to destination: URL) throws -> AtomicWriteReceipt {
        // 7. A new secrets file may be the first thing ever written under a
        //    path like `secrets/prod.yaml` — `secrets/` need not exist yet.
        //    An already-existing directory is left exactly as it is: this
        //    only sets the mode on what it actually creates (see Apple's own
        //    documentation for `createDirectory(at:withIntermediateDirectories:attributes:)`,
        //    which applies `attributes` to every directory this call
        //    creates, not only the last).
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: modeForNewDirectories])

        // 8. The only step that touches disk in this whole call, and the
        //    only one still capable of refusing: `.absent` closes the
        //    window between step 2's check and this write atomically
        //    (`AtomicFileWriter`'s own doc comment, "A third case"), so a
        //    file that appeared in that gap is still caught here rather than
        //    silently overwritten.
        do {
            return try AtomicFileWriter.write(encrypted, to: destination, expecting: .absent)
        } catch let error as AtomicFileWriter.Error {
            throw Failure.write(error)
        }
    }

    // MARK: - Step 2: pre-existing destination

    /// `lstat`, not `FileManager.fileExists`, for the identical reason
    /// `AtomicFileWriter.refuseIfPresent` uses it: `fileExists` follows a
    /// symlink and reports `false` for one whose target is missing, which
    /// would let a dangling symlink at `destination` sail through this check
    /// only to be caught later — or not — by step 8 instead of here.
    private static func refuseIfPresent(_ destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            throw Failure.destinationExists(path: destination.path)
        }
    }

    // MARK: - Step 1: containment

    /// Refuses `destination` unless it resolves to somewhere inside
    /// `projectRoot`. See this type's doc comment, "Containment, including
    /// through a symlink that does not exist yet", for why a plain
    /// `CanonicalPath.of(destination.path)` is not enough on its own.
    private static func refuseIfOutsideProject(_ destination: URL, projectRoot: URL) throws {
        // A relative `destination`/`projectRoot` cannot be proven to lie
        // anywhere in particular — resolving it would silently fall back to
        // this process's own working directory, exactly the failure mode
        // `CreationPlanResolver.Error`'s doc comment describes for the
        // identical shape of mistake. There is no dedicated `Failure` case
        // for it (the interface this type implements does not have one):
        // the honest answer is the same one a proven escape gets, because
        // this type genuinely cannot tell the two apart from a path alone.
        guard destination.path.hasPrefix("/"), projectRoot.path.hasPrefix("/") else {
            throw Failure.destinationOutsideProject(path: destination.path)
        }

        let root = CanonicalPath.of(projectRoot.path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let canonicalTarget = canonicalizedForContainment(destination)

        guard canonicalTarget.hasPrefix(prefix) else {
            throw Failure.destinationOutsideProject(path: destination.path)
        }
    }

    /// One spelling for `url`, safe to compare against a canonicalized
    /// project root even when most of `url` does not exist on disk yet.
    ///
    /// Walks upward from `url` until it finds an ancestor that actually
    /// exists (following symlinks — a symlinked directory counts as
    /// "there"), resolves *that* through `CanonicalPath.of` — the only call
    /// in this file that ever asks the filesystem to follow a symlink — and
    /// reattaches every path component below it exactly as spelled, because
    /// a component that does not exist cannot itself be a symlink pointing
    /// anywhere. See this type's doc comment for the measured reason
    /// `CanonicalPath.of(url.path)` alone cannot do this: it needs the
    /// *entire* path to exist before it will resolve any part of it.
    private static func canonicalizedForContainment(_ url: URL) -> String {
        var current = url.standardizedFileURL
        var trailingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            trailingComponents.append(current.lastPathComponent)
            current = parent
        }

        let resolvedAncestor = CanonicalPath.of(current.path)
        return trailingComponents.reversed().reduce(resolvedAncestor) { path, component in
            path.hasSuffix("/") ? path + component : path + "/" + component
        }
    }
}
