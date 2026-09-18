import QuotaPresentation
import SwiftUI

struct QuotaMeter: View {
  var remainingPercent: Double

  var body: some View {
    GeometryReader { proxy in
      let fraction = min(max(remainingPercent / 100, 0), 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaTheme.meterTrack)
        Capsule()
          .fill(QuotaTheme.color(for: QuotaTone.remaining(percent: remainingPercent)))
          .frame(width: proxy.size.width * CGFloat(fraction))
      }
    }
    .frame(height: QuotaDesign.Layout.meterHeight)
    .accessibilityHidden(true)
  }
}
