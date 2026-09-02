import SwiftUI

/// The Setup guide page — PROPOSAL.md §5, reachable from the sidebar footer
/// next to About and Settings (SOPS-41).
///
/// Six sections of prose (catalog strings) and snippets
/// (`SetupGuideContent`, verbatim), each snippet with its own copy button
/// through one shared `CopyFeedback`. The last section is a prompt the user
/// can paste into an AI assistant; its whole point is that it carries the
/// security rules of sops+age with it, so an assistant cannot helpfully
/// suggest pasting a private key somewhere.
///
/// Public for the snapshot catalog, like `AboutView`. Rendered inside a
/// `ScrollView` by `AppShell` — the page is tall, and the ScrollView is
/// what keeps it from pinning the window's minimum height (see the `.about`
/// case there).
public struct SetupGuideView: View {

    @State private var copyFeedback: CopyFeedback

    public init(copyFeedback: CopyFeedback = CopyFeedback()) {
        self._copyFeedback = State(initialValue: copyFeedback)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(.guideTitle).font(.title).bold()
                Text(.guideIntro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section(.guideComposeTitle, body: .guideComposeBody,
                    snippets: [SetupGuideContent.composeExecEnv, SetupGuideContent.composeMakefile])

            section(.guideNoComposeTitle, body: .guideNoComposeBody,
                    snippets: [SetupGuideContent.plainExecEnv, SetupGuideContent.direnvEnvrc,
                               SetupGuideContent.systemdEnvironmentFile])

            section(.guideServerKeyTitle, body: .guideServerKeyBody,
                    snippets: [SetupGuideContent.serverInstall, SetupGuideContent.serverKeygen,
                               SetupGuideContent.serverPublicKey, SetupGuideContent.serverKeyFile])

            VStack(alignment: .leading, spacing: 10) {
                Text(.guideColleagueKeyTitle).font(.title2).bold()
                Text(.guideColleagueKeyBody).fixedSize(horizontal: false, vertical: true)
                platform(.guideColleagueKeyMacOS, SetupGuideContent.colleagueMacOS)
                platform(.guideColleagueKeyLinux, SetupGuideContent.colleagueLinux)
                platform(.guideColleagueKeyWindows, SetupGuideContent.colleagueWindows)
                Text(.guideColleagueKeyWSL).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(.guideColleagueKeyShare).fixedSize(horizontal: false, vertical: true)
                snippet(SetupGuideContent.colleagueShare)
            }

            section(.guideSopsYamlTitle, body: .guideSopsYamlBody,
                    snippets: [SetupGuideContent.sopsYamlSingleRule, SetupGuideContent.sopsYamlEncryptedRegex,
                               SetupGuideContent.sopsYamlPerEnvironment])

            section(.guideAIPromptTitle, body: .guideAIPromptBody,
                    snippets: [SetupGuideContent.aiAssistantPrompt])
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: LocalizedKey, body: LocalizedKey,
                         snippets: [SetupGuideContent.Snippet]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2).bold()
            Text(body).fixedSize(horizontal: false, vertical: true)
            ForEach(snippets) { snippet($0) }
        }
    }

    @ViewBuilder
    private func platform(_ label: LocalizedKey, _ snippet: SetupGuideContent.Snippet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            self.snippet(snippet)
        }
    }

    private func snippet(_ snippet: SetupGuideContent.Snippet) -> some View {
        CommandSnippetView(command: snippet.text, feedbackID: snippet.id,
                           copyFeedback: copyFeedback, multiline: snippet.multiline)
    }
}
