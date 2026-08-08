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
        tracker.update(isDirty: true, save: { .saved })
        #expect(tracker.isDirty)
        tracker.update(isDirty: false, save: { .saved })
        #expect(!tracker.isDirty)
    }

    @Test("clear resets to clean and drops the save action")
    func clearResets() async {
        let tracker = UnsavedChangesTracker()
        var saveWasCalled = false
        tracker.update(isDirty: true, save: {
            saveWasCalled = true
            return .saved
        })

        tracker.clear()

        #expect(!tracker.isDirty)
        let outcome = await tracker.save()
        #expect(outcome == nil, "clear() must drop the save action, not just the dirty flag")
        #expect(!saveWasCalled)
    }

    @Test("save() forwards to the registered action and returns its outcome")
    func saveForwardsToRegisteredAction() async {
        let tracker = UnsavedChangesTracker()
        var saveWasCalled = false
        tracker.update(isDirty: true, save: {
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
        tracker.update(isDirty: true, save: { .failed("disk full") })

        let outcome = await tracker.save()

        #expect(outcome == .failed("disk full"))
    }
}
