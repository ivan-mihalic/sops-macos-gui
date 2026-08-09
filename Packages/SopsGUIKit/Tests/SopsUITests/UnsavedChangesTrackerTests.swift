import Testing
@testable import SopsUI

@Suite("UnsavedChangesTracker")
@MainActor
struct UnsavedChangesTrackerTests {

    @Test("a fresh tracker reports nothing dirty")
    func freshTrackerIsClean() {
        let tracker = UnsavedChangesTracker()
        #expect(!tracker.isDirty)
    }

    @Test("update reflects the registered dirty state")
    func updateReflectsDirtyState() {
        let tracker = UnsavedChangesTracker()
        tracker.update(isDirty: true, isSaving: false, save: { .saved })
        #expect(tracker.isDirty)
        tracker.update(isDirty: false, isSaving: false, save: { .saved })
        #expect(!tracker.isDirty)
    }

    /// The quit path reads this to refuse a termination that would land
    /// between a save's encrypt and its write — see `QuitRequestTests`.
    @Test("update reflects the registered save-in-flight state")
    func updateReflectsSavingState() {
        let tracker = UnsavedChangesTracker()
        #expect(!tracker.isSaving, "a fresh tracker cannot be saving anything")
        tracker.update(isDirty: true, isSaving: true, save: { .saved })
        #expect(tracker.isSaving)
        tracker.update(isDirty: true, isSaving: false, save: { .saved })
        #expect(!tracker.isSaving)
    }

    @Test("clear resets to clean and drops the save action")
    func clearResets() async {
        let tracker = UnsavedChangesTracker()
        var saveWasCalled = false
        tracker.update(isDirty: true, isSaving: false, save: {
            saveWasCalled = true
            return .saved
        })

        tracker.clear()

        #expect(!tracker.isDirty)
        #expect(!tracker.isSaving, "a cleared tracker claims nothing about a document it no longer has")
        let outcome = await tracker.save()
        #expect(outcome == nil, "clear() must drop the save action, not just the dirty flag")
        #expect(!saveWasCalled)
    }

    @Test("save() forwards to the registered action and returns its outcome")
    func saveForwardsToRegisteredAction() async {
        let tracker = UnsavedChangesTracker()
        var saveWasCalled = false
        tracker.update(isDirty: true, isSaving: false, save: {
            saveWasCalled = true
            return .saved
        })

        let outcome = await tracker.save()

        #expect(outcome == .saved)
        #expect(saveWasCalled)
    }

    @Test("save() with nothing registered returns nil rather than crashing")
    func saveWithNothingRegisteredReturnsNil() async {
        let tracker = UnsavedChangesTracker()
        let outcome = await tracker.save()
        #expect(outcome == nil)
    }

    @Test("a failed save's message passes through untouched")
    func failedSavePassesThroughMessage() async {
        let tracker = UnsavedChangesTracker()
        tracker.update(isDirty: true, isSaving: false, save: { .failed("disk full") })

        let outcome = await tracker.save()

        #expect(outcome == .failed("disk full"))
    }
}
