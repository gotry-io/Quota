import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation
  let now: Date
  @State private var isHovered = false

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
        AccountQuotaView(
          presentation: account,
          accountIndex: index,
          now: now,
          emphasizesMetadata: isHovered
        )

        if index < presentation.accounts.count - 1 {
          Divider()
            .opacity(0.45)
            .padding(.vertical, 2)
        }
      }

      if presentation.accounts.isEmpty, presentation.status != nil {
        SourceLabel(
          symbolName: "laptopcomputer",
          displayName: "This Mac",
          accessibilityLabel: "Source: This Mac"
        )
        .foregroundStyle(isHovered ? QuotaPalette.body : QuotaPalette.mute)
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.1)) {
        isHovered = hovering
      }
    }
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
  let emphasizesMetadata: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.iconLabel) {
      accountHeader

      ForEach(presentation.snapshot.windows) { window in
        QuotaWindowRow(window: window, isStale: presentation.isStale)
      }

      accountFooter
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
          presentation.accountLabelDisplay.map { "Account: \($0)" }
            ?? "Account \(accountIndex + 1)"
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

  private var accountFooter: some View {
    HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.iconLabel) {
      SourceLabel(
        symbolName: presentation.sourceSymbolName,
        displayName: presentation.selectedSourceDisplayName,
        accessibilityLabel: presentation.sourceAccessibilityLabel
      )

      Spacer(minLength: 8)

      Text(observationLabel)
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel(observationAccessibilityLabel)
    }
    .quotaFont(.meta)
    .foregroundStyle(emphasizesMetadata ? QuotaPalette.body : QuotaPalette.mute)
  }

  private var observationLabel: String {
    presentation.isStale ? "Stale · \(observedAge) ago" : "\(observedAge) ago"
  }

  private var observationAccessibilityLabel: String {
    let observed = presentation.snapshot.observedAt.formatted(.relative(presentation: .named))
    return presentation.isStale ? "Stale data. Observed \(observed)" : "Observed \(observed)"
  }

  private var observedAge: String {
    CompactAgeFormatter.string(since: presentation.snapshot.observedAt, now: now)
  }
}

enum CompactAgeFormatter {
  static func string(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)min" }
    if seconds < 86_400 { return "\(seconds / 3_600)h" }
    if seconds < 604_800 { return "\(seconds / 86_400)d" }
    if seconds < 31_536_000 { return "\(seconds / 604_800)w" }
    return "\(seconds / 31_536_000)y"
  }
}

private struct QuotaWindowRow: View {
  let window: QuotaWindow
  let isStale: Bool

  private var meterColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  private var valueColor: Color {
    isStale ? QuotaPalette.mute : QuotaPalette.ink
  }

  private var remainingLabel: String {
    if let absolute = window.absoluteRemainingLabel {
      return absolute
    }
    return "\(percent(window.remainingPercent)) left"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.inline) {
        Text(window.title)
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
        Text("Resets \(formatResetDate(resetsAt))")
          .quotaMetaStyle()
      } else if window.showsPercentMeter {
        Text("Reset time unavailable")
          .quotaMetaStyle()
      }
    }
    .padding(.top, 2)
  }
}

/// Selected-source provenance: icon + device name. No tooltip (name is visible).
private struct SourceLabel: View {
  let symbolName: String
  let displayName: String
  let accessibilityLabel: String

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbolName)
        .symbolRenderingMode(.monochrome)
      Text(displayName)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .quotaFont(.meta)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
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
    .accessibilityValue(percent(value))
  }
}

private func percent(_ value: Double) -> String {
  if abs(value.rounded() - value) < 0.05 {
    return "\(Int(value.rounded()))%"
  }
  return String(format: "%.1f%%", value)
}

private func formatResetDate(_ date: Date) -> String {
  date.formatted(
    .dateTime
      .weekday(.abbreviated)
      .hour()
      .minute()
  )
}
