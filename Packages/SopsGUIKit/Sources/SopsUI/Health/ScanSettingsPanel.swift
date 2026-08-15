import SwiftUI
import SopsHealth

/// The Settings tab that owns `ProjectScanner.maxScannedFiles`'s override
/// (ticket #25 claim 1).
///
/// Before this existed, the scan budget was a hardcoded `20_000` with
/// nothing anywhere in the app that could change it. A monorepo past that
/// count had every project finding permanently demoted to `.unknown`
/// (`ScanLimitation.budgetExhausted.blocksAffirmativeVerdict` is `true`) and
/// no lever to pull — the disclosure named the number in prose
/// (`ProjectScopeDisclosure`) but nothing in the app let the user act on it.
///
/// Same shape as `UpdateConsentToggle`: the control writes straight to
/// `UserDefaults` through `ScanBudgetSetting`, which every scan reads live
/// (`ProjectHealthCheck.scanBudget`, `FileListModel.refresh()`,
/// `ProjectRecipientApplier`'s default `scanProject`), so raising the limit
/// here and pressing Re-run in the Health tab changes the result
/// immediately — no relaunch needed.
public struct ScanSettingsPanel: View {
    private let defaults: UserDefaults
    @State private var budget: Int

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _budget = State(initialValue: ScanBudgetSetting.current(in: defaults))
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent(LocalizedKey.settingsScanningBudgetLabel.text) {
                    TextField("", value: $budget, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onChange(of: budget) { _, newValue in
                            ScanBudgetSetting.set(newValue, in: defaults)
                        }
                }
                Button(LocalizedKey.settingsScanningResetButton.text) {
                    ScanBudgetSetting.reset(in: defaults)
                    budget = ScanBudgetSetting.current(in: defaults)
                }
                // Disabled rather than hidden when there is nothing to reset,
                // matching the rest of this app's convention for a control
                // that would otherwise do nothing when pressed — see
                // `ProjectAccessGate`/`SecretEditorView.canOpenAccessPanel`
                // for the same shape applied to a different guard.
                .disabled(budget == ProjectScanner.maxScannedFiles
                    && defaults.integer(forKey: ScanBudgetSetting.defaultsKey) == 0)
            } footer: {
                Text(.settingsScanningBudgetFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
