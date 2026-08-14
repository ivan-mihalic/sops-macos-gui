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
    /// current session identity cannot read back. Trades away more than
    /// that one thing: it also means the file is written with **no content
    /// verification at all**, because there is no identity in hand to
    /// decrypt it back for comparison — see `Failure.wouldBeUnreadable` and
    /// this type's "Self-readability is the default" section for the full
    /// account.
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
/// anywhere in this type, because there is nothing to delete: the *file* was
/// never there. Step 7 is the exception worth naming precisely: it can
/// create intermediate directories before step 8 ever runs. If step 8 then
/// fails — a losing `RENAME_EXCL` race, or `AtomicFileWriter` refusing for
/// some other reason — `finishWriting` removes exactly what step 7 created,
/// and only what is still empty: a directory a second writer's own file has
/// since landed in (the race-winner case) is left alone, because that
/// content is precisely what must not be touched. A directory that
/// pre-existed before this call is never touched either way. See
/// `finishWriting`'s catch clause for the mechanism.
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
/// **With `acknowledgedUnreadable == true`, a decrypt failure for *any*
/// reason — a wrong or missing identity, or a genuine engine fault, and
/// this implementation cannot tell those apart (see `Failure
/// .wouldBeUnreadable`'s own doc comment for why) — results in the file
/// being written with no content verification at all.** Not attempted and
/// ignored: skipped outright, because there is no identity in hand that
/// could decrypt the result to compare against either way. This is
/// defensible — the caller has already said this session cannot read the
/// file back — but it is a real, load-bearing consequence of the flag and
/// not just a footnote: it must never be added to a code path where "the
/// bridge glitched" and "this recipient set is genuinely unreadable to me"
/// need to be told apart.
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
/// | `.dotEnv` | Every entry has exactly one row with `path == [key]` and a matching `value`; `rows.count == entries.count`. This is the one source with a hand-rolled serialiser (`FlatYAMLEmitter`) standing between the user's values and the bridge, and it is the reason this post-condition exists at all — see that type's own doc comment. |
/// | `.verbatimYAML` | `decryptToRows` succeeds, and (ticket #10, claim 4) non-trivial source text must not come back as *zero* rows. An empty result is only a legitimate document when the source itself was trivially empty — `{}` or blank — not corruption: a user pasting literally `{}` means to create the file and fill it in afterward, exactly as `.empty` already does deliberately. The bridge's own comment agrees — `Engine/gobridge/bridge.go:332-333`: "an empty file has nothing to encrypt, and that is not a broken rule." (A comments-only template is a *different* case, not this one: the bridge's YAML loader rejects a document with no actual node in it before this type's round-trip logic is ever reached — `.engine("the document is not valid YAML")` — see the comment on `verbatimYAMLEmptyDocumentIsCreated` in `SecretFileCreatorTests` for that measurement.) Reporting `{}` as `roundTripMismatch` would tell a user their file was corrupted when it was not — but real, non-trivial text coming back with nothing in it at all is exactly the total-data-loss shape `roundTripMismatch` exists to catch, and until now nothing here did: see `verifyRoundTrip`'s own doc comment for why this stops short of a full row-count comparison. |
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
///
/// ## Why `..` is refused rather than resolved
///
/// A `..` component that follows a symlink is a second, sharper version of
/// the same problem, and it is not hypothetical — it was measured directly
/// against `refuseIfOutsideProject`'s first implementation. With a real
/// symlink `project/link -> /outside` and `destination =
/// project/link/../inside.yaml`, that implementation approved the write:
/// `URL.standardizedFileURL` — the one tool available for a path that does
/// not exist yet — collapses `..` *lexically*, cancelling it against the
/// token immediately before it in the string without knowing that token
/// names a symlink. It reported `project/inside.yaml`: inside. The real
/// filesystem does not agree — `open(2)`/`renamex_np` walk the identical raw
/// path component by component, follow `link` to `/outside` *first*, and
/// only then apply `..`, landing at `/inside.yaml`: outside. Measured with
/// the file actually created both ways on the same input, side by side.
///
/// There is no safe fix that still resolves `..` here. Doing it correctly
/// means re-deriving the kernel's own path-walking order in Swift —
/// exactly the reimplementation-of-something-foundational risk ADR 0002
/// warns about, just for path resolution instead of YAML. So
/// `refuseIfOutsideProject` refuses any `..` path component outright,
/// before `canonicalizedForContainment` ever runs, rather than trying to
/// resolve it. This is not merely moving the problem to a different
/// caller: nothing in this app's real call sites needs to *express* `..`
/// to reach a legitimate destination — a file picker returns an already-
/// canonical absolute path with no `..` in it, and a project-relative
/// name typed by a user is joined with `appendingPathComponent`, not
/// pasted in as a single string a user could smuggle `../` into. The one
/// way to *construct* a `destination` containing `..` is deliberately, and
/// that is exactly the input this guard exists to catch. `SecretFileCreatorTests
/// .dotDotThroughASymlinkIsRefused` pins the measured scenario above.
public enum SecretFileCreator {

