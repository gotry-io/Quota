import SwiftUI

struct SettingsAboutView: View {
  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 16) {
          QuotaAppMark()
            .frame(maxWidth: .infinity)

          Text(SettingsCopy.productSentence)
            .fixedSize(horizontal: false, vertical: true)

          Text(SettingsCopy.privacySentence)
            .fixedSize(horizontal: false, vertical: true)
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
}
