import AppKit
import SwiftUI
import SopsUI
import SopsHealth
import SopsProjects

/// The two things that have to happen around termination, both of them
/// through AppKit rather than SwiftUI because SwiftUI has no hook for either.
///
/// `applicationShouldTerminate` is the one funnel *every* quit passes through
/// — ⌘Q, the app's own Quit item, the Dock icon's Quit, the Apple menu at
/// logout/restart/shutdown, and `osascript -e 'quit app "SopsGUI"'`. Before it
/// existed here, only the first two asked about unsaved edits, because they
/// were the only ones that went through a SwiftUI command; every other path
/// got AppKit's default `.terminateNow` and the edits vanished. All the
/// judgement lives in `QuitRequest` (in SopsUI, where a test can reach it);
/// what is left below is the mapping onto AppKit's enum.
///
/// `applicationWillTerminate` runs the pasteboard's termination-time guard on
/// the way out. AppKit calls it for an ordinary quit — never for a force-quit
/// or a crash — so it closes the specific gap where a secret was copied and
/// the ~30s auto-clear timer (`ClipboardClearing.copy`) hadn't fired yet when
/// the user quit. See `ClipboardClearing.clearOnTermination()` for the guard
/// itself and the same limit stated where it's enforced.
///
/// Both collaborators are handed over by `SopsGUIApp` once the scene is up.
/// Until then they are `nil` and termination is allowed through, which is
/// correct rather than merely convenient: no document can be open before the
/// window that opens documents exists, so there is nothing to lose.

