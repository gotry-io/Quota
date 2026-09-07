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
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 8) {
        Text(provider.displayName)
          .font(.headline)
          .foregroundStyle(.primary)
        if let serviceStatus, ProviderServiceStatusCopy.showsDot(serviceStatus.indicator) {
          Circle()
            .fill(statusDotColor(serviceStatus.indicator))
            .frame(width: QuotaTheme.statusDotSize, height: QuotaTheme.statusDotSize)
            .accessibilityHidden(true)
        }
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
          if let plan { planCapsule(plan) }
        }
        VStack(alignment: .leading, spacing: 6) {
          accountLabel(label)
          if let plan { planCapsule(plan) }
        }
      }
      // One element: the plan capsule is a label, not a target, so it must not be its own node.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(plan.map { "Account: \(label). Plan: \($0)" } ?? "Account: \(label)")

      if snapshot.windows.isEmpty {
        Text("No quota windows yet.")
          .font(.subheadline)
          .foregroundStyle(.primary)
      } else {
        ForEach(snapshot.windows) { window in
          QuotaWindowBlock(window: window, stateLabel: stateLabel)
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
    switch indicator {
    case .none:
      Color.secondary
    case .minor:
      Color.orange
    case .major, .critical:
      Color.red
    }
  }

  private func accountLabel(_ label: String) -> some View {
    Text(label)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func planCapsule(_ plan: String) -> some View {
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

struct QuotaWindowBlock: View {
  let window: QuotaWindow
  /// Why the reading is not current, or `nil` while it is.
  var stateLabel: String? = nil
  /// Detail uses a live timer under a day; Overview keeps the shared static reset copy.
  var usesLiveCountdown: Bool = false
  var emphasizedRemaining: Bool = false
  /// There is no Rust on iOS, so this app derives pace itself from the reading it was handed.
  var now: Date = Date()
  /// The curve this device's own samples draw for the window, when it has any (ADR 0042).
  var history: QuotaHistory? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(QuotaFormat.windowTitle(window))
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)

      Text(QuotaFormat.remaining(window))
        .font(
          (emphasizedRemaining ? Font.title : Font.title2).monospacedDigit().weight(.semibold)
        )
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)

      if window.showsPercentMeter {
        ProgressView(value: window.remainingPercent, total: 100)
          .tint(QuotaTheme.emerald)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }

      if let history, !history.points.isEmpty {
        QuotaPaceLineView(history: history)
      }

      if usesLiveCountdown {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          countdownRow(now: context.date)
        }
      } else if let support = supportLine {
        // No line limit: at accessibility text sizes a capped line clips the reset time.
        Text(support)
          .font(.footnote)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let paceLine {
        Text(paceLine.text)
          .font(.footnote)
          .foregroundStyle(paceLine.warns ? QuotaTheme.warning : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func countdownRow(now: Date) -> some View {
    switch QuotaFormat.countdown(resetsAt: window.resetsAt, now: now) {
    case .live(let end):
      // The shared reset copy says "Resets in …"; the live timer keeps the same words.
      (Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(
          Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
    case .copy(let text):
      Text(text)
        .font(.footnote)
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

  /// Whether this window's rate lasts to its reset, and whether that warns.
  private var paceLine: (text: String, warns: Bool)? {
    let pace = QuotaPace.evaluate(window.paceReading, now: now)
    guard let text = QuotaPaceCopy.line(pace, resetsAt: window.resetsAt) else { return nil }
    if case .runsOut = pace { return (text, true) }
    return (text, false)
  }

  private var accessibilityText: String {
    var parts = [QuotaFormat.remainingAccessibility(window)]
    if let reset = window.resetsAt.flatMap({ QuotaFormat.resetTime($0) }) {
      parts.append(reset)
    }
    if let paceLine {
      parts.append(paceLine.text)
    }
    if let stateLabel {
      parts.append(stateLabel)
    }
    return parts.joined(separator: ", ")
  }
}