    /// `Equatable` so a caller can ask "is this still the same thing I was
    /// about to create?" — `NewSecretFileModel` files what it learned from a
    /// failed attempt under the exact `Source` it attempted, and can only
    /// read that back while the value still compares equal. Equality here is
    /// equality of what would be written, nothing more: `verbatimYAML` on its
    /// text, `dotEnv` on its entries.
    public enum Source: Equatable, Sendable {
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
        /// `projectRoot` — a literal `..` component anywhere in the path
        /// (refused outright rather than resolved; see
        /// `refuseIfOutsideProject`'s doc comment), an absolute path
        /// elsewhere, a symlink out of the project, a `projectRoot` that is
        /// not there (or not a directory) at all, or a `destination`/
        /// `projectRoot` that was not given as an absolute path in the
        /// first place (see `refuseIfOutsideProject`'s doc comment for why
        /// that last case is folded in here rather than given its own
        /// case).
        case destinationOutsideProject(path: String)
        /// Step 6: the recipient set could decrypt what was produced, but
        /// what came back does not match what was meant to be written. No
        /// associated value — see this type's file-level "no secret values"
        /// discipline; a mismatch is a shape a document took, never the
        /// values that made it that shape.
        ///
        /// `.dotEnv` values used to reach this case through no fault of the
        /// user's own — a value containing `U+0085` (NEL) round-tripped
        /// through `FlatYAMLEmitter.quotedValue` unescaped and came back
        /// different from what was written. That gap is closed (`quotedValue`
        /// escapes NEL now; see its doc comment), but `CreationFailurePresenter`
        /// still avoids claiming "corrupted" here — this case can still fire
        /// for other reasons this type does not enumerate (a future encoding
        /// edge case, an engine behaviour change), and asserting damage the
        /// user did not do is the wrong default for a case whose exact cause
        /// is not carried in the enum.
        case roundTripMismatch
        /// The `acknowledgedUnreadable` branch's own check (ticket #10, claim
        /// 1): the recipient metadata sops actually wrote to `encrypted` does
        /// not match `plan.recipients`. No associated value, for the same
        /// reason `roundTripMismatch` has none — see
        /// `verifyRecipientsStructurally`'s doc comment for what this catches
        /// and why it exists only on the one path where nothing else does.
        case recipientsMismatch
        /// Step 3 (see this type's doc comment for why its *check* runs
        /// where step 6 does): decrypting what step 5 just produced, with
        /// `sessionKey`, failed because this session's identity genuinely is
        /// not among `plan.recipients`, and the caller has not set
        /// `ResolvedEncryption.acknowledgedUnreadable`.
        ///
        /// Ticket #10, claim 2: this used to be thrown for *every* decrypt
        /// failure at this point — `SopsBridgeError` used to be a bare
        /// `description` string, so this type could not reliably tell "this
        /// identity genuinely is not among the recipients" apart from some
        /// other decrypt-time engine fault without pattern-matching the
        /// bridge's own error text — exactly the kind of dependency on prose
        /// this codebase does not take elsewhere (`Failure.engine`'s own
        /// doc comment states the opposite discipline: names are checked
        /// structurally, never by string content). `SopsBridgeError.kind`
        /// now supplies exactly that structural check — set by the bridge
        /// itself, never inferred from its prose — so a decrypt failure of
        /// any *other* shape is `.engine` instead, whether or not the
        /// caller acknowledged unreadability. See `create`'s own
        /// `decryptFailureKind` handling for where that split happens.
        case wouldBeUnreadable
        /// Step 5: `plan.recipients`/`plan.encryptedRegex` could not be
        /// encrypted for — the bridge's own diagnostic. Fixed, value-free
        /// text by the bridge's own construction —
        /// `Engine/gobridge/bridge.go`'s recipient checks name an index,
        /// never the recipient string itself, precisely so a pasted private
        /// key never reaches here.
        ///
        /// Never thrown from the decrypt in step 3/6 — see
        /// `.wouldBeUnreadable`'s doc comment for why that path cannot
        /// distinguish its own failures and reports all of them the other
        /// way instead.
        case engine(String)
        /// Step 7: the intermediate directories on the way to `destination`
        /// could not be created — a read-only project directory, or a path
        /// component that already exists as a regular file (`ENOTDIR`).
        /// Reachable without anything exotic: `destination` is
        /// `project/secrets/prod.yaml` and `project/secrets` already exists
        /// as a plain file rather than a directory. `path` is the directory
        /// this call tried to create; `reason` is errno-derived only, the
        /// same contract `AtomicFileWriter.Error`'s cases keep — see that
        /// type's "Errors never contain the file's contents" section.
        case couldNotCreateDirectory(path: String, reason: String)
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
        //
        // Ticket #10, claim 2: this used to report every failure here —
        // wrong identity, a genuine engine fault, a malformed bridge
        // response — as `wouldBeUnreadable`, because `SopsBridgeError` used
        // to be a bare `description` string with no structured cause to
        // switch on. It now carries `kind`, set by the bridge itself
        // (`Engine/gobridge/document.go`'s `ErrKindNoMatchingIdentity`) for
        // exactly the one case this branch needs to tell apart: "this
        // identity genuinely is not among the recipients" versus everything
        // else. Still never inferred from `description`'s own text — the
        // discipline `Failure.engine`'s doc comment states stays intact,
        // because `kind` is a value the bridge sets deliberately, not a
        // pattern this app goes looking for in prose.
        let rows: [SecretRow]?
        var decryptFailureKind: SopsBridgeError.Kind?
        var decryptFailureDescription = "the encrypted document could not be decrypted for verification"
        do {
            rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: sessionKey)
        } catch let error as SopsBridgeError {
            rows = nil
            decryptFailureKind = error.kind
            decryptFailureDescription = error.description
        } catch {
            rows = nil
        }

