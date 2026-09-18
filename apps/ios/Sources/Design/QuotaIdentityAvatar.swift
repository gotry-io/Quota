import QuotaPresentation
import SwiftUI

/// 44pt identity circle used on Settings and Confirm: first letter of the account
/// label on brand emerald so white ink stays readable in both appearances.
struct QuotaIdentityAvatar: View {
  var label: String
  var size: CGFloat = QuotaDesign.Layout.identityAvatarSize

  var body: some View {
    Text(letter)
      .font(.title2.weight(.semibold))
      .minimumScaleFactor(0.5)
      .lineLimit(1)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(fill, in: Circle())
      .accessibilityHidden(true)
  }

  private var letter: String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
  }

  /// Light-mode emerald in both appearances: `QuotaTheme.emerald` turns mint in
  /// dark mode, and white on mint fails contrast.
  private var fill: Color {
    Color(
      red: QuotaBrand.emerald.red,
      green: QuotaBrand.emerald.green,
      blue: QuotaBrand.emerald.blue
    )
  }
}
