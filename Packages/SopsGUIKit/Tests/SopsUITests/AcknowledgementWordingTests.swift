import Testing
@testable import SopsUI

/// What the "create it anyway" checkbox has to admit.
///
/// It said only *"I understand I may not be able to open this file again in
/// this app."* — which is true, and is not the whole consequence. Ticking it
/// makes `SecretFileCreator` write the file **with no content verification at
/// all**; the type's own doc comment states this outright and calls it "a
/// real, load-bearing consequence of the flag and not just a footnote".
///
/// So the user was consenting to less than what happens. The round-trip check
/// — the thing that catches a value that would not come back the way it went
/// in — is skipped too, and nothing on screen said so.
///
/// Asserted on the catalog string rather than through a rendered sheet
/// because the claim is about the words, and the words are the whole of what
/// the user has to go on at that moment.
@Suite("The unreadable-file acknowledgement admits what it costs")
struct AcknowledgementWordingTests {

    @Test("the checkbox says content will not be verified, not only that reading may fail")
    func namesTheSkippedVerification() {
        let label = LocalizedKey.newFileAcknowledgeUnreadableCheckbox.text.lowercased()

        #expect(label.contains("check") || label.contains("verif"),
                Comment(rawValue: """
                    The acknowledgement only mentions not being able to open the file. \
                    Ticking it also skips content verification entirely — the user is \
                    agreeing to more than the label describes. Label was: \
                    \(LocalizedKey.newFileAcknowledgeUnreadableCheckbox.text)
                    """))
    }

    /// The original half stays. Losing it would trade one incomplete sentence
    /// for another — the reason this checkbox exists at all is that the file
    /// may be unopenable, and that is what makes the decision consequential.
    @Test("it still says the file may not open again")
    func keepsTheOriginalWarning() {
        let label = LocalizedKey.newFileAcknowledgeUnreadableCheckbox.text.lowercased()
        #expect(label.contains("open"))
    }
}