        guard let rows else {
            // A failure this app cannot class as "this session cannot read
            // it" is a genuine engine-level surprise, and `acknowledgedUnreadable`
            // was never meant to paper over one of those — the caller
            // accepted a recipient set that excludes them, not an engine
            // that might be broken. Reported the same way as step 5's own
            // encrypt failures, and — unlike `wouldBeUnreadable` below —
            // regardless of whether the caller acknowledged anything.
            guard decryptFailureKind == .noMatchingIdentity else {
                throw Failure.engine(decryptFailureDescription)
            }
            guard plan.acknowledgedUnreadable else { throw Failure.wouldBeUnreadable }
            // Acknowledged, and confirmed to be the honest case: this
            // session's identity is not among the recipients, and there is
            // no identity in hand that could decrypt the result to compare
            // against either way. So this file is written with **no content
            // verification at all**, not "verification attempted and
            // ignored". That is the real, load-bearing consequence of
            // setting `acknowledgedUnreadable`, spelled out here because it
            // is easy to read the flag's name as being only about *who can
            // read the file later* rather than also about *what this call
            // itself can still promise*.
            try verifyRecipientsStructurally(encrypted, expected: plan.recipients)
            let receipt = try finishWriting(encrypted, to: destination)
            // Ticket #10, claim 3: record, durably, that this file was
            // written unverified — see `AcknowledgedUnreadableMarker`'s own
            // doc comment. After the write, not before: a marker on a file
            // that never actually landed would be a lie, and `finishWriting`
            // is the one step still capable of refusing.
            AcknowledgedUnreadableMarker.mark(receipt.destination)
            return receipt
        }
        try verifyRoundTrip(source, rows: rows)

