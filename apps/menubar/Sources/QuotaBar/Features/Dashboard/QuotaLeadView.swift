import QuotaPresentation
import QuotaWire
import SwiftUI

/// The head of the Quota page: the tightest current window as the Quota mark's ring at size,
/// beside the next seven days of resets, one lane per current subscription
/// (`docs/design.md` Tightest-window gauge and Next resets).
struct QuotaLeadView: View {
  let subscriptions: [DashboardProvider]
  let now: Date
  let resetStyle: ResetCopyStyle

  var body: some View {
    let tightest = TightestWindow.choose(
      in: subscriptions,
      isCurrent: { !$0.isStale },
      windows: \.quotaWindows
    )
    let lanes = NextResets.lanes(
      in: subscriptions,
      isCurrent: { !$0.isStale },
      windows: \.quotaWindows,
      now: now
    )
    if tightest != nil || !lanes.isEmpty {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: QuotaDesign.Layout.contentGutter) {
          if let tightest { tightestBlock(tightest).frame(width: 260, alignment: .leading) }
          if !lanes.isEmpty { NextResetsView(lanes: lanes, now: now, resetStyle: resetStyle) }
        }
        VStack(alignment: .leading, spacing: QuotaDesign.Spacing.lg) {
          if let tightest { tightestBlock(tightest) }
          if !lanes.isEmpty { NextResetsView(lanes: lanes, now: now, resetStyle: resetStyle) }
        }
      }
      .padding(QuotaDesign.Layout.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaCardSurface()
      .accessibilityIdentifier("quota.lead")
    }
  }

  private func tightestBlock(
    _ choice: TightestWindowChoice<DashboardProvider, QuotaWindow>
  ) -> some View {
    let window = choice.window
    let reset = window.resetsAt.flatMap {
      FreshnessCopy.resetCopy(resetsAt: $0, now: now, style: resetStyle)
    }
    let pace = window.pace.flatMap { QuotaPaceCopy.headline($0, resetsAt: window.resetsAt) }
    let warns: Bool = {
      if case .runsOut = window.pace { return true }
      return false
    }()
    return HStack(alignment: .center, spacing: QuotaDesign.Spacing.md) {
      QuotaGaugeRing(remainingPercent: choice.remainingPercent)
        .frame(width: 72, height: 72)
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
        Text("Tightest window")
          .quotaSectionHeaderStyle()
        Text("\(choice.subscription.provider.displayName) · \(window.displayTitle)")
          .quotaRowTitleStyle()
          .fixedSize(horizontal: false, vertical: true)
        if let reset {
          Text(reset)
            .quotaMetaStyle()
        }
        if let pace {
          Text(pace)
            .quotaFont(.meta)
            .foregroundStyle(warns ? QuotaPalette.warning : QuotaPalette.mute)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tightest window")
    .accessibilityValue(
      [
        "\(choice.subscription.provider.displayName) \(window.displayTitle)",
        "\(RemainingQuotaFormat.percent(choice.remainingPercent)) remaining",
        reset, pace,
      ]
      .compactMap { $0 }
      .joined(separator: ", ")
    )
  }
}

/// The Quota mark's ring at size: remaining as the arc in the band colour from twelve o'clock,
/// a dot at its end, and the percent inside.
struct QuotaGaugeRing: View {
  let remainingPercent: Double

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      let line = side * 5 / 64
      let fraction = min(max(remainingPercent / 100, 0), 1)
      let color = QuotaPalette.usageColor(remainingPercent: remainingPercent)
      ZStack {
        Circle()
          .inset(by: side * 8 / 64)
          .stroke(QuotaPalette.progressTrack, lineWidth: line)
        if fraction > 0 {
          Circle()
            .inset(by: side * 8 / 64)
            .trim(from: 0, to: fraction)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        Text(RemainingQuotaFormat.percent(remainingPercent))
          .font(.system(size: side * 15 / 64, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(QuotaPalette.ink)
          .minimumScaleFactor(0.6)
          .lineLimit(1)
          .padding(.horizontal, side * 14 / 64)
      }
      .frame(width: side, height: side)
    }
    .accessibilityHidden(true)
  }
}

/// Next resets: the coming seven days in local time, one lane per current subscription, a ring
/// per reset instant in the band colour of the lowest window it refills. Its text alternative is
/// each window's **Resets** line.
struct NextResetsView: View {
  let lanes: [NextResetsLane<DashboardProvider, QuotaWindow>]
  let now: Date
  let resetStyle: ResetCopyStyle
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var laneHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 34 : 22 }
  private let labelWidth: CGFloat = 104
  private let horizon = NextResets.horizon

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      HStack(alignment: .firstTextBaseline) {
        Text("Next resets")
          .quotaSectionHeaderStyle()
        Spacer(minLength: QuotaDesign.Spacing.sm)
        Text("7 days · local time")
          .quotaMetaStyle()
      }
      HStack(spacing: QuotaDesign.Spacing.sm) {
        Color.clear.frame(width: labelWidth, height: 1)
        dayRuler
      }
      .accessibilityHidden(true)
      ForEach(lanes, id: \.subscription.id) { lane in
        HStack(spacing: QuotaDesign.Spacing.sm) {
          Text(laneTitle(lane.subscription))
            .quotaFont(.meta)
            .foregroundStyle(QuotaPalette.body)
            .lineLimit(1)
            .frame(width: labelWidth, alignment: .leading)
          track(lane)
        }
        .frame(height: laneHeight)
      }
      .accessibilityHidden(true)
    }
    .frame(minWidth: 320)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Next resets")
    .accessibilityValue(spokenResets)
    .accessibilityIdentifier("quota.next-resets")
  }

  /// **Now**, then each local midnight inside the seven days with its weekday.
  private var dayRuler: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Text("Now")
          .quotaMetaStyle()
        ForEach(midnights, id: \.self) { midnight in
          let x = position(midnight, width: geometry.size.width)
          Rectangle()
            .fill(QuotaPalette.hairline)
            .frame(width: 0.5, height: 12)
            .offset(x: x)
          // A midnight too close to **Now** keeps its line and gives the label to Now.
          if x > 32 {
            Text(midnight.formatted(.dateTime.weekday(.abbreviated)))
              .quotaMetaStyle()
              .offset(x: x + 3)
          }
        }
      }
    }
    .frame(height: 14)
  }

  private func track(_ lane: NextResetsLane<DashboardProvider, QuotaWindow>) -> some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let middle = geometry.size.height / 2
      ZStack(alignment: .topLeading) {
        Path { path in
          path.move(to: CGPoint(x: 0, y: middle))
          path.addLine(to: CGPoint(x: width, y: middle))
        }
        .stroke(QuotaPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        ForEach(Array(labelled(lane.resets, width: width).enumerated()), id: \.offset) {
          _, entry in
          let x = position(entry.reset.at, width: width)
          let color =
            entry.reset.lowestRemainingPercent.map {
              QuotaPalette.usageColor(remainingPercent: $0)
            } ?? QuotaPalette.mute
          Circle()
            .strokeBorder(color, lineWidth: 2)
            .background(Circle().fill(QuotaPalette.cardFill))
            .frame(width: 10, height: 10)
            .offset(x: x - 5, y: middle - 5)
            .help(entry.reset.windows.map(\.displayTitle).joined(separator: " · "))
          if entry.showsLabel {
            let titles = entry.reset.windows.map(\.displayTitle).joined(separator: " · ")
            let trailing = x > width - 120
            Text(titles)
              .quotaMetaStyle()
              .lineLimit(1)
              .fixedSize()
              .padding(.horizontal, 2)
              .background(QuotaPalette.cardFill)
              .frame(width: 112, alignment: trailing ? .trailing : .leading)
              .offset(x: trailing ? x - 121 : x + 9, y: middle - 7)
          }
        }
      }
    }
  }

  /// Two accounts of one provider are two lanes, told apart by the account.
  private func laneTitle(_ subscription: DashboardProvider) -> String {
    subscription.accountLabel.map { "\(subscription.provider.displayName) · \($0)" }
      ?? subscription.provider.displayName
  }

  /// A reset is labelled with its window titles only where the label clears the one before it.
  private func labelled(
    _ resets: [NextResetInstant<QuotaWindow>],
    width: CGFloat
  ) -> [(reset: NextResetInstant<QuotaWindow>, showsLabel: Bool)] {
    var lastLabelled: CGFloat = -.infinity
    return resets.map { reset in
      let x = position(reset.at, width: width)
      let shows = x - lastLabelled > 124
      if shows { lastLabelled = x }
      return (reset, shows)
    }
  }

  private var midnights: [Date] {
    let calendar = Calendar.current
    var result: [Date] = []
    var day = calendar.startOfDay(for: now)
    while let next = calendar.date(byAdding: .day, value: 1, to: day),
      next < now.addingTimeInterval(horizon)
    {
      result.append(next)
      day = next
    }
    return result
  }

  private func position(_ date: Date, width: CGFloat) -> CGFloat {
    let fraction = min(max(date.timeIntervalSince(now) / horizon, 0), 1)
    return width * fraction
  }

  private var spokenResets: String {
    lanes.map { lane in
      let resets = lane.resets.map { reset in
        let titles = reset.windows.map(\.displayTitle).joined(separator: " and ")
        let when =
          FreshnessCopy.resetCopy(resetsAt: reset.at, now: now, style: resetStyle) ?? ""
        return "\(titles), \(when)"
      }
      return "\(laneTitle(lane.subscription)): \(resets.joined(separator: "; "))"
    }
    .joined(separator: ". ")
  }
}
