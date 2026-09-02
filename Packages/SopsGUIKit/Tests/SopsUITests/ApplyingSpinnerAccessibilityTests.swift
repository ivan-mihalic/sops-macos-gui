import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixtures

private struct ConfirmationFixtureError: Error, CustomStringConvertible {
    let description: String
}

private struct ConfirmationAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> ConfirmationAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ConfirmationFixtureError(description: "age-keygen not found in \(candidates)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw ConfirmationFixtureError(description: "age-keygen produced no usable key pair")
        }
        return ConfirmationAgeKeyPair(private: priv, public: pub)
    }
}

private func confirmationScratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let confirmationPlainYAML = "database:\n    password: correct-horse-battery-staple\n"

/// Holds the *rewrap* — never the load — until the test releases it, so the
/// panel can be walked while an apply is genuinely in flight.
private actor RewrapGate {
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func enter() async {
        if released { return }
        await withCheckedContinuation { release = $0 }
    }

    func releaseNow() {
        released = true
        release?.resume()
        release = nil
    }
}

/// D5. `LocalizationTests` proves the "applying…" string exists and resolves;
/// nothing proved it is *on the spinner* while an apply runs. It is testable
/// because `RecipientAccessModel` takes a rewrap seam that can be held open.
///
/// ⚠️ SOPS-39 task 10 removed this suite's project-wide twin along with
/// `ProjectAccessView`. A project-wide apply now runs through
/// `RewrapCoordinator` into `RewrapSheet`, and the coordinator builds its own
/// `ProjectAccessModel` internally — there is no seam to hold open, so the
/// in-flight state cannot be observed from a probe without adding one.
/// `projectAccessApplyingLabel` is therefore resolved but not proven to be on
/// screen; recorded rather than quietly dropped.
@Suite("The in-flight spinner announces itself on the per-file panel")
@MainActor
struct ApplyingSpinnerAccessibilityTests {

    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    @Test("the panel's spinner carries its accessibility label while apply runs")
    func filePanelSpinnerIsLabelled() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let added = try ConfirmationAgeKeyPair.generate()
        let root = try confirmationScratchDirectory("access-spinner")
        let file = root.appendingPathComponent("a.yaml")
        try SopsBridge.encrypt(confirmationPlainYAML, format: .yaml, recipients: [owner.public])
            .write(to: file, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let gate = RewrapGate()
        let model = RecipientAccessModel(
            fileURL: file, projectURL: nil, keyStore: keyStore, format: .yaml,
            rewrapRecipients: { contents, format, recipients, key in
                await gate.enter()
                return try SopsBridge.updateRecipients(contents, format: format, to: recipients, agePrivateKey: key)
            })

        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })
        model.stageAdd(added.public)

        let applying = Task { await model.apply() }
        await host.settle(until: { model.isApplying })
        try #require(model.isApplying, "the apply never started — this test would be vacuous")

        let inFlight = labels(in: host.nodes())
        #expect(inFlight.contains(LocalizedKey.accessApplyingLabel.text),
                "a bare ProgressView announces nothing to VoiceOver")
        #expect(!inFlight.contains(LocalizedKey.accessApplyButton.text),
                "the Apply button is replaced by the spinner, so this is really the in-flight state")

        await gate.releaseNow()
        #expect(await applying.value == .applied)
        await host.settle(until: { !model.isApplying })
        #expect(!labels(in: host.nodes()).contains(LocalizedKey.accessApplyingLabel.text),
                "the label must go away with the spinner")
    }
}
