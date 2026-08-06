import SwiftUI

public struct AppShell: View {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case projects, about, settings

        /// PROPOSAL.md §4: About and Settings sit at the bottom of the sidebar.
        public static let pinnedToBottom: [Section] = [.about, .settings]
    }

    @State private var selection: Section = .projects

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(.sidebarProjects, systemImage: "folder")
                    .tag(Section.projects)
                Spacer()
                Label(.sidebarAbout, systemImage: "info.circle")
                    .tag(Section.about)
                Label(.sidebarSettings, systemImage: "gearshape")
                    .tag(Section.settings)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Text(.detailNoSelection)
                .foregroundStyle(.secondary)
        }
    }
}
