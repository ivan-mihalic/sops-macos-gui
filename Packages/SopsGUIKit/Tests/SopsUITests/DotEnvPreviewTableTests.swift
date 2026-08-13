import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// What a `.env` import would actually produce, rendered before anything is
/// written — see `DotEnvPreviewTable`'s own doc comment for the property
/// this suite exists to guard: this is the first new plaintext surface since
/// the editor, and `AccessibilityTreeTests` already caught a masked value
/// leaking into the accessibility tree once. That is the exact hazard here,
/// one view over — including for a *skipped* line, whose raw text is just as
/// likely to hold a secret as an accepted entry's value (see
/// `DotEnvSkippedLine`'s own doc comment).
///
/// Uses `AXProbe`, the same headless accessibility-tree probe
/// `AccessibilityTreeTests.swift` defines (`internal`, not `private`, for
/// exactly this reason — see that file's header comment).
@Suite("DotEnvPreviewTable")
struct DotEnvPreviewTableTests {

    /// Recognisable value planted in both an accepted entry and a skipped
    /// line's raw text, mirroring `CreationFailurePresenterTests
    /// .sentinelValue` — the same string, so a grep for "does any fixture in
    /// this package use a real-looking secret" finds one place, not two.
    private static let sentinelValue = "correct-horse-battery-staple"

    /// One entry and one skipped line, each carrying the sentinel — the
    /// shape the brief calls out explicitly: `KEY = "value` with an
    /// unterminated quote is a skipped line holding a password just as
    /// easily as an accepted entry does.
    private static func fixture() -> ParsedDotEnv {
        ParsedDotEnv(
            entries: [
                DotEnvEntry(key: "API_KEY", value: sentinelValue, line: 1),
            ],
            skipped: [
                DotEnvSkippedLine(line: 2, text: "PASSWORD = \"\(sentinelValue)"),
            ],
            suspicions: [])
    }

    // MARK: - No plaintext reaches the tree while masked

    @Test("no plaintext value reaches the accessibility tree of a masked preview")
    @MainActor
    func maskedValuesNeverReachTheAccessibilityTree() {
        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(parsed: Self.fixture())
        }

