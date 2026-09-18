import QuotaPresentation
import SwiftUI

struct QuotaMeter: View {
  var fraction: Double
  var fill: Color
  var height: CGFloat

  init(remainingPercent: Double, height: CGFloat = QuotaDesign.Layout.meterHeight) {
    let remaining = min(max(remainingPercent, 0), 100)
    fraction = remaining / 100
    fill = QuotaTheme.color(for: QuotaTone.remaining(percent: remaining))
    self.height = height
  }

  /// Spend (or any other) fill. Tone is the caller's, not remaining-quota bands.
  init(fraction: Double, tone: QuotaTone, height: CGFloat = QuotaDesign.Layout.meterHeight) {
    self.fraction = min(max(fraction, 0), 1)
    fill = QuotaTheme.color(for: tone)
    self.height = height
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaTheme.meterTrack)
        Capsule()
          .fill(fill)
          .frame(width: proxy.size.width * CGFloat(fraction))
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}
