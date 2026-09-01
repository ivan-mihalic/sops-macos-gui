import Testing

@testable import SopsEngine

/// `SopsFileFormat.forDestinationName(_:)` (task SOPS-38) is the one place
/// this app decides a not-yet-created file's format from its name alone —
/// `SecretFileCreator.create` and `NewSecretFileModel.targetFormat` both call
/// it, so this suite is the single place that decision itself is pinned.
@Suite("SopsFileFormat.forDestinationName")
struct SopsFileFormatDestinationNameTests {

    @Test("a plain .env name is dotenv")
    func plainDotEnv() {
        #expect(SopsFileFormat.forDestinationName(".env") == .dotenv)
    }

    @Test("a .sops.env name is dotenv, same as any other .env name")
    func sopsDotEnv() {
        #expect(SopsFileFormat.forDestinationName(".sops.env") == .dotenv)
    }

    @Test("a named .env file, with a directory-shaped prefix, is dotenv")
    func namedDotEnvWithPrefix() {
        #expect(SopsFileFormat.forDestinationName("secrets/production.env") == .dotenv)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(SopsFileFormat.forDestinationName("PRODUCTION.ENV") == .dotenv)
        #expect(SopsFileFormat.forDestinationName("Secrets.Env") == .dotenv)
    }

    @Test("a plain .yaml name is yaml")
    func plainYAML() {
        #expect(SopsFileFormat.forDestinationName("secret.yaml") == .yaml)
    }

    @Test("a name with no extension at all is yaml")
    func noExtension() {
        #expect(SopsFileFormat.forDestinationName("secret") == .yaml)
    }

    @Test("a name that merely contains \"env\" without the dot is not dotenv")
    func containsEnvWithoutDot() {
        #expect(SopsFileFormat.forDestinationName("foo.venv") == .yaml)
        #expect(SopsFileFormat.forDestinationName("environment.yaml") == .yaml)
    }

    @Test("a plain .json name is json")
    func plainJSON() {
        #expect(SopsFileFormat.forDestinationName("secret.json") == .json)
    }

    @Test("a .sops.json name is json, same as any other .json name")
    func sopsJSON() {
        #expect(SopsFileFormat.forDestinationName(".sops.json") == .json)
    }

    @Test("a named .json file, with a directory-shaped prefix, is json")
    func namedJSONWithPrefix() {
        #expect(SopsFileFormat.forDestinationName("secrets/production.json") == .json)
    }

    @Test("json matching is case-insensitive")
    func jsonCaseInsensitive() {
        #expect(SopsFileFormat.forDestinationName("PRODUCTION.JSON") == .json)
        #expect(SopsFileFormat.forDestinationName("Secrets.Json") == .json)
    }

    @Test("a name that merely contains \"json\" without the dot is not json")
    func containsJSONWithoutDot() {
        #expect(SopsFileFormat.forDestinationName("foo.msjson") == .yaml)
        #expect(SopsFileFormat.forDestinationName("jsonfile.yaml") == .yaml)
    }

    @Test("a plain .ini name is ini")
    func plainINI() {
        #expect(SopsFileFormat.forDestinationName("secret.ini") == .ini)
    }

    @Test("a .sops.ini name is ini, same as any other .ini name")
    func sopsINI() {
        #expect(SopsFileFormat.forDestinationName(".sops.ini") == .ini)
    }

    @Test("a named .ini file, with a directory-shaped prefix, is ini")
    func namedINIWithPrefix() {
        #expect(SopsFileFormat.forDestinationName("secrets/production.ini") == .ini)
    }

    @Test("ini matching is case-insensitive")
    func iniCaseInsensitive() {
        #expect(SopsFileFormat.forDestinationName("PRODUCTION.INI") == .ini)
        #expect(SopsFileFormat.forDestinationName("Secrets.Ini") == .ini)
    }

    @Test("a name that merely contains \"ini\" without the dot is not ini")
    func containsINIWithoutDot() {
        #expect(SopsFileFormat.forDestinationName("foo.mini") == .yaml)
        #expect(SopsFileFormat.forDestinationName("initial.yaml") == .yaml)
    }

    @Test("an empty name is yaml")
    func emptyName() {
        #expect(SopsFileFormat.forDestinationName("") == .yaml)
    }
}
