import SwiftUI

enum GeneralSettingsCopy {
  static let launchAtLogin = "Launch at Login"
  static let launchAtLoginHint = "Start QuotaBar when you log in"
  static let openWindowAtLaunch = "Open window at launch"
  static let openWindowAtLaunchHint = "Show the QuotaBar window when you open the app"
  static let showInDock = "Show in Dock"
  static let showInDockHint = "Keep QuotaBar in the Dock when its window is closed"
  static let refreshInterval = "Refresh Interval"
  static let uploadUsage = "Upload Usage to Account"
  static let uploadUsageHint = "Upload this Mac's Usage to your Quota account"
  static let groupUsage = "Group Usage by project"
  static let groupUsageHint = "Show This Mac Usage broken down by repository"
  static let resetLocalData = "Reset Local Data"
  static let resetLocalDataHint =
    "Deletes collected quota and Usage history on this Mac and refreshes."
}

/// The confirmation Reset Local Data raises. The main window can use a system
/// dialog; these are the words the dialog says, so the row and the confirmation
/// cannot drift apart.
enum ResetLocalDataCopy {
  static let title = "Reset Local Data?"
  static let confirmTitle = "Reset Local Data"
  static let message =
    "This Mac's collected quota and Usage history are deleted and rebuilt on the next refresh. "
    + "You stay signed in."
}

/// Main window → Settings → General: launch, open-window-at-launch, Dock, collection cadence,
/// Usage upload, project grouping, and the local-data reset.
struct GeneralSettingsView: View {
  @Bindable var model: MenuBarViewModel
  @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
  @State private var confirmReset = false
  @AppStorage(LaunchWindowPreference.storageKey) private var opensMainWindow =
    LaunchWindowPreference.fallback
  @AppStorage(DockVisibilityPreference.storageKey) private var dockShown =
    DockVisibilityPreference.fallback

  var body: some View {
    Form {
      Section {
        Toggle(
          GeneralSettingsCopy.launchAtLogin,
          isOn: Binding(
            get: { launchAtLoginEnabled },
            set: { desired in
              _ = LaunchAtLoginController.apply(enabled: desired)
              launchAtLoginEnabled = LaunchAtLoginController.isEnabled
            }
          )
        )
        .accessibilityLabel(GeneralSettingsCopy.launchAtLogin)
        .accessibilityHint(GeneralSettingsCopy.launchAtLoginHint)

        Toggle(GeneralSettingsCopy.openWindowAtLaunch, isOn: $opensMainWindow)
          .accessibilityLabel(GeneralSettingsCopy.openWindowAtLaunch)
          .accessibilityHint(GeneralSettingsCopy.openWindowAtLaunchHint)

        Toggle(
          GeneralSettingsCopy.showInDock,
          isOn: Binding(
            get: { dockShown },
            set: { desired in
              dockShown = desired
              WindowActivation.shared.applyDockVisibility()
            }
          )
        )
        .accessibilityLabel(GeneralSettingsCopy.showInDock)
        .accessibilityHint(GeneralSettingsCopy.showInDockHint)

        Picker(
          GeneralSettingsCopy.refreshInterval,
          selection: Binding(
            get: { QuotaRefreshInterval.resolved(model.quotaRefreshIntervalSeconds) },
            set: { interval in
              Task { await model.setQuotaRefreshInterval(interval) }
            }
          )
        ) {
          ForEach(QuotaRefreshInterval.allCases) { interval in
            Text(interval.label).tag(interval)
          }
        }
        .disabled(model.isUpdatingQuotaRefreshInterval)
        .accessibilityLabel(GeneralSettingsCopy.refreshInterval)

        Toggle(
          GeneralSettingsCopy.uploadUsage,
          isOn: Binding(
            get: { model.usageUploadEnabled },
            set: { desired in Task { await model.setUsageUploadEnabled(desired) } }
          )
        )
        .disabled(model.isUpdatingUsageUpload || model.syncUsageDisabledReason != nil)
        .accessibilityLabel(GeneralSettingsCopy.uploadUsage)
        .accessibilityHint(model.syncUsageDisabledReason ?? GeneralSettingsCopy.uploadUsageHint)

        Toggle(
          GeneralSettingsCopy.groupUsage,
          isOn: Binding(
            get: { model.groupUsageByProject },
            set: { desired in Task { await model.setGroupUsageByProject(desired) } }
          )
        )
        .disabled(model.isUpdatingGroupUsageByProject)
        .accessibilityLabel(GeneralSettingsCopy.groupUsage)
        .accessibilityHint(GeneralSettingsCopy.groupUsageHint)
      } footer: {
        if let message = LaunchAtLoginController.statusMessage {
          Text(message)
        } else if let reason = model.syncUsageDisabledReason {
          Text(reason)
        }
      }

      Section {
        Button(GeneralSettingsCopy.resetLocalData, role: .destructive) {
          confirmReset = true
        }
        .accessibilityLabel("Reset local data")
        .accessibilityHint(GeneralSettingsCopy.resetLocalDataHint)
      }
    }
    .formStyle(.grouped)
    .quotaSettingsColumn()
    .onAppear {
      LaunchAtLoginController.seedDefaultOnIfNeeded()
      launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    }
    .confirmationDialog(
      ResetLocalDataCopy.title,
      isPresented: $confirmReset,
      titleVisibility: .visible
    ) {
      Button(ResetLocalDataCopy.confirmTitle, role: .destructive) {
        Task { await model.resetLocalData() }
      }
    } message: {
      Text(ResetLocalDataCopy.message)
    }
  }
}
