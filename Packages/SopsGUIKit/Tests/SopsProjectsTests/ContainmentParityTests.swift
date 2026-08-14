import Foundation
import ScratchCleanup
import SopsEngine
import Testing

@testable import SopsProjects

/// #18: "inside the project" is checked three times over — `CreationPlanResolver`,
/// `SecretFileCreator`, `SopsConfigGenerator` — each with its own doc comment
/// justifying why it does not simply call one of the others.
/// `CreationPlanResolver`'s "Which containment predicate" section has the
/// fullest account: two of the three (`SecretFileCreator`, `SopsConfigGenerator`)
/// resolve symlinks before comparing, because they are about to touch disk;
/// `CreationPlanResolver` deliberately does not, because it wraps
/// `SopsBridge.lookupCreationRule`, which itself strips `projectRoot` as a
/// literal, unresolved string prefix — resolving symlinks here would make
/// this type's notion of "inside" disagree with the bridge call it exists to
/// answer honestly about.
///
/// Unifying the *implementation* is therefore out of scope, for the identical
/// ADR 0002 reasoning that keeps each of them from hand-resolving `..`
/// through a symlink itself (see `SecretFileCreator`'s "Why `..` is refused
/// rather than resolved"). What the ticket's acceptance criterion asks for
/// when unification is not the answer is one shared test suite — this file —
/// so a future change to any one of the three that reopens an escape the
/// others still close cannot land unnoticed in only one of three separate
/// test files the way the three implementations themselves once could.
@Suite("Containment parity — CreationPlanResolver, SecretFileCreator, SopsConfigGenerator agree")
struct ContainmentParityTests {

