import SwiftUI

public struct AppShell: View {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case projects, about, settings

        /// PROPOSAL.md §4: About and Settings sit at the bottom of the sidebar.
        /// `body` reads this directly to decide which rows scroll at the top
        /// versus which are pinned in the bottom inset — it is not just
        /// documentation, it drives the actual layout.
        public static let pinnedToBottom: [Section] = [.about, .settings]

        fileprivate var labelKey: LocalizedKey {
            switch self {
            case .projects: .sidebarProjects
            case .about: .sidebarAbout
            case .settings: .sidebarSettings
            }
        }

        fileprivate var systemImage: String {
            switch self {
            case .projects: "folder"
            case .about: "info.circle"
            case .settings: "gearshape"
            }
        }
    }

    /// Everything not pinned to the bottom, in declaration order. Derived from
    /// `pinnedToBottom` so there is one source of truth for the split.
    private static let scrollingSections: [Section] =
        Section.allCases.filter { !Section.pinnedToBottom.contains($0) }

    @State private var selection: Section = .projects
    private let projects: ProjectSidebarModel

    /// `projects` has no default: the caller (`SopsGUIApp`) owns the single
    /// `ProjectStore` instance the health check is also wired to (see
    /// `HealthViewModel.init(reportBuilder:)`), and a hidden default here
    /// would make it too easy to accidentally construct a second, unrelated
    /// store — which would desync the sidebar from what the health report
    /// sees, silently.
    public init(projects: ProjectSidebarModel) {
        self.projects = projects
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Self.scrollingSections, id: \.self) { section in
                    Label(section.labelKey, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Divider()
                    ForEach(Section.pinnedToBottom, id: \.self) { section in
                        PinnedSidebarRow(section: section, selection: $selection)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            // Only `.projects` has real content so far — About and Settings
            // are reached elsewhere (Settings opens via ⌘, as its own scene;
            // About has no view yet). Selecting either still shows the
            // placeholder rather than the project list, which would be a
            // confusing thing to land on from an unrelated sidebar row.
            switch selection {
            case .projects:
                ProjectSidebar(model: projects)
            case .about, .settings:
                Text(.detailNoSelection)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A sidebar row for a pinned section, styled to match the selection look of
/// a native `List` row so the bottom inset reads as part of the same
/// sidebar. Deliberately not a `List` row itself: a bare `Spacer()` inside a
/// `List` renders as an ordinary fixed-height row rather than flexible
/// space (that was the original bug), and a second `List` nested in the
/// `safeAreaInset` doesn't reliably self-size to its two rows even with
/// `.fixedSize(vertical: true)` — it rendered at zero height. Plain buttons
/// laid out in a `VStack` size themselves correctly at every window height.
private struct PinnedSidebarRow: View {
    let section: AppShell.Section
    @Binding var selection: AppShell.Section

    private var isSelected: Bool { selection == section }

    var body: some View {
        Button {
            selection = section
        } label: {
            Label(section.labelKey, systemImage: section.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
    }
}
