import Foundation
import SwiftUI
import Testing
@testable import SopsUI

/// The Setup guide page (PROPOSAL.md §5, SOPS-41) and the snippet view it is
/// built from. Rendered through `AXProbe` like every other page; the prompt
/// is additionally pinned as a plain string, because what it must say is a
/// property of the text, not of the layout.
@Suite("SetupGuideView")
@MainActor
struct SetupGuideViewTests {

    private static let size = CGSize(width: 760, height: 2600)

    private func text(_ nodes: [AXProbe.Node]) -> String {
        nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
    }

    @Test("every section title is shown")
    func everySectionTitleIsShown() {
        let flat = text(AXProbe.tree(size: Self.size) { SetupGuideView() })
        for key in [LocalizedKey.guideTitle, .guideComposeTitle, .guideNoComposeTitle, .guideServerKeyTitle,
                    .guideColleagueKeyTitle, .guideSopsYamlTitle, .guideAIPromptTitle] {
            #expect(flat.contains(key.text), "missing \(key.rawValue): \(flat.prefix(400))")
        }
    }

    @Test("every snippet has a copy button")
    func everySnippetHasACopyButton() {
        let nodes = AXProbe.tree(size: Self.size) { SetupGuideView() }
        let buttons = nodes.filter { $0.role.contains("Button") && $0.label == LocalizedKey.actionCopy.text }
        #expect(buttons.count == SetupGuideContent.allSnippets.count,
                "\(buttons.count) copy buttons for \(SetupGuideContent.allSnippets.count) snippets")
        #expect(SetupGuideContent.allSnippets.count >= 15)
        #expect(Set(SetupGuideContent.allSnippets.map(\.id)).count == SetupGuideContent.allSnippets.count,
                "snippet ids must be unique — CopyFeedback keys on them")
    }

    @Test("the copy button of one snippet reads Copied without the others following")
    func onlyTheCopiedSnippetReadsCopied() {
        let feedback = CopyFeedback(confirmationDuration: .seconds(30))
        feedback.confirmCopy(of: SetupGuideContent.serverKeygen.id)
        let nodes = AXProbe.tree(size: Self.size) { SetupGuideView(copyFeedback: feedback) }
        let copied = nodes.filter { $0.label == LocalizedKey.actionCopied.text }
        #expect(copied.count == 1, "\(copied.count)")
    }

    /// The prompt's job is to carry the security core into a chat the app
    /// cannot see. Each phrase here is one rule an assistant must not talk
    /// the user out of.
    @Test("the AI prompt states the security core and names nothing of the user's")
    func aiPromptStatesTheSecurityCore() {
        let prompt = SetupGuideContent.aiAssistantPrompt.text
        for required in ["never leaves the machine", "never commit", "age1", "chmod 600", "/etc/age",
                         "SOPS_AGE_KEY_FILE", "safe to commit", "rewrap", "keeps whatever it already read",
                         "exec-env"] {
            #expect(prompt.contains(required), "prompt lacks \"\(required)\"")
        }
        // A public key placeholder is fine in the cookbook; the prompt itself
        // carries no key of any kind, so nothing real can ever slip into it.
        #expect(!prompt.contains("age1e"), "the prompt must not carry a key, even an example one")
        #expect(!prompt.contains("AGE-SECRET-KEY-1Q"), "and certainly not a private one")
    }

    /// Commands are verbatim, never catalog entries — see `SetupGuideContent`.
    @Test("no snippet text is a catalog string")
    func noSnippetIsLocalized() {
        let catalog = Set(LocalizedKey.allCases.map(\.text))
        for snippet in SetupGuideContent.allSnippets {
            #expect(!catalog.contains(snippet.text), "\(snippet.id) is in the catalog")
        }
    }

    /// The colleague snippets name the same key path the health check looks
    /// at, so the guide and the check cannot disagree about where a key goes.
    @Test("colleague snippets use the app's own key location")
    func colleagueSnippetsUseTheAppsKeyLocation() {
        #expect(SetupGuideContent.colleagueMacOS.text.contains("Library/Application Support/sops/age/keys.txt"))
        #expect(SetupGuideContent.colleagueLinux.text.contains("~/.config/sops/age/keys.txt"))
        #expect(SetupGuideContent.colleagueMacOS.text.contains("chmod 600"))
        #expect(SetupGuideContent.colleagueLinux.text.contains("chmod 600"))
    }
}

@Suite("CommandSnippetView")
@MainActor
struct CommandSnippetViewTests {

    private func text(_ nodes: [AXProbe.Node]) -> String {
        nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
    }

    @Test("a snippet shows its command and a Copy button")
    func snippetShowsCommandAndACopyButton() {
        let nodes = AXProbe.tree(size: CGSize(width: 500, height: 100)) {
            CommandSnippetView(command: "chmod 600 /tmp/x-canary", feedbackID: "x", copyFeedback: CopyFeedback())
        }
        let flat = text(nodes)
        #expect(flat.contains("chmod 600 /tmp/x-canary"), "\(flat)")
        #expect(nodes.contains { $0.role.contains("Button") && $0.label == LocalizedKey.actionCopy.text }, "\(flat)")
    }

    @Test("the copy button reads Copied for its own target only")
    func copyButtonReadsCopiedForItsOwnTarget() {
        let feedback = CopyFeedback(confirmationDuration: .seconds(30))
        feedback.confirmCopy(of: "x")
        let mine = text(AXProbe.tree(size: CGSize(width: 500, height: 100)) {
            CommandSnippetView(command: "echo", feedbackID: "x", copyFeedback: feedback)
        })
        let other = text(AXProbe.tree(size: CGSize(width: 500, height: 100)) {
            CommandSnippetView(command: "echo", feedbackID: "y", copyFeedback: feedback)
        })
        #expect(mine.contains(LocalizedKey.actionCopied.text), "\(mine)")
        #expect(!other.contains(LocalizedKey.actionCopied.text), "\(other)")
    }
}
