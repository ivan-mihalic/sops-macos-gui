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

    @Test("json and ini names fall back to yaml — this build writes neither yet")
    func unimplementedFormatsFallBackToYAML() {
        #expect(SopsFileFormat.forDestinationName("secret.json") == .yaml)
        #expect(SopsFileFormat.forDestinationName("secret.ini") == .yaml)
    }

    @Test("an empty name is yaml")
    func emptyName() {
        #expect(SopsFileFormat.forDestinationName("") == .yaml)
    }
}
