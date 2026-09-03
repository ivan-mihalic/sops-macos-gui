import Testing
@testable import snapshots

/// SOPS-48. The filter that decides which snapshots reach the **committed**
/// `docs/images/` directory.
///
/// The bug: the filter matched a substring, so `Scripts/guide-snapshots.sh`'s
/// `guide-` also selected `setup-guide-dark` — a review-set entry belonging to
/// the gitignored directory — and wrote a 1.5 MB image into the repository's
/// documentation folder. The run printed "24/24 snapshots written" and exited 0.
/// It was found by `git status`, which is not a place a guarantee should live.
@Suite("Snapshot filter")
struct SnapshotFilterTests {

    @Test("the guide filter selects the guide catalog")
    func guideFilterSelectsGuideEntries() {
        #expect(SnapshotMain.matches(name: "guide-16-key-import", filter: "guide-"))
        #expect(SnapshotMain.matches(name: "guide-01-welcome", filter: "guide-"))
    }

    /// The regression itself, by name.
    @Test("the guide filter does not select a review entry that merely contains it")
    func guideFilterRejectsSubstringMatches() {
        #expect(SnapshotMain.matches(name: "setup-guide-dark", filter: "guide-") == false)
        #expect(SnapshotMain.matches(name: "setup-guide", filter: "guide-") == false)
    }

    @Test("an unrelated name is not selected")
    func unrelatedNamesAreRejected() {
        #expect(SnapshotMain.matches(name: "about-dark", filter: "guide-") == false)
    }
}
