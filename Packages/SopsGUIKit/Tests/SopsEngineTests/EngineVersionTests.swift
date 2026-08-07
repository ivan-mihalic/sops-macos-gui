import Testing

@testable import SopsEngine

@Suite("Engine version introspection")
struct EngineVersionTests {

    @Test("the embedded sops version is readable and is bare semver")
    func embeddedSopsVersion() throws {
        let version = EngineVersion.sops
        #expect(version.split(separator: ".").count == 3)
        #expect(!version.hasPrefix("v"))
        // A real bridge build must report a real version, never the
        // not-found marker — and never the old "0.0.0" stand-in either.
        #expect(version != EngineVersion.unknown)
        #expect(version != "0.0.0")
    }

    @Test("the embedded age version is readable and is bare semver")
    func embeddedAgeVersion() throws {
        let version = EngineVersion.age
        #expect(version.split(separator: ".").count == 3)
        #expect(!version.hasPrefix("v"))
        // This is the version debug.ReadBuildInfo() must survive a
        // -buildmode=c-archive build to report; the marker means it silently
        // didn't (see task-3 brief's AgeVersion risk).
        #expect(version != EngineVersion.unknown)
        #expect(version != "0.0.0")
    }

    /// The structural property the whole I2 fix rests on.
    ///
    /// Every consumer of these strings *compares* them. The old sentinel was
    /// "0.0.0", which parses cleanly and then loses every comparison — so an
    /// engine version that was never read made an installed sops 3.0.0 look
    /// current, and made the freshness check warn confidently about a number
    /// nobody established. A marker that cannot parse forces the ambiguity
    /// into the type system instead: `SemanticVersion(parsing:)` returns nil,
    /// and a nil has to be handled somewhere.
    @Test("the not-found marker cannot be mistaken for a version number")
    func unknownMarkerIsNotAVersion() {
        #expect(!EngineVersion.unknown.isEmpty)
        for component in EngineVersion.unknown.split(separator: ".") {
            let isAllDigits = component.allSatisfy { $0.isNumber }
            #expect(!isAllDigits, "\(EngineVersion.unknown) looks parseable as a version number")
        }
    }

    /// The two must not be wired to the same module — a copy-paste that made
    /// `AgeVersion()` read the sops module would still produce valid semver
    /// and satisfy every shape check above.
    @Test("sops and age are read from different modules")
    func versionsComeFromDifferentModules() {
        #expect(EngineVersion.sops != EngineVersion.age)
    }
}
