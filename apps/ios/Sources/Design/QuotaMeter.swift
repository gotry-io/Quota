import QuotaPresentation
import SwiftUI

struct QuotaMeter: View {
  var fraction: Double
  var fill: Color

  init(remainingPercent: Double) {
    let remaining = min(max(remainingPercent, 0), 100)
    fraction = remaining / 100
    fill = QuotaTheme.color(for: QuotaTone.remaining(percent: remaining))
  }

  /// Spend (or any other) fill. Tone is the caller's, not remaining-quota bands.
  init(fraction: Double, tone: QuotaTone) {
    self.fraction = min(max(fraction, 0), 1)
    fill = QuotaTheme.color(for: tone)
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
    .frame(height: QuotaDesign.Layout.meterHeight)
    .accessibilityHidden(true)
  }
}
