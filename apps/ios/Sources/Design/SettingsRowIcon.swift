import SwiftUI

/// Leading 28pt rounded-square icon for a Settings hub row: white SF Symbol on a
/// tinted fill, matching the system Settings list.
struct SettingsRowIcon: View {
  let symbol: String
  let tint: Color

  var body: some View {
    Image(systemName: symbol)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.white)
      .frame(
        width: QuotaDesign.Layout.settingsRowIconSize,
        height: QuotaDesign.Layout.settingsRowIconSize
      )
      .background(
        tint,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}
