import SwiftUI
import SopsUI

@main
struct SopsGUIApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            Text("Settings")
                .frame(width: 480, height: 320)
        }
    }
}
