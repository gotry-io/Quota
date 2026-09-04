import SwiftUI

struct SettingsAboutView: View {
  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 16) {
          Image(systemName: "gauge.with.dots.needle.33percent")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(QuotaTheme.emerald)
            .frame(width: 56, height: 56)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Quota")
            .accessibilityAddTraits(.isImage)

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
