import QuotaPresentation
import SwiftUI

struct QuotaMeter: View {
  var fraction: Double
  var fill: Color
  var height: CGFloat
  /// Where remaining would stand now at an even burn rate, 0…1 (docs/design.md, Even-pace
  /// tick). A fill ending short of it is burning faster than even. Nil draws no tick.
  var evenPace: Double? = nil

  /// `evenPacePercent` is `EvenPacePosition.remainingPercent`: nil wherever the pace rule does
  /// not answer, because the tick only accompanies a pace line.
  init(
    remainingPercent: Double,
    evenPacePercent: Double? = nil,
    height: CGFloat = QuotaDesign.Layout.meterHeight
  ) {
    let remaining = min(max(remainingPercent, 0), 100)
    fraction = remaining / 100
    fill = QuotaTheme.color(for: QuotaTone.remaining(percent: remaining))
    evenPace = evenPacePercent.map { min(max($0, 0), 100) / 100 }
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
        if let evenPace {
          Capsule()
            .fill(Color.primary.opacity(0.7))
            .frame(width: 2, height: height + 6)
            .offset(x: min(max(proxy.size.width * CGFloat(evenPace) - 1, 0), proxy.size.width - 2))
        }
      }
      .frame(height: height)
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}