        return try finishWriting(encrypted, to: destination)
    }

    // MARK: - The one check still possible without a readable identity

    /// Ticket #10, claim 1: when `acknowledgedUnreadable` is set, decrypting
    /// to compare content is impossible — there is no identity in hand that
    /// could decrypt the result. But sops's own recipient metadata is public
    /// and readable without any identity at all
    /// (`SopsBridge.recipients(in:)`), so it is the one structural fact this
    /// call can still check. Not full verification — it says nothing about
    /// the encrypted values themselves — but it catches the same class of bug
    /// the round trip exists for on every other path: the file just produced
    /// does not actually declare the recipients this call meant to encrypt
    /// for.
    ///
    /// `internal`, not `private`: `SecretFileCreatorTests` exercises this
    /// directly with a hand-built mismatch, because there is no seam in
    /// `create()` itself to make the bridge actually produce the wrong
    /// recipient set — that would require a genuine engine bug, which this
    /// suite has no way to manufacture on demand.
    static func verifyRecipientsStructurally(_ encrypted: String, expected: [String]) throws {
        let actual: [String]
        do {
            actual = try SopsBridge.recipients(in: encrypted)
        } catch let error as SopsBridgeError {
            throw Failure.engine(error.description)
        }
        guard Set(actual) == Set(expected) else { throw Failure.recipientsMismatch }
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
    ///
    /// `internal`, not `private`: ticket #10, claim 4's regression test
    /// drives the `.verbatimYAML` branch directly with a hand-built,
    /// impossible-through-the-real-bridge "rows came back empty" result —
    /// see `SecretFileCreatorTests.verbatimYAMLThatLosesAllContentIsCaught`.
    static func verifyRoundTrip(_ source: Source, rows: [SecretRow]) throws {
        switch source {
        case .empty:
            return
        case .verbatimYAML(let text):
            // Only reaching here already proves `decryptToRows` succeeded —
            // that is most of the check for this source. `rows` being empty
            // is not itself a defect: a comments-only or `{}` document is a
            // legitimate thing to paste in and fill out later. See the
            // table above for the fuller account and why an empty result
            // must not, by itself, throw `roundTripMismatch`.
            //
            // What it must not paper over is real content coming back as
            // *nothing at all* — total data loss on the one source with no
            // Swift-side emitter standing between the user's paste and the
            // bridge, so any such loss can only be an engine-level bug, not
            // a user mistake this app introduced. This is deliberately not
            // a row *count* comparison: getting the expected count would
            // mean parsing the user's YAML on the Swift side, which ADR
            // 0002 forbids — sops's own parser is the only thing allowed to
            // decide how many leaves a document has. So this checks the one
            // shape of loss that needs no parsing at all: text that is not
            // itself an empty document coming back with zero rows.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDeliberatelyEmpty = trimmed.isEmpty || trimmed == "{}"
            guard isDeliberatelyEmpty || !rows.isEmpty else { throw Failure.roundTripMismatch }
            return
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
        //
        //    `existingAncestor` is found *before* creating anything: the
        //    nearest directory on the way to `directory` that already exists.
        //    If step 8 below then fails, that is exactly the boundary a
        //    cleanup may remove up to and not past — see `finishWriting`'s
        //    catch clause and `removeEmptyDirectoriesCreatedForThisCall`.
        let directory = destination.deletingLastPathComponent()
        let existingAncestor = nearestExistingAncestor(of: directory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: modeForNewDirectories])
        } catch {
            throw Failure.couldNotCreateDirectory(
                path: directory.path, reason: (error as NSError).localizedDescription)
        }

        // Test-only, and a no-op in every build that does not set it. Lets
        // `SecretFileCreatorTests` land step 8's failure deterministically
        // — chmodding the directory this call just created so staging the
        // temp file inside it fails — rather than racing a real losing
        // `RENAME_EXCL` attempt, which this process cannot reliably force
        // from outside `AtomicFileWriter`.
        afterDirectoryCreatedHookForTesting?(directory)

        // 8. The only step that touches disk in this whole call, and the
        //    only one still capable of refusing: `.absent` closes the
        //    window between step 2's check and this write atomically
        //    (`AtomicFileWriter`'s own doc comment, "A third case"), so a
        //    file that appeared in that gap is still caught here rather than
        //    silently overwritten.
        do {
            return try AtomicFileWriter.write(encrypted, to: destination, expecting: .absent)
        } catch let error as AtomicFileWriter.Error {
            // A losing `RENAME_EXCL` race, or `AtomicFileWriter` refusing for
            // some other reason (a permissions problem staging the temp
            // file, a full volume), can leave the directory step 7 just
            // created sitting there with nothing in it — the secrets file
            // itself still never existed (see this type's own doc comment,
            // "The order is the whole point"), but the directory now does,
            // for no reason a retry needs. Only removed when it is genuinely
            // empty: if another writer's file *did* land inside it (the
            // race-winner case), that content is exactly what must not be
            // touched, and `removeEmptyDirectoriesCreatedForThisCall` checks
            // for that before removing anything.
            removeEmptyDirectoriesCreatedForThisCall(from: directory, upTo: existingAncestor)
            throw Failure.write(error)
        }
    }

    /// The nearest ancestor of `url` that already exists on disk — `url`
    /// itself if it is already there. Used to bound cleanup on a later
    /// failure to exactly what step 7 created and nothing older.
    private static func nearestExistingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return current
    }

    /// Removes `directory` and any of its now-empty parents, stopping at
    /// (and never touching) `existingAncestor` — the directory that was
    /// already there before step 7 ran. Stops at the first non-empty
    /// directory it finds, innermost first, which is what makes this safe to
    /// call after a race a second writer won: that writer's file is what
    /// makes the directory non-empty, and finding it here is exactly the
    /// signal to leave the rest alone.
    private static func removeEmptyDirectoriesCreatedForThisCall(
        from directory: URL, upTo existingAncestor: URL
    ) {
        var current = directory
        while current.path != existingAncestor.path {
            guard
                let entries = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                entries.isEmpty
            else { return }
            guard (try? FileManager.default.removeItem(at: current)) != nil else { return }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return }
            current = parent
        }
    }

    /// See the call site in `finishWriting` above. Lock-guarded for the same
    /// reason `AtomicFileWriter.beforeReplaceHookForTesting` is: process-wide
    /// mutable state that `swift test`'s parallel execution can touch from
    /// more than one thread.
    static var afterDirectoryCreatedHookForTesting: (@Sendable (URL) -> Void)? {
        get {
            afterDirectoryCreatedHookLock.lock()
            defer { afterDirectoryCreatedHookLock.unlock() }
            return unguardedAfterDirectoryCreatedHook
        }
        set {
            afterDirectoryCreatedHookLock.lock()
            defer { afterDirectoryCreatedHookLock.unlock() }
            unguardedAfterDirectoryCreatedHook = newValue
        }
    }
    private static let afterDirectoryCreatedHookLock = NSLock()
    private static nonisolated(unsafe) var unguardedAfterDirectoryCreatedHook: (@Sendable (URL) -> Void)?

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
    /// `CanonicalPath.of(destination.path)` is not enough on its own, and
    /// "Why `..` is refused rather than resolved" for the guard below.
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

        // `projectRoot` itself has to be a real, present directory, or
        // "inside `projectRoot`" is not a claim anything below can honestly
        // make: a project root that does not exist yet makes the prefix
        // check below vacuously true against any literal path sharing its
        // spelling, and step 7's `createDirectory(withIntermediateDirectories:
        // true)` would then happily create the "project" itself as a side
        // effect of creating the file inside it.
        var projectRootIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: projectRoot.path, isDirectory: &projectRootIsDirectory),
            projectRootIsDirectory.boolValue
        else {
            throw Failure.destinationOutsideProject(path: destination.path)
        }

        // See "Why `..` is refused rather than resolved" in this type's doc
        // comment: there is no safe way in this implementation to resolve a
        // `..` component that might follow a symlink, so any literal `..`
        // anywhere in `destination` is refused outright, before anything
        // tries to canonicalize it.
        guard !destination.path.split(separator: "/").contains("..") else {
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
    /// Walks upward from `url` — exactly as given, never lexically
    /// standardized first (see "Why `..` is refused rather than resolved" in
    /// this type's doc comment for why that distinction is load-bearing) —
    /// until it finds an ancestor that actually exists (following symlinks —
    /// a symlinked directory counts as "there"), resolves *that* through
    /// `CanonicalPath.of` — the only call in this file that ever asks the
    /// filesystem to follow a symlink — and reattaches every path component
    /// below it exactly as spelled, because a component that does not exist
    /// cannot itself be a symlink pointing anywhere. See this type's doc
    /// comment for the measured reason `CanonicalPath.of(url.path)` alone
    /// cannot do this: it needs the *entire* path to exist before it will
    /// resolve any part of it. Only ever called after `refuseIfOutsideProject`
    /// has already refused any `..` component, so there is nothing left here
    /// for a lexical shortcut to mishandle.
    private static func canonicalizedForContainment(_ url: URL) -> String {
        var current = url
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
