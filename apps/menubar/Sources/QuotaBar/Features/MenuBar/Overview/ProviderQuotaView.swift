import QuotaPresentation
import QuotaWire
import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      providerHeader

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
    .accessibilityElement(children: .combine)
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
          isStale: presentation.state != .available
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

private struct QuotaWindowRow: View {
  let window: QuotaWindow
  let provider: ProviderID
  let isStale: Bool

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

      if let resetsAt = window.resetsAt {
        Text("Resets \(ResetDateFormatter.string(from: resetsAt))")
          .quotaMetaStyle()
      } else if window.showsPercentMeter {
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

enum ResetDateFormatter {
  /// Near resets keep weekday + time (5-hour / weekly windows). Monthly horizons use month + day.
  static func string(
    from date: Date,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: now),
      to: calendar.startOfDay(for: date)
    ).day ?? 0
    let style = Date.FormatStyle(
      date: .omitted,
      time: .omitted,
      locale: locale,
      calendar: calendar,
      timeZone: calendar.timeZone
    )
    if abs(days) <= 6 {
      return date.formatted(style.weekday(.abbreviated).hour().minute())
    }
    if calendar.component(.year, from: now) == calendar.component(.year, from: date) {
      return date.formatted(style.month(.abbreviated).day())
    }
    return date.formatted(style.month(.abbreviated).day().year())
  }
}
