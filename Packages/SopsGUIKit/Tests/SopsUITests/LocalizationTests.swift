import Foundation
import Testing
@testable import SopsUI

@Suite("localization")
struct LocalizationTests {

    // SwiftPM compiles Localizable.xcstrings into en.lproj/Localizable.strings when the
    // target declares `.process("Resources")` — that compilation is what makes
    // String(localized:bundle:) actually resolve at runtime. Checking for the raw
    // ".xcstrings" file here would pass only under `.copy`, which ships the source file
    // uncompiled and silently breaks every localized lookup — the opposite of what this
    // module needs. So this test asserts on the compiled artifact that really ships.
    @Test("the string catalog ships in the module bundle")
    func catalogIsBundled() throws {
        #expect(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj") != nil,
                "compiled Localizable.strings is missing from the SopsUI bundle's en.lproj")
    }

    // Every view added in any task must add its keys here. A key that resolves
    // to itself means the catalog entry was forgotten.
    @Test("every key this module uses resolves to English text, not to the key",
          arguments: LocalizedKey.allCases)
    func everyKeyResolves(key: LocalizedKey) {
        #expect(key.text != key.rawValue, "missing catalog entry for \(key.rawValue)")
    }
}
