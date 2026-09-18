import SwiftUI

struct SettingsAboutView: View {
  var body: some View {
    Form {
      Section {
        VStack(spacing: 12) {
          QuotaAppMark(size: QuotaDesign.Layout.quotaMarkAbout)
          Text(SettingsCopy.bundleVersionLabel())
            .font(QuotaDesign.Typography.support)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          Text(SettingsCopy.productSentence)
            .fixedSize(horizontal: false, vertical: true)

          Text(SettingsCopy.privacySentence)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
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
}
