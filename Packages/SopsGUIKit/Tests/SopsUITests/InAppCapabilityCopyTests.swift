import Testing
@testable import SopsUI

/// SOPS-48. Every place the app tells a user to go and do something in a
/// terminal has to still be true that the app cannot do it itself.
///
/// This is the failure mode SOPS-46 found once and SOPS-48 found again, in a
/// different text each time: a sentence that was accurate when written, and
/// that a later feature quietly turned into an untruth. Nothing goes red when
/// that happens — the string still compiles, still renders, still reads
/// plausibly. Here, SOPS-44 shipped an in-app age key generator and two
/// separate texts went on saying "run age-keygen in a terminal" as though it
/// did not exist.
///
/// A text may still *mention* a terminal command — for someone with no project
/// added, `age-keygen` is genuinely the only route, because the generator lives
/// on a project's Access page. What it may not do is send the reader there
/// **without** naming the in-app route first.
@Suite("Copy does not send users to a terminal for what the app can do")
struct InAppCapabilityCopyTests {

    /// The texts that offer a way to obtain a key. Both were wrong at the same
    /// time, in the same way, and neither is reachable from the other — the
    /// editor sends a user to Settings › Key without passing the health report,
    /// and the health report is read by people who never open Settings › Key.
    private static let keyAcquisitionCopy: [(String, String)] = [
        ("key.paste.no-key-yet", LocalizedKey.keyPasteNoKeyYet.text),
        ("guide.colleague-key.body", LocalizedKey.guideColleagueKeyBody.text),
    ]

    /// The claim this suite exists to keep out of the app: a text stating in so
    /// many words that the app cannot do a thing it can do. This one shipped in
    /// the Setup guide from SOPS-41 and was already false when SOPS-44 landed
    /// the generator, three tickets before anybody noticed.
    @Test("no copy claims the app cannot generate a key")
    func nothingClaimsTheAppCannotGenerate() {
        let forbidden = ["does not generate", "cannot generate", "can't generate", "doesn't generate"]

        for (id, text) in Self.keyAcquisitionCopy {
            let lowered = text.lowercased()
            for claim in forbidden {
                #expect(lowered.contains(claim) == false, Comment(rawValue: """
                    \(id) says the app cannot generate a key. It has been able to since SOPS-44 \
                    (Access › Add named key › Generate new key). Text was: \(text)
                    """))
            }
        }
    }

    @Test("copy that names age-keygen also names the in-app generator")
    func keygenMentionsAreAccompanied() {
        for (id, text) in Self.keyAcquisitionCopy where text.contains("age-keygen") {
            let lowered = text.lowercased()
            #expect(lowered.contains("generate new key") || lowered.contains("add named key"),
                    Comment(rawValue: """
                        \(id) sends the reader to age-keygen in a terminal without mentioning that this app \
                        generates a key itself (Access › Add named key › Generate new key, shipped in SOPS-44). \
                        Text was: \(text)
                        """))
        }
    }

    /// The in-app route is only worth naming while it exists. If the generator
    /// is ever moved or removed, this fails and the copy above has to be
    /// revisited rather than left pointing at nothing.
    @Test("the in-app route named by that copy is a real control")
    func theNamedRouteExists() {
        #expect(LocalizedKey.accessAddNamedModeGenerate.text.lowercased().contains("generate"))
        #expect(LocalizedKey.accessGenerateButton.text.isEmpty == false)
        #expect(LocalizedKey.accessGenerateIntro.text.isEmpty == false)
    }

    /// The generator's own introduction makes three promises about what
    /// generating does *not* do. The third one changed meaning under SOPS-46 —
    /// the app can now put a key in the Keychain — so the sentence has to be
    /// about *this sheet*, not about the app as a whole.
    @Test("the generator does not claim the app can never store a key")
    func generatorIntroDoesNotOverclaim() {
        let intro = LocalizedKey.accessGenerateIntro.text.lowercased()

        #expect(intro.contains("never puts a key into your key store") == false,
                "SOPS-46 gave the app a way to store a key; this sentence says it has none")
        // It must still say what generating does not do — dropping the promise
        // entirely would be the other way to make this test pass.
        #expect(intro.contains("nothing is installed"))
    }
}