/// Intercepts `windowShouldClose:` and forwards **everything else** to the
/// delegate SwiftUI installed.
///
/// ## Why a proxy and not just taking the delegate
///
/// The first attempt at guarding ⌘W did this:
///
/// ```swift
/// for window in NSApp.windows where window.delegate == nil { window.delegate = appDelegate }
/// ```
///
/// which assigned **zero** windows, because a SwiftUI window already has one
/// (`AppKitWindowController`). The guard was dead code, and a review measured
/// the result: dirty document → ⌘W → no prompt → window closes →
/// `SecretEditorView`'s `onDisappear` clears the tracker →
/// `applicationShouldTerminate` sees `isDirty == false` → `.terminateNow`.
/// The document, the warning, and the process, all gone in one keystroke.
///
/// Dropping the `where` clause is not the fix either. With the delegate simply
/// replaced, SwiftUI's teardown changed — `onDisappear` stopped firing at all.
/// So this keeps SwiftUI's delegate and stands in front of it, using ObjC
/// message forwarding so that every method this class does *not* implement is
/// answered by the original, including ones AppKit may add later.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    /// SwiftUI's own delegate. Weak: the window owns it, and this proxy must
    /// not be what keeps it alive.
    weak var forwarding: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    init(forwarding: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.forwarding = forwarding
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose()
    }

    // MARK: - Forwarding

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarding?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return forwarding
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var unsavedChanges: UnsavedChangesTracker?
    var quitRequest: QuitRequest?

    /// Strong references, because `NSWindow.delegate` is weak — without this
    /// the proxy is deallocated the moment it is installed and the window
    /// silently reverts to SwiftUI's delegate. Keyed by window so a repeated
    /// `.onAppear` replaces rather than stacks proxies.
    private var closeGuards: [ObjectIdentifier: WindowCloseGuard] = [:]

    /// Puts a `WindowCloseGuard` in front of every window that does not
    /// already have one.
    ///
    /// Idempotent, because `.onAppear` can fire more than once for the same
    /// window and chaining a proxy onto a proxy would make `windowShouldClose`
    /// ask twice.
    func installWindowCloseGuards() {
        // Removing the New Window menu item took the *menu* away; window
        // tabbing puts the capability back. Measured on a scene of this exact
        // shape: `allowsAutomaticWindowTabbing` is true by default,
        // `newWindowForTab:` has a live target, and sending that action really
        // does produce a second window. It is not reachable from today's UI —
        // the tab bar only appears once two windows exist — so the defence
        // rested entirely on a menu item that no longer exists.
        //
        // Two windows share one `UnsavedChangesTracker`, and its registration
        // is last-writer-wins, so a second window opening a clean file wipes
        // the first window's dirty registration and ⌘Q stops warning. That is
        // the finding this app already fixed once, at the menu layer.
        NSWindow.allowsAutomaticWindowTabbing = false

        for window in NSApp.windows {
            let key = ObjectIdentifier(window)
            guard closeGuards[key] == nil else { continue }
            // Guarding the Settings window would **not** be harmless, which
            // an earlier version of this comment claimed. Its close would run
            // through `windowShouldClose` into the *quit* dialog, whose
            // "Discard and Quit" terminates the app — and that dialog is
            // attached to the WindowGroup's content, so it would appear over
            // the main window rather than the one being closed.
            //
            // It does not happen today: the Settings scene is created lazily
            // (measured — one window exists when this runs) and `.onAppear`
            // gets here first. That is a timing accident, not a guarantee, so
            // the window is skipped by identity rather than by hoping.
            if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
                continue
            }
            let guardDelegate = WindowCloseGuard(forwarding: window.delegate) { [weak self] in
                self?.windowShouldClose(window) ?? true
            }
            closeGuards[key] = guardDelegate
            window.delegate = guardDelegate
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitRequest, let unsavedChanges else { return .terminateNow }
        switch quitRequest.answerTerminationRequest(
            documentIsDirty: unsavedChanges.isDirty, saveIsInFlight: unsavedChanges.isSaving)
        {
        case .terminateNow:
            return .terminateNow
        case .askFirst:
            // Not `.terminateLater`: see QuitRequest's doc comment for why the
            // safe failure here is a cancelled logout and not a hung process.
            return .terminateCancel
        case .waitForSaveInFlight:
            // Same reply, no dialog. A save takes 133–380 ms and cannot be
            // interrupted; quitting inside that window risks tearing the
            // process down between the encrypt and the write. The user's next
            // ⌘Q, a moment later, meets a settled document — and if they were
            // saving because they wanted to quit, that quit now goes straight
            // through instead of asking about changes that are already on
            // disk.
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardClearing.clearOnTermination()
    }

    /// Closing the window is the fourth way out of a dirty document, and until
    /// this existed it was unguarded.
    ///
    /// `WindowGroup` gives every window a Close item and a red button, neither
    /// of which passes through `applicationShouldTerminate`. Measured against
    /// the real shell: one window, a dirty document, `performClose(nil)` — the
    /// window count went 1 → 0 with no sheet shown, and because
    /// `SecretEditorView`'s `onDisappear` clears the tracker on the way out, the
    /// **next ⌘Q then answered `.terminateNow`**. The same click destroyed the
    /// document and disarmed the warning that would have named it. That is the
    /// third time this milestone has produced exactly that pair, and the reason
    /// this is a delegate method rather than another `.disabled`.
    ///
    /// It answers with `QuitRequest`, not a second notion of dirty — the same
    /// mistake, made once per exit, is how the earlier three came about.
    ///
    /// The dialog it raises is the quit dialog, and that is deliberate rather
    /// than a shortcut: `.newItem` is removed below, so there is exactly one
    /// window, and closing the only window of a single-document app is the
    /// same decision as quitting. `applicationShouldTerminateAfterLastWindowClosed`
    /// returns true for the same reason, so the two paths cannot drift into
    /// disagreeing about what a closed window means.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let quitRequest, let unsavedChanges else { return true }
        switch quitRequest.answerTerminationRequest(
            documentIsDirty: unsavedChanges.isDirty, saveIsInFlight: unsavedChanges.isSaving)
        {
        case .terminateNow:
            return true
        case .askFirst:
            // `answerTerminationRequest` has raised the dialog. Refusing the
            // close keeps the document, the window and the tracker exactly as
            // they were while the user answers.
            return false
        case .waitForSaveInFlight:
            // No dialog, same refusal: a save takes 133–380 ms and cannot be
            // interrupted. Closing between the encrypt and the write is the
            // one moment where the file on disk is neither version.
            return false
        }
    }

    /// With one window and no way to open a second, a closed window means the
    /// app is done. Stated explicitly so it cannot quietly diverge from
    /// `windowShouldClose`, which reuses the quit question on that assumption.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    /// Sparkle. Created before `health`, because the report below is built
    /// from its status provider — see `AppUpdater`.
    private let appUpdater = AppUpdater()
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
    /// Answers every termination request and holds the "the user already said
    /// yes" latch — see `QuitRequest`. Handed to `AppDelegate` in `onAppear`
    /// below, because `applicationShouldTerminate` is the only hook that sees
    /// all the ways this app can be told to quit.
    @State private var quitRequest = QuitRequest()
    @State private var quitSaveErrorMessage: String?

    init() {
        let store = projectStore
        let keys = keyStore
        let updates = appUpdater.statusProvider
        _projects = State(initialValue: ProjectSidebarModel(store: store))
        _health = State(initialValue: HealthViewModel(reportBuilder: {
            .standard(updateChecksEnabled: { UpdateCheckConsent.isEnabled() },
                      projects: store.healthSource, keyStore: keys.healthSource,
                      // The real thing since 0.1.0. `UnshippedAppUpdates` — the
                      // stub that made `security.app-updates` permanently
                      // `.skipped` — is gone from the app; it survives as the
                      // package's default so `SopsGUIKit` still builds without
                      // Sparkle.
                      appUpdates: updates)
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
                    // `AppDelegate` cannot reach into scene state, and this is
                    // the earliest point at which both it and the state exist.
                    // Until it runs, `applicationShouldTerminate` sees nil and
                    // lets a quit through — correct, because no document can
                    // be open before this window is.
                    appDelegate.unsavedChanges = unsavedChanges
                    appDelegate.quitRequest = quitRequest
                    // SwiftUI owns the window, so guarding its close button
                    // means standing in front of the delegate it installed —
                    // never replacing it, which stops `onDisappear` firing.
                    // Done here rather than in `applicationDidFinishLaunching`
                    // because the window does not exist yet at launch.
                    appDelegate.installWindowCloseGuards()
                }
                // The confirmation itself has to be attached to a view that's
                // actually on screen — `.commands` closures below are not
                // views and can't host an `.alert`/`.confirmationDialog` of
                // their own, and neither can `AppDelegate`.
                .confirmationDialog(
                    LocalizedKey.editorQuitUnsavedTitle.text,
                    isPresented: $quitRequest.isAsking
                ) {
                    Button(LocalizedKey.editorSaveAndQuit.text) {
                        Task { await saveAndQuit() }
                    }
                    Button(LocalizedKey.editorDiscardAndQuit.text, role: .destructive) {
                        // Latch first, then terminate: this call comes straight
                        // back through `applicationShouldTerminate`, where the
                        // document is still dirty, and without the latch the
                        // app could never actually be quit. See `QuitRequest`.
                        quitRequest.settle()
                        NSApp.terminate(nil)
                    }
                    Button(LocalizedKey.actionCancel.text, role: .cancel) {
                        quitRequest.cancel()
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
        // The window used to have no size of its own. `WindowGroup`'s default
        // resizability is `.automatic`, which sizes the window from its
        // content's ideal dimensions — and `AppShell` is a
        // `NavigationSplitView` whose panes all say `maxWidth: .infinity`, so
        // the first launch on a large display produced a window as wide as the
        // screen that then could not be resized. Both halves of that are fixed
        // here: a chosen default size (see `MainWindowMetrics`) and a
        // resizability that only pins the *minimum*.
        .defaultSize(MainWindowMetrics.defaultSize(
            forVisibleFrame: NSScreen.main?.visibleFrame.size
                ?? MainWindowMetrics.idealSize))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(updater: appUpdater.updater)
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
                    // looks brand new. When a scan is already in flight,
                    // `refresh()` makes that run go around again rather than
                    // handing back its result — it used to join and return,
                    // which meant this menu item could settle the wizard on a
                    // report built before the user pressed it.
                    Task { await health.refresh() }
                }
            }
            // This item no longer decides anything, and that is the fix. It
            // used to call a `requestQuit()` that checked `isDirty` itself,
            // which meant ⌘Q and this menu item asked and every other way of
            // quitting the app did not. The check now lives behind
            // `AppDelegate.applicationShouldTerminate`, which all of them go
            // through, so this is an ordinary Quit button again — kept only so
            // the item keeps its own localized title and ⌘Q binding.
            // No New Window, and this is a correctness fix rather than a
            // simplification. Two windows shared one `UnsavedChangesTracker`
            // — verified by object identity — and `SecretEditorView`'s
            // registration is last-writer-wins, so a second window opening a
            // clean file overwrote the first window's dirty registration and
            // ⌘Q went from asking to `.terminateNow`. Closing an unrelated
            // *clean* window disarmed the warning for the dirty document still
            // on screen.
            //
            // `UnsavedChangesTracker`'s own doc comment says it holds at most
            // one document's state because "this app opens one file at a time
            // (PROPOSAL.md's editor is single-document)". That was a statement
            // about the spec that `WindowGroup` did not honour. Making it true
            // is cheaper and less error-prone than making the tracker
            // per-window, and it is what the spec says the app is.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button(LocalizedKey.actionQuit.text) {
                    NSApp.terminate(nil)
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
                UpdateSettingsPanel(onConsentChanged: { appUpdater.refreshConsent() })
                    .tabItem { Label(.settingsTabUpdates, systemImage: "arrow.down.circle") }
            }
            .frame(width: 620, height: 480)
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
            // Only latched on the path that actually saved. A failed save
            // falls through to the error below with the guard still armed, so
            // the next quit asks again rather than walking out over the
            // unsaved edit.
            quitRequest.settle()
            NSApp.terminate(nil)
        case .failed(let message):
            quitSaveErrorMessage = message
        }
    }
}
