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
  /// The refresh that is running has not brought this row's reading back yet. The last reading
  /// stays; a small spinner takes the chevron's place, in the chevron's frame, so nothing moves.
  var isAwaitingReading = false

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
        ZStack {
          if isAwaitingReading {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
        .frame(width: Self.trailingSize, height: Self.trailingSize)
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

  private static let trailingSize: CGFloat = 16

  private var headerAccessibilityLabel: String {
    let name =
      if let serviceStatus, ProviderServiceStatusCopy.showsDot(serviceStatus.indicator) {
        "\(provider.displayName). \(serviceStatus.description)"
      } else {
        provider.displayName
      }
    return isAwaitingReading ? "\(name). \(OverviewCopy.updating)" : name
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
  /// There is no Rust on iOS, so this app derives pace itself from the reading it was handed.
  var now: Date? = nil
  @Environment(\.displayClock) private var displayClock

  private var currentNow: Date { now ?? displayClock.now() }

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
      TimelineView(.periodic(from: .now, by: 60)) { context in
        countdownRow(now: now ?? (displayClock.isFixed ? displayClock.now() : context.date))
      }
      ForEach(Array(expiryLines.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(QuotaDesign.Typography.meta)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("subscription.expiry")
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
      .accessibilityIdentifier(remainingIdentifier)
  }

  private var remainingValue: some View {
    Text(QuotaFormat.remaining(window))
      .font(QuotaDesign.Typography.remainingValue)
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(remainingIdentifier)
  }

  private var compactRemaining: some View {
    Text(QuotaFormat.remaining(window))
      .font(.body.monospacedDigit().weight(.semibold))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier(remainingIdentifier)
  }

  /// Hero remaining on Overview; the same reading on subscription detail.
  private var remainingIdentifier: String {
    switch presentation {
    case .overviewHero, .overviewCompact: "overview.remaining"
    case .detail: "subscription.remaining"
    }
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
        .accessibilityIdentifier(remainingIdentifier)
    } else if let reset {
      Text(reset)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(remainingIdentifier)
    } else if let paceHeadline {
      Text(paceHeadline)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(paceWarns ? QuotaTheme.warning : Color.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(remainingIdentifier)
    }
  }

  @ViewBuilder
  private func countdownRow(now: Date) -> some View {
    switch QuotaFormat.countdown(resetsAt: window.resetsAt, now: now) {
    case .live(let end):
      if displayClock.isFixed {
        if let text = QuotaFormat.resetTime(end, now: now) {
          Text(text)
            .font(QuotaDesign.Typography.meta)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(remainingIdentifier)
        }
      } else {
        // The shared reset copy says "Resets in …"; the live timer keeps the same words.
        (Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
          .font(QuotaDesign.Typography.meta.monospacedDigit())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(remainingIdentifier)
          .accessibilityLabel(
            Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
      }
    case .copy(let text):
      Text(text)
        .font(QuotaDesign.Typography.meta)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(remainingIdentifier)
    case nil:
      EmptyView()
    }
  }

  /// When this window's units lapse, one line per instant: subscription detail only.
  private var expiryLines: [String] {
    ExpiryCopy.lines(window.expiries, total: window.remainingValue, now: currentNow)
  }

  /// A reading that is not current says so even when it still carries a reset time,
  /// because the reset it names may already have passed. A window that never resets and lists
  /// when its units lapse names the nearest of those instead.
  private var supportLine: String? {
    let reset =
      window.resetsAt.flatMap { QuotaFormat.resetTime($0, now: currentNow) }
      ?? ExpiryCopy.next(window.expiries, now: currentNow)
    guard let stateLabel else { return reset }
    return reset.map { "\(stateLabel) · \($0)" } ?? stateLabel
  }

  /// Whether this window's rate lasts to its reset, derived on this device.
  private var pace: QuotaPace {
    QuotaPace.evaluate(window.paceReading, now: currentNow)
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

  private var accessibilityText: String {
    var parts = [QuotaFormat.remainingAccessibility(window)]
    if let reset = window.resetsAt.flatMap({ QuotaFormat.resetTime($0) }) {
      parts.append(reset)
    }
    if presentation == .detail {
      parts.append(contentsOf: expiryLines)
    } else if window.resetsAt == nil, let next = ExpiryCopy.next(window.expiries, now: currentNow) {
      parts.append(next)
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
