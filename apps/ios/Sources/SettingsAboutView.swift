import SwiftUI

struct SettingsAboutView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section {
        VStack(spacing: 12) {
          QuotaAppMark(size: QuotaDesign.Layout.quotaMarkAbout)
          Text(SettingsCopy.bundleVersionLabel())
            .font(QuotaDesign.Typography.support)
            .foregroundStyle(QuotaTheme.secondary)
            .monospacedDigit()

          Text(SettingsCopy.productSentence)
            .fixedSize(horizontal: false, vertical: true)

          Text(SettingsCopy.privacySentence)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
      }

      if model.showsShareQuotaHistory {
        Section {
          Toggle(isOn: historySync) {
            Text(SettingsCopy.shareQuotaHistory)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityIdentifier("settings.history.sync")
        } footer: {
          Text(SettingsCopy.shareQuotaHistoryFootnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.history.sync.footnote")
        }
      }

      Section {
        LabeledContent(SettingsCopy.version, value: SettingsCopy.bundleVersionLabel())
          .accessibilityIdentifier("settings.about.version")
        Link(SettingsCopy.website, destination: QuotaWebLinks.website)
        Link(SettingsCopy.github, destination: QuotaWebLinks.githubRepository)
        LabeledContent(SettingsCopy.license, value: SettingsCopy.licenseValue)
          .accessibilityIdentifier("settings.about.license")
      }
    }
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("settings.about.root")
    .navigationTitle(SettingsCopy.about)
  }

  private var historySync: Binding<Bool> {
    Binding(
      get: { model.accountSettings.historySync == true },
      set: { enabled in
        Task { await model.accountSettings.apply(.setHistorySync(enabled)) }
      }
    )
  }
}
