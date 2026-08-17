import Testing
@testable import SopsUI

/// Settings › Key has to answer "and where do I get one?" on its own.
///
/// It is where the app sends anyone who cannot open a file: *"Add your age
/// private key in Settings › Key to open this file."* Someone arriving from
/// that message never passes through Settings › Health, so the command added
/// to the `security.keystore` finding does not reach them. They land on a
/// paste field, holding nothing to paste.
///
/// The two places say the same thing on purpose. This is not the app repeating
/// itself for emphasis — they are two independent entrances to the same dead
/// end, and closing only one leaves the other exactly as it was.
@Suite("Settings › Key says how to obtain a key")
struct KeyPaneGuidanceTests {

    @Test("the pane names the command that creates a key")
    func paneNamesKeygen() {
        let text = LocalizedKey.keyPasteNoKeyYet.text
        #expect(text.contains("age-keygen"), Comment(rawValue: """
            Settings › Key does not say how to get a key. It is where the editor sends a \
            user who has none, and they arrive without passing the health report, so the \
            command on that finding never reaches them. Text was: \(text)
            """))
    }

    @Test("it names the line to paste, not just the command")
    func paneNamesTheSecretLine() {
        #expect(LocalizedKey.keyPasteNoKeyYet.text.contains("AGE-SECRET-KEY-1"))
    }

    /// The existing footer keeps its own job — saying the key is held for the
    /// session only. The new line is an addition beside it, not a replacement:
    /// losing the memory-only promise would trade one gap for another.
    @Test("the session-only promise is still made")
    func footerStillPromisesMemoryOnly() {
        let footer = LocalizedKey.keyPasteFooter.text.lowercased()
        #expect(footer.contains("memory") || footer.contains("session"))
    }
}
