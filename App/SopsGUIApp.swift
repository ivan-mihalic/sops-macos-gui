import AppKit
import SwiftUI
import SopsUI
import SopsHealth
import SopsProjects

/// Runs the pasteboard's termination-time guard on the way out. AppKit calls
/// `applicationWillTerminate(_:)` for an ordinary quit — Cmd-Q, the app's
/// Quit menu item, "Quit and Keep Windows" — never for a force-quit or a
/// crash, so this closes the specific gap where a secret was copied and the
/// ~30s auto-clear timer (`ClipboardClearing.copy`) hadn't fired yet when the
/// user quit. See `ClipboardClearing.clearOnTermination()` for the guard
/// itself and the same limit stated where it's enforced.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ClipboardClearing.clearOnTermination()
    }
}

@main
struct SopsGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // One ProjectStore, shared by the sidebar and the health check, backed
    // by the app's real Application Support location. The sidebar mutates it
    // (add/remove); the health report reads it fresh on every refresh — see
    // `_health`'s initializer below and `HealthViewModel.init(reportBuilder:)`.
    // Two separate instances would each load the same file at launch and
    // *look* consistent then, but the sidebar's edits would never reach the
    // health check without a relaunch — the exact staleness bug
    // `reportBuilder` exists to avoid.
    private let projectStore = ProjectStore(fileURL: ProjectStore.defaultFileURL)
    // One SessionKeyStore, shared by the Settings › Key panel and the health
    // check, for the same reason `projectStore` is shared: an import made in
    // the Key panel must be visible to the next health run without a
    // relaunch, and two separate instances would silently desync.
    private let keyStore = SessionKeyStore()
    @State private var projects: ProjectSidebarModel
    // Rebuilt from scratch on every refresh rather than captured once at
    // launch, so a project added through the sidebar mid-session is seen the
    // next time the report runs, not only after relaunching the app. Also
    // read live from UserDefaults on every run: Settings › Updates writes the
    // same key, and a captured Bool would ignore the toggle for the rest of
    // the session. The key store is read fresh for the same reason — an
    // import or a Forget in Settings › Key must show up the next time the
    // report runs, not only after relaunching.
    @State private var health: HealthViewModel
    @State private var onboarding = OnboardingState()
    @State private var isShowingOnboarding = false
    // Shared with `AppShell`'s editor so the app-level Quit command (below)
    // can ask before discarding an open document — see
    // `UnsavedChangesTracker`'s doc comment for why this can't just be a
    // `@State` local to whichever view happens to own the open file.
    @State private var unsavedChanges = UnsavedChangesTracker()
    @State private var isShowingQuitConfirmation = false
    @State private var quitSaveErrorMessage: String?

    init() {
        let store = projectStore
        let keys = keyStore
        _projects = State(initialValue: ProjectSidebarModel(store: store))
        _health = State(initialValue: HealthViewModel(reportBuilder: {
            .standard(updateChecksEnabled: { UpdateCheckConsent.isEnabled() },
                      projects: store.healthSource, keyStore: keys.healthSource)
        }))
    }

    var body: some Scene {
        WindowGroup {
            AppShell(projects: projects, keyStore: keyStore, unsavedChanges: unsavedChanges)
                .sheet(isPresented: $isShowingOnboarding) {
                    OnboardingWizard(health: health, state: onboarding)
                }
                .onAppear {
                    isShowingOnboarding = !onboarding.hasCompletedOnboarding
                }
                // The confirmation itself has to be attached to a view that's
                // actually on screen — `.commands` closures below are not
                // views and can't host an `.alert`/`.confirmationDialog` of
                // their own.
                .confirmationDialog(
                    LocalizedKey.editorQuitUnsavedTitle.text,
                    isPresented: $isShowingQuitConfirmation
                ) {
                    Button(LocalizedKey.editorSaveAndQuit.text) {
                        Task { await saveAndQuit() }
                    }
                    Button(LocalizedKey.editorDiscardAndQuit.text, role: .destructive) {
                        NSApp.terminate(nil)
                    }
                    Button(LocalizedKey.actionCancel.text, role: .cancel) {
                        isShowingQuitConfirmation = false
                    }
                } message: {
                    Text(.editorQuitUnsavedMessage)
                }
                .alert(
                    LocalizedKey.editorSaveErrorTitle.text,
                    isPresented: Binding(
                        get: { quitSaveErrorMessage != nil },
                        set: { isPresented in if !isPresented { quitSaveErrorMessage = nil } })
                ) {
                    Button(LocalizedKey.actionDone.text) { quitSaveErrorMessage = nil }
                } message: {
                    Text(quitSaveErrorMessage ?? "")
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(LocalizedKey.actionRunSetupCheck.text) {
                    onboarding.restart()
                    isShowingOnboarding = true
                    // The menu item is named for an action, and PROPOSAL.md §6
                    // requires the report to re-run on demand — so it re-runs
                    // here rather than relying on the wizard's `.task`. That
                    // fires only when the sheet is *presented*; invoking this
                    // while the wizard is already open changes no sheet
                    // identity, so the user was walked back to Welcome and
                    // shown the previous scan's results under a flow that
                    // looks brand new. `refresh()` coalesces, so this is at
                    // worst a no-op when a scan is already in flight.
                    Task { await health.refresh() }
                }
            }
            // PROPOSAL.md's editor is the one place in this app where
            // quitting can destroy work — an open document with unsaved
            // edits. Replacing the standard Quit item (rather than adding a
            // second one) is what lets this also intercept ⌘Q itself, not
            // just the menu click.
            CommandGroup(replacing: .appTermination) {
                Button(LocalizedKey.actionQuit.text) {
                    requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            TabView {
                HealthPanel(model: health)
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
                KeyImportView(store: keyStore)
                    .tabItem { Label(.settingsTabKey, systemImage: "key") }
                UpdateSettingsPanel()
                    .tabItem { Label(.settingsTabUpdates, systemImage: "arrow.down.circle") }
            }
            .frame(width: 620, height: 480)
        }
    }

    /// Quits immediately when nothing is unsaved; otherwise shows the
    /// confirmation instead of terminating. `unsavedChanges.isDirty` is kept
    /// current by whichever `SecretEditorView` is on screen — see
    /// `UnsavedChangesTracker`.
    private func requestQuit() {
        if unsavedChanges.isDirty {
            isShowingQuitConfirmation = true
        } else {
            NSApp.terminate(nil)
        }
    }

    /// "Save and Quit": saves the open document through the tracker (which
    /// forwards to the real `SecretDocumentViewModel.save()` — see
    /// `UnsavedChangesTracker.save()`) and only terminates if that actually
    /// succeeded. A failed save here must behave exactly like a failed save
    /// from the editor's own Save button: the app stays open, the edit is
    /// still sitting there unsaved, and the user sees why — never a quiet
    /// termination over a write that didn't happen.
    private func saveAndQuit() async {
        switch await unsavedChanges.save() {
        case .saved, nil:
            NSApp.terminate(nil)
        case .failed(let message):
            quitSaveErrorMessage = message
        }
    }
}
