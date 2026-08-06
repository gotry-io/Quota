import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation
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
          // Single-account identity lives on the provider title line; multi-account keeps a row.
          showsAccountHeader: presentation.accounts.count > 1
        )

        if index < presentation.accounts.count - 1 {
          Divider()
            .padding(.vertical, 2)
        }
      }

      // Provider-level observation time (same for all windows in one report).
      // Hover-only chrome; VoiceOver always gets the value via accessibility.
      if isHovered, let observedAt = presentation.latestObservedAt {
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Text("Observed \(observedAt, style: .relative) ago")
            .quotaMetaStyle()
            .accessibilityHidden(true)
        }
        .padding(.top, 2)
        .transition(.opacity)
      }
    }
    .padding(.vertical, QuotaDesign.Layout.providerRowVerticalPadding)
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(
      presentation.latestObservedAt.map { "Observed \($0.formatted(.relative(presentation: .named)))" }
        ?? ""
    )
  }

  private var providerHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.inline) {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
      }
      .quotaRowTitleStyle()
      .layoutPriority(1)

      // Single-account plan + masked label sit on the title line (not a second row).
      if presentation.accounts.count == 1,
        let account = presentation.accounts.first,
        let identity = account.identitySummary
      {
        Text(identity)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.mute)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(0)
          .accessibilityLabel(account.accessibilityIdentityLabel)
      }

      // Status sits with the provider name. Never replace trailing Local/Remote —
      // provenance answers "where from", status answers "what's wrong".
      if let status = presentation.status {
        Text(status.title)
          .quotaMetaStyle()
          .lineLimit(1)
          .fixedSize()
          .accessibilityHidden(true)
      } else if presentation.accounts.count == 1,
        presentation.accounts.first?.isStale == true
      {
        QuotaStatusTag(text: "Stale", systemImage: "clock")
      }

      Spacer(minLength: 8)

      if presentation.accounts.count == 1,
        let account = presentation.accounts.first
      {
        SourceBadge(
          symbolName: account.sourceSymbolName,
          tooltip: account.sourceTooltip,
          accessibilityLabel: account.sourceAccessibilityLabel
        )
      } else if presentation.accounts.isEmpty, presentation.status != nil {
        // Issue-only local row: collection context is local.
        SourceBadge(
          symbolName: "laptopcomputer",
          tooltip: "This Mac",
          accessibilityLabel: "Source: This Mac"
        )
      }
    }
  }
}

private extension AccountQuotaPresentation {
  var identitySummary: String? {
    PlanDisplay.accountSummary(plan: snapshot.account.plan, label: snapshot.account.label)
  }

  var accessibilityIdentityLabel: String {
    let plan = PlanDisplay.planBadge(snapshot.account.plan)
    let label = PlanDisplay.accountLabel(snapshot.account.label)
    switch (plan, label) {
    case let (plan?, label?): return "Plan: \(plan), Account: \(label)"
    case let (plan?, nil): return "Plan: \(plan)"
    case let (nil, label?): return "Account: \(label)"
    case (nil, nil): return "Account"
    }
  }
}

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  /// Multi-account only; single-account identity is on the provider title line.
  let showsAccountHeader: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.iconLabel) {
      if showsAccountHeader {
        accountHeader
      }

      ForEach(presentation.snapshot.windows) { window in
        QuotaWindowRow(window: window, isStale: presentation.isStale)
      }
    }
  }

  private var accountHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.iconLabel) {
      if let identity = presentation.identitySummary {
        Text(identity)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel(presentation.accessibilityIdentityLabel)
      } else {
        Text("Account \(accountIndex + 1)")
          .quotaSecondaryStyle()
      }

      if presentation.isStale {
        QuotaStatusTag(text: "Stale", systemImage: "clock")
      }

      Spacer(minLength: 8)

      SourceBadge(
        symbolName: presentation.sourceSymbolName,
        tooltip: presentation.sourceTooltip,
        accessibilityLabel: presentation.sourceAccessibilityLabel
      )
    }
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

  /// Prefer absolute remaining when protocol provides value_unit + remaining_value.
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

      QuotaProgressBar(value: window.remainingPercent, fill: meterColor)

      // Window meta is reset timing only. Observation time is provider-level (hover).
      resetText
        .quotaMetaStyle()
    }
    .padding(.top, 2)
  }

  private var resetText: Text {
    if let resetsAt = window.resetsAt {
      Text("Resets \(formatResetDate(resetsAt))")
    } else {
      Text("Reset time unavailable")
    }
  }
}

/// Selected-source provenance only. Matches SubscriptionResolver's chosen snapshot —
/// never a multi-source blend.
private struct SourceBadge: View {
  let symbolName: String
  let tooltip: String
  let accessibilityLabel: String

  var body: some View {
    Image(systemName: symbolName)
      .quotaFont(.metaMedium)
      .foregroundStyle(QuotaPalette.mute)
      .symbolRenderingMode(.monochrome)
      .help(tooltip)
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
  // Locale-appropriate weekday + time, no seconds (e.g. "Sat, 12:51 PM").
  date.formatted(
    .dateTime
      .weekday(.abbreviated)
      .hour()
      .minute()
  )
}
