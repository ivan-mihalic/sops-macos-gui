import Testing
@testable import SopsHealth

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("parses bare and v-prefixed versions identically")
    func parsesBothForms() throws {
        #expect(SemanticVersion(parsing: "3.13.3") == SemanticVersion(3, 13, 3))
        #expect(SemanticVersion(parsing: "v3.13.3") == SemanticVersion(3, 13, 3))
    }

    @Test("treats a missing patch component as zero")
    func toleratesShortVersions() throws {
        #expect(SemanticVersion(parsing: "1.3") == SemanticVersion(1, 3, 0))
        #expect(SemanticVersion(parsing: "2") == SemanticVersion(2, 0, 0))
    }

    @Test("ignores trailing build metadata")
    func ignoresSuffix() throws {
        #expect(SemanticVersion(parsing: "2.54.0 (Apple Git-157)") == SemanticVersion(2, 54, 0))
        #expect(SemanticVersion(parsing: "1.3.1-rc.2") == SemanticVersion(1, 3, 1))
    }

    @Test("rejects strings with no leading number")
    func rejectsGarbage() throws {
        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "unknown") == nil)
    }

    @Test("compares numerically, not lexicographically")
    func comparesNumerically() throws {
        #expect(SemanticVersion(1, 9, 0) < SemanticVersion(1, 10, 0))
        #expect(SemanticVersion(3, 13, 2) < SemanticVersion(3, 13, 3))
        #expect(SemanticVersion(4, 0, 0) > SemanticVersion(3, 99, 99))
    }

    @Test("renders without a v prefix")
    func rendersBare() throws {
        #expect(SemanticVersion(3, 13, 3).description == "3.13.3")
    }

    @Test("rejects numbers that overflow Int")
    func rejectsOverflow() throws {
        #expect(SemanticVersion(parsing: "99999999999999999999.0.0") == nil)
    }

    @Test("rejects empty components between separators")
    func rejectsEmptyComponent() throws {
        #expect(SemanticVersion(parsing: "1..3") == nil)
    }
}
