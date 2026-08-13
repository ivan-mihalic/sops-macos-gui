import Foundation

@testable import SopsUI

// MARK: - Mirror-sweep leak proof
//
// Shared by `NewSecretFileModelTests.swift` and `EncryptedImportPreviewTests
// .swift`, both of which use this to prove `forgetLastCreateFailure()`
// actually drops retained plaintext from `NewSecretFileModel`'s own memory —
// not merely that the model's *displayed* state moved on. Extracted here
// after a review round found the two copies byte-identical; `internal`
// (the default), not `private`, so both files can see it, the same way
// `GatingHost`/`GatingAXProbe` (`RecipientAccessGatingTests.swift`) are
// shared across this test target rather than duplicated.
//
// ## Why `Mirror`, not a behavioural assertion
//
// `lastCreateFailure` is `private` to `NewSecretFileModel` and escapes only
// through `value(ifStillAbout:)` — reading it back requires naming the exact
// current subject, which a caller that has already moved on to a different
// file cannot do. Clearing it on a fresh pick therefore changes **no
// observable behaviour** any black-box test could see: `plainYAMLText`/
// `dotEnvParsed`/`encryptedImportOutcome` are already overwritten by the new
// source regardless of whether the stale `lastCreateFailure` was cleared
// alongside them. That is exactly what makes this the class of guard that
// regresses silently — verified directly: temporarily removing the
// `forgetLastCreateFailure()` call added to `chooseEncryptedFile(at:)` left
// the entire behavioural suite green. `Mirror(reflecting:)` reads storage
// directly, `private` or not, which is the only way to prove the retained
// copy is actually gone.

/// Every `String` reachable from `value` by walking its storage with
/// `Mirror`. Depth-capped as a backstop against a reference cycle this
/// object graph is not expected to have (`NewSecretFileModel` holds no
/// back-reference to anything that holds it), not because one is
/// anticipated.
func allStrings(reachableFrom value: Any, depth: Int = 0) -> [String] {
    guard depth < 20 else { return [] }
    var found: [String] = []
    if let string = value as? String { found.append(string) }
    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
        found += allStrings(reachableFrom: child.value, depth: depth + 1)
    }
    return found
}

func modelRetains(_ needle: String, _ model: NewSecretFileModel) -> Bool {
    allStrings(reachableFrom: model).contains { $0.contains(needle) }
}