        // Canary: a tree that never populated cannot leak anything, and
        // would let the assertion below pass while proving nothing — same
        // discipline `AccessibilityTreeTests` uses throughout.
        #expect(nodes.contains { $0.value == "API_KEY" },
                "the tree did not populate — this test would be vacuous")

        for node in nodes {
            #expect(!node.value.contains(Self.sentinelValue),
                    "an accessibility value exposed the raw .env value or skipped line")
            #expect(!node.label.contains(Self.sentinelValue),
                    "an accessibility label exposed the raw .env value or skipped line")
            #expect(!node.help.contains(Self.sentinelValue),
                    "accessibility help text exposed the raw .env value or skipped line")
        }
    }

    /// Proves `maskedValuesNeverReachTheAccessibilityTree` is not vacuous the
    /// other way round too: revealing both rows through the same
    /// `initiallyRevealedRowIDs` seam `SecretEditorView` uses (its own doc
    /// comment: the headless snapshot tool cannot click anything, so a test
    /// seam is the only way to reach a revealed row at all) must make the
    /// sentinel actually appear. If it did not, the masked test above could
    /// be passing because nothing ever renders the real value anywhere,
    /// which would say nothing about masking at all.
    @Test("revealing a row exposes its value to the accessibility tree")
    @MainActor
    func revealingARowExposesItsValue() {
        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(
                parsed: Self.fixture(),
                initiallyRevealedRowIDs: [.entry(key: "API_KEY"), .skipped(line: 2)])
        }

        #expect(nodes.contains { $0.value == "API_KEY" },
                "the tree did not populate — this test would be vacuous")
        #expect(nodes.contains { $0.value.contains(Self.sentinelValue) },
                "revealing a row must actually show its value — otherwise the masked test proves nothing")
    }

    /// The value that *is* announced while masked is the same fixed-width
    /// mask `SecretEditorView` uses, never the plaintext — and the row stays
    /// navigable: its key (or line number) is still announced, so a masked
    /// row does not read as anonymous. Mirrors
    /// `AccessibilityTreeTests.maskedRowIsStillNavigable`.
    @Test("a masked row still announces its key or line number, and the reveal control")
    @MainActor
    func maskedRowIsStillNavigable() {
        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(parsed: Self.fixture())
        }

        let values = Set(nodes.map(\.value))
        let labels = Set(nodes.map(\.label))
        #expect(values.contains("API_KEY"))
        #expect(labels.contains(LocalizedKey.editorRevealValue.text))
        // The masked entry value is announced as bullets, never as the
        // plaintext or as nothing at all.
        #expect(nodes.contains {
            !$0.value.isEmpty && $0.value != "API_KEY" && $0.value.allSatisfy { $0 == "•" }
        })
    }

    // MARK: - Every suspicion kind renders its own sentence

    /// One `ParsedDotEnv` per `DotEnvSuspicion.Kind`, each carrying exactly
    /// the suspicion under test on its one entry. `expectedText` is computed
    /// the same way the view itself computes it — through
    /// `LocalizedKey....text`, formatted identically for `.duplicateKey` —
    /// so this holds under both of this machine's compilers exactly as
    /// `AccessibilityTreeTests.statusRowsAnnounceTheirStatus`'s own comment
    /// explains: a hardcoded English literal would pass under one and fail
    /// under the other.
    @Test("every suspicion kind renders its own explanatory sentence", arguments: [
        (DotEnvSuspicion.Kind.strayOpeningQuote, LocalizedKey.dotEnvPreviewSuspicionStrayOpeningQuote.text),
        (.notAPosixName, LocalizedKey.dotEnvPreviewSuspicionNotAPosixName.text),
        (.looksInterpolated, LocalizedKey.dotEnvPreviewSuspicionLooksInterpolated.text),
        (.emptyValue, LocalizedKey.dotEnvPreviewSuspicionEmptyValue.text),
        (.duplicateKey(supersededLines: [1, 3]),
         String(format: LocalizedKey.dotEnvPreviewSuspicionDuplicateKey.text, 5, "1, 3")),
    ])
    @MainActor
    func everySuspicionKindRendersItsSentence(kind: DotEnvSuspicion.Kind, expectedText: String) {
        // `.duplicateKey`'s expected text is formatted against line 5 above,
        // so the entry here must resolve on line 5 too — the winning
        // occurrence's own line, per `DotEnvEntry.line`'s doc comment.
        let entry = DotEnvEntry(key: "SOME_KEY", value: "some-value", line: 5)
        let parsed = ParsedDotEnv(
            entries: [entry], skipped: [],
            suspicions: [DotEnvSuspicion(key: "SOME_KEY", kind: kind)])

        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(parsed: parsed)
        }

        #expect(nodes.contains { $0.value == "SOME_KEY" },
                "the tree did not populate — this test would be vacuous")
        #expect(nodes.contains { $0.value == expectedText },
                "no node announced the suspicion sentence \"\(expectedText)\" for \(kind)")
    }

    // MARK: - Skipped lines are shown, with their line numbers

    @Test("a skipped line is shown with its line number, masked by default")
    @MainActor
    func skippedLineShowsItsLineNumber() {
        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(parsed: Self.fixture())
        }
        let values = nodes.map(\.value)

        #expect(values.contains(String(format: LocalizedKey.dotEnvPreviewSkippedLineLabel.text, 2)),
                "the skipped line's own line number must be shown: \(values)")
        for value in values {
            #expect(!value.contains(Self.sentinelValue))
        }
    }

    // MARK: - The empty state

    @Test("an empty parse result says there is nothing to import")
    @MainActor
    func emptyParseResultSaysSo() {
        let empty = ParsedDotEnv(entries: [], skipped: [], suspicions: [])
        let nodes = AXProbe.tree(size: CGSize(width: 640, height: 400)) {
            DotEnvPreviewTable(parsed: empty)
        }
        #expect(nodes.contains { $0.value == LocalizedKey.dotEnvPreviewEmpty.text })
    }
}
