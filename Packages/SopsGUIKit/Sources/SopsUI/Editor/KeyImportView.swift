import SwiftUI
import SopsHealth
import SopsProjects

/// Gives the app a decryption key for the session: a paste field, and a
/// separate, explicit action that imports from a plaintext key file already
/// on this Mac.
///
/// The key-file import is a button, never something this view does on
/// its own `onAppear` or similar — `SecurityPostureCheck`'s
/// `security.legacy-key-file` finding exists specifically to warn the user
/// that file sits on disk unprotected, and silently reading it the moment
/// this view opens would contradict that warning with the app's own
/// behavior. The user has to ask for it.
///
/// *Which* file, and what the control says about it, is
/// `LegacyKeyFileImportOptions` — including why the several-candidates case is
/// a menu the user picks from rather than a choice this app makes, and why only
/// the exactly-one case is allowed to put a path in a label. Resolving that is
/// a `stat` per candidate and never an open, so the never-reads-without-a-click
/// property above survives intact.
public struct KeyImportView: View {
    @Bindable private var store: SessionKeyStore
    @State private var pastedText: String = ""
    @State private var errorMessage: String?
    /// The path a successful key-file import actually read, or nil. Was a
    /// bare `justImportedFromLegacyFile: Bool` back when there was only ever
    /// one path it could have been; the `chmod` advice below has to name the
    /// file that exists, so the flag has to carry which one.
    @State private var importedPath: String?
    /// Was a write-only `didCopyChmodCommand` flag that never went back to
    /// "Copy" once pressed — the same defect `HealthFindingRow` carried, and
    /// unreachable from a test for the same reason. See `CopyFeedback`.
    @State private var copyFeedback = CopyFeedback()
    /// SOPS-46. Whether the next import should also be written to the vault.
    /// Off by default: storing a private key durably is a decision, and a
    /// checkbox that arrives pre-ticked is not one the user made.
    @State private var rememberInKeychain = false
    /// Set when an import succeeded but saving it did not — see
    /// `SessionKeyStore.importKey(_:remember:)` for why that is a warning
    /// rather than a thrown error, and why it must not be shown in the error
    /// alert next to "your key was rejected".
    @State private var notSavedReason: String?
    /// True only while a Touch ID prompt is up, so the unlock button can
    /// disable itself. Not a general "busy" flag: nothing else in this view
    /// blocks.
    @State private var isUnlocking = false
    /// The TTL control's own state. `SessionTTLPreference` shipped with the
    /// mechanism and nothing that could set it — `PROPOSAL §4` lists this
    /// control, and it belongs beside the key it governs rather than on a
    /// screen that is not about the key.
    @State private var ttl: SessionTTLSetting

    /// Re-run on every appearance, not resolved once and frozen: a user who
    /// reads the `security.legacy-key-file` finding, goes and `chmod`s or
    /// deletes the file, and comes back to this tab must not be looking at a
    /// button describing the disk as it was when the window opened.
    private let resolveLegacyKeyFiles: @Sendable () -> LegacyKeyFileImportOptions
    @State private var legacyKeyFiles: LegacyKeyFileImportOptions

    /// `legacyKeyFiles` is injected so tests and `SnapshotTool` can reach all
    /// three cases without creating files under the real `$HOME` — see
    /// `LegacyKeyFileImportOptions.resolve`, whose defaults are the only place
    /// the real machine is consulted.
    /// `defaults` is injectable for the same reason `UpdateConsentToggle`'s is:
    /// the snapshot tool renders this view, and `CLAUDE.md` requires fixtures to
    /// stay off `UserDefaults.standard` entirely. A stepper bound to the real
    /// domain would let a snapshot run change the machine owner's own TTL.
    public init(store: SessionKeyStore,
                legacyKeyFiles: @escaping @Sendable () -> LegacyKeyFileImportOptions
                    = { .resolve() },
                defaults: UserDefaults = .standard) {
        _ttl = State(initialValue: SessionTTLSetting(defaults: defaults))
        self.store = store
        self.resolveLegacyKeyFiles = legacyKeyFiles
        _legacyKeyFiles = State(initialValue: legacyKeyFiles())
    }

