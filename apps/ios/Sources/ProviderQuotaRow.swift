import QuotaBrandIcons
import QuotaPresentation
import QuotaProviderStatus
import QuotaWire
import SwiftUI

struct ProviderQuotaRow: View {
  let provider: ProviderID
  let snapshot: QuotaSnapshot
  var accountIndex: Int = 0
  var serviceStatus: ProviderStatusReading? = nil

  var body: some View {
    let label = PlanDisplay.accountLabel(snapshot.account.label) ?? "Account \(accountIndex + 1)"
    let stateLabel = snapshot.stateLabel()
    let hero = snapshot.primaryCadenceWindows.first ?? snapshot.windows.first
    let rest = snapshot.windows.filter { $0.id != hero?.id }
    return VStack(alignment: .leading, spacing: QuotaDesign.Layout.rowSpacing) {
      HStack(alignment: .center, spacing: 8) {
        ProviderMark(provider: provider, size: QuotaDesign.Layout.markSize)
          .foregroundStyle(.primary)
        Text(provider.displayName)
          .font(QuotaDesign.Typography.cardTitle)
          .foregroundStyle(.primary)
        if let serviceStatus, ProviderServiceStatusCopy.showsDot(serviceStatus.indicator) {
          Circle()
            .fill(statusDotColor(serviceStatus.indicator))
            .frame(width: QuotaTheme.statusDotSize, height: QuotaTheme.statusDotSize)
            .accessibilityHidden(true)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityLabel(headerAccessibilityLabel)

      let plan = QuotaFormat.planBadge(snapshot.account.plan)
      // Label and plan share a line while they fit; at accessibility text sizes they stack so
      // neither is clipped.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          accountLabel(label)
          Spacer(minLength: 8)
          if let plan { PlanCapsule(plan: plan) }
        }
        VStack(alignment: .leading, spacing: 6) {
          accountLabel(label)
          if let plan { PlanCapsule(plan: plan) }
        }
      }
      // One element: the plan capsule is a label, not a target, so it must not be its own node.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(plan.map { "Account: \(label). Plan: \($0)" } ?? "Account: \(label)")

      if snapshot.windows.isEmpty {
        Text("No quota windows yet.")
          .font(QuotaDesign.Typography.support)
          .foregroundStyle(.primary)
      } else if let hero {
        QuotaWindowBlock(
          window: hero,
          stateLabel: stateLabel,
          presentation: .overviewHero
        )
        ForEach(rest) { window in
          Divider()
          QuotaWindowBlock(
            window: window,
            stateLabel: stateLabel,
            presentation: .overviewCompact
          )
        }
      }
    }
  }

  private var headerAccessibilityLabel: String {
    if let serviceStatus, ProviderServiceStatusCopy.showsDot(serviceStatus.indicator) {
      "\(provider.displayName). \(serviceStatus.description)"
    } else {
      provider.displayName
    }
  }

  private func statusDotColor(_ indicator: ProviderServiceStatusIndicator) -> Color {
    guard let tone = ProviderServiceStatusCopy.tone(indicator) else {
      return QuotaTheme.secondary
    }
    return QuotaTheme.color(for: tone)
  }

  private func accountLabel(_ label: String) -> some View {
    Text(label)
      .font(QuotaDesign.Typography.support)
      .foregroundStyle(QuotaTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct PlanCapsule: View {
  let plan: String

  var body: some View {
    Text(plan)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .fixedSize()
      .layoutPriority(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .overlay {
        Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 1)
      }
      .accessibilityHidden(true)
      .accessibilityElement(children: .ignore)
      .allowsHitTesting(false)
  }
}

enum QuotaWindowPresentation {
  /// Overview primary cadence: large remaining, 8pt meter, reset and pace on one meta line.
  case overviewHero
  /// Overview secondary windows: compact remaining, 4pt meter, reset and pace as meta.
  case overviewCompact
  /// Subscription detail: large remaining, live countdown, pace headline and detail.
  case detail
}

struct QuotaWindowBlock: View {
  let window: QuotaWindow
  /// Why the reading is not current, or `nil` while it is.
  var stateLabel: String? = nil
  var presentation: QuotaWindowPresentation = .detail
  /// The curve this device's own samples draw for the window, when it has any (ADR 0042).
  var history: QuotaHistory? = nil
  /// There is no Rust on iOS, so this app derives pace itself from the reading it was handed.
  var now: Date = Date()

  var body: some View {
    Group {
      switch presentation {
      case .overviewHero:
        heroBody
      case .overviewCompact:
        compactBody
      case .detail:
        detailBody
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var heroBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      windowTitle
      remainingValue
      meter(height: QuotaDesign.Layout.meterHeight)
      joinedMeta
    }
  }

  private var compactBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          windowTitle
          Spacer(minLength: 8)
          compactRemaining
        }
        VStack(alignment: .leading, spacing: 2) {
          windowTitle
          compactRemaining
        }
      }
      meter(height: QuotaDesign.Layout.compactMeterHeight)
      joinedMeta
    }
  }

