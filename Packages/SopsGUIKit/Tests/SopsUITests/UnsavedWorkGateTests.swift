import Testing
@testable import SopsUI

/// Ticket #23. `WorkspaceSwitchDecision.forSwitch`, `SecretEditorView
/// .canOpenAccessPanel` and the since-retired `ProjectAccessGate.canOpen`
/// (SOPS-39 task 10) each independently wrote `!isDirty && !isSaving` before
/// `UnsavedWorkGate` existed — three copies of the same rule, agreeing today
/// only because nobody had changed one without checking the other two. This pins the one shared definition
/// directly, ahead of `UnsavedWorkGateCoverageTests`, which pins that every
/// gate of this shape actually calls it.
@Suite("UnsavedWorkGate — the one definition of \"safe to act on this document\"")
struct UnsavedWorkGateTests {

    @Test("clean and idle is clear")
    func cleanAndIdleIsClear() {
        #expect(UnsavedWorkGate.isClear(isDirty: false, isSaving: false))
    }

    @Test("dirty blocks")
    func dirtyBlocks() {
        #expect(!UnsavedWorkGate.isClear(isDirty: true, isSaving: false))
    }

    @Test("saving blocks, even when not dirty")
    func savingBlocksEvenWhenNotDirty() {
        #expect(!UnsavedWorkGate.isClear(isDirty: false, isSaving: true))
    }

    @Test("dirty and saving together still just blocks")
    func dirtyAndSavingBlocks() {
        #expect(!UnsavedWorkGate.isClear(isDirty: true, isSaving: true))
    }
}
