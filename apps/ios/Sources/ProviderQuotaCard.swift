import QuotaPresentation
import QuotaWire
import SwiftUI

struct ProviderQuotaCard: View {
  let model: ProviderQuotaCardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.provider.displayName)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      ForEach(Array(model.subscriptions.enumerated()), id: \.offset) { index, subscription in
        if index > 0 {
          Divider()
        }
        observationBlock(subscription.snapshot, index: index)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func observationBlock(_ snapshot: QuotaSnapshot, index: Int) -> some View {
    let label = PlanDisplay.accountLabel(snapshot.account.label) ?? "Account \(index + 1)"
    let stateLabel = snapshot.stateLabel()
    return VStack(alignment: .leading, spacing: 12) {
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
        Text("No quota windows reported.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.windows) { window in
          QuotaWindowBlock(window: window, stateLabel: stateLabel)
        }
      }
    }
  }

  private func accountLabel(_ label: String) -> some View {
    Text(label)
      .font(.subheadline.weight(.medium))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func planCapsule(_ plan: String) -> some View {
    Text(plan)
      .font(.caption.weight(.semibold))
      .layoutPriority(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(QuotaTheme.meterTrack, in: Capsule())
      .accessibilityHidden(true)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(QuotaFormat.windowTitle(window))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text(QuotaFormat.remaining(window))
        .font(
          (emphasizedRemaining ? Font.title : Font.title2).monospacedDigit().weight(.semibold)
        )
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)

      if !window.isBalanceOnly {
        ProgressView(value: window.remainingPercent, total: 100)
          .tint(QuotaTheme.emerald)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }

      if usesLiveCountdown {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          countdownRow(now: context.date)
        }
      } else if let support = supportLine {
        // No line limit: at accessibility text sizes a capped line clips the reset time.
        Text(support)
          .font(.footnote)
          .foregroundStyle(.tertiary)
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
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(
          Text("Resets in ") + Text(timerInterval: min(now, end)...end, countsDown: true))
    case .copy(let text):
      Text(text)
        .font(.footnote)
        .foregroundStyle(.tertiary)
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

  private var accessibilityText: String {
    var parts = [QuotaFormat.remainingAccessibility(window)]
    if let reset = window.resetsAt.flatMap({ QuotaFormat.resetTime($0) }) {
      parts.append(reset)
    }
    if let stateLabel {
      parts.append(stateLabel)
    }
    return parts.joined(separator: ", ")
  }
}