  private var detailBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      windowTitle
      remainingValue
      meter(height: QuotaDesign.Layout.meterHeight)
      if let history, !history.points.isEmpty {
        QuotaPaceLineView(history: history, tint: windowTone)
      }
      TimelineView(.periodic(from: .now, by: 60)) { context in
        countdownRow(now: context.date)
      }
      if let paceHeadline {
        Text(paceHeadline)
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(paceWarns ? QuotaTheme.warning : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let paceDetail {
          Text(paceDetail)
            .font(QuotaDesign.Typography.meta)
            .foregroundStyle(QuotaTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var windowTitle: some View {
    Text(QuotaFormat.windowTitle(window))
      .font(QuotaDesign.Typography.support)
      .foregroundStyle(QuotaTheme.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var remainingValue: some View {
    Text(QuotaFormat.remaining(window))
      .font(QuotaDesign.Typography.remainingValue)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var compactRemaining: some View {
    Text(QuotaFormat.remaining(window))
      .font(.body.monospacedDigit().weight(.semibold))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func meter(height: CGFloat) -> some View {
    if window.showsPercentMeter {
      QuotaMeter(remainingPercent: window.remainingPercent, height: height)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var joinedMeta: some View {
    let reset = supportLine
    if let reset, let paceHeadline {
      Text("\(reset) · \(paceHeadline)")
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(paceWarns ? QuotaTheme.warning : Color.primary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let reset {
      Text(reset)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let paceHeadline {
      Text(paceHeadline)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(paceWarns ? QuotaTheme.warning : Color.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func countdownRow(now: Date) -> some View {
    switch QuotaFormat.countdown(resetsAt: window.resetsAt, now: now) {
    case .live(let end):
      // The shared reset copy says "Resets in …"; the live timer keeps the same words.
      (Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
        .font(QuotaDesign.Typography.meta.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(
          Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
    case .copy(let text):
      Text(text)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }

  /// A reading that is not current says so even when it still carries a reset time,
  /// because the reset it names may already have passed.
  private var supportLine: String? {
    let reset = window.resetsAt.flatMap { QuotaFormat.resetTime($0) }
    guard let stateLabel else { return reset }
    return reset.map { "\(stateLabel) · \($0)" } ?? stateLabel
  }

  /// Whether this window's rate lasts to its reset, derived on this device.
  private var pace: QuotaPace {
    QuotaPace.evaluate(window.paceReading, now: now)
  }

  private var paceHeadline: String? {
    QuotaPaceCopy.headline(pace, resetsAt: window.resetsAt)
  }

  private var paceDetail: String? {
    QuotaPaceCopy.detail(pace)
  }

  private var paceWarns: Bool {
    if case .runsOut = pace { return true }
    return false
  }

  private var windowTone: Color {
    QuotaTheme.color(for: QuotaTone.remaining(percent: window.remainingPercent))
  }

  private var accessibilityText: String {
    var parts = [QuotaFormat.remainingAccessibility(window)]
    if let reset = window.resetsAt.flatMap({ QuotaFormat.resetTime($0) }) {
      parts.append(reset)
    }
    if let paceHeadline {
      parts.append(paceHeadline)
    }
    if presentation == .detail, let paceDetail {
      parts.append(paceDetail)
    }
    if let stateLabel {
      parts.append(stateLabel)
    }
    return parts.joined(separator: ", ")
  }
}