    public var body: some View {
        Form {
            Section {
                statusRow

                if let notSavedReason {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(.keyNotSavedTitle)
                            Text(verbatim: notSavedReason)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            unlockSection

            Section {
                TextEditor(text: $pastedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .accessibilityLabel(LocalizedKey.keyPasteHeader.text)

                HStack {
                    Button(LocalizedKey.keyImportPasteButton.text) {
                        importPastedText()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    if store.state == .configured {
                        Button(LocalizedKey.keyForgetButton.text, role: .destructive) {
                            store.forget()
                            importedPath = nil
                        }
                    }
                }

                Toggle(LocalizedKey.keyRememberToggle.text, isOn: $rememberInKeychain)
            } header: {
                Text(.keyPasteHeader)
            } footer: {
                Text(.keyPasteFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only while there is no key. Someone who has already imported
                // one knows where theirs came from, and a standing recipe for
                // making another would just be noise under the field.
                //
                // This says the same thing the `security.keystore` finding
                // says, on purpose. They are two separate entrances to the
                // same dead end — the editor sends a user straight here with
                // "Add your age private key in Settings › Key", and that route
                // never passes the health report — so closing only one leaves
                // the other exactly as it was.
                if store.state == .empty {
                    Text(.keyPasteNoKeyYet)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(.keyRememberFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                // SOPS-51. Was a `Stepper` over 1…480 in steps of five: 96
                // reachable values for a decision with four meaningful
                // answers, and eleven presses to get from 15 minutes to an
                // hour. `ttl.offeredMinutes` is the four, plus any off-list
                // value already stored — see that property for why dropping
                // such a value would lose a setting by merely looking at it.
                Picker(LocalizedKey.keyTTLHeader.text, selection: $ttl.minutes) {
                    ForEach(ttl.offeredMinutes, id: \.self) { minutes in
                        Text(Self.durationLabel(forMinutes: minutes)).tag(minutes)
                    }
                }
            } footer: {
                Text(.keyTTLFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                legacyImportControl

                if let importedPath {
                    legacyFileImportedCallout(path: importedPath)
                }
            } footer: {
                legacyImportFooter
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { legacyKeyFiles = resolveLegacyKeyFiles() }
        .alert(
            LocalizedKey.keyImportErrorTitle.text,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Three states, three sentences. This was a binary
    /// configured/empty pair until SOPS-46; `.locked` cannot borrow either of
    /// them, because "no key" is false and "a key is imported" is not yet
    /// true.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(store.state == .configured ? .green : .secondary)
            Text(statusText)
        }
    }

    private var statusSymbol: String {
        switch store.state {
        case .configured: "checkmark.circle.fill"
        case .locked: "lock.fill"
        case .empty, .unavailable: "circle.dashed"
        }
    }

    private var statusText: String {
        switch store.state {
        case .configured: LocalizedKey.keyStatusConfigured.text
        case .locked: LocalizedKey.keyStatusLocked.text
        // `.unavailable` is not reachable from `SessionKeyStore`, whose own
        // `state` never returns it. Sharing `.empty`'s sentence rather than
        // inventing a fourth is the honest fallback: both mean "this app has
        // no key to work with right now".
        case .empty, .unavailable: LocalizedKey.keyStatusEmpty.text
        }
    }

    /// The unlock affordance, present only while there is something to
    /// unlock. Above the paste field on purpose: someone whose key is in the
    /// Keychain should not have to read past an import form to find the
    /// one-click way back in.
    @ViewBuilder private var unlockSection: some View {
        if store.state == .locked {
            Section {
                Button {
                    unlock()
                } label: {
                    Text(.keyUnlockButton)
                }
                .disabled(isUnlocking)

                Button(LocalizedKey.keyRemoveButton.text, role: .destructive) {
                    removeStoredKey()
                }
            } footer: {
                Text(.keyUnlockFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one control whose shape depends on what is actually on disk. See
    /// `LegacyKeyFileImportOptions` for the decision and its justification;
    /// the rule this enforces is that a path appears in a label only when that
    /// path is certainly the one a click will read.
    @ViewBuilder
    private var legacyImportControl: some View {
        switch legacyKeyFiles {
        case .noneFound:
            // Disabled rather than absent: the footer below names where this
            // app looked, and a footer with no control above it is an
            // explanation of nothing.
            Button(LocalizedKey.keyImportLegacyNoneButton.text) {}
                .disabled(true)

        case .one(let path):
            Button {
                importFromLegacyFile(at: path)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(.keyImportLegacyButton)
                    // `Text(verbatim:)`, never a `String(format:)` of a
                    // localized template: SwiftPM's native build copies the
                    // catalog uncompiled, so under bare `swift test` the
                    // template resolves to its own raw key — which has no
                    // `%@` in it, so the path would be dropped on the floor
                    // under one of this machine's two compilers and present
                    // under the other. Composed this way it is the same text
                    // either way, and the path is never a translatable string
                    // in the first place.
                    Text(verbatim: path)
                        .font(.caption)
                        .monospaced()
                }
            }

        case .several(let paths):
            // A menu, because there is no correct answer to "which file?"
            // before the user gives one, and this app does not guess. Opening
            // the menu reads nothing; each item reads exactly its own path.
            Menu {
                ForEach(paths, id: \.self) { path in
                    Button {
                        importFromLegacyFile(at: path)
                    } label: {
                        Text(verbatim: path)
                    }
                }
            } label: {
                Text(.keyImportLegacyChooseButton)
            }
            .fixedSize()
        }
    }

    /// Always the never-automatically promise; plus, when nothing was found,
    /// the list of places that were looked at.
    ///
    /// The extra sentence is the same discipline `SecurityPostureCheck`'s
    /// all-clear had to learn: "nothing found" is indistinguishable from
    /// "looked in the wrong place" unless the places are named, and this app
    /// spent a whole milestone naming the wrong one.
    private var legacyImportFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.keyImportLegacyFooter)
            if case .noneFound(let searched) = legacyKeyFiles {
                Text(.keyImportLegacyNoneFooter)
                ForEach(searched, id: \.self) { path in
                    Text(verbatim: path).monospaced()
                }
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shown once, right after a successful import from a key file on disk.
    /// This app has been telling the user that file is a risk
    /// (`security.legacy-key-file`); this is the moment it can point at the
    /// next step — and it repeats that finding's own `chmod 600` advice
    /// rather than inventing a different fix for the same problem. Both come
    /// from `AgeKeyFileLocations.protectCommand(for:)` so they cannot drift.
    ///
    /// `path` is the file that was actually read, not a constant: naming a
    /// path the user does not have is the defect this whole task exists to
    /// close, and it would be at its worst in a command the user is invited
    /// to paste into a shell.
    @ViewBuilder
    private func legacyFileImportedCallout(path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.keyImportLegacySuccess)
                .fixedSize(horizontal: false, vertical: true)
            // Nil when no honest single-line command can name the file — a
            // `SOPS_AGE_KEY_FILE` containing a newline is the reachable case.
            // The import still succeeded and the warning still stands; only
            // the paste-able command is withheld, which is what
            // `ShellQuoting` refuses for everywhere else.
            if let command = AgeKeyFileLocations.protectCommand(for: [path]) {
                // Copy semantics — `copyWithoutAutoClear`, the concealed
                // markers — live in `CommandSnippetView`; this command names
                // the absolute path to a private key file.
                CommandSnippetView(command: command, feedbackID: Self.chmodCopyTarget, copyFeedback: copyFeedback)
            } else {
                // Ticket #7: before this branch existed, `command == nil`
                // meant the whole block above simply vanished — the success
                // message stood alone with no hint that there was still
                // something to do. Same wording `SecurityPostureCheck`'s
                // matching fallback uses, for the same reason the command
                // itself is shared: one explanation for one problem.
                Text(.keyImportLegacyChmodUnavailable)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// This view has exactly one copy button, so its `CopyFeedback` target is
    /// a constant rather than anything derived. It only ever has to be
    /// distinct from other targets sharing the same `CopyFeedback` — and this
    /// one is shared with nothing.
    private static let chmodCopyTarget = "key.chmod"

    private func importPastedText() {
        do {
            let warning = try store.importKey(pastedText, remember: rememberInKeychain)
            pastedText = ""
            importedPath = nil
            errorMessage = nil
            notSavedReason = warning.map(Self.reason(for:))
        } catch {
            errorMessage = message(for: error)
        }
    }

    /// SOPS-46. Reads the key out of the vault, which puts a Touch ID prompt
    /// on screen.
    ///
    /// A cancelled prompt is not an error worth an alert — the user just
    /// decided not to, and the button is still there — so it is swallowed.
    /// Everything else goes through the same alert a bad paste would, because
    /// everything else means the key did not come back and the user needs to
    /// know why.
    private func unlock() {
        isUnlocking = true
        Task {
            defer { isUnlocking = false }
            do {
                try await store.unlock()
                errorMessage = nil
                notSavedReason = nil
            } catch AgeKeyVaultError.authenticationCancelled {
                errorMessage = nil
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func removeStoredKey() {
        do {
            try store.forgetPermanently()
            importedPath = nil
            notSavedReason = nil
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    /// "5 minutes", "1 hour" — never "60 minutes", which is not how anybody
    /// says an hour.
    ///
    /// Whole hours only: the menu offers one, and a stored 90 stays "90
    /// minutes" rather than becoming "1.5 hours", because a fraction in a
    /// duration label reads as a precision this setting does not have.
    static func durationLabel(forMinutes minutes: Int) -> String {
        if minutes >= 60 && minutes % 60 == 0 {
            return String(format: LocalizedKey.keyTTLHours.text, minutes / 60)
        }
        return String(format: LocalizedKey.keyTTLMinutes.text, minutes)
    }

    /// The user-facing half of an `AgeKeyVaultError`. Never the raw status
    /// code on its own — `.failed` is the case with nothing to say, and it
    /// says exactly that rather than printing a number into a sentence.
    static func reason(for error: AgeKeyVaultError) -> String {
        switch error {
        case .unavailable(let reason): reason
        case .authenticationCancelled: "Touch ID was cancelled, so the key was not saved."
        case .noStoredKey: "There was no key to read back."
        case .unreadableStoredKey: "The stored key could not be read."
        case .failed: "The Keychain refused to store this key."
        }
    }

    /// The only place in this view that opens a key file, and it is reachable
    /// only from a `Button` action — a menu item's or the single-file
    /// button's. See the type's doc comment for why that matters.
    private func importFromLegacyFile(at path: String) {
        do {
            let warning = try store.importFromLegacyKeyFile(at: path, remember: rememberInKeychain)
            importedPath = path
            copyFeedback.reset()
            errorMessage = nil
            notSavedReason = warning.map(Self.reason(for:))
        } catch {
            importedPath = nil
            errorMessage = message(for: error)
        }
    }

    /// Every case here maps to fixed, pre-written English text — never the
    /// error's own `String(describing:)` or the input the user typed. That
    /// is deliberate, not incidental: an import error is the single most
    /// tempting place in this app to echo the input back "so the user can
    /// see what they pasted", and the standing rule (CLAUDE.md) is that no
    /// secret value reaches a log, an error, or a crash report. See
    /// `SessionKeyStoreTests.noErrorMessageLeaksTheSuppliedKey` for the
    /// property this upholds.
    private func message(for error: Swift.Error) -> String {
        switch error {
        case SessionKeyStore.Error.empty:
            LocalizedKey.keyErrorEmpty.text
        case SessionKeyStore.Error.notAnAgeKey:
            LocalizedKey.keyErrorNotAnAgeKey.text
        case SessionKeyStore.Error.multipleKeysInFile(let count):
            String(format: LocalizedKey.keyErrorMultipleKeys.text, count)
        case SessionKeyStore.Error.multipleLinesPasted:
            LocalizedKey.keyErrorMultipleLinesPasted.text
        case SessionKeyStore.Error.unreadableKeysFile:
            LocalizedKey.keyErrorUnreadableKeysFile.text
        case let vaultError as AgeKeyVaultError:
            // Vault errors reach this alert only from `unlock()` and
            // `removeStoredKey()`; the import path routes its own through the
            // inline warning instead, because there the key did arrive.
            Self.reason(for: vaultError)
        default:
            // `importFromLegacyKeyFile(at:)` also throws whatever
            // `String(contentsOfFile:encoding:)` throws (file missing,
            // unreadable, wrong encoding) — none of those carry key
            // material, but they're Foundation/POSIX errors, not this
            // store's own cases, so they get one generic, honest message
            // rather than a leaked system error string.
            LocalizedKey.keyErrorReadFailed.text
        }
    }
}
