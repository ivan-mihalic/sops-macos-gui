import Testing
@testable import SopsUI

/// Both halves of a project access change have to tell the user to commit.
///
/// Writing `.sops.yaml` already did: *"Commit it so the rest of your team gets
/// it."* Re-wrapping the files did not — and that is the half the team
/// actually needs. The config decides who *future* files are encrypted for;
/// the re-wrap is what changes who can read the secrets that already exist.
/// Leaving it uncommitted means the change works on this Mac and nowhere else,
/// with nothing on screen suggesting a step is missing.
///
/// The asymmetry was the tell: one of two actions that both produce commitable
/// changes said so, and the more consequential one stayed quiet.
@Suite("Both access changes ask to be committed")
struct CommitRemindersTests {

    @Test("writing .sops.yaml asks for a commit")
    func configWriteAsksForCommit() {
        #expect(LocalizedKey.projectAccessConfigWritten.text.lowercased().contains("commit"))
    }

    /// SOPS-39 task 10 narrowed this from "the summary or the note says
    /// commit" to the note alone: `project-access.results.summary` was the
    /// retired panel's updated/unchanged/failed line, and `RewrapSheet` — the
    /// surface a project-wide re-wrap reports into now — draws per-file rows
    /// and the note, no summary. Asserting over a string nothing renders is
    /// how a guard keeps a dead key alive and stops meaning anything.
    @Test("re-wrapping the files asks for a commit too")
    func applyToFilesAsksForCommit() {
        let note = LocalizedKey.projectAccessResultsCommitNote.text.lowercased()

        #expect(note.contains("commit"), Comment(rawValue: """
            Re-wrapping files changes who can read secrets that already exist — the change \
            the rest of the team most needs — and nothing tells the user to commit it, \
            though writing .sops.yaml does. The note read: \
            \(LocalizedKey.projectAccessResultsCommitNote.text)
            """))
    }
}
