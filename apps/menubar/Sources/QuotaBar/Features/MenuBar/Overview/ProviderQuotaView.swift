import QuotaPresentation
import QuotaWire
import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation
  let now: Date
  let onOpenProvider: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Button(action: onOpenProvider) {
        providerHeader
          .padding(.horizontal, QuotaDesign.Spacing.sm)
          .frame(
            maxWidth: .infinity,
            minHeight: QuotaDesign.Layout.minimumInteractiveDimension,
            alignment: .leading
          )
          .contentShape(Rectangle())
      }
      .padding(.horizontal, -QuotaDesign.Spacing.sm)
      .buttonStyle(QuotaListRowButtonStyle(surfaceInset: 0))
      .accessibilityLabel(headerAccessibilityLabel)
      .accessibilityHint("Opens \(presentation.provider.displayName) settings")

      if let detail = presentation.status?.detail {
        Text(detail)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(presentation.status?.accessibilityLabel ?? detail)
      }

      ForEach(Array(presentation.accounts.enumerated()), id: \.element.id) { index, account in
        AccountQuotaView(presentation: account, accountIndex: index, now: now)

        if index < presentation.accounts.count - 1 {
          Divider()
            .opacity(0.45)
            .padding(.vertical, 2)
        }
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
  }

  private var headerAccessibilityLabel: String {
    if let title = presentation.status?.title {
      "\(presentation.provider.displayName). \(title)"
    } else {
      presentation.provider.displayName
    }
  }

  private var providerHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.inline) {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
          .quotaRowTitleStyle()
      }
      .layoutPriority(1)

      if let title = presentation.status?.title {
        Text(title)
          .quotaMetaStyle()
          .lineLimit(1)
          .fixedSize()
          .accessibilityHidden(true)
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .quotaChevronStyle()
        .accessibilityHidden(true)
    }
  }
}

extension AccountQuotaPresentation {
  fileprivate var planDisplayName: String? {
    PlanDisplay.planBadge(snapshot.account.plan)
  }

  fileprivate var accountLabelDisplay: String? {
    PlanDisplay.accountLabel(snapshot.account.label)
  }
}

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.iconLabel) {
      accountHeader

      ForEach(presentation.snapshot.windows) { window in
        QuotaWindowRow(
          window: window,
          provider: presentation.snapshot.provider,
          isStale: presentation.state != .available,
          now: now
        )
      }
    }
  }

  private var accountHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.iconLabel) {
      Text(presentation.accountLabelDisplay ?? "Account \(accountIndex + 1)")
        .quotaFont(.quotaLabel)
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
        .accessibilityLabel(
          presentation.accessibilityLabel(accountIndex: accountIndex, now: now)
        )

      Spacer(minLength: 8)

      if let plan = presentation.planDisplayName {
        Text(plan)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(1)
          .fixedSize()
          .accessibilityLabel("Plan: \(plan)")
      }
    }
  }
}

struct QuotaWindowRow: View {
  let window: QuotaWindow
  let provider: ProviderID
  let isStale: Bool
  let now: Date

  private var remainingLabel: String {
    window.overviewRemainingDisplayLabel(provider: provider)
  }

  private var meterColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  private var valueColor: Color {
    isStale ? QuotaPalette.mute : QuotaPalette.ink
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.inline) {
        Text(window.displayTitle)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
        Spacer(minLength: 8)
        Text(remainingLabel)
          .quotaFont(.remainingValue)
          .monospacedDigit()
          .foregroundStyle(valueColor)
          .accessibilityLabel(remainingLabel)
      }

      if window.showsPercentMeter {
        QuotaProgressBar(value: window.remainingPercent, fill: meterColor)
      }

      if let resetsAt = window.resetsAt,
        let reset = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now)
      {
        Text(reset)
          .quotaMetaStyle()
      } else if window.resetsAt == nil, FreshnessCopy.showsNoResetTime(window) {
        Text(FreshnessCopy.noResetTime)
          .quotaMetaStyle()
      }
    }
    .padding(.top, 2)
  }
}

private struct QuotaProgressBar: View {
  let value: Double
  let fill: Color

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(QuotaPalette.progressTrack)
        Capsule()
          .fill(fill)
          .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
      }
    }
    .frame(height: QuotaDesign.Layout.progressHeight)
    .accessibilityLabel("Remaining quota")
    .accessibilityValue(QuotaWindow.formattedPercent(value))
  }
}
