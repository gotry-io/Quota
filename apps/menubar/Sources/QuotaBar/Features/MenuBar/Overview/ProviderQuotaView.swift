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
          showsAccountHeader: presentation.accounts.count > 1
        )

        if index < presentation.accounts.count - 1 {
          Divider()
            .padding(.vertical, 2)
        }
      }

      // Source (+ observation age when present): hover-only under the provider block.
      // Multi-account also keeps source on each account header (per selected snapshot).
      if isHovered, showsHoverMeta {
        HStack(alignment: .center, spacing: QuotaDesign.Spacing.iconLabel) {
          if let source = hoverProvenanceAccount {
            SourceLabel(
              symbolName: source.sourceSymbolName,
              displayName: source.selectedSourceDisplayName,
              accessibilityLabel: source.sourceAccessibilityLabel
            )
          } else if presentation.accounts.isEmpty, presentation.status != nil {
            SourceLabel(
              symbolName: "laptopcomputer",
              displayName: "This Mac",
              accessibilityLabel: "Source: This Mac"
            )
          }

          Spacer(minLength: 0)

          if let observedAt = presentation.latestObservedAt {
            Text("Observed \(observedAt, style: .relative) ago")
              .quotaMetaStyle()
              .accessibilityHidden(true)
          }
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
    .accessibilityValue(accessibilityObservedValue)
  }

  private var showsHoverMeta: Bool {
    presentation.latestObservedAt != nil
      || hoverProvenanceAccount != nil
      || (presentation.accounts.isEmpty && presentation.status != nil)
  }

  /// Newest observed account for provider-level hover source (single-account default).
  private var hoverProvenanceAccount: AccountQuotaPresentation? {
    guard !presentation.accounts.isEmpty else { return nil }
    guard let latest = presentation.latestObservedAt else {
      return presentation.accounts.first
    }
    return presentation.accounts.first { $0.snapshot.observedAt == latest }
      ?? presentation.accounts.first
  }

  private var accessibilityObservedValue: String {
    var parts: [String] = []
    if let source = hoverProvenanceAccount {
      parts.append(source.sourceAccessibilityLabel)
    } else if presentation.accounts.isEmpty, presentation.status != nil {
      parts.append("Source: This Mac")
    }
    if let observedAt = presentation.latestObservedAt {
      parts.append("Observed \(observedAt.formatted(.relative(presentation: .named)))")
    }
    return parts.joined(separator: ". ")
  }

  private var providerHeader: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.inline) {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        ProviderBrandIcon(provider: presentation.provider)
        Text(presentation.provider.displayName)
          .quotaRowTitleStyle()

        // Plan after name only; account id is trailing (not combined with plan).
        if presentation.accounts.count == 1,
          let plan = presentation.accounts.first?.planDisplayName
        {
          Text(plan)
            .quotaFont(.quotaLabel)
            .foregroundStyle(QuotaPalette.mute)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Plan: \(plan)")
        }
      }
      .layoutPriority(1)

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
        let account = presentation.accounts.first,
        let label = account.accountLabelDisplay
      {
        Text(label)
          .quotaFont(.quotaLabel)
          .foregroundStyle(QuotaPalette.mute)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(0)
          .accessibilityLabel("Account: \(label)")
      }
    }
  }
}

private extension AccountQuotaPresentation {
  var planDisplayName: String? {
    PlanDisplay.planBadge(snapshot.account.plan)
  }

  var accountLabelDisplay: String? {
    PlanDisplay.accountLabel(snapshot.account.label)
  }

  var identitySummary: String? {
    PlanDisplay.accountSummary(plan: snapshot.account.plan, label: snapshot.account.label)
  }

  var accessibilityIdentityLabel: String {
    let plan = planDisplayName
    let label = accountLabelDisplay
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
    // Multi-account: identity + per-account source (provider hover only shows newest).
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.iconLabel) {
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

      SourceLabel(
        symbolName: presentation.sourceSymbolName,
        displayName: presentation.selectedSourceDisplayName,
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
        .quotaFont(.metaMedium)
        .symbolRenderingMode(.monochrome)
      Text(displayName)
        .quotaMetaStyle()
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundStyle(QuotaPalette.mute)
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
