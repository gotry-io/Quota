import SwiftUI

struct ProviderQuotaView: View {
  let presentation: ProviderQuotaPresentation

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
          showsAccountStatus: presentation.accounts.count > 1
        )

        if index < presentation.accounts.count - 1 {
          Divider()
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
      }
      .quotaRowTitleStyle()

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

private struct AccountQuotaView: View {
  let presentation: AccountQuotaPresentation
  let accountIndex: Int
  let showsAccountStatus: Bool

  private var snapshot: QuotaSnapshot { presentation.snapshot }

  private var identitySummary: String? {
    PlanDisplay.accountSummary(
      plan: snapshot.account.plan,
      label: snapshot.account.label
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.iconLabel) {
      if showsAccountMetadata {
        accountHeader
      }

      ForEach(snapshot.windows) { window in
        QuotaWindowRow(
          window: window,
          observedAt: snapshot.observedAt,
          isStale: presentation.isStale
        )
      }
    }
  }

  private var showsAccountMetadata: Bool {
    if showsAccountStatus {
      return true
    }
    return identitySummary != nil
  }

  private var accountHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.iconLabel) {
      if let identitySummary {
        Text(identitySummary)
          .font(QuotaDesign.Typography.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel(accessibilityIdentityLabel)
      } else if showsAccountStatus {
        Text("Account \(accountIndex + 1)")
          .quotaSecondaryStyle()
      }

      if showsAccountStatus, presentation.isStale {
        QuotaStatusTag(text: "Stale", systemImage: "clock")
      }

      Spacer(minLength: 8)

      if showsAccountStatus {
        SourceBadge(
          symbolName: presentation.sourceSymbolName,
          tooltip: presentation.sourceTooltip,
          accessibilityLabel: presentation.sourceAccessibilityLabel
        )
      }
    }
  }

  private var accessibilityIdentityLabel: String {
    let plan = PlanDisplay.planBadge(snapshot.account.plan)
    let label = PlanDisplay.accountLabel(snapshot.account.label)
    switch (plan, label) {
    case let (plan?, label?):
      return "Plan: \(plan), Account: \(label)"
    case let (plan?, nil):
      return "Plan: \(plan)"
    case let (nil, label?):
      return "Account: \(label)"
    case (nil, nil):
      return "Account"
    }
  }
}

private struct QuotaWindowRow: View {
  let window: QuotaWindow
  let observedAt: Date
  let isStale: Bool

  private var usageColor: Color {
    let color = QuotaPalette.usageColor(remainingPercent: window.remainingPercent)
    return isStale ? color.opacity(0.55) : color
  }

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.meta) {
      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.inline) {
        Text(window.title)
          .font(QuotaDesign.Typography.quotaLabel)
          .foregroundStyle(QuotaPalette.body)
        Spacer(minLength: 8)
        Text(percent(window.remainingPercent))
          .font(QuotaDesign.Typography.remainingValue)
          .monospacedDigit()
          .foregroundStyle(usageColor)
          .accessibilityLabel("\(percent(window.remainingPercent)) left")
      }

      QuotaProgressBar(value: window.remainingPercent, fill: usageColor)

      HStack(alignment: .firstTextBaseline, spacing: QuotaDesign.Spacing.inline) {
        if let resetsAt = window.resetsAt {
          Text("Resets \(formatResetDate(resetsAt))")
        } else {
          Text("Reset time unavailable")
        }

        if isStale {
          Text("· Observed \(observedAt, style: .relative) ago")
        }
      }
      .quotaMetaStyle()
      .lineLimit(1)
    }
    .padding(.top, 2)
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
      .font(QuotaDesign.Typography.metaMedium)
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

private let resetDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale.current
  formatter.timeZone = .current
  // Compact absolute time: keeps second precision without a long gray line.
  formatter.dateFormat = "MM-dd HH:mm:ss"
  return formatter
}()

private func formatResetDate(_ date: Date) -> String {
  resetDateFormatter.string(from: date)
}
