import QuotaPresentation
import QuotaWire
import SwiftUI

/// The curve a window's own samples draw, and the dashed line they extrapolate to its reset.
///
/// The service folded both (ADR 0042); this view only plots them. The vertical axis is the
/// whole window, 0 to 100 percent used, so two windows of different cadences are read the same
/// way; the horizontal axis is the window's start to its reset.
struct QuotaPaceLineView: View {
  let history: QuotaHistory
  let tint: Color

  /// Small enough to sit under a meter without competing with it, tall enough for the shape of
  /// an afternoon to be legible.
  static let height: CGFloat = 22

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
      context.stroke(curve, with: .color(tint), lineWidth: 1.5)

      guard let last = history.points.last, let projection = history.projection else { return }
      var dashed = Path()
      dashed.move(to: plot(last))
      dashed.addLine(to: plot(projection))
      context.stroke(
        dashed,
        with: .color(tint.opacity(0.65)),
        style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
      )
    }
    .frame(height: Self.height)
    .accessibilityLabel("Pace line")
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    let used = history.points.last.map { QuotaWindow.formattedPercent($0.usedPercent) } ?? "0%"
    guard let projection = history.projection else { return "\(used) used so far" }
    return "\(used) used so far, \(QuotaWindow.formattedPercent(projection.usedPercent)) at reset"
  }
}

/// The windows of one provider that the reader's day already holds.
///
/// One line names them — `Today: 3 windows · 82% / 40% / 12%` — and opens into the list, so a
/// reader who only wants the shape of the day never pays for the rows.
struct TodayWindowsRow: View {
  let windows: [QuotaHistoryWindow]
  @State private var isExpanded = false

  var body: some View {
    if let line = QuotaHistoryCopy.todayLine(windows) {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
        Button {
          isExpanded.toggle()
        } label: {
          HStack(spacing: QuotaDesign.Spacing.iconLabel) {
            Text(line)
              .quotaMetaStyle()
              .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .quotaChevronStyle()
              .accessibilityHidden(true)
          }
          .frame(
            maxWidth: .infinity,
            minHeight: QuotaDesign.Layout.minimumInteractiveDimension,
            alignment: .leading
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(QuotaListRowButtonStyle(surfaceInset: 0))
        .accessibilityLabel(line)
        .accessibilityHint(isExpanded ? "Hides today's windows" : "Shows today's windows")
        .accessibilityIdentifier("QuotaBar.TodayWindows")

        if isExpanded {
          ForEach(windows, id: \.startedAt) { window in
            HStack(spacing: QuotaDesign.Spacing.inline) {
              Text(QuotaHistoryCopy.span(window))
                .quotaMetaStyle()
              Spacer(minLength: 8)
              Text(QuotaHistoryCopy.peak(window.peakUsedPercent))
                .quotaMetaStyle()
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }
}
