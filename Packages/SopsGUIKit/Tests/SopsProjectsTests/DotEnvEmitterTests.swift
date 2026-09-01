import Foundation
import SopsEngine
import Testing

@testable import SopsProjects

/// `DotEnvEmitter` is the second place in this feature (alongside
/// `FlatYAMLEmitter`) where a secret is hand-serialised into text rather than
/// passed through sops's own store untouched — see that type's own doc
/// comment for why a mistake here is silent, not a crash. Every test proves
/// correctness by round-tripping through the real bridge (`SopsBridge.encrypt(
/// format: .dotenv)` → `decryptToRows`), the same discipline
/// `FlatYAMLEmitterTests` keeps for the identical reason: a text comparison
/// only proves this file agrees with itself, not that sops's own dotenv store
/// reads the result back the way it was written.
@Suite("DotEnvEmitter")
struct DotEnvEmitterTests {

    private static let pair = try! AgeKeyPair.generate()

    private func roundTrip(_ entries: [DotEnvEntry]) throws -> [SecretRow] {
        let text = DotEnvEmitter.emit(entries)
        let encrypted = try SopsBridge.encrypt(text, format: .dotenv, recipients: [Self.pair.public])
        return try SopsBridge.decryptToRows(encrypted, format: .dotenv, agePrivateKey: Self.pair.private)
    }

    @Test("an empty entry list emits an empty document")
    func emptyEntriesEmitEmptyText() {
        #expect(DotEnvEmitter.emit([]) == "")
    }

    @Test("an empty entry list round-trips to zero rows")
    func emptyEntriesRoundTrip() throws {
        let rows = try roundTrip([])
        #expect(rows.isEmpty)
    }

    @Test("every value shape the dotenv store's own grammar allows survives the round trip")
    func valuesSurviveRoundTrip() throws {
        let entries = [
            DotEnvEntry(key: "NEWLINE", value: "line one\nline two", line: 1),
            DotEnvEntry(key: "QUOTE", value: "she said \"hi\"", line: 2),
            DotEnvEntry(key: "SINGLE_QUOTE", value: "it's fine", line: 3),
            DotEnvEntry(key: "HASH", value: "value #not-a-comment", line: 4),
            DotEnvEntry(key: "EMOJI", value: "rocket 🚀 ship", line: 5),
            DotEnvEntry(key: "EMPTY", value: "", line: 6),
            DotEnvEntry(key: "LEADING_SPACE", value: " starts with a space", line: 7),
            DotEnvEntry(key: "TRAILING_SPACE", value: "ends with a space ", line: 8),
            DotEnvEntry(key: "EQUALS", value: "a=b=c", line: 9),
            DotEnvEntry(key: "TAB", value: "a\tb", line: 10),
        ]

        let rows = try roundTrip(entries)

        #expect(rows.count == entries.count)
        for entry in entries {
            let row = rows.first { $0.path == [entry.key] }
            #expect(row?.value == entry.value, "key \(entry.key)")
        }
    }

    @Test("every key shape DotEnvParser can produce is taken verbatim, with no quoting")
    func keyShapesSurviveRoundTrip() throws {
        // The dotenv store's own `LoadPlainFile` takes everything before the
        // first "=" as the key, unconditionally — no charset restriction of
        // its own — so none of these need the escaping `FlatYAMLEmitter
        // .quotedKey` applies for a YAML target. All four are shapes
        // `DotEnvParser`'s own key grammar (`[\w.-]+`) actually admits.
        let entries = [
            DotEnvEntry(key: "a.b-c", value: "dotted-dashed", line: 1),
            DotEnvEntry(key: "9KEY", value: "leading-digit", line: 2),
            DotEnvEntry(key: "-X", value: "leading-hyphen", line: 3),
            DotEnvEntry(key: "MY-KEY", value: "hyphenated", line: 4),
            DotEnvEntry(key: "PLAIN_KEY", value: "plain", line: 5),
        ]

        let rows = try roundTrip(entries)

        #expect(rows.count == entries.count)
        for entry in entries {
            #expect(rows.first { $0.path == [entry.key] }?.value == entry.value, "key \(entry.key)")
        }
    }

    @Test("a value is always typed .string, even one that looks like a number or a bool")
    func valuesAlwaysComeBackAsStrings() throws {
        let entries = [
            DotEnvEntry(key: "PORT", value: "5432", line: 1),
            DotEnvEntry(key: "FLAG", value: "true", line: 2),
        ]

        let rows = try roundTrip(entries)

        #expect(rows.first { $0.path == ["PORT"] }?.kind == .string)
        #expect(rows.first { $0.path == ["FLAG"] }?.kind == .string)
    }

    @Test("entries are emitted in order, one KEY=value line each")
    func emitsOneLinePerEntryInOrder() {
        let entries = [
            DotEnvEntry(key: "FIRST", value: "1", line: 1),
            DotEnvEntry(key: "SECOND", value: "2", line: 2),
        ]

        #expect(DotEnvEmitter.emit(entries) == "FIRST=1\nSECOND=2\n")
    }

    @Test("a real newline is escaped to the literal two characters backslash-n")
    func newlineEscaping() {
        #expect(DotEnvEmitter.escapedValue("a\nb") == "a\\nb")
    }

    @Test("a lone carriage return is left untouched — the store only splits on LF")
    func carriageReturnUntouched() throws {
        let entries = [DotEnvEntry(key: "CR", value: "a\rb", line: 1)]
        let rows = try roundTrip(entries)
        #expect(rows.first { $0.path == ["CR"] }?.value == "a\rb")
    }
}
