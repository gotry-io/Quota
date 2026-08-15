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

      ForEach(Array(model.observations.enumerated()), id: \.offset) { index, observation in
        if index > 0 {
          Divider()
        }
        observationBlock(observation.snapshot, index: index)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
  }

  private func observationBlock(_ snapshot: QuotaSnapshot, index: Int) -> some View {
    let label = PlanDisplay.accountLabel(snapshot.account.label) ?? "Account \(index + 1)"
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel("Account: \(label)")
        Spacer(minLength: 8)
        if let plan = QuotaFormat.planBadge(snapshot.account.plan) {
          Text(plan)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(QuotaTheme.meterTrack, in: Capsule())
            .accessibilityLabel("Plan: \(plan)")
        }
      }

      if snapshot.windows.isEmpty {
        Text("No quota windows reported.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.windows) { window in
          QuotaWindowBlock(window: window, isStale: snapshot.status == .stale)
        }
      }
    }
  }
}

struct QuotaWindowBlock: View {
  let window: QuotaWindow
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(QuotaFormat.windowTitle(window))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Text(QuotaFormat.remaining(window))
        .font(.title2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)

      if !window.isBalanceOnly {
        ProgressView(value: QuotaFormat.remainingPercent(window), total: 100)
          .tint(QuotaTheme.emerald)
          .accessibilityHidden(true)
      }

      if let resets = window.resetsAt {
        Text("Resets \(QuotaFormat.resetTime(resets))")
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      } else if isStale {
        Text("Stale")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var accessibilityText: String {
    var parts = [QuotaFormat.remainingAccessibility(window)]
    if let resets = window.resetsAt {
      parts.append("Resets \(QuotaFormat.resetTime(resets))")
    }
    if isStale {
      parts.append("Stale")
    }
    return parts.joined(separator: ", ")
  }
}
