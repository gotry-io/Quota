import SwiftUI

struct SettingsAppearanceView: View {
  @Bindable var settings: SettingsModel

  var body: some View {
    Form {
      Section {
        Picker(
          SettingsCopy.appearance,
          selection: Binding(
            get: { settings.appearance },
            set: { settings.setAppearance($0) }
          )
        ) {
          ForEach(AppearancePreference.allCases) { option in
            Text(option.title)
              .tag(option)
              .accessibilityIdentifier("settings.appearance.\(option.rawValue)")
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text(SettingsCopy.appearance)
          .foregroundStyle(Color(uiColor: .label))
      }
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .quotaTabBarClearance()
    .accessibilityIdentifier("settings.appearance.root")
    .navigationTitle(SettingsCopy.appearance)
  }
}
