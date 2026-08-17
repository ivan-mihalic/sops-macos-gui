import Testing
@testable import SopsEngine
@testable import SopsUI

/// The most common reason a file will not open needs a sentence of its own.
///
/// The app deliberately never rewords the engine's diagnostics — that policy
/// is right, and this does not change it. But it left the single most likely
/// failure, *this key is not one of this file's recipients*, showing whatever
/// age and sops happened to say about it. A newcomer who picked the wrong key,
/// or whose colleague never added theirs, got a technical string instead of
/// the one fact that would tell them what to do.
///
/// The bridge already classifies this case — `SopsBridgeError.Kind
/// .noMatchingIdentity`, set Go-side — so nothing here is guessing from
/// message text. The engine's own words are kept underneath, because they are
/// still the authoritative account of what happened.
@Suite("A wrong key says so in plain words")
struct WrongKeyMessageTests {

    @Test("a no-matching-identity failure leads with an explanation")
    func explainsAWrongKey() {
        let message = SecretDocumentViewModel.loadFailureMessage(
            for: SopsBridgeError(description: "no identity matched any of the recipients",
                                 kind: .noMatchingIdentity))

        #expect(message.hasPrefix(LocalizedKey.editorLoadFailedWrongKey.text), Comment(rawValue: """
            A wrong-key failure still leads with the engine's diagnostic. This is the most \
            common reason a file will not open and the bridge already tells us it is the \
            cause, so the user should read what to do first. Message was: \(message)
            """))
    }

    /// The engine's account is not replaced. Whatever age actually reported is
    /// what a bug report needs, and dropping it to make the screen tidier
    /// would trade a real diagnostic for a friendlier guess.
    @Test("the engine's own words are still there")
    func keepsTheEngineDiagnostic() {
        let message = SecretDocumentViewModel.loadFailureMessage(
            for: SopsBridgeError(description: "no identity matched any of the recipients",
                                 kind: .noMatchingIdentity))
        #expect(message.contains("no identity matched any of the recipients"))
    }

    /// Any other failure is passed through untouched — the policy of not
    /// rewording the engine holds everywhere it is not specifically overridden.
    @Test("an unclassified failure is passed through unchanged")
    func passesOtherFailuresThrough() {
        let raw = "the sops engine faulted while reading this document"
        let message = SecretDocumentViewModel.loadFailureMessage(
            for: SopsBridgeError(description: raw))
        #expect(message == raw)
    }
}
