import QuotaPresentation
import SwiftUI

/// The curve this phone's own samples draw for a window, and the dashed line they extrapolate
/// to its reset.
///
/// Only a reading this phone took has samples behind it, so only such a window gets a line; a
/// reading that came from an Account is one some Mac took and this phone has no history of
/// ([ADR 0042](../../../docs/decisions/0042-quota-history-is-local-samples.md)).
struct QuotaPaceLineView: View {
  let history: QuotaHistory

  /// Tall enough for the shape of a day to be legible under a meter, short enough not to push
  /// the reset line off a compact row.
  static let height: CGFloat = 44

  var body: some View {
    Canvas { context, size in
      let plot = { (point: QuotaHistoryPoint) -> CGPoint in
        CGPoint(
          x: size.width * point.elapsedFraction,
          y: size.height * (1 - min(max(point.usedPercent, 0), 100) / 100)
        )
      }
      guard let first = history.points.first else { return }
      var curve = Path()
      curve.move(to: plot(first))
      for point in history.points.dropFirst() {
        curve.addLine(to: plot(point))
      }
      context.stroke(curve, with: .color(QuotaTheme.emerald), lineWidth: 2)

      guard let last = history.points.last, let projection = history.projection else { return }
      var dashed = Path()
      dashed.move(to: plot(last))
      dashed.addLine(to: plot(projection))
      context.stroke(
        dashed,
        with: .color(QuotaTheme.emerald.opacity(0.6)),
        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
      )
    }
    .frame(height: Self.height)
    .frame(maxWidth: .infinity)
    .accessibilityElement()
    .accessibilityLabel("Pace line")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("subscription.paceline")
  }

  private var accessibilityValue: String {
    let used = Int((history.points.last?.usedPercent ?? 0).rounded())
    guard let projection = history.projection else { return "\(used)% used so far" }
    return "\(used)% used so far, \(Int(projection.usedPercent.rounded()))% at reset"
  }
}
