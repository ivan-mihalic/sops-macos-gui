import Testing

@testable import SopsEngine

@Suite("Engine version introspection")
struct EngineVersionTests {

    @Test("the embedded sops version is readable and is bare semver")
    func embeddedSopsVersion() throws {
        let version = EngineVersion.sops
        #expect(version.split(separator: ".").count == 3)
        #expect(!version.hasPrefix("v"))
        // "0.0.0" is the C shim's not-found fallback; a real bridge build
        // must never actually report it.
        #expect(version != "0.0.0")
    }

    @Test("the embedded age version is readable and is bare semver")
    func embeddedAgeVersion() throws {
        let version = EngineVersion.age
        #expect(version.split(separator: ".").count == 3)
        #expect(!version.hasPrefix("v"))
        // This is the version debug.ReadBuildInfo() must survive a
        // -buildmode=c-archive build to report; "0.0.0" means it silently
        // didn't (see task-3 brief's AgeVersion risk).
        #expect(version != "0.0.0")
    }
}