    private func makeProject(_ label: String = "containment-parity") throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// Calls `makeFixture` fresh before *each* of the three refusal points —
    /// never once and shared across all three. `SecretFileCreator.create`
    /// runs the encrypt/decrypt round trip against the real bridge, and
    /// measured directly (at the time this file was first written): sharing
    /// one `(target, projectRoot)` pair built once at the top of a test
    /// across sequential `#expect` blocks in the same function made an
    /// *unrelated* block's outcome bleed into the next one's — a
    /// `SecretFileCreator` check that failed on its own reported no error at
    /// all when a `SopsConfigGenerator` check ran immediately before it in
    /// the same function. This sidesteps the interaction entirely rather
    /// than explaining it: each call site gets its own project, its own
    /// symlink if the scenario needs one, and its own target, so nothing
    /// upstream of it in this file's control flow could have altered the
    /// filesystem it looks at. Slower (three walks of the fixture builder
    /// instead of one) and worth it — a shared-fixture version of this test
    /// is exactly the kind of test that passes for the wrong reason.
    ///
    /// ## Ticket #31: the bleed does not reproduce, and cannot for these fixtures
    ///
    /// Investigated properly rather than left as "worked around, cause
    /// unknown": `sharedFixtureAcrossSequentialChecksDoesNotBleed` below
    /// rebuilds the exact original shape — one fixture, built once, fed to
    /// `SopsConfigGenerator.propose` and then `SecretFileCreator.create` in
    /// sequence with no rebuild in between, `SopsConfigGenerator` running
    /// immediately before `SecretFileCreator` exactly as the paragraph above
    /// describes. It was run against all four of this file's own fixture
    /// shapes (`..`, an unrelated absolute path, a symlink escape, a missing
    /// project root) and against both call orders (`SopsConfigGenerator`
    /// then `SecretFileCreator`, and this file's own current order) — eight
    /// combinations total, every one green, no bleed, every run repeated
    /// several times to rule out a parallel-test race rather than trusting
    /// one pass.
    ///
    /// Reading why closes the question rather than just failing to reproduce
    /// it: for every one of these four fixture shapes, `SopsConfigGenerator
    /// .propose` refuses inside `refuseDotDotComponent`/
    /// `requireProjectRootExists`/`relativePath(of:in:)` — all three pure,
    /// disk-free checks that run *before* `verify(_:forTarget:in:recipients:)`,
    /// the one place this type ever touches disk (a `.sops.yaml.<uuid>.tmp`
    /// probe, staged and removed by its own `defer`). None of these four
    /// shapes is a valid proposal, so `verify` never runs and the probe is
    /// never staged — confirmed directly, not assumed: the regression test
    /// below lists `projectRoot` after the `SopsConfigGenerator` call and
    /// asserts it is empty. `SecretFileCreator.refuseIfOutsideProject` is the
    /// identical shape — pure, disk-free, refuses before step 2 ever runs.
    /// So there is no artifact, no shared mutable state, and nothing *to*
    /// bleed for any fixture this suite exercises; that is the **benign**
    /// explanation, but pinned by code reading and measurement rather than
    /// merely preferred over the alternative. The security explanation the
    /// ticket named — a containment guard passing only because something
    /// else ran first — would require one of the checks to actually read or
    /// write something on a refusal path; none of the three does, for any of
    /// today's four scenarios.
    ///
    /// What this does **not** claim: that the original observation was
    /// imagined. Draft code that predates this file's final shape may well
    /// have had a fixture, an ordering, or a not-yet-early-enough guard this
    /// investigation did not reconstruct — there is no earlier revision of
    /// this file in git history to diff against (`c70fb68` is the only
    /// commit that ever touched it), and `.superpowers/` reports from that
    /// work are gitignored and did not survive. What *is* pinned, by the
    /// regression test below and not by argument alone: today's
    /// implementation does not have this defect, for every containment
    /// shape this suite checks, and the reason is structural rather than
    /// coincidental.
    private func assertAllThreeRefuse(
        makeFixture: () throws -> (target: URL, projectRoot: URL)
    ) throws {
        let owner = try AgeKeyPair.generate()

        do {
            let fixture = try makeFixture()
            #expect(throws: CreationPlanResolver.Error.self) {
                _ = try CreationPlanResolver.plan(forTarget: fixture.target, in: fixture.projectRoot)
            }
        }
        do {
            let fixture = try makeFixture()
            #expect(throws: SecretFileCreator.Failure.self) {
                _ = try SecretFileCreator.create(
                    .empty,
                    plan: ResolvedEncryption(
                        recipients: [owner.public], encryptedRegex: "", acknowledgedUnreadable: false),
                    at: fixture.target, in: fixture.projectRoot, sessionKey: owner.private)
            }
        }
        do {
            let fixture = try makeFixture()
            #expect(throws: SopsConfigGenerator.Error.self) {
                _ = try SopsConfigGenerator.propose(
                    forTarget: fixture.target, in: fixture.projectRoot, recipients: [owner.public])
            }
        }
    }

    /// Ticket #31's regression guard, not merely its write-up. Rebuilds the
    /// exact shape the finding described — one `(target, projectRoot)`
    /// fixture, built once, fed to `SopsConfigGenerator.propose` and then
    /// `SecretFileCreator.create` in sequence with no rebuild in between,
    /// `SopsConfigGenerator` running immediately before `SecretFileCreator`
    /// — against the "unrelated absolute path" scenario, the cleanest of
    /// this file's four fixtures for the diagnostic in the middle: `project`
    /// starts empty and nothing legitimate should ever be staged in it, so
    /// listing it after the first call is a direct check for a left-behind
    /// artifact, not an inference from behaviour alone.
    ///
    /// See `assertAllThreeRefuse`'s own doc comment, "Ticket #31: the bleed
    /// does not reproduce, and cannot for these fixtures", for the full
    /// account and for why this is the benign outcome (nothing to bleed) and
    /// not the security one (a guard passing because something else ran
    /// first) — pinned here rather than only asserted there.
    @Test("SopsConfigGenerator running immediately before SecretFileCreator, on one unrebuilt fixture, does not change SecretFileCreator's refusal")
    func sharedFixtureAcrossSequentialChecksDoesNotBleed() throws {
        let owner = try AgeKeyPair.generate()
        let project = try makeProject()
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("containment-parity-elsewhere-\(UUID().uuidString)")
            .appendingPathComponent("secret.yaml")

        #expect(throws: SopsConfigGenerator.Error.self) {
            _ = try SopsConfigGenerator.propose(
                forTarget: elsewhere, in: project, recipients: [owner.public])
        }

        let leftBehind = try FileManager.default.contentsOfDirectory(atPath: project.path)
        let leftBehindMessage: String = "SopsConfigGenerator.propose left files behind in the project "
            + "root: \(leftBehind) — if this ever fails, that artifact is a live candidate for the "
            + "bleed ticket #31 went looking for and did not find"
        #expect(leftBehind.isEmpty, "\(leftBehindMessage)")

        #expect(throws: SecretFileCreator.Failure.self) {
            _ = try SecretFileCreator.create(
                .empty,
                plan: ResolvedEncryption(
                    recipients: [owner.public], encryptedRegex: "", acknowledgedUnreadable: false),
                at: elsewhere, in: project, sessionKey: owner.private)
        }
    }

    @Test("a literal .. component anywhere in the target is refused by all three")
    func dotDotComponentRefusedByAllThree() throws {
        try assertAllThreeRefuse {
            let project = try makeProject()
            return (project.appendingPathComponent("secrets/../../etc/passwd"), project)
        }
    }

    @Test("a target sharing no prefix at all with the project root is refused by all three")
    func unrelatedAbsolutePathRefusedByAllThree() throws {
        try assertAllThreeRefuse {
            let project = try makeProject()
            let elsewhere = FileManager.default.temporaryDirectory
                .appendingPathComponent("containment-parity-elsewhere-\(UUID().uuidString)")
                .appendingPathComponent("secret.yaml")
            return (elsewhere, project)
        }
    }

    /// The sharpest case, and the one that actually distinguishes a lexical
    /// `..` collapse from what the real filesystem does. `project/link` is a
    /// genuine symlink to a directory *outside* the project; the target walks
    /// back in with `..`. `URL.standardizedFileURL` cancels the `..` against
    /// `link` lexically and reports a path back inside the project;
    /// `open(2)`/`renamex_np` follow `link` first and land outside — see
    /// `SecretFileCreator`'s own doc comment, "Why `..` is refused rather
    /// than resolved", for the measurement this fixture reproduces. That test
    /// pins it for `SecretFileCreator` alone; this applies the identical
    /// fixture shape to all three.
    @Test("a .. that walks back in through a real symlink out of the project is refused by all three")
    func dotDotThroughASymlinkRefusedByAllThree() throws {
        try assertAllThreeRefuse {
            let project = try makeProject()
            let outside = try makeProject("containment-parity-outside")
            let link = project.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let target = link.appendingPathComponent("..").appendingPathComponent("inside.yaml")
            return (target, project)
        }
    }

    @Test("a project root that does not exist is refused by all three")
    func missingProjectRootRefusedByAllThree() throws {
        try assertAllThreeRefuse {
            let project = FileManager.default.temporaryDirectory
                .appendingPathComponent("containment-parity-missing-\(UUID().uuidString)", isDirectory: true)
            return (project.appendingPathComponent("secret.yaml"), project)
        }
    }
}
