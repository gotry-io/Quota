import SwiftUI

enum MacSetupGuide {
  static let downloadURL = URL(string: "https://quota.gotry.io/download")!
  static let title = "Set up QuotaBar"
  static let detail = "Install QuotaBar on a Mac signed in with this GitHub account."
  static let overviewAction = "Download for Mac"
  static let devicesAction = "Download QuotaBar"
  static let emptyDevicesTitle = "No Macs connected"
}

struct MacSetupGuideSection: View {
  var body: some View {
    Section {
      Link(destination: MacSetupGuide.downloadURL) {
        Text(MacSetupGuide.overviewAction)
          .font(.body)
          .frame(maxWidth: .infinity, minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
      }
      .accessibilityLabel(MacSetupGuide.overviewAction)
    } header: {
      Text(MacSetupGuide.title)
    } footer: {
      Text(MacSetupGuide.detail)
    }
  }
}
